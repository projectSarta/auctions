<#
.SYNOPSIS
  Slow-retry enrichment after a captcha hit. Same phases as overnight_run.ps1
  but skips the full scrape (we already did one this morning) and uses long
  delays (1.5s images, 2.5s reports) to stay below MoJ's anti-bot threshold.
#>
[CmdletBinding()] param()

$ErrorActionPreference = 'Continue'
$Root = $PSScriptRoot
$Log  = Join-Path $Root 'overnight_slow.log'

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

Set-Content -Path $Log -Value ("===== Slow retry started {0} =====" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')) -Encoding UTF8

# Cool-off pause before first request so any active rate-limit window expires.
Write-Host "Cooling off for 30s before first request..."
Start-Sleep -Seconds 30

Step 'Phase A: enrich images (active, slow)' {
  & powershell.exe -ExecutionPolicy Bypass -File (Join-Path $Root 'enrich_images.ps1') -ActiveOnly -MaxItems 2000 -DelayMs 1500 -MaxConsecutiveErrors 10
}

Step 'Phase B: enrich reports (active, slow)' {
  & powershell.exe -ExecutionPolicy Bypass -File (Join-Path $Root 'enrich_reports.ps1') -ActiveOnly -MaxItems 2000 -DelayMs 2500 -MaxConsecutiveErrors 8
}

Step 'Phase C: resize new images' {
  & powershell.exe -ExecutionPolicy Bypass -File (Join-Path $Root 'resize_images.ps1')
}

Step 'Phase D: commit + push' {
  Set-Location $Root
  $ErrorActionPreference = 'Continue'
  try {
    & git add auctions.js auctions.json images reports dashboard.html enrich_images.ps1 enrich_reports.ps1 resize_images.ps1 overnight_slow.ps1 2>&1 | Out-String | Write-Host
  } catch {}
  $status = (& git status --porcelain 2>$null) -join "`n"
  if (-not $status) { Write-Host "nothing to commit"; return }
  $ts  = (Get-Date).ToString('yyyy-MM-dd HH:mm')
  $msg = "Slow-retry enrichment after captcha cool-off ($ts)`n`nCo-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
  try {
    & git commit -m $msg 2>&1 | Out-String | Write-Host
    & git push origin main 2>&1 | Out-String | Write-Host
  } catch {}
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
--- Slow-retry Summary ---
  Total auctions:       $($data.auctions.Count)
  Active listings:      $($active.Count)
  Active with image:    $((($active | Where-Object { $_.image -and $_.image -ne '' })).Count)
  Active with report:   $((($active | Where-Object { $_.reportUrl -and $_.reportUrl -ne '' })).Count)
"@
Add-Content -Path $Log -Value $summary -Encoding UTF8
Write-Host $summary
Add-Content -Path $Log -Value ("`n===== Slow retry finished {0} =====" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')) -Encoding UTF8
