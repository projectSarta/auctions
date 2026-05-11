<#
.SYNOPSIS
  Enrich auctions.json with thumbnail images by fetching each auction's detail page
  (AuctionInfo.aspx) and downloading the primary photo into ./images/<id>.jpg.

.DESCRIPTION
  - Skips auctions that already have an image set.
  - Throttles between fetches (default 5 sec).
  - Detects captcha and stops gracefully after MaxConsecutiveCaptcha failures
    so we don't burn the entire IP budget.
  - Saves progress after every successful image (auctions.json + auctions.js).
  - Run repeatedly — each run picks up where the previous one stopped.

.PARAMETER MaxItems
  How many auctions to attempt this run. Default 60.
.PARAMETER OnlyCategory
  Optional regex filter on category name (e.g. 'مركبة').
.PARAMETER DelayMs
  Milliseconds between AuctionInfo.aspx fetches. Default 5000.
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
  } finally {
    if (Test-Path $tmp) { Remove-Item $tmp -Force }
  }
}

function Curl-Download([string]$url, [string]$outPath) {
  & $CurlExe --silent --insecure --location --compressed `
    --user-agent $UserAgent `
    --cookie-jar $CookieJar --cookie $CookieJar `
    --output $outPath --max-time 30 $url | Out-Null
  return ($LASTEXITCODE -eq 0)
}

function Test-Captcha([string]$html) {
  if ($null -eq $html) { return $true }
  if ($html.Length -lt 5000) { return $true }
  if ($html.Contains('Validation request') -or $html.Contains('captcha_resp')) { return $true }
  return $false
}

function Save-Data($data) {
  $json = $data | ConvertTo-Json -Depth 12
  [System.IO.File]::WriteAllText($JsonPath, $json, [System.Text.UTF8Encoding]::new($false))
  [System.IO.File]::WriteAllText($JsPath,   "window.AUCTION_DATA = $json;", [System.Text.UTF8Encoding]::new($false))
}

Write-Host "Loading auctions.json..."
$data = Get-Content $JsonPath -Raw -Encoding UTF8 | ConvertFrom-Json

# Build token-by-category lookup
$tokenByCat = @{}
foreach ($c in $data.categories) { $tokenByCat[$c.name] = $c.token }
if ($tokenByCat.Count -eq 0) { throw 'No categories in auctions.json' }

# Pick auctions needing enrichment
$candidates = $data.auctions | Where-Object {
  (-not $_.image -or $_.image -eq '') -and
  (-not $OnlyCategory -or ($_.category -match $OnlyCategory)) -and
  $tokenByCat.ContainsKey($_.category)
}
"Candidates needing image: $($candidates.Count)"
"Will attempt up to: $MaxItems"
"---"

# Warm session (visit index.aspx so subsequent AuctionInfo.aspx works with cookies)
[void](Curl-Get "$Base/index.aspx")

$tried = 0; $ok = 0; $skipped = 0; $captchaStreak = 0
foreach ($a in $candidates) {
  if ($tried -ge $MaxItems) { break }
  $tried++

  $tok = $tokenByCat[$a.category]
  $url = "$Base/AuctionInfo.aspx?token=$tok&auction=$($a.id)"
  Write-Host -NoNewline ("  [{0,3}/{1}] id={2,-6} {3} ... " -f $tried, $MaxItems, $a.id, $a.category)

  $html = Curl-Get $url
  if (Test-Captcha $html) {
    Write-Host "captcha" -ForegroundColor Yellow
    $captchaStreak++
    if ($captchaStreak -ge $MaxConsecutiveCaptcha) {
      Write-Host "[stopping] $MaxConsecutiveCaptcha consecutive captcha hits — IP budget exhausted." -ForegroundColor Red
      break
    }
    Start-Sleep -Milliseconds ($DelayMs * 2)
    continue
  }
  $captchaStreak = 0

  # Find first usable image src on the detail page
  $imgUrl = $null
  $m = [regex]::Match($html, '<img[^>]+id="imgAuctionImage_\d+"[^>]+src="([^"]+)"')
  if ($m.Success -and ($m.Groups[1].Value -notmatch 'noimage')) {
    $imgUrl = $m.Groups[1].Value
  }
  if (-not $imgUrl) {
    # Any non-UI image
    foreach ($mm in [regex]::Matches($html, '<img[^>]+src="([^"]+\.(?:jpg|jpeg|png|gif))"')) {
      $u = $mm.Groups[1].Value
      if ($u -match 'noimage|logo|favicon|splash|fa[-_]|ipad|iphone|menu') { continue }
      $imgUrl = $u; break
    }
  }
  if (-not $imgUrl) {
    Write-Host "no image" -ForegroundColor DarkGray
    $skipped++
    Start-Sleep -Milliseconds $DelayMs
    continue
  }

  # Resolve relative URL
  if ($imgUrl.StartsWith('/')) { $imgUrl = $Base + $imgUrl }

  # Determine extension
  $ext = '.jpg'
  if ($imgUrl -match '\.(jpe?g|png|gif)(\?|$)') { $ext = '.' + $matches[1] }
  $localPath = Join-Path $ImagesDir ("$($a.id)$ext")

  if (Curl-Download $imgUrl $localPath) {
    $rel = "images/$($a.id)$ext"
    # Mutate the in-memory record
    $a | Add-Member -MemberType NoteProperty -Name 'image' -Value $rel -Force
    Save-Data $data
    $ok++
    Write-Host "✓ $rel" -ForegroundColor Green
  } else {
    Write-Host "download failed" -ForegroundColor DarkYellow
  }

  Start-Sleep -Milliseconds $DelayMs
}

""
"--- Done ---"
"  attempted:  $tried"
"  ok:         $ok"
"  skipped:    $skipped (no image on detail page)"
"  remaining:  $($candidates.Count - $tried)"
