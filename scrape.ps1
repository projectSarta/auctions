<#
.SYNOPSIS
  Scrape Jordan MoJ auctions (auctions.moj.gov.jo) into auctions.json + auctions.js.

.DESCRIPTION
  Walks all 5 category tabs from index.aspx, paginates each via ASP.NET
  __doPostBack on lbNext while preserving ViewState/EventValidation, parses
  each auction-div block into structured fields, and writes the combined data
  INCREMENTALLY (after every page that yields new items) so the dashboard
  always has fresh data to load.

.PARAMETER MaxPagesPerCategory
  Limit pages per category (10 items per page). Default 3. Use 0 for unlimited.

.PARAMETER Full
  Equivalent to -MaxPagesPerCategory 0 (scrape everything).

.EXAMPLE
  ./scrape.ps1                    # quick scrape (~150 items)
  ./scrape.ps1 -Full              # full scrape (~2400 items, slow)
  ./scrape.ps1 -MaxPagesPerCategory 10
#>
[CmdletBinding()]
param(
  [int]$MaxPagesPerCategory = 3,
  [switch]$Full,
  [int]$DelayMs = 3000,
  [int]$CaptchaCooldownSec = 90,
  [int]$MaxCaptchaWaits = 6,
  [int]$MaxResetsPerCategory = 30,   # max session resets per category
  [int]$MaxKnownPages = 15,          # cap pages walked through already-seen territory before resetting
  [int]$MaxMinutes = 0,              # global time budget (0 = unlimited)
  [switch]$Fresh,                    # ignore existing auctions.json (don't merge)
  [string]$OnlyCategory = ''         # if set, only scrape categories matching this regex (e.g. 'مركبة')
)

if ($Full) { $MaxPagesPerCategory = 0 }
$ScriptStart = Get-Date

$ErrorActionPreference = 'Stop'

$CurlExe   = 'C:\Windows\System32\curl.exe'
$Base      = 'https://auctions.moj.gov.jo'
$UserAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36'
$CookieJar = Join-Path $PSScriptRoot 'cookies.txt'
if (Test-Path $CookieJar) { Remove-Item $CookieJar -Force }

function Curl-Get([string]$url) {
  $tmp = [System.IO.Path]::GetTempFileName()
  try {
    & $CurlExe --silent --insecure --location --compressed `
      --user-agent $UserAgent `
      --header 'Accept: text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8' `
      --header 'Accept-Language: ar,en;q=0.8' `
      --cookie-jar $CookieJar --cookie $CookieJar `
      --output $tmp `
      $url | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "curl GET failed (exit $LASTEXITCODE) for $url" }
    return [System.IO.File]::ReadAllText($tmp, [System.Text.UTF8Encoding]::new($false))
  } finally {
    if (Test-Path $tmp) { Remove-Item $tmp -Force }
  }
}

function Curl-PostForm([string]$url, [hashtable]$form) {
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

    & $CurlExe --silent --insecure --location --compressed `
      --user-agent $UserAgent `
      --header 'Accept: text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8' `
      --header 'Accept-Language: ar,en;q=0.8' `
      --header 'Content-Type: application/x-www-form-urlencoded' `
      --cookie-jar $CookieJar --cookie $CookieJar `
      --data "@$bodyFile" `
      --output $outFile `
      $url | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "curl POST failed (exit $LASTEXITCODE) for $url" }
    return [System.IO.File]::ReadAllText($outFile, [System.Text.UTF8Encoding]::new($false))
  } finally {
    if (Test-Path $bodyFile) { Remove-Item $bodyFile -Force }
    if (Test-Path $outFile)  { Remove-Item $outFile  -Force }
  }
}

function Test-Captcha([string]$html) {
  if ($null -eq $html) { return $true }
  if ($html.Length -lt 5000) { return $true }
  if ($html.Contains('Validation request') -or $html.Contains('captcha_resp')) { return $true }
  return $false
}

function Wait-PastCaptcha([string]$probeUrl) {
  for ($i = 1; $i -le $MaxCaptchaWaits; $i++) {
    Write-Host ("    [captcha] cooldown {0}s (attempt {1}/{2})" -f $CaptchaCooldownSec, $i, $MaxCaptchaWaits) -ForegroundColor Yellow
    Start-Sleep -Seconds $CaptchaCooldownSec
    try {
      $h = Curl-Get $probeUrl
      if (-not (Test-Captcha $h)) { return $h }
    } catch { }
  }
  return $null
}

function Reset-Session {
  if (Test-Path $CookieJar) { Remove-Item $CookieJar -Force }
  Start-Sleep -Seconds $CaptchaCooldownSec
  try { [void](Curl-Get "$Base/index.aspx") } catch { }
}

function Get-FormFields([string]$html) {
  $vs  = [regex]::Match($html, 'name="__VIEWSTATE"\s+id="__VIEWSTATE"\s+value="([^"]*)"').Groups[1].Value
  $vsg = [regex]::Match($html, 'name="__VIEWSTATEGENERATOR"\s+id="__VIEWSTATEGENERATOR"\s+value="([^"]*)"').Groups[1].Value
  $ev  = [regex]::Match($html, 'name="__EVENTVALIDATION"\s+id="__EVENTVALIDATION"\s+value="([^"]*)"').Groups[1].Value
  @{ ViewState = $vs; ViewStateGenerator = $vsg; EventValidation = $ev }
}

function Clean-Text([string]$s) {
  if ($null -eq $s) { return '' }
  $s = [regex]::Replace($s, '<[^>]+>', ' ')
  $s = [System.Net.WebUtility]::HtmlDecode($s)
  $s = [regex]::Replace($s, '\s+', ' ')
  $s.Trim()
}

function Parse-Auctions([string]$html, [string]$category) {
  $parts = [regex]::Split($html, '<div class="row auction-div">')
  $out = New-Object System.Collections.ArrayList
  for ($i = 1; $i -lt $parts.Count; $i++) {
    $blk = $parts[$i]

    $idMatch = [regex]::Match($blk, 'AuctionEndDateFormated_(\d+)')
    if (-not $idMatch.Success) { continue }
    $id = $idMatch.Groups[1].Value

    $header = ''
    $hm = [regex]::Match($blk, 'col-xs-11 bold[^>]*>([\s\S]*?)</div>')
    if ($hm.Success) { $header = Clean-Text $hm.Groups[1].Value }

    $img = ''
    $im = [regex]::Match($blk, 'id="imgAuctionImage_' + $id + '"[^>]*src="([^"]+)"')
    if ($im.Success) {
      $imgPath = $im.Groups[1].Value
      if ($imgPath -ne '/Images/noimage.jpg') {
        if ($imgPath.StartsWith('/')) { $img = $Base + $imgPath } else { $img = $imgPath }
      }
    }

    $endDate = ''
    $em = [regex]::Match($blk, 'id="AuctionEndDateFormated_' + $id + '"[^>]*>([^<]*)</span>')
    if ($em.Success) { $endDate = $em.Groups[1].Value.Trim() }

    $numBids  = (([regex]::Match($blk, 'id="NumberOfBiddings_' + $id + '">([^<]*)')).Groups[1].Value).Trim()
    $startAmt = (([regex]::Match($blk, 'id="StartingAuctionAmount_' + $id + '">([^<]*)')).Groups[1].Value).Trim()
    $estVal   = (([regex]::Match($blk, 'id="intEstimatedValue_' + $id + '">([^<]*)')).Groups[1].Value).Trim()
    $highAmt  = (([regex]::Match($blk, 'id="HighestAuctionAmount_' + $id + '">([^<]*)')).Groups[1].Value).Trim()

    $notes = ''
    $nm = [regex]::Match($blk, 'المشروحات\s*:\s*</span>\s*<span[^>]*>\s*<strong>([\s\S]*?)</strong>')
    if ($nm.Success) { $notes = Clean-Text $nm.Groups[1].Value }

    $details = [ordered]@{}
    $rows = [regex]::Split($blk, '<div class="row div-seperator">')
    for ($r = 1; $r -lt $rows.Count; $r++) {
      $row = $rows[$r]
      $lbl = [regex]::Match($row, '<div class="col-xs-\d+ bold">([\s\S]*?)</div>')
      $val = [regex]::Match($row, '<div class="col-xs-\d+"(?:\s+[^>]*)?>([\s\S]*?)</div>')
      if ($lbl.Success -and $val.Success) {
        $label = Clean-Text $lbl.Groups[1].Value
        $value = Clean-Text $val.Groups[1].Value
        if ($label -and -not $details.Contains($label)) { $details[$label] = $value }
      }
    }

    [void]$out.Add([pscustomobject]@{
      id              = [int]$id
      category        = $category
      header          = $header
      court           = $details['المحكمة / الدائرة']
      caseNumber      = $details['رقم الدعوى']
      status          = $details['حالة المزاد']
      announcement    = $details['الإعلان']
      announcementStart = $details['تاريخ بداية الاعلان']
      announcementEnd = $details['تاريخ انتهاء الاعلان']
      startingAmount  = $startAmt
      estimatedValue  = $estVal
      currentAmount   = $highAmt
      minIncrement    = $details['الحد الأدنى لقيمة الزيادة']
      numBids         = $numBids
      newspaper       = $details['الصحيفة']
      newspaperIssue  = $details['العدد']
      publishedAt     = $details['تاريخ النشر']
      endDate         = $endDate
      image           = $img
      notes           = $notes
      sourceUrl       = "$Base/AuctionInfo.aspx?token=$($script:CurrentToken)&auction=$id"
      details         = $details
    })
  }
  ,$out
}

function Save-Progress($path, $jsPath, $payload) {
  $json = $payload | ConvertTo-Json -Depth 12
  [System.IO.File]::WriteAllText($path, $json, [System.Text.UTF8Encoding]::new($false))
  [System.IO.File]::WriteAllText($jsPath, "window.AUCTION_DATA = $json;", [System.Text.UTF8Encoding]::new($false))
}

# --- 1. Index → categories ---
Write-Host "Fetching index page..."
$idxHtml = Curl-Get "$Base/index.aspx"

$catRe = '<a href="AuctionsList\.aspx\?token=([^"]+)">[\s\S]*?<span>([^<]+)</span>\s*<br\s*/?>\s*<span>\s*\(\s*(\d+)\s*\)'
$catMatches = [regex]::Matches($idxHtml, $catRe)
$categories = @()
foreach ($m in $catMatches) {
  $categories += [pscustomobject]@{
    token      = $m.Groups[1].Value
    name       = ($m.Groups[2].Value).Trim()
    totalCount = [int]$m.Groups[3].Value
  }
}
Write-Host ("Found {0} categories:" -f $categories.Count)
$categories | ForEach-Object { Write-Host ("  - {0} ({1})" -f $_.name, $_.totalCount) }

# --- 2. Scrape each category ---
$all = New-Object System.Collections.ArrayList
$jsonPath = Join-Path $PSScriptRoot 'auctions.json'
$jsPath   = Join-Path $PSScriptRoot 'auctions.js'

# Pre-seed from existing data so reruns only ADD new auctions and never lose what we already have.
$existingByCat = @{}
if (-not $Fresh -and (Test-Path $jsonPath)) {
  try {
    $prev = Get-Content $jsonPath -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($a in $prev.auctions) {
      [void]$all.Add($a)
      if (-not $existingByCat.ContainsKey($a.category)) {
        $existingByCat[$a.category] = New-Object 'System.Collections.Generic.HashSet[int]'
      }
      [void]$existingByCat[$a.category].Add([int]$a.id)
    }
    Write-Host ("Pre-seeded with {0} existing auctions from auctions.json" -f $all.Count) -ForegroundColor DarkGray
  } catch {
    Write-Host ("Could not load existing auctions.json: {0}" -f $_.Exception.Message) -ForegroundColor Yellow
  }
}

function Save-All([bool]$inProgress = $true) {
  $payload = [pscustomobject]@{
    scrapedAt    = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    source       = "$Base/index.aspx"
    totalScraped = $all.Count
    pageLimit    = $MaxPagesPerCategory
    inProgress   = $inProgress
    categories   = $categories
    auctions     = $all
  }
  Save-Progress $jsonPath $jsPath $payload
}

foreach ($cat in $categories) {
  if ($OnlyCategory -and ($cat.name -notmatch $OnlyCategory)) {
    Write-Host ("Skipping category (filter): {0}" -f $cat.name) -ForegroundColor DarkGray
    continue
  }
  Write-Host ""
  Write-Host ("Scraping category: {0}  (target: {1})" -f $cat.name, $cat.totalCount) -ForegroundColor Cyan
  $catUrl = "$Base/AuctionsList.aspx?token=$($cat.token)"
  $script:CurrentToken = $cat.token
  $seen = New-Object 'System.Collections.Generic.HashSet[int]'
  if ($existingByCat.ContainsKey($cat.name)) {
    foreach ($id in $existingByCat[$cat.name]) { [void]$seen.Add($id) }
    Write-Host ("  pre-seeded {0} existing IDs for this category" -f $seen.Count) -ForegroundColor DarkGray
  }
  $resets = 0
  $zeroProgressWalks = 0

  :catLoop while ($true) {
    $html = Curl-Get $catUrl
    if (Test-Captcha $html) {
      Write-Host "  [captcha] hit on initial GET" -ForegroundColor Yellow
      $html = Wait-PastCaptcha $catUrl
      if ($null -eq $html) {
        Write-Host "  [captcha] giving up on this category" -ForegroundColor Red
        break
      }
    }

    $countBeforeWalk = $seen.Count
    $page = 1
    $stalePageStreak = 0
    $seenNewThisWalk = $false
    $lastPageIds = $null
    $maxPagesPerWalk = 250
    while ($true) {
      $items = Parse-Auctions $html $cat.name
      $thisPageIds = New-Object 'System.Collections.Generic.HashSet[int]'
      foreach ($it in $items) { [void]$thisPageIds.Add([int]$it.id) }

      $newCount = 0
      foreach ($it in $items) {
        if (-not $seen.Contains([int]$it.id)) {
          [void]$seen.Add([int]$it.id)
          [void]$all.Add($it)
          $newCount++
        }
      }
      if ($newCount -gt 0) { $seenNewThisWalk = $true }
      Write-Host ("  Page {0}: {1} items ({2} new, total this category: {3}/{4}, all={5})" -f $page, $items.Count, $newCount, $seen.Count, $cat.totalCount, $all.Count)

      # Save after every page that yielded new auctions, so the dashboard sees progress live.
      if ($newCount -gt 0) { Save-All $true }

      if ($cat.totalCount -gt 0 -and $seen.Count -ge $cat.totalCount) {
        Write-Host "  (collected all)" -ForegroundColor Green
        break catLoop
      }
      if ($MaxPagesPerCategory -gt 0 -and $page -ge $MaxPagesPerCategory) {
        Write-Host "  (page limit reached)"
        break catLoop
      }
      if ($items.Count -eq 0) {
        Write-Host "  (empty page)"
        break
      }
      if ($page -ge $maxPagesPerWalk) {
        Write-Host "  (max pages per walk reached)" -ForegroundColor Yellow
        break
      }
      # Cap how many pages we'll walk through already-known territory before giving up
      # this walk. Without this we burn requests + risk hard IP-ban from rate limiter.
      if (-not $seenNewThisWalk -and $page -ge $MaxKnownPages) {
        Write-Host ("  (walked {0} pages of known territory without new items — reset)" -f $MaxKnownPages) -ForegroundColor DarkYellow
        break
      }
      # Stall detection only applies AFTER the walk has yielded at least one new item.
      # Until then we may be walking through already-known pages from a previous walk —
      # we must push through them to reach the new territory deeper in the listing.
      if ($seenNewThisWalk) {
        if ($lastPageIds -and $thisPageIds.Count -gt 0 -and $thisPageIds.SetEquals($lastPageIds)) {
          Write-Host "  (same IDs as previous page — pagination stalled)" -ForegroundColor Yellow
          break
        }
        if ($newCount -eq 0) {
          $stalePageStreak++
          if ($stalePageStreak -ge 3) {
            Write-Host "  (stale pagination — needs reset)" -ForegroundColor Yellow
            break
          }
        } else {
          $stalePageStreak = 0
        }
      }
      $lastPageIds = $thisPageIds

      if ($html -notmatch 'id="cph_Base_lbNext"\s+class="page-link lnkPN"\s+href="javascript:__doPostBack') {
        Write-Host "  (no more pages on this walk)"
        break
      }

      $f = Get-FormFields $html
      $body = @{
        '__EVENTTARGET'                         = 'ctl00$cph_Base$lbNext'
        '__EVENTARGUMENT'                       = ''
        '__VIEWSTATE'                           = $f.ViewState
        '__VIEWSTATEGENERATOR'                  = $f.ViewStateGenerator
        '__EVENTVALIDATION'                     = $f.EventValidation
        '__SCROLLPOSITIONX'                     = '0'
        '__SCROLLPOSITIONY'                     = '0'
        'ctl00$cph_Base$hdnCurrentAuctionID'    = '-1'
        'ctl00$cph_Base$hdnCaseId'              = '-1'
        'ctl00$cph_Base$hdnUserIdAuctionStatus' = '-1'
      }

      if ($DelayMs -gt 0) { Start-Sleep -Milliseconds $DelayMs }

      try {
        $next = Curl-PostForm $catUrl $body
      } catch {
        Write-Host ("  ERROR posting next page: {0}" -f $_.Exception.Message) -ForegroundColor Red
        break
      }

      if (Test-Captcha $next) {
        Write-Host "  [captcha] hit mid-walk" -ForegroundColor Yellow
        break
      }

      $html = $next
      $page++
    }

    if ($cat.totalCount -gt 0 -and $seen.Count -ge $cat.totalCount) { break }
    if ($MaxMinutes -gt 0 -and ((Get-Date) - $ScriptStart).TotalMinutes -ge $MaxMinutes) {
      Write-Host ("  Time budget reached ({0} min). Stopping." -f $MaxMinutes) -ForegroundColor Yellow
      break
    }
    $resets++
    if ($resets -gt $MaxResetsPerCategory) {
      Write-Host ("  Reset cap reached ({0}). Stopping at {1}/{2}." -f $MaxResetsPerCategory, $seen.Count, $cat.totalCount) -ForegroundColor Yellow
      break
    }
    $progressedThisWalk = ($seen.Count - $countBeforeWalk)
    if ($progressedThisWalk -eq 0) {
      $zeroProgressWalks++
      if ($zeroProgressWalks -ge 3) {
        Write-Host ("  3 consecutive walks added 0 new items. Aborting category at {0}/{1}." -f $seen.Count, $cat.totalCount) -ForegroundColor Yellow
        break
      }
    } else {
      $zeroProgressWalks = 0
    }
    Write-Host ("  Resetting session (reset {0}/{1}, +{2} this walk)..." -f $resets, $MaxResetsPerCategory, $progressedThisWalk) -ForegroundColor Cyan
    Reset-Session
  }

  Save-All $true
  Write-Host ("  [saved] {0} auctions written so far" -f $all.Count) -ForegroundColor DarkGray
}

Save-All $false
Write-Host ""
Write-Host ("TOTAL: {0} auctions" -f $all.Count) -ForegroundColor Green
Write-Host ("Wrote {0}" -f $jsonPath)
Write-Host ("Wrote {0}" -f $jsPath)
