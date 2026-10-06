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

# Is MoJ actually serving us right now? One cheap GET, using the same block
# test scrape.ps1 uses: a truncated body or a 'Validation request' /
# 'captcha_resp' marker means we are being refused.
#
# This exists because of what the 2026-10-05 06:20 run did. MoJ was already
# serving captchas 90 seconds in, and the run then spent 76 of its 80 minutes
# discovering that over and over - 21 minutes in report enrichment, 55 in the
# scrape (56 captcha/retry events, six 90-second cooldowns per category) -
# before giving up on every category and committing nothing. Every phase
# reported success, so from the outside the pipeline looked healthy.
# $Url is for testing only; left unset it probes MoJ's index page.
function Test-MojServing([string]$Url = 'https://auctions.moj.gov.jo/index.aspx') {
  $tmp = [System.IO.Path]::GetTempFileName()
  try {
    & curl.exe --silent --insecure --location --compressed --max-time 25 `
      --user-agent 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36' `
      --output $tmp $Url | Out-Null
    if ($LASTEXITCODE -ne 0) { return $false }          # timeout / connection reset
    $h = [System.IO.File]::ReadAllText($tmp, [System.Text.UTF8Encoding]::new($false))
    if ($h.Length -lt 5000) { return $false }
    if ($h.Contains('Validation request') -or $h.Contains('captcha_resp')) { return $false }
    return $true
  } catch { return $false }
  finally { if (Test-Path $tmp) { Remove-Item $tmp -Force -ErrorAction SilentlyContinue } }
}

$script:MojBlocked = $false

function Skip-Phase([string]$name, [string]$why) {
  $msg = "[skip] $name - $why"
  Add-Content -Path $Log -Value $msg -Encoding UTF8
  Write-Host $msg -ForegroundColor Yellow
}

# A phase that talks to MoJ. Skipped when the no-run budget is gone, and
# skipped for the rest of the run once MoJ is found to be blocking, so a
# blocked run degrades to "commit what we already have" in seconds instead of
# grinding for over an hour.
#
# This gate only decides whether a phase STARTS. It cannot interrupt one that is
# already running, so every phase must also be able to stop itself: the budget
# is handed to each via -MaxMinutes ($script:PhaseBudgetMin) and each honours it
# between items. Without that the gate is much weaker than it looks - on
# 2026-10-06 a reports batch started with 22 minutes of budget, took 63, and ran
# 30 minutes into the protected window.
function FetchStep([string]$name, [scriptblock]$cmd) {
  if ($script:MojBlocked) { Skip-Phase $name 'MoJ is blocking (detected earlier this run)'; return }

  $budget = Get-FetchBudgetMinutes
  if ($budget -lt 1) {
    $a = Get-AmmanNow
    $when = if ($null -eq $a) { 'Amman time unavailable' } else { $a.ToString('HH:mm') + ' Amman' }
    Skip-Phase $name "no-run window ($when)"
    return
  }

  if (-not (Test-MojServing)) {
    $script:MojBlocked = $true
    Skip-Phase $name 'MoJ is serving captchas - abandoning all remaining fetch phases'
    return
  }

  $script:PhaseBudgetMin = $budget
  Step $name $cmd
}

# Start fresh log header
$start = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
Set-Content -Path $Log -Value "===== Overnight run started $start =====" -Encoding UTF8

# Phase order note (changed 2026-10-05): the scrape used to run THIRD, behind
# two enrichment passes. MoJ blocks us well before a run finishes, so whatever
# requests we get before the wall went to image and report enrichment while the
# scrape - the only phase that refreshes endDate, bids and new listings - got
# whatever was left, usually nothing. The scrape now goes first.
#
# Running it first also removes the old double enrichment pass: the scrape
# backfills caseId, which report enrichment needs, so a single pass afterwards
# sees the fresh caseIds and there is nothing left for a second pass to catch.

# Phase 1: fresh full scrape - new listings, refreshed endDate/bids, caseId backfill.
FetchStep 'Phase 1: full scrape (new listings + backfill caseId)' {
  & powershell.exe -ExecutionPolicy Bypass -File (Join-Path $Root 'scrape.ps1') -Full -MaxMinutes $script:PhaseBudgetMin
}

# Phase 2: per-lot permalinks. MoJ's AuctionInfo.aspx?token=<perLotToken> is a
# real single-auction page, reachable only by replaying the listing's
# LinkButton2 postback. The token is deterministic, so one harvest per lot is
# enough and repeat runs only pay for lots added since.
#
# Moved ahead of the other enrichment on 2026-10-06. It used to run last and was
# therefore the first thing starved when MoJ blocked us mid-run: permalink
# coverage on active lots had fallen to 5% (30 of 649) while the 280 tokens we
# do hold mostly belong to lots that have since ended.
#
# The cap is deliberately TIGHT (150 lots, ~5 min) rather than the 500 it had
# when it ran last. Going second means it now competes with reports for the
# pre-block budget, and reports are not comfortable either - only 37% of active
# lots have one. A small guaranteed slice each run accumulates across runs
# without starving the phase below it; a big slice would just move the problem.
FetchStep 'Phase 2: harvest per-lot MoJ permalinks (active)' {
  & powershell.exe -ExecutionPolicy Bypass -File (Join-Path $Root 'enrich_links.ps1') -MaxLots 150 -DelayMs 900 -MaxMinutes ([Math]::Min(8, $script:PhaseBudgetMin))
}

# Phase 3: expert reports, now with caseIds the scrape backfilled this run.
# Highest-value enrichment for the "spot undervalued lots" job, so it sits ahead
# of images and maps.
FetchStep 'Phase 3: enrich reports (active)' {
  & powershell.exe -ExecutionPolicy Bypass -File (Join-Path $Root 'enrich_reports.ps1') -ActiveOnly -MaxItems 2000 -DelayMs 1200 -MaxMinutes $script:PhaseBudgetMin
}

# Phase 4: images for active listings, including everything the scrape just found.
FetchStep 'Phase 4: enrich images (active)' {
  & powershell.exe -ExecutionPolicy Bypass -File (Join-Path $Root 'enrich_images.ps1') -ActiveOnly -MaxItems 2000 -DelayMs 400 -MaxMinutes $script:PhaseBudgetMin
}

# Phase 5: aradi.io parcel polygons (fetched server-side, embedded so the
# browser doesn't have to hit aradi's no-CORS /api/plot endpoint at all).
# Last of the fetch phases because it is the only one that does not hit MoJ,
# so it is the least affected by being starved.
FetchStep 'Phase 5: enrich aradi polygons (active land rows)' {
  & powershell.exe -ExecutionPolicy Bypass -File (Join-Path $Root 'enrich_aradi.ps1') -MaxItems 400 -DelayMs 250 -MaxMinutes $script:PhaseBudgetMin
}

# Phase 6: rebuild summary.json — the landing page (index.html) reads this
# few-KB digest instead of the ~17 MB auctions.json.
Step 'Phase 6: build landing-page summary' {
  & powershell.exe -ExecutionPolicy Bypass -File (Join-Path $Root 'build_summary.ps1')
}

# Phase 7: resize all images to thumbnails to stay under GitHub Pages limits
Step 'Phase 7: resize images' {
  & powershell.exe -ExecutionPolicy Bypass -File (Join-Path $Root 'resize_images.ps1')
}

# Phase 8: commit + push. Wrap git calls in try/catch so the harmless
# LF/CRLF warnings (which PowerShell promotes to fatal errors under
# ErrorActionPreference=Stop) don't kill the publish.
Step 'Phase 8: commit + push' {
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
