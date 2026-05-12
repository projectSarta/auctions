<#
.SYNOPSIS
  Pass 3: deep caseId backfill via the focused listing-page walk,
  then re-enrich reports, resize, commit + push.
#>
[CmdletBinding()] param()

$ErrorActionPreference = 'Continue'
$Root = $PSScriptRoot
$Log  = Join-Path $Root 'overnight3.log'

function Step([string]$name, [scriptblock]$cmd) {
  $ts = Get-Date -Format 'HH:mm:ss'
  $hdr = "`n[$ts] ===== $name ====="
  Add-Content -Path $Log -Value $hdr -Encoding UTF8
  Write-Host $hdr -ForegroundColor Cyan
  try { & $cmd 2>&1 | Tee-Object -FilePath $Log -Append }
  catch {
    $err = "[$ts] ERROR in {0} : {1}" -f $name, $_.Exception.Message
    Add-Content -Path $Log -Value $err -Encoding UTF8
    Write-Host $err -ForegroundColor Red
  }
}

Set-Content -Path $Log -Value ("===== Pass 3 started {0} =====" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')) -Encoding UTF8

Step 'Phase A: walk every listing page, backfill caseId from SetAuctionData' {
  & powershell.exe -ExecutionPolicy Bypass -File (Join-Path $Root 'backfill_caseid.ps1') -MaxPagesPerCategory 200 -DelayMs 700
}

Step 'Phase B: re-enrich reports (active, with backfilled caseIds)' {
  & powershell.exe -ExecutionPolicy Bypass -File (Join-Path $Root 'enrich_reports.ps1') -ActiveOnly -MaxItems 2000 -DelayMs 1200
}

Step 'Phase C: resize images' {
  & powershell.exe -ExecutionPolicy Bypass -File (Join-Path $Root 'resize_images.ps1')
}

Step 'Phase D: commit + push' {
  Set-Location $Root
  $ErrorActionPreference = 'Continue'
  try {
    & git add auctions.js auctions.json images dashboard.html enrich_images.ps1 enrich_reports.ps1 resize_images.ps1 backfill_caseid.ps1 overnight_run3.ps1 2>&1 | Out-String | Write-Host
  } catch { Write-Host ("git add note: {0}" -f $_.Exception.Message) }
  $status = (& git status --porcelain 2>$null) -join "`n"
  if (-not $status) { Write-Host "nothing to commit"; return }
  $ts  = (Get-Date).ToString('yyyy-MM-dd HH:mm')
  $msg = "Overnight pass 3: deep caseId backfill + final report enrichment ($ts)`n`nCo-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
  try {
    & git commit -m $msg 2>&1 | Out-String | Write-Host
    & git push origin main 2>&1 | Out-String | Write-Host
  } catch { Write-Host ("git push note: {0}" -f $_.Exception.Message) }
}

$data = Get-Content (Join-Path $Root 'auctions.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$nowMs = [DateTimeOffset]::Now.ToUnixTimeMilliseconds()
$active = $data.auctions | Where-Object {
  if (-not $_.endDate) { return $true }
  try { ([DateTimeOffset]::new([DateTime]::Parse([string]$_.endDate)).ToUnixTimeMilliseconds() -gt $nowMs) }
  catch { $true }
}
$summary = @"
--- Pass 3 Summary ---
  Total auctions:       $($data.auctions.Count)
  Active listings:      $($active.Count)
  Active with image:    $((($active | Where-Object { $_.image -and $_.image -ne '' })).Count)
  Active with report:   $((($active | Where-Object { $_.reportUrl -and $_.reportUrl -ne '' })).Count)
  Active with caseId:   $((($active | Where-Object { $_.caseId -and $_.caseId -gt 0 })).Count)
"@
Add-Content -Path $Log -Value $summary -Encoding UTF8
Write-Host $summary
Add-Content -Path $Log -Value ("`n===== Pass 3 finished {0} =====" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')) -Encoding UTF8
