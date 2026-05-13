<#
.SYNOPSIS
  Local HTTP server for the MoJ auctions dashboard.

.DESCRIPTION
  Serves dashboard.html / auctions.js / static assets, and exposes:
    POST /api/refresh           — kick off a full re-scrape (returns jobId)
    GET  /api/refresh/status    — current job state (running / done / error) + tail of log
    GET  /api/auction?id=<id>&token=<categoryToken>
                                — fetch AuctionInfo.aspx for that auction,
                                  return discovered images + expert-report links

.EXAMPLE
  ./serve.ps1                   # listens on http://localhost:8123
  ./serve.ps1 -Port 9000
#>
[CmdletBinding()]
param(
  [int]$Port = 8123
)

$ErrorActionPreference = 'Stop'

$Root      = $PSScriptRoot
$CurlExe   = 'C:\Windows\System32\curl.exe'
$Base      = 'https://auctions.moj.gov.jo'
$UserAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36'
# Use a separate cookie jar so the server doesn't fight the scraper if both run.
$CookieJar = Join-Path $Root 'cookies_serve.txt'

# ----- Refresh job state (single-slot) -----
$script:RefreshJob = $null   # holds @{ proc, log, startedAt, status }

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

function Send-Bytes($ctx, [byte[]]$bytes, [string]$contentType, [int]$status = 200) {
  $resp = $ctx.Response
  $resp.StatusCode = $status
  $resp.ContentType = $contentType
  $resp.Headers.Add('Cache-Control', 'no-cache')
  $resp.Headers.Add('Access-Control-Allow-Origin', '*')
  $resp.ContentLength64 = $bytes.Length
  try {
    $resp.OutputStream.Write($bytes, 0, $bytes.Length)
  } catch { }
  finally {
    try { $resp.OutputStream.Close() } catch { }
  }
}

function Send-Text($ctx, [string]$text, [string]$contentType = 'text/plain; charset=utf-8', [int]$status = 200) {
  Send-Bytes $ctx ([System.Text.UTF8Encoding]::new($false).GetBytes($text)) $contentType $status
}

function Send-Json($ctx, $obj, [int]$status = 200) {
  $json = $obj | ConvertTo-Json -Depth 10 -Compress
  Send-Text $ctx $json 'application/json; charset=utf-8' $status
}

function Send-File($ctx, [string]$path, [string]$contentType) {
  if (-not (Test-Path $path)) { Send-Text $ctx "Not found: $path" 'text/plain; charset=utf-8' 404; return }
  $bytes = [System.IO.File]::ReadAllBytes($path)
  Send-Bytes $ctx $bytes $contentType 200
}

function Get-ContentType([string]$path) {
  switch -Wildcard ($path.ToLower()) {
    '*.html' { 'text/html; charset=utf-8' }
    '*.js'   { 'application/javascript; charset=utf-8' }
    '*.css'  { 'text/css; charset=utf-8' }
    '*.json' { 'application/json; charset=utf-8' }
    '*.png'  { 'image/png' }
    '*.jpg'  { 'image/jpeg' }
    '*.jpeg' { 'image/jpeg' }
    '*.gif'  { 'image/gif' }
    '*.svg'  { 'image/svg+xml' }
    default  { 'application/octet-stream' }
  }
}

function Parse-AuctionInfoPage([string]$html) {
  # Captcha?
  if ($html.Length -lt 5000 -or $html.Contains('Validation request') -or $html.Contains('captcha_resp')) {
    return [pscustomobject]@{ captcha = $true; images = @(); reports = @() }
  }

  # Image candidates: <img src="..."> where src is jpg/png/jpeg/gif and not a UI asset
  $imgs = New-Object 'System.Collections.Generic.List[string]'
  foreach ($m in [regex]::Matches($html, '<img[^>]+src="([^"]+\.(?:jpg|jpeg|png|gif|JPG|JPEG|PNG|GIF))"')) {
    $u = $m.Groups[1].Value
    if ($u -match '/(noimage|logo|favicon|splash|ipad|iphone|menu|gavel|fa[-_])' ) { continue }
    if ($u -match '^data:') { continue }
    if ($u.StartsWith('/')) { $u = $Base + $u }
    if (-not $imgs.Contains($u)) { $imgs.Add($u) | Out-Null }
  }
  # Anchor candidates: <a href="..."> where href is a known doc type, or where surrounding text mentions تقرير/خبرة
  $reports = New-Object 'System.Collections.Generic.List[object]'
  foreach ($m in [regex]::Matches($html, '<a[^>]+href="([^"]+)"[^>]*>([\s\S]*?)</a>')) {
    $href = $m.Groups[1].Value
    $text = ($m.Groups[2].Value -replace '<[^>]+>', ' ' -replace '\s+', ' ').Trim()
    $isDoc = $href -match '\.(pdf|doc|docx|xls|xlsx|jpg|png)(\?|$)'
    $mentionsReport = ($text -match 'تقرير|خبرة|مرفق|التقرير|attach|report')
    if ($isDoc -or $mentionsReport) {
      $u = $href
      if ($u.StartsWith('/')) { $u = $Base + $u }
      $reports.Add([pscustomobject]@{ url = $u; text = $text }) | Out-Null
    }
  }
  return [pscustomobject]@{ captcha = $false; images = $imgs; reports = $reports }
}

# ----- Routes -----
function Handle-Request($ctx) {
  $req  = $ctx.Request
  $path = $req.Url.AbsolutePath
  $method = $req.HttpMethod

  # Static
  if ($method -eq 'GET') {
    if ($path -eq '/' -or $path -eq '/dashboard' -or $path -eq '/dashboard.html') {
      Send-File $ctx (Join-Path $Root 'dashboard.html') 'text/html; charset=utf-8'
      return
    }
    if ($path -eq '/auctions.js' -or $path -eq '/auctions.json') {
      Send-File $ctx (Join-Path $Root ($path.TrimStart('/'))) (Get-ContentType $path)
      return
    }
  }

  # GET /api/auction?id=..&token=..
  if ($method -eq 'GET' -and $path -eq '/api/auction') {
    $id    = $req.QueryString['id']
    $token = $req.QueryString['token']
    if (-not $id -or -not $token) {
      Send-Json $ctx @{ error = 'id and token required' } 400
      return
    }
    try {
      $url = "$Base/AuctionInfo.aspx?token=$token&auction=$id"
      $html = Curl-Get $url
      $parsed = Parse-AuctionInfoPage $html
      Send-Json $ctx ([pscustomobject]@{
        id      = [int]$id
        url     = $url
        captcha = $parsed.captcha
        images  = $parsed.images
        reports = $parsed.reports
      })
    } catch {
      Send-Json $ctx @{ error = $_.Exception.Message } 500
    }
    return
  }

  # GET /api/bids?token=..
  # Fetches the listing page for the given category, parses every auction's
  # current highest-bid and bid-count, returns them as a JSON array.
  if ($method -eq 'GET' -and $path -eq '/api/bids') {
    $token = $req.QueryString['token']
    if (-not $token) {
      Send-Json $ctx @{ error = 'token required' } 400
      return
    }
    try {
      $listUrl = "$Base/AuctionsList.aspx?token=$token"
      $html = Curl-Get $listUrl
      if (-not $html -or $html.Length -lt 5000 -or $html.Contains('captcha_resp')) {
        Send-Json $ctx ([pscustomobject]@{ token = $token; captcha = $true; updates = @() })
        return
      }
      $byId = @{}
      $highRe = [regex]'HighestAuctionAmount_(\d+)"[^>]*>\s*([^<\s]+)'
      foreach ($m in $highRe.Matches($html)) {
        $id = [int]$m.Groups[1].Value
        $v  = $m.Groups[2].Value -replace '[^\d.\-]', ''
        $cur = if ($v) { [double]$v } else { 0 }
        if (-not $byId.ContainsKey($id)) { $byId[$id] = @{ id = $id; currentAmount = $cur; numBids = 0 } }
        else { $byId[$id].currentAmount = $cur }
      }
      $numRe = [regex]'NumberOfBiddings_(\d+)"[^>]*>\s*(\d+)'
      foreach ($m in $numRe.Matches($html)) {
        $id = [int]$m.Groups[1].Value
        $n  = [int]$m.Groups[2].Value
        if (-not $byId.ContainsKey($id)) { $byId[$id] = @{ id = $id; currentAmount = 0; numBids = $n } }
        else { $byId[$id].numBids = $n }
      }
      Send-Json $ctx ([pscustomobject]@{
        token = $token; captcha = $false; count = $byId.Count;
        updates = @($byId.Values); ts = [DateTimeOffset]::Now.ToUnixTimeMilliseconds()
      })
    } catch {
      Send-Json $ctx @{ error = $_.Exception.Message } 500
    }
    return
  }

  # POST /api/refresh
  if ($method -eq 'POST' -and $path -eq '/api/refresh') {
    if ($script:RefreshJob -and $script:RefreshJob.proc -and -not $script:RefreshJob.proc.HasExited) {
      Send-Json $ctx @{ status = 'already_running'; startedAt = $script:RefreshJob.startedAt } 409
      return
    }
    $log = Join-Path $Root 'refresh.log'
    if (Test-Path $log) { Remove-Item $log -Force }
    $args = @('-ExecutionPolicy','Bypass','-File',(Join-Path $Root 'scrape.ps1'),'-Full','-DelayMs','1500')
    $proc = Start-Process -FilePath 'powershell.exe' -ArgumentList $args `
      -WorkingDirectory $Root -RedirectStandardOutput $log -RedirectStandardError (Join-Path $Root 'refresh.err') `
      -WindowStyle Hidden -PassThru
    $script:RefreshJob = @{ proc = $proc; log = $log; startedAt = (Get-Date).ToString('s'); status = 'running' }
    Send-Json $ctx @{ status = 'started'; pid = $proc.Id; startedAt = $script:RefreshJob.startedAt }
    return
  }

  # GET /api/refresh/status
  if ($method -eq 'GET' -and $path -eq '/api/refresh/status') {
    $job = $script:RefreshJob
    if ($null -eq $job) { Send-Json $ctx @{ status = 'idle' }; return }
    $running = $job.proc -and -not $job.proc.HasExited
    $tail = ''
    if (Test-Path $job.log) {
      try {
        $allLines = [System.IO.File]::ReadAllLines($job.log, [System.Text.UTF8Encoding]::new($false))
        $start = [Math]::Max(0, $allLines.Length - 30)
        $tail = ($allLines[$start..($allLines.Length-1)] -join "`n")
      } catch { }
    }
    $exitCode = $null
    if (-not $running) { try { $exitCode = $job.proc.ExitCode } catch { } }
    Send-Json $ctx @{
      status    = $(if ($running) { 'running' } else { if ($exitCode -eq 0) { 'done' } else { 'error' } })
      startedAt = $job.startedAt
      exitCode  = $exitCode
      tail      = $tail
    }
    return
  }

  # OPTIONS for CORS preflight
  if ($method -eq 'OPTIONS') {
    $ctx.Response.Headers.Add('Access-Control-Allow-Origin', '*')
    $ctx.Response.Headers.Add('Access-Control-Allow-Methods', 'GET,POST,OPTIONS')
    $ctx.Response.Headers.Add('Access-Control-Allow-Headers', 'Content-Type')
    $ctx.Response.StatusCode = 204
    $ctx.Response.OutputStream.Close()
    return
  }

  # Try static fallback (any file in script directory)
  if ($method -eq 'GET') {
    $candidate = Join-Path $Root ($path.TrimStart('/').Replace('/', [System.IO.Path]::DirectorySeparatorChar))
    $full = [System.IO.Path]::GetFullPath($candidate)
    if ($full.StartsWith($Root) -and (Test-Path $full -PathType Leaf)) {
      Send-File $ctx $full (Get-ContentType $full)
      return
    }
  }

  Send-Text $ctx "Not found: $path" 'text/plain; charset=utf-8' 404
}

# ----- Listener loop -----
$listener = [System.Net.HttpListener]::new()
$prefix = "http://localhost:$Port/"
$listener.Prefixes.Add($prefix)
try {
  $listener.Start()
} catch {
  Write-Host "Failed to start listener at $prefix : $($_.Exception.Message)" -ForegroundColor Red
  Write-Host "If you see 'Access is denied', try running as Administrator OR run:" -ForegroundColor Yellow
  Write-Host "  netsh http add urlacl url=$prefix user=$env:USERNAME" -ForegroundColor Yellow
  exit 1
}

Write-Host "MoJ Auctions Dashboard server listening at $prefix" -ForegroundColor Green
Write-Host "Open: $prefix" -ForegroundColor Green
Write-Host "Press Ctrl+C to stop." -ForegroundColor DarkGray

# Open the dashboard in the default browser
try { Start-Process $prefix } catch { }

while ($listener.IsListening) {
  try {
    $ctx = $listener.GetContext()
    try {
      Handle-Request $ctx
    } catch {
      Write-Host "Handler error: $($_.Exception.Message)" -ForegroundColor Red
      try { Send-Text $ctx ("Server error: " + $_.Exception.Message) 'text/plain; charset=utf-8' 500 } catch { }
    }
  } catch [System.Net.HttpListenerException] {
    if ($_.Exception.ErrorCode -eq 995) { break }   # listener stopped
    Write-Host "Listener error: $($_.Exception.Message)" -ForegroundColor Red
  }
}

$listener.Close()
Write-Host "Server stopped."
