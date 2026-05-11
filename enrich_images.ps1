<#
.SYNOPSIS
  Enrich auctions.json with thumbnail images using the proper ASP.NET postback flow.

.DESCRIPTION
  - Skips auctions that already have an image OR are missing caseId (re-scrape needed first).
  - For each candidate:
      1) GET AuctionsList.aspx?token=<cat-token>            (warm session, grab ViewState)
      2) POST back with __EVENTTARGET=...LinkButton1 +
         hdnCurrentAuctionID=<id> + hdnCaseId=<caseId>      (mimic clicking 'تفاصيل')
      3) curl follows 302 to /AuctionInfo.aspx?token=&auction=
      4) parse response for `data:image/...;base64,...`
      5) decode bytes, save to images/<id>.<ext>, set image="images/<id>.<ext>"
  - Throttles between fetches, stops on persistent captcha so we don't burn the IP budget.
  - Saves progress after every successful image.

.PARAMETER MaxItems         How many auctions to attempt this run. Default 60.
.PARAMETER OnlyCategory     Optional regex filter on category name (e.g. 'مركبة').
.PARAMETER DelayMs          ms between AuctionsList postbacks. Default 5000.
.PARAMETER MaxConsecutiveCaptcha  Stop after this many captcha hits in a row.
#>
[CmdletBinding()]
param(
  [int]$MaxItems = 60,
  [string]$OnlyCategory = '',
  [int]$DelayMs = 5000,
  [int]$MaxConsecutiveCaptcha = 3
)

$ErrorActionPreference = 'Stop'
$CurlExe   = 'C:\Windows\System32\curl.exe'
$Base      = 'https://auctions.moj.gov.jo'
$UserAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36'
$Root      = $PSScriptRoot
$CookieJar = Join-Path $Root 'cookies_enrich.txt'
$ImagesDir = Join-Path $Root 'images'
$JsonPath  = Join-Path $Root 'auctions.json'
$JsPath    = Join-Path $Root 'auctions.js'

if (-not (Test-Path $ImagesDir)) { New-Item -ItemType Directory -Path $ImagesDir | Out-Null }
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
      --data "@$bodyFile" `
      --output $outFile `
      $url | Out-Null
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

Write-Host "Loading auctions.json..."
$data = Get-Content $JsonPath -Raw -Encoding UTF8 | ConvertFrom-Json

$tokenByCat = @{}
foreach ($c in $data.categories) { $tokenByCat[$c.name] = $c.token }
if ($tokenByCat.Count -eq 0) { throw 'No categories in auctions.json' }

# Candidates: no image yet AND has caseId AND matches filter
$candidates = $data.auctions | Where-Object {
  (-not $_.image -or $_.image -eq '') -and
  ($_.PSObject.Properties.Match('caseId').Count -and $_.caseId -gt 0) -and
  (-not $OnlyCategory -or ($_.category -match $OnlyCategory)) -and
  $tokenByCat.ContainsKey($_.category)
}

$noCaseId = ($data.auctions | Where-Object {
  (-not $_.image -or $_.image -eq '') -and
  (-not $_.PSObject.Properties.Match('caseId').Count -or $_.caseId -in 0,$null) -and
  (-not $OnlyCategory -or ($_.category -match $OnlyCategory))
}).Count

"Candidates ready (have caseId): $($candidates.Count)"
"Waiting for caseId (need re-scrape): $noCaseId"
"Will attempt up to: $MaxItems"
"---"

if ($candidates.Count -eq 0) {
  Write-Host "Nothing to do. Run a full scrape first (publish.ps1 or scrape.ps1 -Full) to backfill caseId on existing rows." -ForegroundColor Yellow
  exit 0
}

# Warm session
[void](Curl-Get "$Base/index.aspx")

$tried = 0; $withImg = 0; $noImg = 0; $captchaStreak = 0
foreach ($a in $candidates) {
  if ($tried -ge $MaxItems) { break }
  $tried++

  $tok = $tokenByCat[$a.category]
  $listUrl = "$Base/AuctionsList.aspx?token=$tok"
  Write-Host -NoNewline ("  [{0,3}/{1}] id={2,-6} caseId={3,-9} {4} ... " -f $tried, $MaxItems, $a.id, $a.caseId, $a.category)

  # 1) GET the listing page (warms session + ViewState)
  $listing = Curl-Get $listUrl
  if (Test-Captcha $listing) {
    Write-Host "captcha on listing" -ForegroundColor Yellow
    $captchaStreak++
    if ($captchaStreak -ge $MaxConsecutiveCaptcha) {
      Write-Host "[stopping] $MaxConsecutiveCaptcha consecutive captcha hits." -ForegroundColor Red
      break
    }
    Start-Sleep -Milliseconds ($DelayMs * 2)
    continue
  }

  # 2) POST back to AuctionsList.aspx with the auction selected via hidden fields.
  #    Server reads hdnCurrentAuctionID + hdnCaseId, then 302s us to AuctionInfo.aspx
  #    with the auction-specific page rendered (which may contain an inline base64 image).
  $f = Get-FormFields $listing
  $body = @{
    '__EVENTTARGET'                              = 'ctl00$cph_Base$AuctionsListRepeater$ctl00$LinkButton1'
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
    $captchaStreak++
    if ($captchaStreak -ge $MaxConsecutiveCaptcha) {
      Write-Host "[stopping] $MaxConsecutiveCaptcha consecutive captcha hits." -ForegroundColor Red
      break
    }
    Start-Sleep -Milliseconds ($DelayMs * 2)
    continue
  }
  $captchaStreak = 0

  # 3) Find inline base64 image — prefer ones nested inside divAuctionImage_<id>
  $b64 = $null; $declaredExt = 'jpg'
  $nested = [regex]::Match($detail, 'divAuctionImage_' + $a.id + '[\s\S]{0,4000}?data:image/([a-z]+);base64,([A-Za-z0-9+/=]+)')
  if ($nested.Success) {
    $declaredExt = $nested.Groups[1].Value
    $b64         = $nested.Groups[2].Value
  } else {
    $loose = [regex]::Match($detail, 'data:image/([a-z]+);base64,([A-Za-z0-9+/=]{500,})')
    if ($loose.Success) {
      $declaredExt = $loose.Groups[1].Value
      $b64         = $loose.Groups[2].Value
    }
  }

  if (-not $b64) {
    Write-Host "no inline image" -ForegroundColor DarkGray
    $noImg++
    Start-Sleep -Milliseconds $DelayMs
    continue
  }

  # Magic-byte sniff: declared 'png' but bytes start with /9j/ → it's actually JPEG.
  $ext = $declaredExt
  if ($b64.StartsWith('/9j/')) { $ext = 'jpg' }
  elseif ($b64.StartsWith('iVBOR')) { $ext = 'png' }
  elseif ($b64.StartsWith('R0lGOD')) { $ext = 'gif' }

  try {
    $bytes = [System.Convert]::FromBase64String($b64)
  } catch {
    Write-Host "bad base64 (skipping)" -ForegroundColor DarkYellow
    Start-Sleep -Milliseconds $DelayMs
    continue
  }

  $localFile = "$($a.id).$ext"
  $localPath = Join-Path $ImagesDir $localFile
  [System.IO.File]::WriteAllBytes($localPath, $bytes)

  $a | Add-Member -MemberType NoteProperty -Name 'image' -Value ("images/" + $localFile) -Force
  Save-Data $data
  $withImg++
  Write-Host ("✓ saved {0} ({1:N0} bytes)" -f $localFile, $bytes.Length) -ForegroundColor Green

  Start-Sleep -Milliseconds $DelayMs
}

""
"--- Summary ---"
"  attempted: $tried"
"  saved imgs: $withImg"
"  no inline image on page: $noImg"
"  remaining candidates: $($candidates.Count - $tried)"
