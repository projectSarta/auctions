<#
.SYNOPSIS
  Enrich auctions.json with the expert-report PDF URL for each auction.

.DESCRIPTION
  The MoJ auctions site exposes an expert-report PDF via:
      /Forms/Auctions/frmDownloadReports.aspx?token=<encrypted-token>
  The token is unique per auction, stable over time, and works in a fresh
  session with no cookies (anyone can hit the URL). We just need to scrape
  it once per auction.

  Discovery flow (mirrors the image-enrichment postback):
    1) GET /AuctionsList.aspx?token=<cat-token>     (warm session, grab ViewState)
    2) POST back with __EVENTTARGET = ...$lbtnDetails + hdnCurrentAuctionID +
       hdnCaseId (mimic clicking the "تفاصيل" / "المرفقات والصور" button)
    3) Server redirects to a details page; parse the HTML for
       /Forms/Auctions/frmDownloadReports.aspx?token=<x>
    4) Store the full URL in auction.reportUrl

  Requires the auction to have caseId set (re-scrape via scrape.ps1 -Full
  first if any are missing).

.PARAMETER MaxItems          Max auctions to attempt this run. Default 400.
.PARAMETER OnlyCategory      Optional regex filter on category name.
.PARAMETER DelayMs           Delay between requests. Default 1500 (postbacks are heavier).
.PARAMETER MaxConsecutiveErrors  Bail after this many failures in a row.
#>
[CmdletBinding()]
param(
  [int]$MaxItems = 400,
  [string]$OnlyCategory = '',
  [int]$DelayMs = 1500,
  [int]$MaxConsecutiveErrors = 5,
  [switch]$ActiveOnly
)

$ErrorActionPreference = 'Stop'
$CurlExe   = 'C:\Windows\System32\curl.exe'
$Base      = 'https://auctions.moj.gov.jo'
$UserAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36'
$Root      = $PSScriptRoot
$CookieJar = Join-Path $Root 'cookies_reports.txt'
$JsonPath  = Join-Path $Root 'auctions.json'
$JsPath    = Join-Path $Root 'auctions.js'

if (Test-Path $CookieJar) { Remove-Item $CookieJar -Force }

function Curl-Get([string]$url) {
  $tmp = [System.IO.Path]::GetTempFileName()
  try {
    & $CurlExe --silent --insecure --location --compressed `
      --user-agent $UserAgent `
      --header 'Accept: text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8' `
      --header 'Accept-Language: ar,en;q=0.8' `
      --cookie-jar $CookieJar --cookie $CookieJar `
      --output $tmp $url | Out-Null
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

    & $CurlExe --silent --insecure --location --compressed `
      --user-agent $UserAgent `
      --header 'Accept: text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8' `
      --header 'Accept-Language: ar,en;q=0.8' `
      --header 'Content-Type: application/x-www-form-urlencoded' `
      --header ("Referer: " + $referer) `
      --cookie-jar $CookieJar --cookie $CookieJar `
      --data "@$bodyFile" --output $outFile $url | Out-Null
    if ($LASTEXITCODE -ne 0) { return $null }
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

function Get-FormFields([string]$html) {
  $vs  = [regex]::Match($html, 'name="__VIEWSTATE"\s+id="__VIEWSTATE"\s+value="([^"]*)"').Groups[1].Value
  $vsg = [regex]::Match($html, 'name="__VIEWSTATEGENERATOR"\s+id="__VIEWSTATEGENERATOR"\s+value="([^"]*)"').Groups[1].Value
  $ev  = [regex]::Match($html, 'name="__EVENTVALIDATION"\s+id="__EVENTVALIDATION"\s+value="([^"]*)"').Groups[1].Value
  @{ ViewState = $vs; ViewStateGenerator = $vsg; EventValidation = $ev }
}

function Save-Data($data) {
  $json = $data | ConvertTo-Json -Depth 12
  [System.IO.File]::WriteAllText($JsonPath, $json, [System.Text.UTF8Encoding]::new($false))
  [System.IO.File]::WriteAllText($JsPath,   "window.AUCTION_DATA = $json;", [System.Text.UTF8Encoding]::new($false))
}

Write-Host "Loading auctions.json..." -ForegroundColor Cyan
$data = Get-Content $JsonPath -Raw -Encoding UTF8 | ConvertFrom-Json

$tokenByCat = @{}
foreach ($c in $data.categories) { $tokenByCat[$c.name] = $c.token }
if ($tokenByCat.Count -eq 0) { throw 'No categories in auctions.json' }

# Candidates: no reportUrl AND has caseId AND matches filter
$nowMs = [DateTimeOffset]::Now.ToUnixTimeMilliseconds()
$isActive = {
  param($auction)
  if (-not $auction.endDate) { return $true }
  try {
    $dt = [DateTime]::Parse([string]$auction.endDate)
    return ([DateTimeOffset]::new($dt).ToUnixTimeMilliseconds() -gt $nowMs)
  } catch { return $true }
}
$candidates = $data.auctions | Where-Object {
  (-not $_.reportUrl -or $_.reportUrl -eq '') -and
  ($_.PSObject.Properties.Match('caseId').Count -and $_.caseId -gt 0) -and
  (-not $OnlyCategory -or ($_.category -match $OnlyCategory)) -and
  $tokenByCat.ContainsKey($_.category) -and
  (-not $ActiveOnly -or (& $isActive $_))
}

"Candidates without reportUrl (and with caseId): $($candidates.Count)"
"Will attempt up to: $MaxItems"
"---"

if ($candidates.Count -eq 0) {
  Write-Host "Nothing to do." -ForegroundColor Yellow
  exit 0
}

# Warm session
[void](Curl-Get "$Base/index.aspx")

$tried = 0; $withUrl = 0; $noUrl = 0; $errStreak = 0
foreach ($a in $candidates) {
  if ($tried -ge $MaxItems) { break }
  $tried++

  $tok = $tokenByCat[$a.category]
  $listUrl = "$Base/AuctionsList.aspx?token=$tok"
  Write-Host -NoNewline ("  [{0,3}/{1}] id={2,-6} caseId={3,-9} ... " -f $tried, $MaxItems, $a.id, $a.caseId)

  # 1) GET the listing page (warms session + ViewState)
  $listing = Curl-Get $listUrl
  if (Test-Captcha $listing) {
    Write-Host "captcha on listing" -ForegroundColor Yellow
    $errStreak++
    if ($errStreak -ge $MaxConsecutiveErrors) { Write-Host "[stop] too many captchas." -ForegroundColor Red; break }
    Start-Sleep -Milliseconds ($DelayMs * 2)
    continue
  }

  # 2) POST back to AuctionsList.aspx with the lbtnDetails button + the auction selected
  $f = Get-FormFields $listing
  $body = @{
    '__EVENTTARGET'                              = 'ctl00$cph_Base$AuctionsListRepeater$ctl00$lbtnDetails'
    '__EVENTARGUMENT'                            = ''
    '__VIEWSTATE'                                = $f.ViewState
    '__VIEWSTATEGENERATOR'                       = $f.ViewStateGenerator
    '__EVENTVALIDATION'                          = $f.EventValidation
    '__SCROLLPOSITIONX'                          = '0'
    '__SCROLLPOSITIONY'                          = '0'
    'ctl00$cph_Base$hdnCurrentAuctionID'         = [string]$a.id
    'ctl00$cph_Base$hdnCaseId'                   = [string]$a.caseId
    'ctl00$cph_Base$hdnUserIdAuctionStatus'      = '-1'
  }

  $detail = Curl-PostForm $listUrl $body $listUrl
  if (Test-Captcha $detail) {
    Write-Host "captcha on postback" -ForegroundColor Yellow
    $errStreak++
    if ($errStreak -ge $MaxConsecutiveErrors) { Write-Host "[stop] too many captchas." -ForegroundColor Red; break }
    Start-Sleep -Milliseconds ($DelayMs * 2)
    continue
  }
  $errStreak = 0

  # 3) Find the report-download URL token
  $m = [regex]::Match($detail, 'frmDownloadReports\.aspx\?token=([^"''&\s<]+)')
  if (-not $m.Success) {
    Write-Host "no report on page" -ForegroundColor DarkGray
    $noUrl++
    Start-Sleep -Milliseconds $DelayMs
    continue
  }
  $reportToken = $m.Groups[1].Value
  $reportUrl   = "$Base/Forms/Auctions/frmDownloadReports.aspx?token=$reportToken"

  $a | Add-Member -MemberType NoteProperty -Name 'reportUrl' -Value $reportUrl -Force

  # Also pull the PDF bytes locally so GitHub Pages can serve them inline
  # (the MoJ origin sends Content-Disposition: attachment which forces a
  # download; static files on GitHub Pages don't, so we get in-tab viewing).
  $reportsDir = Join-Path $Root 'reports'
  if (-not (Test-Path $reportsDir)) { New-Item -ItemType Directory -Path $reportsDir | Out-Null }
  $pdfFile = Join-Path $reportsDir ("$($a.id).pdf")
  $tmpPdf  = [System.IO.Path]::GetTempFileName()
  try {
    & $CurlExe --silent --insecure --location --compressed --user-agent $UserAgent `
      --cookie-jar $CookieJar --cookie $CookieJar `
      --output $tmpPdf $reportUrl | Out-Null
    if ((Test-Path $tmpPdf) -and ((Get-Item $tmpPdf).Length -gt 200)) {
      $bytes = [System.IO.File]::ReadAllBytes($tmpPdf)
      # quick sanity: PDFs start with "%PDF-"
      if ($bytes.Length -gt 4 -and [System.Text.Encoding]::ASCII.GetString($bytes, 0, 4) -eq '%PDF') {
        [System.IO.File]::WriteAllBytes($pdfFile, $bytes)
        $a | Add-Member -MemberType NoteProperty -Name 'pdfPath' -Value ("reports/$($a.id).pdf") -Force
      }
    }
  } catch {} finally {
    if (Test-Path $tmpPdf) { Remove-Item $tmpPdf -Force }
  }

  Save-Data $data
  $withUrl++
  Write-Host ("OK token=" + $reportToken.Substring(0, [Math]::Min(12, $reportToken.Length)) + "..." + $(if (Test-Path $pdfFile) { " +pdf" } else { "" })) -ForegroundColor Green

  Start-Sleep -Milliseconds $DelayMs
}

""
"--- Summary ---"
"  attempted:   $tried"
"  got report:  $withUrl"
"  no report:   $noUrl"
"  remaining:   $($candidates.Count - $tried)"
