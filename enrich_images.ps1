<#
.SYNOPSIS
  Enrich auctions.json with thumbnail images via the site's own JSON web method.

.DESCRIPTION
  Reverse-engineered from /JS/AuctionsListScripts.js (function LoadAuctionsImages):
  the listing page lazy-loads each thumbnail by POSTing JSON to a single endpoint:

      POST /AuctionsList.aspx/GetAuctionItemsImage
      Content-Type: application/json
      Body: { "AuctionID": "<id>", "ImageControlID": "imgAuctionImage_<id>" }

  Returns: { "d": { "strImageControl": "imgAuctionImage_<id>",
                    "strAuctionImageData": "data:image/png;base64,<...>" } }

  We hit it directly. No __VIEWSTATE / __EVENTVALIDATION / postback / caseId needed —
  just a warm session cookie from /AuctionsList.aspx?token=<cat>.

  Per auction:
    1) Ensure we have a session cookie for this category (warm once per token).
    2) POST the JSON web method with AuctionID = <id>.
    3) Decode base64, sniff magic bytes (declared PNG is often JPEG), write to
       images/<id>.<ext>, set auction.image = "images/<id>.<ext>".
    4) Save auctions.json + auctions.js after every success.

.PARAMETER MaxItems         Max auctions to attempt this run. Default 200.
.PARAMETER OnlyCategory     Optional regex filter on category name (e.g. 'مركبة').
.PARAMETER DelayMs          Delay between requests in ms. Default 500.
.PARAMETER MaxConsecutiveErrors  Bail after this many failures in a row. Default 5.
#>
[CmdletBinding()]
param(
  [int]$MaxItems = 200,
  [string]$OnlyCategory = '',
  [int]$DelayMs = 500,
  [int]$MaxConsecutiveErrors = 5,
  # When set, only process auctions whose endDate is in the future (live listings).
  [switch]$ActiveOnly
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

function Warm-Session([string]$token) {
  $tmp = [System.IO.Path]::GetTempFileName()
  try {
    & $CurlExe --silent --insecure --location --compressed `
      --user-agent $UserAgent `
      --header 'Accept: text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8' `
      --header 'Accept-Language: ar,en;q=0.8' `
      --cookie-jar $CookieJar --cookie $CookieJar `
      --output $tmp `
      "$Base/AuctionsList.aspx?token=$token" | Out-Null
  } finally { if (Test-Path $tmp) { Remove-Item $tmp -Force } }
}

function Get-AuctionImageDataUri([int]$auctionId, [string]$refererToken) {
  $bodyFile = [System.IO.Path]::GetTempFileName()
  $outFile  = [System.IO.Path]::GetTempFileName()
  try {
    $payload = '{ "AuctionID": "' + $auctionId + '","ImageControlID": "imgAuctionImage_' + $auctionId + '"}'
    [System.IO.File]::WriteAllText($bodyFile, $payload, [System.Text.UTF8Encoding]::new($false))

    & $CurlExe --silent --insecure --location --compressed `
      --user-agent $UserAgent `
      --header 'Accept: application/json, text/javascript, */*; q=0.01' `
      --header 'Content-Type: application/json; charset=UTF-8' `
      --header 'X-Requested-With: XMLHttpRequest' `
      --header ("Referer: " + $Base + "/AuctionsList.aspx?token=" + $refererToken) `
      --cookie-jar $CookieJar --cookie $CookieJar `
      --data "@$bodyFile" `
      --output $outFile `
      "$Base/AuctionsList.aspx/GetAuctionItemsImage" | Out-Null
    if ($LASTEXITCODE -ne 0) { return $null }

    $raw = [System.IO.File]::ReadAllText($outFile, [System.Text.UTF8Encoding]::new($false))
    if (-not $raw -or $raw.Length -lt 50) { return $null }

    # Anti-scrape responses: "Validation request" / login redirects / tiny HTML
    if ($raw.TrimStart().StartsWith('<')) { return $null }

    try { $obj = $raw | ConvertFrom-Json } catch { return $null }
    if (-not $obj.d) { return $null }
    return [string]$obj.d.strAuctionImageData
  } finally {
    if (Test-Path $bodyFile) { Remove-Item $bodyFile -Force }
    if (Test-Path $outFile)  { Remove-Item $outFile  -Force }
  }
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

# Candidates: no image yet AND category we have a token for (caseId no longer required)
$nowMs = [DateTimeOffset]::Now.ToUnixTimeMilliseconds()
$isActive = {
  param($auction)
  if (-not $auction.endDate) { return $true }   # unknown end = treat as active
  try {
    $dt = [DateTime]::Parse([string]$auction.endDate)
    return ([DateTimeOffset]::new($dt).ToUnixTimeMilliseconds() -gt $nowMs)
  } catch { return $true }
}
$candidates = $data.auctions | Where-Object {
  (-not $_.image -or $_.image -eq '') -and
  (-not $OnlyCategory -or ($_.category -match $OnlyCategory)) -and
  $tokenByCat.ContainsKey($_.category) -and
  (-not $ActiveOnly -or (& $isActive $_))
}

"Candidates without image: $($candidates.Count)"
"Will attempt up to: $MaxItems"
"---"

if ($candidates.Count -eq 0) {
  Write-Host "Nothing to do. Every auction in scope already has an image." -ForegroundColor Yellow
  exit 0
}

# Warm session for each distinct category we'll touch
$warmedTokens = @{}
foreach ($a in ($candidates | Select-Object -First $MaxItems)) {
  $t = $tokenByCat[$a.category]
  if (-not $warmedTokens.ContainsKey($t)) {
    Warm-Session $t
    $warmedTokens[$t] = $true
  }
}

$tried = 0; $withImg = 0; $noImg = 0; $errStreak = 0
foreach ($a in $candidates) {
  if ($tried -ge $MaxItems) { break }
  $tried++

  $tok = $tokenByCat[$a.category]
  Write-Host -NoNewline ("  [{0,3}/{1}] id={2,-6} {3} ... " -f $tried, $MaxItems, $a.id, $a.category)

  $dataUri = Get-AuctionImageDataUri -auctionId $a.id -refererToken $tok
  if (-not $dataUri) {
    Write-Host "request failed" -ForegroundColor Yellow
    $errStreak++
    if ($errStreak -ge $MaxConsecutiveErrors) {
      Write-Host "[stopping] $MaxConsecutiveErrors consecutive failures." -ForegroundColor Red
      break
    }
    Start-Sleep -Milliseconds ($DelayMs * 2)
    continue
  }

  $m = [regex]::Match($dataUri, '(?i)^data:image/([a-z]+);base64,(.+)$')
  if (-not $m.Success) {
    # The site uses '/Images/noimage.jpg' (a plain URL, not a data URI) when there is no image.
    if ($dataUri -match 'noimage') {
      Write-Host "no image on server" -ForegroundColor DarkGray
    } else {
      Write-Host ("unexpected payload head: " + $dataUri.Substring(0, [Math]::Min(60, $dataUri.Length))) -ForegroundColor DarkYellow
    }
    $noImg++; $errStreak = 0
    Start-Sleep -Milliseconds $DelayMs
    continue
  }

  $declared = $m.Groups[1].Value
  $b64      = $m.Groups[2].Value

  # Magic-byte sniff: declared 'png' often actually JPEG (server lies about MIME).
  $ext = $declared
  if     ($b64.StartsWith('/9j/'))   { $ext = 'jpg' }
  elseif ($b64.StartsWith('iVBOR'))  { $ext = 'png' }
  elseif ($b64.StartsWith('R0lGOD')) { $ext = 'gif' }

  try {
    $bytes = [System.Convert]::FromBase64String($b64)
  } catch {
    Write-Host "bad base64 (skipping)" -ForegroundColor DarkYellow
    $noImg++; $errStreak = 0
    Start-Sleep -Milliseconds $DelayMs
    continue
  }

  $localFile = "$($a.id).$ext"
  $localPath = Join-Path $ImagesDir $localFile
  [System.IO.File]::WriteAllBytes($localPath, $bytes)

  $a | Add-Member -MemberType NoteProperty -Name 'image' -Value ("images/" + $localFile) -Force
  Save-Data $data
  $withImg++; $errStreak = 0
  Write-Host ("OK saved {0} ({1:N0} bytes)" -f $localFile, $bytes.Length) -ForegroundColor Green

  Start-Sleep -Milliseconds $DelayMs
}

""
"--- Summary ---"
"  attempted: $tried"
"  saved imgs: $withImg"
"  no image:  $noImg"
"  remaining: $($candidates.Count - $tried)"
