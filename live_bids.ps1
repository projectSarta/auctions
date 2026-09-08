<#
.SYNOPSIS
  Live bid tracker: subscribes to MoJ's SignalR biddingHub (longPolling) for
  auctions ending soon, and publishes live state to live_bids.json.

.DESCRIPTION
  MoJ's listing pages stream real-time events over classic SignalR 2.x
  (/signalr, hub "biddinghub", longPolling transport). Anonymous negotiate
  works; the WAF requires GET for connect/poll and POST only for send
  (matching the real jquery.signalR client's verbs).

  Events captured per auction:
    UpdateHighestBiddingAmmount (id, amount)     -> live bid + bid history
    UpdateMinimumBidValue       (id, minValue)
    UpdateAuctionEndDate        (id, newEnd,...) -> anti-snipe extensions
    UpdateAuctionBiddingStatus  (id, status)
    UpdateAuctionExistenceStatus(id, status)
    cancelAuction               (id, reason, displayReason)

  State is written to live_bids.json after every event and pushed to git on a
  cadence so the GitHub Pages dashboard can overlay near-live data. The file
  is tracker-owned: the scraper never writes it, so pushes seldom conflict.

.PARAMETER Minutes       Session length before clean exit (default 55).
.PARAMETER WindowHours   Subscribe to auctions ending within this many hours (default 30).
.PARAMETER MaxAuctions   Subscription cap per session (default 190).
.PARAMETER PushEveryMin  Git push cadence in minutes; 0 = never push (default 5).
#>
[CmdletBinding()]
param(
  [int]$Minutes = 55,
  [int]$WindowHours = 30,
  [int]$MaxAuctions = 190,
  [int]$PushEveryMin = 5
)

$ErrorActionPreference = 'Stop'
$Curl = 'C:\Windows\System32\curl.exe'
$Base = 'https://auctions.moj.gov.jo'
$UA   = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36'
$Root = $PSScriptRoot
$Jar  = Join-Path $env:TEMP ('moj_livebids_' + $PID + '.txt')
$OutFile = Join-Path $Root 'live_bids.json'
$CD = [System.Uri]::EscapeDataString('[{"name":"biddinghub"}]')
$Deadline = (Get-Date).AddMinutes($Minutes)

function CurlGet([string]$url, [int]$timeoutSec = 130) {
  & $Curl --silent --insecure --max-time $timeoutSec --user-agent $UA `
    --header "Referer: $Base/AuctionsList.aspx" `
    --cookie-jar $Jar --cookie $Jar $url
}
function CurlSend([string]$url, [string]$body) {
  & $Curl --silent --insecure --max-time 30 --user-agent $UA `
    --header "Referer: $Base/AuctionsList.aspx" `
    --header 'Content-Type: application/x-www-form-urlencoded' `
    --cookie-jar $Jar --cookie $Jar --data $body $url
}

# ---- pick target auctions ----
Write-Host "Loading auctions.json..." -ForegroundColor Cyan
$data = Get-Content (Join-Path $Root 'auctions.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$now = Get-Date
$targets = @($data.auctions | Where-Object {
  $_.endDate -and
  ([DateTime]::Parse($_.endDate) -gt $now) -and
  ([DateTime]::Parse($_.endDate) -lt $now.AddHours($WindowHours)) -and
  $_.lastSeenInListingAt -and
  ([DateTime]::Parse($_.lastSeenInListingAt).ToUniversalTime() -gt [DateTime]::UtcNow.AddDays(-3))
} | Sort-Object { [DateTime]::Parse($_.endDate) } | Select-Object -First $MaxAuctions)
Write-Host ("Targets ending within {0}h: {1}" -f $WindowHours, $targets.Count)
if ($targets.Count -eq 0) { Write-Host "Nothing ending soon - exiting."; exit 0 }

# ---- live state (id -> entry), seeded from the scrape so overlay deltas are visible ----
$state = @{}
foreach ($t in $targets) {
  $state[[string]$t.id] = [ordered]@{
    id            = [int]$t.id
    baseAmount    = [string]$t.currentAmount   # scrape-time amount, for delta display
    currentAmount = $null                      # set on first live event
    minIncrement  = $null
    endDate       = $null                      # set only when MoJ extends
    status        = $null
    cancelled     = $false
    cancelReason  = $null
    lastEventAt   = $null
    bids          = @()                        # [{at, amount}] live bid history
  }
}
$script:dirty = $false

function Save-State {
  $doc = [ordered]@{
    updatedAt   = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
    sessionEnds = $Deadline.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    auctions    = @($state.Values | Where-Object { $_.lastEventAt -or $_.cancelled })
    tracked     = $state.Count
  }
  $json = $doc | ConvertTo-Json -Depth 8
  [System.IO.File]::WriteAllText($OutFile, $json, [System.Text.UTF8Encoding]::new($false))
}

$script:lastPush = Get-Date
function Push-IfDue {
  if ($PushEveryMin -le 0 -or -not $script:dirty) { return }
  if (((Get-Date) - $script:lastPush).TotalMinutes -lt $PushEveryMin) { return }
  Write-Host "[push] live_bids.json" -ForegroundColor Cyan
  try {
    Push-Location $Root
    & git -c windows.appendAtomically=false pull --rebase origin main 2>&1 | Out-Null
    & git -c windows.appendAtomically=false add live_bids.json 2>&1 | Out-Null
    $msg = "live: bid tracker update " + (Get-Date).ToString('HH:mm')
    & git -c windows.appendAtomically=false commit -m $msg 2>&1 | Out-Null
    & git -c windows.appendAtomically=false push origin main 2>&1 | Out-Null
    $script:dirty = $false
    $script:lastPush = Get-Date
  } catch { Write-Host ("[push] failed: " + $_.Exception.Message) -ForegroundColor Yellow }
  finally { Pop-Location }
}

function Handle-Event([string]$method, [object[]]$args) {
  if (-not $args -or $args.Count -lt 1) { return }
  $id = [string]$args[0]
  if (-not $state.ContainsKey($id)) {
    # event for a lot we did not subscribe to (group bleed) - track it anyway
    $state[$id] = [ordered]@{ id=[int]$id; baseAmount=$null; currentAmount=$null; minIncrement=$null; endDate=$null; status=$null; cancelled=$false; cancelReason=$null; lastEventAt=$null; bids=@() }
  }
  $e = $state[$id]
  $ts = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
  switch ($method) {
    'UpdateHighestBiddingAmmount' {
      $amt = [string]$args[1]
      $e.currentAmount = $amt
      $e.bids = @($e.bids) + ,([ordered]@{ at=$ts; amount=$amt })
      if ($e.bids.Count -gt 50) { $e.bids = @($e.bids | Select-Object -Last 50) }
      Write-Host ("  [{0}] BID {1} -> {2}" -f (Get-Date).ToString('HH:mm:ss'), $id, $amt) -ForegroundColor Green
    }
    'UpdateMinimumBidValue' {
      $e.minIncrement = [string]$args[1]
      Write-Host ("  [{0}] MININC {1} -> {2}" -f (Get-Date).ToString('HH:mm:ss'), $id, $args[1]) -ForegroundColor DarkCyan
    }
    'UpdateAuctionEndDate' {
      $e.endDate = [string]$args[1]
      Write-Host ("  [{0}] EXTEND {1} -> {2}" -f (Get-Date).ToString('HH:mm:ss'), $id, $args[1]) -ForegroundColor Yellow
    }
    'UpdateAuctionBiddingStatus' {
      $e.status = [string]$args[1]
      Write-Host ("  [{0}] STATUS {1} -> {2}" -f (Get-Date).ToString('HH:mm:ss'), $id, $args[1]) -ForegroundColor DarkYellow
    }
    'UpdateAuctionExistenceStatus' {
      $e.status = [string]$args[1]
      Write-Host ("  [{0}] EXIST {1} -> {2}" -f (Get-Date).ToString('HH:mm:ss'), $id, $args[1]) -ForegroundColor DarkYellow
    }
    'cancelAuction' {
      $e.cancelled = $true
      if ($args.Count -ge 2) { $e.cancelReason = [string]$args[1] }
      Write-Host ("  [{0}] CANCELLED {1}: {2}" -f (Get-Date).ToString('HH:mm:ss'), $id, $e.cancelReason) -ForegroundColor Red
    }
    default { return }
  }
  $e.lastEventAt = $ts
  $script:dirty = $true
  Save-State
}

# ---- one SignalR session (returns when connection dies; caller reconnects) ----
function Run-Session {
  if (Test-Path $Jar) { Remove-Item $Jar -Force }
  $neg = CurlGet "$Base/signalr/negotiate?clientProtocol=1.5&connectionData=$CD" 30 | ConvertFrom-Json
  $tok = [System.Uri]::EscapeDataString($neg.ConnectionToken)
  Write-Host ("[signalr] connected " + $neg.ConnectionId) -ForegroundColor Cyan

  $conn = CurlGet "$Base/signalr/connect?transport=longPolling&clientProtocol=1.5&connectionToken=$tok&connectionData=$CD" 40 | ConvertFrom-Json
  $cursor = $conn.C
  [void](CurlGet "$Base/signalr/start?transport=longPolling&clientProtocol=1.5&connectionToken=$tok&connectionData=$CD" 30)

  # register all targets
  $i = 1
  foreach ($id in $state.Keys) {
    $inv = '{"H":"biddinghub","M":"registerUserToAuction","A":["' + $id + '"],"I":' + $i + '}'
    $r = CurlSend "$Base/signalr/send?transport=longPolling&clientProtocol=1.5&connectionToken=$tok&connectionData=$CD" ("data=" + [System.Uri]::EscapeDataString($inv))
    if (-not $r -or $r -notmatch '"I"') { Write-Host ("  register {0} failed" -f $id) -ForegroundColor Yellow }
    $i++
    Start-Sleep -Milliseconds 120
  }
  Write-Host ("[signalr] registered {0} auctions - polling until {1}" -f $state.Count, $Deadline.ToString('HH:mm'))

  # MoJ configures ConnectionTimeout=10800s — the server may hold a poll for
  # HOURS when no events occur. A curl timeout on poll is therefore NORMAL
  # (a quiet market), not a dead connection: just re-poll with the same
  # cursor — buffered events are delivered on the next poll. We cap each poll
  # at 90s so the loop cycles regularly (git pushes, deadline checks), and
  # only do a full reconnect after many consecutive quiet cycles as a safety.
  $quietCycles = 0
  while ((Get-Date) -lt $Deadline) {
    $mid = [System.Uri]::EscapeDataString([string]$cursor)
    $poll = CurlGet "$Base/signalr/poll?transport=longPolling&clientProtocol=1.5&connectionToken=$tok&connectionData=$CD&messageId=$mid" 90
    Push-IfDue
    if ([string]::IsNullOrWhiteSpace($poll)) {
      $quietCycles++
      if ($quietCycles -ge 20) { Write-Host "[signalr] 20 quiet cycles (~30 min) - precautionary reconnect" -ForegroundColor Yellow; return }
      continue
    }
    $quietCycles = 0
    $pj = $null
    try { $pj = $poll | ConvertFrom-Json } catch {
      Write-Host ("[signalr] unparseable poll response - reconnecting: " + $poll.Substring(0, [Math]::Min(80, $poll.Length))) -ForegroundColor Yellow
      return
    }
    if ($pj.C) { $cursor = $pj.C }
    if ($pj.M) {
      foreach ($msg in $pj.M) {
        if ($msg.H -and $msg.H -ieq 'biddingHub' -and $msg.M) {
          Handle-Event ([string]$msg.M) $msg.A
        }
      }
    }
  }
}

# ---- main loop with reconnect ----
Save-State   # write the initial (empty-events) doc so the dashboard sees the session
while ((Get-Date) -lt $Deadline) {
  try { Run-Session } catch { Write-Host ("[signalr] session error: " + $_.Exception.Message) -ForegroundColor Yellow }
  if ((Get-Date) -lt $Deadline) { Start-Sleep -Seconds 5 }
}

# final save + push
Save-State
$script:lastPush = (Get-Date).AddMinutes(-$PushEveryMin - 1)
Push-IfDue
if (Test-Path $Jar) { Remove-Item $Jar -Force }
$eventsCount = @($state.Values | Where-Object { $_.lastEventAt }).Count
Write-Host ("Session over. Auctions with live events: {0}/{1}" -f $eventsCount, $state.Count) -ForegroundColor Cyan
