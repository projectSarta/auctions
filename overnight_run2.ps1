<#
.SYNOPSIS
  Follow-up to overnight_run.ps1: the first pass left 319 active listings
  without a caseId (because scrape.ps1 -Full only checks for NEW items,
  not refreshes). This run uses -Refresh to force re-walk of every
  category, which backfills caseId on existing rows. Then re-runs report
  enrichment to pick up the now-eligible auctions, plus a retry of image
  enrichment (the regex was fixed to handle uppercase data:image/PNG MIME).
#>
[CmdletBinding()] param()

$ErrorActionPreference = 'Continue'
$Root = $PSScriptRoot
$Log  = Join-Path $Root 'overnight2.log'

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

$start = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
Set-Content -Path $Log -Value "===== Pass 2 started $start =====" -Encoding UTF8

# Phase A: Refresh existing rows (backfill caseId)
Step 'Phase A: scrape -Refresh (backfill caseId on existing rows)' {
  & powershell.exe -ExecutionPolicy Bypass -File (Join-Path $Root 'scrape.ps1') -Refresh
}

# Phase B: Re-enrich images for active listings (uppercase-MIME fix)
Step 'Phase B: enrich images (active, with regex fix for uppercase MIME)' {
  & powershell.exe -ExecutionPolicy Bypass -File (Join-Path $Root 'enrich_images.ps1') -ActiveOnly -MaxItems 2000 -DelayMs 400
}

# Phase C: Re-enrich reports — should pick up the newly backfilled caseIds
Step 'Phase C: enrich reports (active, with backfilled caseIds)' {
  & powershell.exe -ExecutionPolicy Bypass -File (Join-Path $Root 'enrich_reports.ps1') -ActiveOnly -MaxItems 2000 -DelayMs 1200
}

# Phase D: resize
Step 'Phase D: resize images' {
  & powershell.exe -ExecutionPolicy Bypass -File (Join-Path $Root 'resize_images.ps1')
}

# Phase E: commit + push
Step 'Phase E: commit + push' {
  Set-Location $Root
  $ErrorActionPreference = 'Continue'
  try {
    & git add auctions.js auctions.json images dashboard.html enrich_images.ps1 enrich_reports.ps1 resize_images.ps1 overnight_run.ps1 overnight_run2.ps1 probe_report.ps1 2>&1 | Out-String | Write-Host
  } catch { Write-Host "git add note: $($_.Exception.Message)" }
  $status = (& git status --porcelain 2>$null) -join "`n"
  if (-not $status) { Write-Host "nothing to commit"; return }
  $ts  = (Get-Date).ToString('yyyy-MM-dd HH:mm')
  $msg = "Overnight pass 2: backfill caseId + retry report/image enrichment ($ts)`n`nCo-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
  try {
    & git commit -m $msg 2>&1 | Out-String | Write-Host
    & git push origin main 2>&1 | Out-String | Write-Host
  } catch { Write-Host "git commit/push note: $($_.Exception.Message)" }
}

# Final summary
$data = Get-Content (Join-Path $Root 'auctions.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$nowMs = [DateTimeOffset]::Now.ToUnixTimeMilliseconds()
$active = $data.auctions | Where-Object {
  if (-not $_.endDate) { return $true }
  try { ([DateTimeOffset]::new([DateTime]::Parse([string]$_.endDate)).ToUnixTimeMilliseconds() -gt $nowMs) }
  catch { $true }
}
$summary = @"
--- Pass 2 Summary ---
  Total auctions:       $($data.auctions.Count)
  Active listings:      $($active.Count)
  Active with image:    $((($active | Where-Object { $_.image -and $_.image -ne '' })).Count)
  Active with report:   $((($active | Where-Object { $_.reportUrl -and $_.reportUrl -ne '' })).Count)
  Active with caseId:   $((($active | Where-Object { $_.caseId -and $_.caseId -gt 0 })).Count)
"@
Add-Content -Path $Log -Value $summary -Encoding UTF8
Write-Host $summary

$end = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
Add-Content -Path $Log -Value "`n===== Pass 2 finished $end =====" -Encoding UTF8
