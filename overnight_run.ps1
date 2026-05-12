<#
.SYNOPSIS
  Overnight orchestration: enrich active listings (images + reports), fetch
  new listings via a fresh scrape, then re-enrich newly-discovered active
  rows, resize images, and commit + push.

.NOTES
  Each phase logs to overnight.log. Failures in one phase don't abort the
  rest — we just keep going so a single transient hiccup doesn't kill the
  whole run.
#>
[CmdletBinding()] param()

$ErrorActionPreference = 'Continue'
$Root = $PSScriptRoot
$Log  = Join-Path $Root 'overnight.log'

function Step([string]$name, [scriptblock]$cmd) {
  $ts = Get-Date -Format 'HH:mm:ss'
  $hdr = "`n[$ts] ===== $name ====="
  Add-Content -Path $Log -Value $hdr -Encoding UTF8
  Write-Host $hdr -ForegroundColor Cyan
  try { & $cmd 2>&1 | Tee-Object -FilePath $Log -Append }
  catch {
    $err = "[$ts] ERROR in $name : $($_.Exception.Message)"
    Add-Content -Path $Log -Value $err -Encoding UTF8
    Write-Host $err -ForegroundColor Red
  }
}

# Start fresh log header
$start = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
Set-Content -Path $Log -Value "===== Overnight run started $start =====" -Encoding UTF8

# Phase 1: enrich images for active listings (any category)
Step 'Phase 1: enrich images (active, all categories)' {
  & powershell.exe -ExecutionPolicy Bypass -File (Join-Path $Root 'enrich_images.ps1') -ActiveOnly -MaxItems 2000 -DelayMs 400
}

# Phase 2: enrich reports for active listings (whatever caseIds we have now)
Step 'Phase 2: enrich reports (active, current caseIds)' {
  & powershell.exe -ExecutionPolicy Bypass -File (Join-Path $Root 'enrich_reports.ps1') -ActiveOnly -MaxItems 2000 -DelayMs 1200
}

# Phase 3: fresh full scrape — this fetches new listings AND backfills caseId
# on existing rows that don't have one (so report enrichment can catch them next).
Step 'Phase 3: full scrape (new listings + backfill caseId)' {
  & powershell.exe -ExecutionPolicy Bypass -File (Join-Path $Root 'scrape.ps1') -Full
}

# Phase 4: re-enrich images for any newly-scraped active listings
Step 'Phase 4: enrich images for newly scraped (active)' {
  & powershell.exe -ExecutionPolicy Bypass -File (Join-Path $Root 'enrich_images.ps1') -ActiveOnly -MaxItems 2000 -DelayMs 400
}

# Phase 5: re-enrich reports — now with backfilled caseIds, many more candidates
Step 'Phase 5: enrich reports for newly scraped + backfilled (active)' {
  & powershell.exe -ExecutionPolicy Bypass -File (Join-Path $Root 'enrich_reports.ps1') -ActiveOnly -MaxItems 2000 -DelayMs 1200
}

# Phase 6: resize all images to thumbnails to stay under GitHub Pages limits
Step 'Phase 6: resize images' {
  & powershell.exe -ExecutionPolicy Bypass -File (Join-Path $Root 'resize_images.ps1')
}

# Phase 7: commit + push. Wrap git calls in try/catch so the harmless
# LF/CRLF warnings (which PowerShell promotes to fatal errors under
# ErrorActionPreference=Stop) don't kill the publish.
Step 'Phase 7: commit + push' {
  Set-Location $Root
  $ErrorActionPreference = 'Continue'
  try {
    & git add auctions.js auctions.json images dashboard.html enrich_images.ps1 enrich_reports.ps1 resize_images.ps1 overnight_run.ps1 probe_report.ps1 2>&1 | Out-String | Write-Host
  } catch { Write-Host "git add note: $($_.Exception.Message)" }
  $status = (& git status --porcelain 2>$null) -join "`n"
  if (-not $status) { Write-Host "nothing to commit"; return }
  $ts  = (Get-Date).ToString('yyyy-MM-dd HH:mm')
  $msg = "Overnight: enrich active images + reports + fresh scrape ($ts)`n`nCo-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
  try {
    & git commit -m $msg 2>&1 | Out-String | Write-Host
    & git push origin main 2>&1 | Out-String | Write-Host
  } catch { Write-Host "git commit/push note: $($_.Exception.Message)" }
}

$end = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
$done = "`n===== Overnight run finished $end ====="
Add-Content -Path $Log -Value $done -Encoding UTF8
Write-Host $done -ForegroundColor Green

# Print summary stats
$data = Get-Content (Join-Path $Root 'auctions.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$tot     = $data.auctions.Count
$withImg = ($data.auctions | Where-Object { $_.image -and $_.image -ne '' }).Count
$withRpt = ($data.auctions | Where-Object { $_.reportUrl -and $_.reportUrl -ne '' }).Count
$nowMs = [DateTimeOffset]::Now.ToUnixTimeMilliseconds()
$active = $data.auctions | Where-Object {
  if (-not $_.endDate) { return $true }
  try { ([DateTimeOffset]::new([DateTime]::Parse([string]$_.endDate)).ToUnixTimeMilliseconds() -gt $nowMs) }
  catch { $true }
}
$summary = @"
--- Summary ---
  Total auctions:       $tot
  Active listings:      $($active.Count)
  Active with image:    $((($active | Where-Object { $_.image -and $_.image -ne '' })).Count)
  Active with report:   $((($active | Where-Object { $_.reportUrl -and $_.reportUrl -ne '' })).Count)
  Total with image:     $withImg
  Total with report:    $withRpt
"@
Add-Content -Path $Log -Value $summary -Encoding UTF8
Write-Host $summary
