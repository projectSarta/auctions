<#
.SYNOPSIS
  Download the PDF bytes for every auction that already has a reportUrl
  but no local pdfPath. Saves to reports/<id>.pdf so GitHub Pages can
  serve them inline (no Content-Disposition: attachment) — clicking the
  detail-modal button opens the PDF in a new tab rather than downloading.

.PARAMETER ActiveOnly   Only download for active (non-expired) auctions.
.PARAMETER MaxItems     Cap on items to process this run. 0 = unlimited.
.PARAMETER DelayMs      Pause between downloads to be polite to the origin.
#>
[CmdletBinding()]
param(
  [switch]$ActiveOnly,
  [int]$MaxItems = 0,
  [int]$DelayMs  = 400
)

$ErrorActionPreference = 'Continue'
$CurlExe   = 'C:\Windows\System32\curl.exe'
$UserAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/124.0.0.0 Safari/537.36'
$Root      = $PSScriptRoot
$JsonPath  = Join-Path $Root 'auctions.json'
$JsPath    = Join-Path $Root 'auctions.js'
$ReportsDir = Join-Path $Root 'reports'
$CookieJar = Join-Path $Root 'cookies_pdf.txt'
if (-not (Test-Path $ReportsDir)) { New-Item -ItemType Directory -Path $ReportsDir | Out-Null }
if (Test-Path $CookieJar) { Remove-Item $CookieJar -Force }

Write-Host "Loading auctions.json..." -ForegroundColor Cyan
$data = Get-Content $JsonPath -Raw -Encoding UTF8 | ConvertFrom-Json

$nowMs = [DateTimeOffset]::Now.ToUnixTimeMilliseconds()
$isActive = {
  param($a)
  if (-not $a.endDate) { return $true }
  try { ([DateTimeOffset]::new([DateTime]::Parse([string]$a.endDate)).ToUnixTimeMilliseconds() -gt $nowMs) }
  catch { $true }
}

$candidates = $data.auctions | Where-Object {
  $_.reportUrl -and $_.reportUrl -ne '' -and
  (-not $_.pdfPath -or $_.pdfPath -eq '' -or (-not (Test-Path (Join-Path $Root $_.pdfPath)))) -and
  (-not $ActiveOnly -or (& $isActive $_))
}

"Candidates needing PDF: $($candidates.Count)"
if ($candidates.Count -eq 0) { exit 0 }

$tried = 0; $ok = 0; $fail = 0
foreach ($a in $candidates) {
  if ($MaxItems -gt 0 -and $tried -ge $MaxItems) { break }
  $tried++

  $pdfFile = Join-Path $ReportsDir ("$($a.id).pdf")
  $tmp = [System.IO.Path]::GetTempFileName()
  try {
    & $CurlExe --silent --insecure --location --compressed --user-agent $UserAgent `
      --cookie-jar $CookieJar --cookie $CookieJar `
      --output $tmp $a.reportUrl | Out-Null
    if ((Test-Path $tmp) -and ((Get-Item $tmp).Length -gt 200)) {
      $bytes = [System.IO.File]::ReadAllBytes($tmp)
      if ($bytes.Length -gt 4 -and [System.Text.Encoding]::ASCII.GetString($bytes, 0, 4) -eq '%PDF') {
        [System.IO.File]::WriteAllBytes($pdfFile, $bytes)
        $a | Add-Member -MemberType NoteProperty -Name 'pdfPath' -Value ("reports/$($a.id).pdf") -Force
        $ok++
        Write-Host -NoNewline "."
      } else {
        $fail++
        Write-Host -NoNewline "!"
      }
    } else { $fail++; Write-Host -NoNewline "?" }
  } catch { $fail++; Write-Host -NoNewline "x" } finally {
    if (Test-Path $tmp) { Remove-Item $tmp -Force }
  }

  # Save every 25 items so progress is durable
  if (($tried % 25) -eq 0) {
    $json = $data | ConvertTo-Json -Depth 12
    [System.IO.File]::WriteAllText($JsonPath, $json, [System.Text.UTF8Encoding]::new($false))
    [System.IO.File]::WriteAllText($JsPath, "window.AUCTION_DATA = $json;", [System.Text.UTF8Encoding]::new($false))
    Write-Host (" [{0}/{1} ok={2} fail={3}]" -f $tried, $candidates.Count, $ok, $fail)
  }

  Start-Sleep -Milliseconds $DelayMs
}

# Final save
$json = $data | ConvertTo-Json -Depth 12
[System.IO.File]::WriteAllText($JsonPath, $json, [System.Text.UTF8Encoding]::new($false))
[System.IO.File]::WriteAllText($JsPath, "window.AUCTION_DATA = $json;", [System.Text.UTF8Encoding]::new($false))

""
"--- Summary ---"
"  attempted:  $tried"
"  downloaded: $ok"
"  failed:     $fail"
$tot = (Get-ChildItem $ReportsDir -File -Filter '*.pdf' | Measure-Object Length -Sum).Sum
"  reports dir: $([math]::Round($tot / 1MB, 1)) MB across $((Get-ChildItem $ReportsDir -File -Filter '*.pdf').Count) PDFs"
