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

# ---------------------------------------------------------------------------
# No-run window: nothing may touch auctions.moj.gov.jo between 11:00 and 17:00
# Amman. Cron alone cannot guarantee this — GitHub fires scheduled jobs late
# under load, and a run that starts safely can still be mid-scrape when the
# window opens. So the window is enforced here, per phase, against the clock.
# ---------------------------------------------------------------------------
$NoRunStartHour = 11
$NoRunEndHour   = 17
$StopMarginMin  = 10     # stop this many minutes BEFORE the window opens

function Get-AmmanNow {
  # Windows and Linux .NET use different ids for the same zone; try both rather
  # than hardcoding a UTC offset (Jordan's DST rules have changed before).
  foreach ($id in @('Jordan Standard Time','Asia/Amman')) {
    try {
      return [System.TimeZoneInfo]::ConvertTimeFromUtc([DateTime]::UtcNow, [System.TimeZoneInfo]::FindSystemTimeZoneById($id))
    } catch { }
  }
  return $null
}

# Minutes of fetching still permitted before the window opens.
#   -1 = not allowed at all (inside the window, or Amman time unknowable).
# $Now is for testing only; left unset it reads the real Amman clock. A guard
# that enforces a hard rule should be checkable without waiting for the clock.
function Get-FetchBudgetMinutes([datetime]$Now = [datetime]::MinValue) {
  $a = if ($Now -eq [datetime]::MinValue) { Get-AmmanNow } else { $Now }
  if ($null -eq $a) { return -1 }                     # can't verify => don't fetch
  if ($a.Hour -ge $NoRunStartHour -and $a.Hour -lt $NoRunEndHour) { return -1 }
  $next = $a.Date.AddHours($NoRunStartHour)
  if ($a -ge $next) { $next = $next.AddDays(1) }
  $mins = [int](($next - $a).TotalMinutes) - $StopMarginMin
  # Clamp to the -1 sentinel. This matters: scrape.ps1 reads -MaxMinutes <= 0
  # as "no limit", so handing it a small-or-negative number would remove the
  # ceiling at exactly the moment the least time is left.
  if ($mins -lt 1) { return -1 }
  return $mins
}

# A phase that talks to MoJ. Skipped entirely once the budget is gone, so a
# long run degrades to "commit what we already have" instead of overrunning.
function FetchStep([string]$name, [scriptblock]$cmd) {
  $budget = Get-FetchBudgetMinutes
  if ($budget -lt 1) {
    $a = Get-AmmanNow
    $when = if ($null -eq $a) { 'Amman time unavailable' } else { $a.ToString('HH:mm') + ' Amman' }
    $msg = "[skip] $name - no-run window ($when)"
    Add-Content -Path $Log -Value $msg -Encoding UTF8
    Write-Host $msg -ForegroundColor Yellow
    return
  }
  $script:PhaseBudgetMin = $budget
  Step $name $cmd
}

# Start fresh log header
$start = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
Set-Content -Path $Log -Value "===== Overnight run started $start =====" -Encoding UTF8

# Phase 1: enrich images for active listings (any category)
FetchStep 'Phase 1: enrich images (active, all categories)' {
  & powershell.exe -ExecutionPolicy Bypass -File (Join-Path $Root 'enrich_images.ps1') -ActiveOnly -MaxItems 2000 -DelayMs 400
}

# Phase 2: enrich reports for active listings (whatever caseIds we have now)
FetchStep 'Phase 2: enrich reports (active, current caseIds)' {
  & powershell.exe -ExecutionPolicy Bypass -File (Join-Path $Root 'enrich_reports.ps1') -ActiveOnly -MaxItems 2000 -DelayMs 1200
}

# Phase 3: fresh full scrape — this fetches new listings AND backfills caseId
# on existing rows that don't have one (so report enrichment can catch them next).
FetchStep 'Phase 3: full scrape (new listings + backfill caseId)' {
  & powershell.exe -ExecutionPolicy Bypass -File (Join-Path $Root 'scrape.ps1') -Full -MaxMinutes $script:PhaseBudgetMin
}

# Phase 4: re-enrich images for any newly-scraped active listings
FetchStep 'Phase 4: enrich images for newly scraped (active)' {
  & powershell.exe -ExecutionPolicy Bypass -File (Join-Path $Root 'enrich_images.ps1') -ActiveOnly -MaxItems 2000 -DelayMs 400
}

# Phase 5: re-enrich reports — now with backfilled caseIds, many more candidates
FetchStep 'Phase 5: enrich reports for newly scraped + backfilled (active)' {
  & powershell.exe -ExecutionPolicy Bypass -File (Join-Path $Root 'enrich_reports.ps1') -ActiveOnly -MaxItems 2000 -DelayMs 1200
}

# Phase 5b: aradi.io parcel polygons (fetched server-side, embedded so the
# browser doesn't have to hit aradi's no-CORS /api/plot endpoint at all).
FetchStep 'Phase 5b: enrich aradi polygons (active land rows)' {
  & powershell.exe -ExecutionPolicy Bypass -File (Join-Path $Root 'enrich_aradi.ps1') -MaxItems 400 -DelayMs 250
}

# Phase 5b2: per-lot permalinks. MoJ's AuctionInfo.aspx?token=<perLotToken> is
# a real single-auction page, reachable only by replaying the listing's
# LinkButton2 postback. The token is deterministic, so one harvest per lot is
# enough and repeat runs only pay for lots added since. Runs after the scrape
# so newly-listed lots are included.
FetchStep 'Phase 5b2: harvest per-lot MoJ permalinks (active)' {
  & powershell.exe -ExecutionPolicy Bypass -File (Join-Path $Root 'enrich_links.ps1') -MaxLots 500 -DelayMs 900 -MaxMinutes ([Math]::Min(25, $script:PhaseBudgetMin))
}

# Phase 5c: rebuild summary.json — the landing page (index.html) reads this
# few-KB digest instead of the ~17 MB auctions.json.
Step 'Phase 5c: build landing-page summary' {
  & powershell.exe -ExecutionPolicy Bypass -File (Join-Path $Root 'build_summary.ps1')
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

  # Stamp `lastRunAt` on auctions.json BEFORE staging so the dashboard knows
  # when this orchestrator actually ran. (Unlike `scrapedAt`, which only
  # updates when scrape.ps1 reaches its final Save-All — meaning a captcha
  # or zero-new-items run leaves it stale.)
  try {
    $json = Get-Content (Join-Path $Root 'auctions.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $stamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    $json | Add-Member -MemberType NoteProperty -Name 'lastRunAt' -Value $stamp -Force
    $out = $json | ConvertTo-Json -Depth 12
    [System.IO.File]::WriteAllText((Join-Path $Root 'auctions.json'), $out, [System.Text.UTF8Encoding]::new($false))
    [System.IO.File]::WriteAllText((Join-Path $Root 'auctions.js'),   "window.AUCTION_DATA = $out;", [System.Text.UTF8Encoding]::new($false))
  } catch { Write-Host "lastRunAt stamp note: $($_.Exception.Message)" }

  try {
    & git add auctions.js auctions.json summary.json images reports dashboard.html index.html enrich_images.ps1 enrich_reports.ps1 enrich_aradi.ps1 enrich_links.ps1 build_summary.ps1 resize_images.ps1 overnight_run.ps1 probe_report.ps1 2>&1 | Out-String | Write-Host
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
