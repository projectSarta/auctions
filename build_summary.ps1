<#
.SYNOPSIS
  Build summary.json — a small headline feed for the landing page (index.html).

.DESCRIPTION
  auctions.json is ~17 MB; the landing page must not download it just to show
  a few numbers. This distils it to a few KB: headline counts, per-category
  splits, the next lots closing, and the most re-announced lots (bargain
  candidates — a lot on round 4 has failed to sell three times).

  "Active" uses the same rule as the dashboard filter: endDate in the future
  (or missing) AND lastSeenInListingAt within the last 7 days.

  Run after every scrape (wired into overnight_run.ps1).
#>
[CmdletBinding()] param()

$ErrorActionPreference = 'Stop'
$Root     = $PSScriptRoot
$JsonPath = Join-Path $Root 'auctions.json'
$OutPath  = Join-Path $Root 'summary.json'

$data = Get-Content $JsonPath -Raw -Encoding UTF8 | ConvertFrom-Json
$nowLocal = Get-Date
$nowUtc   = [DateTime]::UtcNow

function Try-Date([string]$s) {
  if ([string]::IsNullOrWhiteSpace($s)) { return $null }
  try { return [DateTime]::Parse($s) } catch { return $null }
}
function Num([object]$v) {
  if ($null -eq $v) { return 0 }
  $t = ([string]$v) -replace '[^0-9.]', ''
  if ([string]::IsNullOrWhiteSpace($t)) { return 0 }
  try { return [double]$t } catch { return 0 }
}

# ---- classify ----
$active = @()
foreach ($a in $data.auctions) {
  $seen = Try-Date $a.lastSeenInListingAt
  if (-not $seen) { continue }
  if ($seen.ToUniversalTime() -le $nowUtc.AddDays(-7)) { continue }
  $end = Try-Date $a.endDate
  if ($end -and $end -le $nowLocal) { continue }
  $active += $a
}

$in24 = @(); $inWeek = @(); $reAnn = @()
foreach ($a in $active) {
  $end = Try-Date $a.endDate
  if ($end) {
    $h = ($end - $nowLocal).TotalHours
    if ($h -gt 0 -and $h -lt 24)  { $in24   += $a }
    if ($h -gt 0 -and $h -lt 168) { $inWeek += $a }
  }
  if ($a.PSObject.Properties.Match('announcementSerial').Count -and $a.announcementSerial -gt 1) { $reAnn += $a }
}

# ---- per-category ----
$totalByCat = @{}
foreach ($a in $data.auctions) {
  $c = [string]$a.category
  if (-not $c) { continue }
  if (-not $totalByCat.ContainsKey($c)) { $totalByCat[$c] = 0 }
  $totalByCat[$c]++
}
$activeByCat = @{}
foreach ($a in $active) {
  $c = [string]$a.category
  if (-not $c) { continue }
  if (-not $activeByCat.ContainsKey($c)) { $activeByCat[$c] = 0 }
  $activeByCat[$c]++
}
$categories = @()
foreach ($c in ($data.categories | ForEach-Object { [string]$_.name })) {
  $categories += [ordered]@{
    name   = $c
    active = [int]($activeByCat[$c])
    total  = [int]($totalByCat[$c])
  }
}

# ---- compact lot card ----
function Card([object]$a) {
  $det = $a.details
  $place = ''
  if ($det) {
    $bits = @()
    foreach ($k in 'القرية','المديرية','المحافظة') {
      $v = [string]$det.$k
      if ($v) { $bits += $v }
      if ($bits.Count -ge 2) { break }
    }
    $place = ($bits -join ' · ')
  }
  [ordered]@{
    id             = [int]$a.id
    category       = [string]$a.category
    court          = [string]$a.court
    place          = $place
    endDate        = [string]$a.endDate
    estimatedValue = [double](Num $a.estimatedValue)
    currentAmount  = [double](Num $a.currentAmount)
    numBids        = [int](Num $a.numBids)
    serial         = [int]$(if ($a.PSObject.Properties.Match('announcementSerial').Count) { $a.announcementSerial } else { 0 })
    hasReport      = [bool]$a.pdfPath
    hasMap         = [bool]($a.aradiPlot -and $a.aradiPlot.status -eq 'ok')
  }
}

$closingSoon = @(
  $active |
    Where-Object { Try-Date $_.endDate } |
    Sort-Object { [DateTime]::Parse($_.endDate) } |
    Select-Object -First 6 |
    ForEach-Object { Card $_ }
)
# Bargain candidates: most-re-announced first, then biggest estimated value.
$bargains = @(
  $reAnn |
    Sort-Object @{ Expression = { [int]$_.announcementSerial }; Descending = $true },
                @{ Expression = { Num $_.estimatedValue };      Descending = $true } |
    Select-Object -First 6 |
    ForEach-Object { Card $_ }
)

$doc = [ordered]@{
  generatedAt   = $nowUtc.ToString('yyyy-MM-ddTHH:mm:ssZ')
  dataScrapedAt = [string]$(if ($data.PSObject.Properties.Match('lastRunAt').Count) { $data.lastRunAt } else { $data.scrapedAt })
  totals        = [ordered]@{ all = [int]$data.auctions.Count; active = [int]$active.Count }
  endingIn24h   = [int]$in24.Count
  endingInWeek  = [int]$inWeek.Count
  reAnnounced   = [int]$reAnn.Count
  withReport    = [int](@($active | Where-Object { $_.pdfPath }).Count)
  withMap       = [int](@($active | Where-Object { $_.aradiPlot -and $_.aradiPlot.status -eq 'ok' }).Count)
  categories    = $categories
  closingSoon   = $closingSoon
  bargains      = $bargains
}

$json = $doc | ConvertTo-Json -Depth 8
[System.IO.File]::WriteAllText($OutPath, $json, [System.Text.UTF8Encoding]::new($false))

$size = [math]::Round((Get-Item $OutPath).Length / 1KB, 1)
Write-Host ("summary.json written ({0} KB)" -f $size) -ForegroundColor Green
Write-Host ("  total={0} active={1} in24h={2} inWeek={3} reAnnounced={4} report={5} map={6}" -f `
  $doc.totals.all, $doc.totals.active, $doc.endingIn24h, $doc.endingInWeek, $doc.reAnnounced, $doc.withReport, $doc.withMap)

# ---------------------------------------------------------------------------
# Bake the headline figures into index.html.
#
# The landing page fills these from summary.json at runtime, so a reader that
# does not execute JavaScript sees a literal em dash for every number the
# project exists to publish -- search crawlers and AI assistants among them.
# The page's own JS still overwrites these on load, so the client stays
# authoritative and nothing here can go stale between runs; this only gives a
# non-rendering reader something true to extract.
#
# Idempotent by construction: each element's inner text is replaced whatever it
# currently holds, so re-running works on an already-baked file.
# ---------------------------------------------------------------------------
$IndexPath = Join-Path $Root 'index.html'
# Never bake a zero. MoJ lists ~2,300 lots at any time, so active=0 means the
# dataset has aged past the 7-day lastSeenInListing window, not that there are
# no auctions. Writing that into the page would publish a false claim and leave
# it there until the next successful scrape; the em-dash placeholder is honest
# about not knowing, and the page's JS still fills in live values on load.
if ($doc.totals.active -le 0) {
  Write-Host "  skipped baking index.html: active=0, so the data is stale rather than empty" -ForegroundColor Yellow
} elseif (Test-Path $IndexPath) {
  $html  = Get-Content $IndexPath -Raw -Encoding UTF8
  $nf    = { param($n) '{0:N0}' -f [int]$n }
  $bakes = [ordered]@{
    'sActive'    = (& $nf $doc.totals.active)
    'sActiveSub' = ('من ' + (& $nf $doc.totals.all) + ' مزاد مؤرشف')
    's24'        = (& $nf $doc.endingIn24h)
    'sWeek'      = (& $nf $doc.endingInWeek)
    'sReann'     = (& $nf $doc.reAnnounced)
    'cReport'    = (& $nf $doc.withReport)
    'cMap'       = (& $nf $doc.withMap)
  }

  $hit  = 0
  $miss = @()
  foreach ($id in $bakes.Keys) {
    $pattern = '(<[^>]*\sid="' + [regex]::Escape($id) + '"[^>]*>)[^<]*(</)'
    if ([regex]::IsMatch($html, $pattern)) {
      $hit++
      $value = $bakes[$id] -replace '\$', '$$$$'
      $html  = [regex]::Replace($html, $pattern, ('${1}' + $value + '${2}'))
    } else {
      $miss += $id
    }
  }

  [System.IO.File]::WriteAllText($IndexPath, $html, [System.Text.UTF8Encoding]::new($false))
  Write-Host ("  baked {0}/{1} figures into index.html" -f $hit, $bakes.Count) -ForegroundColor Green
  # A miss means the markup changed and the landing page is now serving a
  # placeholder again. Say so rather than failing silently.
  if ($miss.Count) { Write-Host ("  WARNING: id(s) not found in index.html: {0}" -f ($miss -join ', ')) -ForegroundColor Yellow }
}

