<#
.SYNOPSIS
  Targeted caseId backfill: walks every page of every active category's
  listing, extracts every (auctionId, caseId) pair via SetAuctionData calls,
  and updates auctions.json for any row missing caseId. No detail-page
  fetches — pure listing-page paginated walk.
#>
[CmdletBinding()]
param(
  [int]$MaxPagesPerCategory = 200,
  [int]$DelayMs = 800
)

$ErrorActionPreference = 'Continue'
$CurlExe   = 'C:\Windows\System32\curl.exe'
$Base      = 'https://auctions.moj.gov.jo'
$UserAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36'
$Root      = $PSScriptRoot
$CookieJar = Join-Path $Root 'cookies_backfill.txt'
$JsonPath  = Join-Path $Root 'auctions.json'
$JsPath    = Join-Path $Root 'auctions.js'

if (Test-Path $CookieJar) { Remove-Item $CookieJar -Force }

function Curl-Get([string]$url) {
  $tmp = [System.IO.Path]::GetTempFileName()
  try {
    & $CurlExe --silent --insecure --location --compressed --user-agent $UserAgent `
      --header 'Accept: text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8' `
      --header 'Accept-Language: ar,en;q=0.8' `
      --cookie-jar $CookieJar --cookie $CookieJar --output $tmp $url | Out-Null
    if ($LASTEXITCODE -ne 0) { return $null }
    return [System.IO.File]::ReadAllText($tmp, [System.Text.UTF8Encoding]::new($false))
  } finally { if (Test-Path $tmp) { Remove-Item $tmp -Force } }
}

function Curl-PostForm([string]$url, [hashtable]$form, [string]$referer) {
  $bodyFile = [System.IO.Path]::GetTempFileName()
  $outFile  = [System.IO.Path]::GetTempFileName()
  try {
    $sb = New-Object System.Text.StringBuilder
    $first = $true
    foreach ($k in $form.Keys) {
      if (-not $first) { [void]$sb.Append('&') }
      [void]$sb.Append([System.Uri]::EscapeDataString($k))
      [void]$sb.Append('=')
      [void]$sb.Append([System.Uri]::EscapeDataString([string]$form[$k]))
      $first = $false
    }
    [System.IO.File]::WriteAllText($bodyFile, $sb.ToString(), [System.Text.UTF8Encoding]::new($false))
    & $CurlExe --silent --insecure --location --compressed --user-agent $UserAgent `
      --header 'Accept: text/html' `
      --header 'Content-Type: application/x-www-form-urlencoded' `
      --header ("Referer: " + $referer) `
      --cookie-jar $CookieJar --cookie $CookieJar --data "@$bodyFile" --output $outFile $url | Out-Null
    if ($LASTEXITCODE -ne 0) { return $null }
    return [System.IO.File]::ReadAllText($outFile, [System.Text.UTF8Encoding]::new($false))
  } finally {
    if (Test-Path $bodyFile) { Remove-Item $bodyFile -Force }
    if (Test-Path $outFile)  { Remove-Item $outFile  -Force }
  }
}

function Get-FormFields([string]$html) {
  $vs  = [regex]::Match($html, 'name="__VIEWSTATE"\s+id="__VIEWSTATE"\s+value="([^"]*)"').Groups[1].Value
  $vsg = [regex]::Match($html, 'name="__VIEWSTATEGENERATOR"\s+id="__VIEWSTATEGENERATOR"\s+value="([^"]*)"').Groups[1].Value
  $ev  = [regex]::Match($html, 'name="__EVENTVALIDATION"\s+id="__EVENTVALIDATION"\s+value="([^"]*)"').Groups[1].Value
  @{ ViewState = $vs; ViewStateGenerator = $vsg; EventValidation = $ev }
}

function Extract-Pairs([string]$html) {
  # The listing HTML has these inline calls per auction row:
  #    SetCurrentAuctionID(50878);SetAuctionData(15377773,);
  # We extract the (auctionId, caseId) pair from each.
  $rx = [regex]'SetCurrentAuctionID\((\d+)\)\s*;\s*SetAuctionData\(\s*(\d+)\s*,'
  $pairs = @{}
  foreach ($m in $rx.Matches($html)) {
    $aid = [int]$m.Groups[1].Value
    $cid = [int]$m.Groups[2].Value
    if (-not $pairs.ContainsKey($aid)) { $pairs[$aid] = $cid }
  }
  return $pairs
}

Write-Host "Loading auctions.json..." -ForegroundColor Cyan
$data = Get-Content $JsonPath -Raw -Encoding UTF8 | ConvertFrom-Json

# Index auctions by id for fast lookup
$byId = @{}
foreach ($a in $data.auctions) { $byId[[int]$a.id] = $a }

# Build category-token map
$cats = $data.categories
"Categories: $($cats.Count)"

# Warm session
[void](Curl-Get "$Base/index.aspx")

$totalBackfilled = 0
$totalPairsSeen  = 0

foreach ($cat in $cats) {
  $catName = $cat.name
  $tok = $cat.token
  Write-Host ""
  Write-Host "===== Category: $catName =====" -ForegroundColor Yellow

  $listUrl = "$Base/AuctionsList.aspx?token=$tok"
  $html = Curl-Get $listUrl
  if (-not $html -or $html.Length -lt 5000) {
    Write-Host "  failed to load listing (size=$($html.Length))" -ForegroundColor Red
    continue
  }

  $page = 1
  $catBackfilled = 0
  $consecutiveEmpty = 0

  while ($page -le $MaxPagesPerCategory) {
    $pairs = Extract-Pairs $html
    $itemsOnPage = $pairs.Count
    $totalPairsSeen += $itemsOnPage

    # Apply backfill for this page
    $pageBackfilled = 0
    foreach ($aid in $pairs.Keys) {
      $cid = $pairs[$aid]
      if ($cid -le 0) { continue }
      if (-not $byId.ContainsKey($aid)) { continue }
      $rec = $byId[$aid]
      $hasCid = $rec.PSObject.Properties.Match('caseId').Count -and $rec.caseId -gt 0
      if (-not $hasCid) {
        if ($rec.PSObject.Properties.Match('caseId').Count) {
          $rec.caseId = $cid
        } else {
          $rec | Add-Member -MemberType NoteProperty -Name 'caseId' -Value $cid -Force
        }
        $catBackfilled++
        $totalBackfilled++
        $pageBackfilled++
      }
    }

    Write-Host ("  page {0,3}: {1,2} items, {2,2} caseIds backfilled (total this cat: {3})" -f $page, $itemsOnPage, $pageBackfilled, $catBackfilled)

    if ($itemsOnPage -eq 0) {
      $consecutiveEmpty++
      if ($consecutiveEmpty -ge 3) { Write-Host "  no items on 3 pages, end of listing" -ForegroundColor DarkGray; break }
    } else {
      $consecutiveEmpty = 0
    }

    # Save after each page (cheap insurance)
    if ($pageBackfilled -gt 0) {
      $json = $data | ConvertTo-Json -Depth 12
      [System.IO.File]::WriteAllText($JsonPath, $json, [System.Text.UTF8Encoding]::new($false))
      [System.IO.File]::WriteAllText($JsPath, "window.AUCTION_DATA = $json;", [System.Text.UTF8Encoding]::new($false))
    }

    # Check if there's a "next page" button at all
    if ($html -notmatch 'id="cph_Base_lbNext"\s+class="page-link lnkPN"\s+href="javascript:__doPostBack') {
      Write-Host "  no more pages" -ForegroundColor DarkGray
      break
    }

    Start-Sleep -Milliseconds $DelayMs
    $f = Get-FormFields $html
    $nextPage = $page + 1
    $body = @{
      '__EVENTTARGET'        = 'ctl00$cph_Base$lbNext'
      '__EVENTARGUMENT'      = ''
      '__VIEWSTATE'          = $f.ViewState
      '__VIEWSTATEGENERATOR' = $f.ViewStateGenerator
      '__EVENTVALIDATION'    = $f.EventValidation
      '__SCROLLPOSITIONX'    = '0'
      '__SCROLLPOSITIONY'    = '0'
      'ctl00$cph_Base$hdnCurrentAuctionID'         = '-1'
      'ctl00$cph_Base$hdnCaseId'                   = '-1'
      'ctl00$cph_Base$hdnUserIdAuctionStatus'      = '-1'
    }
    $nextHtml = Curl-PostForm $listUrl $body $listUrl
    if (-not $nextHtml -or $nextHtml.Length -lt 5000) {
      Write-Host "  next-page postback failed (size=$($nextHtml.Length)), stopping this category" -ForegroundColor DarkYellow
      break
    }

    # Detect if we got the same page back (no progress)
    $nextPairs = Extract-Pairs $nextHtml
    $samePage = $true
    foreach ($k in $pairs.Keys) { if (-not $nextPairs.ContainsKey($k)) { $samePage = $false; break } }
    if ($samePage -and $nextPairs.Count -eq $pairs.Count) {
      Write-Host "  next page returned identical items, end of pager" -ForegroundColor DarkGray
      break
    }

    $html = $nextHtml
    $page = $nextPage
  }

  Write-Host ("  Category {0}: backfilled {1} caseIds across {2} pages" -f $catName, $catBackfilled, $page) -ForegroundColor Green
}

# Final save
$json = $data | ConvertTo-Json -Depth 12
[System.IO.File]::WriteAllText($JsonPath, $json, [System.Text.UTF8Encoding]::new($false))
[System.IO.File]::WriteAllText($JsPath, "window.AUCTION_DATA = $json;", [System.Text.UTF8Encoding]::new($false))

""
"--- Summary ---"
"  total (auctionId, caseId) pairs harvested across all pages: $totalPairsSeen"
"  total auctions newly backfilled with caseId:                $totalBackfilled"
