<#
.SYNOPSIS
  Scrape Jordan MoJ auctions (auctions.moj.gov.jo) into auctions.json + auctions.js.

.DESCRIPTION
  Walks all 5 category tabs from index.aspx, paginates each via ASP.NET
  __doPostBack on lbNext while preserving ViewState/EventValidation, parses
  each auction-div block into structured fields, and writes the combined data
  INCREMENTALLY (after every page that yields new items) so the dashboard
  always has fresh data to load.

.PARAMETER MaxPagesPerCategory
  Limit pages per category (10 items per page). Default 3. Use 0 for unlimited.

.PARAMETER Full
  Equivalent to -MaxPagesPerCategory 0 (scrape everything).

.EXAMPLE
  ./scrape.ps1                    # quick scrape (~150 items)
  ./scrape.ps1 -Full              # full scrape (~2400 items, slow)
  ./scrape.ps1 -MaxPagesPerCategory 10
#>
[CmdletBinding()]
param(
  [int]$MaxPagesPerCategory = 3,
  [switch]$Full,
  [int]$DelayMs = 3000,
  [int]$CaptchaCooldownSec = 90,
  [int]$MaxCaptchaWaits = 6,
  [int]$MaxResetsPerCategory = 30,   # max session resets per category
  [int]$MaxKnownPages = 15,          # cap pages walked through already-seen territory before resetting
  [int]$MaxMinutes = 0,              # global time budget (0 = unlimited)
  [switch]$Fresh,                    # ignore existing auctions.json (don't merge)
  [string]$OnlyCategory = '',        # if set, only scrape categories matching this regex (e.g. 'مركبة')
  [switch]$Refresh,                  # don't early-exit when already-complete; keep walking to refresh bids/numBids/endDate
  [switch]$DedupeOnly,               # collapse duplicate rows in auctions.json and exit; no network calls
  [int]$ProactiveResetPages = 0,     # reset the session every N pages; 0 = never (see note at the reset site)
  [int]$SavePageInterval = 10        # checkpoint auctions.json every N pages (end of category always saves)
)

$script:PagesSinceSave = 0

if ($Full) { $MaxPagesPerCategory = 0 }
$ScriptStart = Get-Date

# Global time budget. -MaxMinutes used to be checked in exactly one place —
# inside PASS B's per-category walk — where a plain `break` ended only THAT
# category and the foreach moved straight on to the next one. With 5 categories
# a "60 minute" budget could therefore run for ~5 hours. PASS A checked it
# nowhere at all. This makes the budget stop the whole run, once.
$script:BudgetStopped = $false
function Test-Budget {
  if ($MaxMinutes -le 0) { return $false }
  if ($script:BudgetStopped) { return $true }
  if (((Get-Date) - $ScriptStart).TotalMinutes -ge $MaxMinutes) {
    $script:BudgetStopped = $true
    Write-Host ("  [budget] {0} min reached - stopping all fetch work" -f $MaxMinutes) -ForegroundColor Yellow
    return $true
  }
  return $false
}

$ErrorActionPreference = 'Stop'

$CurlExe   = 'C:\Windows\System32\curl.exe'
$Base      = 'https://auctions.moj.gov.jo'

# ---- Anti-bot resilience ----
# Rotate User-Agent on every session reset so MoJ's fingerprinting can't pin
# the scraper to a single client signature. Picked from current versions of
# Chrome, Edge, Firefox, Safari across Windows/Mac.
$UserAgents = @(
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36',
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36 Edg/126.0.0.0',
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:127.0) Gecko/20100101 Firefox/127.0',
  'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Safari/605.1.15',
  'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36',
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36'
)
$UserAgent = $UserAgents | Get-Random
function Rotate-UserAgent { $script:UserAgent = $script:UserAgents | Get-Random; Write-Host ("    [ua] rotated -> " + $script:UserAgent.Substring(0, [Math]::Min(60, $script:UserAgent.Length)) + "...") -ForegroundColor DarkGray }

# Jittered delay: ±50% around the base value so the request cadence isn't
# clockwork-perfect (which is one of the cheapest bot signals to detect).
function Get-JitteredDelay {
  if ($DelayMs -le 0) { return 0 }
  $min = [int]($DelayMs * 0.5)
  $max = [int]($DelayMs * 1.5)
  return (Get-Random -Minimum $min -Maximum $max)
}
$CookieJar = Join-Path $PSScriptRoot 'cookies.txt'
if (Test-Path $CookieJar) { Remove-Item $CookieJar -Force }

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

function Curl-PostForm([string]$url, [hashtable]$form) {
  $bodyFile = [System.IO.Path]::GetTempFileName()
  $outFile  = [System.IO.Path]::GetTempFileName()
  try {
    # x-www-form-urlencoded encoder that handles arbitrarily long values.
    # [System.Uri]::EscapeDataString() throws on inputs >65,520 chars — modern
    # ASP.NET ViewStates routinely exceed that. We chunk in 32k slices and
    # concatenate (each chunk is encoded safely since neither boundary lands
    # in the middle of a multi-byte sequence we care about).
    $encode = {
      param([string]$s)
      if ($null -eq $s -or $s.Length -eq 0) { return '' }
      if ($s.Length -le 32000) { return [System.Uri]::EscapeDataString($s) }
      $out = New-Object System.Text.StringBuilder
      $i = 0
      while ($i -lt $s.Length) {
        $chunk = $s.Substring($i, [Math]::Min(32000, $s.Length - $i))
        [void]$out.Append([System.Uri]::EscapeDataString($chunk))
        $i += $chunk.Length
      }
      return $out.ToString()
    }
    $sb = New-Object System.Text.StringBuilder
    $first = $true
    foreach ($k in $form.Keys) {
      if (-not $first) { [void]$sb.Append('&') }
      [void]$sb.Append((& $encode $k))
      [void]$sb.Append('=')
      [void]$sb.Append((& $encode ([string]$form[$k])))
      $first = $false
    }
    [System.IO.File]::WriteAllText($bodyFile, $sb.ToString(), [System.Text.UTF8Encoding]::new($false))

    & $CurlExe --silent --insecure --location --compressed `
      --user-agent $UserAgent `
      --header 'Accept: text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8' `
      --header 'Accept-Language: ar,en;q=0.8' `
      --header 'Content-Type: application/x-www-form-urlencoded' `
      --cookie-jar $CookieJar --cookie $CookieJar `
      --data "@$bodyFile" `
      --output $outFile `
      $url | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "curl POST failed (exit $LASTEXITCODE) for $url" }
    return [System.IO.File]::ReadAllText($outFile, [System.Text.UTF8Encoding]::new($false))
  } finally {
    if (Test-Path $bodyFile) { Remove-Item $bodyFile -Force }
    if (Test-Path $outFile)  { Remove-Item $outFile  -Force }
  }
}

function Test-Captcha([string]$html) {
  if ($null -eq $html) { return $true }
  if ($html.Length -lt 5000) { return $true }
  if ($html.Contains('Validation request') -or $html.Contains('captcha_resp')) { return $true }
  return $false
}

function Wait-PastCaptcha([string]$probeUrl) {
  for ($i = 1; $i -le $MaxCaptchaWaits; $i++) {
    Write-Host ("    [captcha] cooldown {0}s (attempt {1}/{2})" -f $CaptchaCooldownSec, $i, $MaxCaptchaWaits) -ForegroundColor Yellow
    Start-Sleep -Seconds $CaptchaCooldownSec
    try {
      $h = Curl-Get $probeUrl
      if (-not (Test-Captcha $h)) { return $h }
    } catch { }
  }
  return $null
}

function Reset-Session {
  if (Test-Path $CookieJar) { Remove-Item $CookieJar -Force }
  Rotate-UserAgent
  Start-Sleep -Seconds $CaptchaCooldownSec
  try { [void](Curl-Get "$Base/index.aspx") } catch { }
}

function Get-FormFields([string]$html) {
  $vs  = [regex]::Match($html, 'name="__VIEWSTATE"\s+id="__VIEWSTATE"\s+value="([^"]*)"').Groups[1].Value
  $vsg = [regex]::Match($html, 'name="__VIEWSTATEGENERATOR"\s+id="__VIEWSTATEGENERATOR"\s+value="([^"]*)"').Groups[1].Value
  $ev  = [regex]::Match($html, 'name="__EVENTVALIDATION"\s+id="__EVENTVALIDATION"\s+value="([^"]*)"').Groups[1].Value
  @{ ViewState = $vs; ViewStateGenerator = $vsg; EventValidation = $ev }
}

function Clean-Text([string]$s) {
  if ($null -eq $s) { return '' }
  $s = [regex]::Replace($s, '<[^>]+>', ' ')
  $s = [System.Net.WebUtility]::HtmlDecode($s)
  $s = [regex]::Replace($s, '\s+', ' ')
  $s.Trim()
}

function Parse-Auctions([string]$html, [string]$category) {
  $parts = [regex]::Split($html, '<div class="row auction-div">')
  $out = New-Object System.Collections.ArrayList
  for ($i = 1; $i -lt $parts.Count; $i++) {
    $blk = $parts[$i]

    $idMatch = [regex]::Match($blk, 'AuctionEndDateFormated_(\d+)')
    if (-not $idMatch.Success) { continue }
    $id = $idMatch.Groups[1].Value

    $header = ''
    $hm = [regex]::Match($blk, 'col-xs-11 bold[^>]*>([\s\S]*?)</div>')
    if ($hm.Success) { $header = Clean-Text $hm.Groups[1].Value }

    $img = ''
    $im = [regex]::Match($blk, 'id="imgAuctionImage_' + $id + '"[^>]*src="([^"]+)"')
    if ($im.Success) {
      $imgPath = $im.Groups[1].Value
      if ($imgPath -ne '/Images/noimage.jpg') {
        if ($imgPath.StartsWith('/')) { $img = $Base + $imgPath } else { $img = $imgPath }
      }
    }

    # endDate: prefer the LIVE countdown deadline (3rd hidden input inside
    # divCountDownVal). This is what MoJ's "باقي على انتهاء المزاد" uses, and
    # it reflects re-announcements properly. The AuctionEndDateFormated_ span
    # can stay stuck on the original deadline.
    $endDate = ''
    $dcd = [regex]::Match($blk, '<div class="divCountDownVal">([\s\S]*?)</div>')
    if ($dcd.Success) {
      $inputVals = [regex]::Matches($dcd.Groups[1].Value, 'value="([^"]*)"') | ForEach-Object { $_.Groups[1].Value }
      if ($inputVals.Count -ge 3) { $endDate = $inputVals[2].Trim() }
    }
    if (-not $endDate) {
      $em = [regex]::Match($blk, 'id="AuctionEndDateFormated_' + $id + '"[^>]*>([^<]*)</span>')
      if ($em.Success) { $endDate = $em.Groups[1].Value.Trim() }
    }

    $numBids  = (([regex]::Match($blk, 'id="NumberOfBiddings_' + $id + '">([^<]*)')).Groups[1].Value).Trim()
    $startAmt = (([regex]::Match($blk, 'id="StartingAuctionAmount_' + $id + '">([^<]*)')).Groups[1].Value).Trim()
    $estVal   = (([regex]::Match($blk, 'id="intEstimatedValue_' + $id + '">([^<]*)')).Groups[1].Value).Trim()
    $highAmt  = (([regex]::Match($blk, 'id="HighestAuctionAmount_' + $id + '">([^<]*)')).Groups[1].Value).Trim()

    $notes = ''
    $nm = [regex]::Match($blk, 'المشروحات\s*:\s*</span>\s*<span[^>]*>\s*<strong>([\s\S]*?)</strong>')
    if ($nm.Success) { $notes = Clean-Text $nm.Groups[1].Value }

    # Capture internal case ID used by AuctionInfo.aspx postback (e.g. SetAuctionData(13731587,);)
    $caseId = 0
    $cm = [regex]::Match($blk, 'SetCurrentAuctionID\(' + $id + '\)\s*;\s*SetAuctionData\((\d+)')
    if ($cm.Success) { $caseId = [int]$cm.Groups[1].Value }

    # Announcement round number (hidden input CurrentAnnouncementSerial_<id>).
    # 1 = first announcement; higher = the lot has been re-announced that many
    # times (failed sales / extensions) — a useful bargain signal the site has
    # always carried but we never harvested.
    $annSerial = 0
    $asm = [regex]::Match($blk, 'id="CurrentAnnouncementSerial_' + $id + '"[^>]*value="(\d+)"')
    if (-not $asm.Success) { $asm = [regex]::Match($blk, 'value="(\d+)"[^>]*id="CurrentAnnouncementSerial_' + $id + '"') }
    if ($asm.Success) { $annSerial = [int]$asm.Groups[1].Value }

    $details = [ordered]@{}
    $rows = [regex]::Split($blk, '<div class="row div-seperator">')
    for ($r = 1; $r -lt $rows.Count; $r++) {
      $row = $rows[$r]
      $lbl = [regex]::Match($row, '<div class="col-xs-\d+ bold">([\s\S]*?)</div>')
      $val = [regex]::Match($row, '<div class="col-xs-\d+"(?:\s+[^>]*)?>([\s\S]*?)</div>')
      if ($lbl.Success -and $val.Success) {
        $label = Clean-Text $lbl.Groups[1].Value
        $value = Clean-Text $val.Groups[1].Value
        if ($label -and -not $details.Contains($label)) { $details[$label] = $value }
      }
    }

    [void]$out.Add([pscustomobject]@{
      id              = [int]$id
      caseId          = $caseId
      category        = $category
      header          = $header
      court           = $details['المحكمة / الدائرة']
      caseNumber      = $details['رقم الدعوى']
      status          = $details['حالة المزاد']
      announcement    = $details['الإعلان']
      announcementSerial = $annSerial
      announcementStart = $details['تاريخ بداية الاعلان']
      announcementEnd = $details['تاريخ انتهاء الاعلان']
      startingAmount  = $startAmt
      estimatedValue  = $estVal
      currentAmount   = $highAmt
      minIncrement    = $details['الحد الأدنى لقيمة الزيادة']
      numBids         = $numBids
      newspaper       = $details['الصحيفة']
      newspaperIssue  = $details['العدد']
      publishedAt     = $details['تاريخ النشر']
      endDate         = $endDate
      image           = $img
      notes           = $notes
      sourceUrl       = "$Base/AuctionInfo.aspx?token=$($script:CurrentToken)&auction=$id"
      details         = $details
    })
  }
  ,$out
}

# Write one file atomically: build a sibling .tmp, then rename over the target.
# A rename cannot half-succeed, so a collision can never leave a truncated
# auctions.json behind - which a direct WriteAllText to a 65 MB file genuinely
# could, and twice nearly did.
#
# The retry is for transient Windows sharing failures. Two different ones have
# already killed a run mid-scrape: OneDrive holding the file open mid-sync
# ("being used by another process"), and an indexer or AV holding a mapped view
# of it ("cannot be performed on a file with a user-mapped section open").
# Both clear on their own within a second or two.
function Write-FileAtomic([string]$path, [string]$text) {
  $tmp = "$path.tmp"
  $enc = [System.Text.UTF8Encoding]::new($false)
  $lastErr = $null
  for ($try = 1; $try -le 5; $try++) {
    try {
      [System.IO.File]::WriteAllText($tmp, $text, $enc)
      Move-Item -LiteralPath $tmp -Destination $path -Force -ErrorAction Stop
      return
    } catch {
      $lastErr = $_
      if ($try -lt 5) {
        Write-Host ("    [io] write to {0} failed (attempt {1}/5), retrying: {2}" -f (Split-Path $path -Leaf), $try, $_.Exception.Message.Split("`n")[0]) -ForegroundColor DarkYellow
        Start-Sleep -Milliseconds (400 * $try)
      }
    }
  }
  if (Test-Path $tmp) { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
  throw $lastErr
}

function Save-Progress($path, $jsPath, $payload) {
  $json = $payload | ConvertTo-Json -Depth 12
  Write-FileAtomic $path   $json
  Write-FileAtomic $jsPath "window.AUCTION_DATA = $json;"
}

# Output paths. Assigned BEFORE the index fetch because the captcha fallback
# below reads $jsonPath to recover cached categories — it used to run against
# an unassigned variable, so that recovery path threw instead of working.
$jsonPath = Join-Path $PSScriptRoot 'auctions.json'
$jsPath   = Join-Path $PSScriptRoot 'auctions.js'

# --- 1. Index → categories ---
# -DedupeOnly rewrites the existing file in place and never scrapes, so skip
# the index fetch entirely: a captcha here would abort the cleanup for no
# reason, and the categories block is carried over from the file untouched.
$idxHtml = ''
if (-not $DedupeOnly) {
  Write-Host "Fetching index page..."
  $idxHtml = Curl-Get "$Base/index.aspx"
}

$catRe = '<a href="AuctionsList\.aspx\?token=([^"]+)">[\s\S]*?<span>([^<]+)</span>\s*<br\s*/?>\s*<span>\s*\(\s*(\d+)\s*\)'
$catMatches = [regex]::Matches($idxHtml, $catRe)
$categories = @()
foreach ($m in $catMatches) {
  $categories += [pscustomobject]@{
    token      = $m.Groups[1].Value
    name       = ($m.Groups[2].Value).Trim()
    totalCount = [int]$m.Groups[3].Value
  }
}
if (-not $DedupeOnly) {
  Write-Host ("Found {0} categories:" -f $categories.Count)
  $categories | ForEach-Object { Write-Host ("  - {0} ({1})" -f $_.name, $_.totalCount) }
}

# Captcha-failed index parse → preserve previously known categories so we don't
# corrupt the saved file (the dashboard depends on this metadata for tokens, stats,
# and the aradi.io map lookup).
if ($categories.Count -eq 0 -and -not $Fresh -and (Test-Path $jsonPath)) {
  try {
    $prev = Get-Content $jsonPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($prev.categories -and $prev.categories.Count -gt 0) {
      $categories = $prev.categories
      if ($DedupeOnly) {
        Write-Host ("Reusing {0} categories from auctions.json (no index fetch in -DedupeOnly)" -f $categories.Count) -ForegroundColor DarkGray
      } else {
        Write-Host ("Index returned captcha; reusing {0} categories from existing auctions.json" -f $categories.Count) -ForegroundColor Yellow
      }
    }
  } catch { }
}
if ($categories.Count -eq 0 -and -not $DedupeOnly) {
  Write-Host "ERROR: no categories available (captcha + no cached metadata). Aborting before save." -ForegroundColor Red
  exit 2
}

# --- 2. Scrape each category ---
# Fold a duplicate row into the one we are keeping. Neither side is discarded
# wholesale: the row with the newer lastSeenInListingAt wins on mutable fields
# (bid, countdown, status), but any field the keeper is missing is taken from
# the other — otherwise enrichment that only ever landed on one of the two
# copies (detailUrl, reportUrl, pdfPath, image, aradiPlot) would be lost.
function Merge-AuctionRow($keep, $other) {
  $kSeen = ''; $oSeen = ''
  if ($keep.PSObject.Properties.Match('lastSeenInListingAt').Count)  { $kSeen = [string]$keep.lastSeenInListingAt }
  if ($other.PSObject.Properties.Match('lastSeenInListingAt').Count) { $oSeen = [string]$other.lastSeenInListingAt }
  $otherIsNewer = ($oSeen -gt $kSeen)

  foreach ($p in $other.PSObject.Properties) {
    $name = $p.Name
    $oVal = $p.Value
    if ($null -eq $oVal -or $oVal -eq '') { continue }
    $has = $keep.PSObject.Properties.Match($name).Count -gt 0
    $kVal = if ($has) { $keep.$name } else { $null }
    $kEmpty = ($null -eq $kVal -or $kVal -eq '')
    # Take the other side's value when ours is missing/blank, or when the other
    # row is the fresher observation and this is a field that moves.
    $mutable = $name -in 'currentAmount','numBids','endDate','status','header','announcement','announcementStart','lastSeenInListingAt'
    if ($kEmpty -or ($otherIsNewer -and $mutable)) {
      if ($has) { $keep.$name = $oVal } else { $keep | Add-Member -MemberType NoteProperty -Name $name -Value $oVal -Force }
    }
  }
  # firstSeenAt is "when WE first saw it" — always the earlier of the two.
  if ($other.PSObject.Properties.Match('firstSeenAt').Count -and $other.firstSeenAt) {
    if (-not $keep.PSObject.Properties.Match('firstSeenAt').Count -or -not $keep.firstSeenAt -or
        ([string]$other.firstSeenAt -lt [string]$keep.firstSeenAt)) {
      $keep | Add-Member -MemberType NoteProperty -Name 'firstSeenAt' -Value $other.firstSeenAt -Force
    }
  }
}

$all = New-Object System.Collections.ArrayList

# Pre-seed from existing data so reruns only ADD new auctions and never lose what we already have.
$existingByCat = @{}
$allById = @{}            # id -> record (for fast in-place updates of currentAmount, numBids, etc.)
if (-not $Fresh -and (Test-Path $jsonPath)) {
  try {
    $prev = Get-Content $jsonPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $dupMerged = 0
    foreach ($a in $prev.auctions) {
      $aid = [int]$a.id
      if ($allById.ContainsKey($aid)) {
        # A duplicate already in the file. Collapse it on load so the invariant
        # "one row per auction id" is enforced rather than merely assumed.
        Merge-AuctionRow $allById[$aid] $a
        $dupMerged++
        continue
      }
      [void]$all.Add($a)
      $allById[$aid] = $a
      if (-not $existingByCat.ContainsKey($a.category)) {
        $existingByCat[$a.category] = New-Object 'System.Collections.Generic.HashSet[int]'
      }
      [void]$existingByCat[$a.category].Add($aid)
    }
    Write-Host ("Pre-seeded with {0} existing auctions from auctions.json" -f $all.Count) -ForegroundColor DarkGray
    if ($dupMerged -gt 0) {
      Write-Host ("  merged {0} duplicate row(s) found in auctions.json" -f $dupMerged) -ForegroundColor Yellow
    }
  } catch {
    Write-Host ("Could not load existing auctions.json: {0}" -f $_.Exception.Message) -ForegroundColor Yellow
  }
}

function Save-All([bool]$inProgress = $true) {
  $payload = [pscustomobject]@{
    scrapedAt    = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    source       = "$Base/index.aspx"
    totalScraped = $all.Count
    pageLimit    = $MaxPagesPerCategory
    inProgress   = $inProgress
    categories   = $categories
    auctions     = $all
  }
  Save-Progress $jsonPath $jsPath $payload
}

# -DedupeOnly: collapse duplicate rows and exit. Runs the SAME pre-seed merge
# the scraper uses, so a cleanup can never drift from the live behaviour, and
# touches no network. Categories are carried over from the file as-is.
if ($DedupeOnly) {
  if ($null -eq $prev) { throw "-DedupeOnly needs an existing auctions.json to read" }
  $before = $prev.auctions.Count
  # Write $prev back verbatim except for the auction list. Going through
  # Save-All would restamp scrapedAt to "now" — which would claim the data is
  # fresh when nothing was actually fetched — and would drop lastRunAt and any
  # other top-level key added outside this script.
  $prev.auctions = $all.ToArray()
  if ($prev.PSObject.Properties.Match('totalScraped').Count) { $prev.totalScraped = $all.Count }
  if ($prev.PSObject.Properties.Match('inProgress').Count)   { $prev.inProgress = $false }
  Save-Progress $jsonPath $jsPath $prev
  Write-Host ""
  Write-Host ("Dedupe: {0} rows -> {1} rows ({2} duplicate row(s) merged)" -f $before, $all.Count, ($before - $all.Count)) -ForegroundColor Green
  $distinctIds = ($all | ForEach-Object { [int]$_.id } | Sort-Object -Unique).Count
  Write-Host ("distinct ids now: {0} (rows {1})" -f $distinctIds, $all.Count) -ForegroundColor DarkGray
  return
}

# We stamp `lastSeenInListingAt` (ISO-8601 UTC) on every auction we see on
# MoJ during this run — immediately as each item is parsed, not at the end.
# Why immediately: deeper pagination keeps getting silently rejected past
# ~150 items per category, so the scrape often dies mid-walk. By stamping
# eagerly, partial runs still contribute useful "this row was on MoJ this
# morning" data. The dashboard's "active" filter accepts anything seen in
# the last 48h, so stale rows naturally fall out without a separate cleanup.

# ============================================================================
# PASS A: Breadth-first page-1..12 sweep. Visit each category, walk up to 12
# pages, upsert items (which eagerly stamps lastSeenInListingAt + firstSeenAt).
# 12 pages × 10 items × 5 categories = ~600 items stamped even before PASS B
# starts. Uses the same paginate-via-postback flow as PASS B, but limited to
# 12 pages per category, so we bail early if MoJ blocks pagination on any one
# category and still move on to the next.
#
# Raised 7 -> 12 on 2026-09-13: the tail past page 7 was only being reached by
# PASS B's deep walk, which is the part MoJ's anti-bot most often cuts short —
# so those rows went unstamped on a blocked run. Costs ~25 extra page requests
# per sweep (35 -> 60), each behind the usual jittered delay.
# ============================================================================
$SweepMaxPages = 12
Write-Host ""
Write-Host ("==== PASS A: breadth-first sweep (up to {0} pages/category) ====" -f $SweepMaxPages) -ForegroundColor Magenta
$sweepNowIso = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')

# Local helper: takes an HTML page's items and upserts them into $all/$allById.
# Returns the count of items stamped this call.
$stampItems = {
  param($items)
  $count = 0
  foreach ($it in $items) {
    $itId = [int]$it.id
    if ($allById.ContainsKey($itId)) {
      $existing = $allById[$itId]
      if ($existing.PSObject.Properties.Match('lastSeenInListingAt').Count) { $existing.lastSeenInListingAt = $sweepNowIso }
      else { $existing | Add-Member -MemberType NoteProperty -Name 'lastSeenInListingAt' -Value $sweepNowIso -Force }
      if ($it.endDate -and $existing.endDate -ne $it.endDate) { $existing.endDate = $it.endDate }
      $count++
    } else {
      $it | Add-Member -MemberType NoteProperty -Name 'firstSeenAt'         -Value $sweepNowIso -Force
      $it | Add-Member -MemberType NoteProperty -Name 'lastSeenInListingAt' -Value $sweepNowIso -Force
      [void]$all.Add($it)
      $allById[$itId] = $it
      # Register the id against its category too, so $existingByCat stays an
      # accurate picture of what we hold per category. (PASS B used to seed a
      # per-category set from this and insert anything missing from it, which is
      # how 139 duplicate rows accumulated; the insert now gates on $allById.)
      if (-not $existingByCat.ContainsKey($it.category)) {
        $existingByCat[$it.category] = New-Object 'System.Collections.Generic.HashSet[int]'
      }
      [void]$existingByCat[$it.category].Add($itId)
      $count++
    }
  }
  return $count
}

foreach ($cat in $categories) {
  if (Test-Budget) { break }
  if ($OnlyCategory -and ($cat.name -notmatch $OnlyCategory)) { continue }
  Write-Host ("  {0}" -f $cat.name)
  $script:CurrentToken = $cat.token
  $sweepUrl = "$Base/AuctionsList.aspx?token=$($cat.token)"
  $sweepCatStamped = 0

  # Page 1: plain GET. If it returns valid HTML but zero items (which we've
  # seen intermittently on the vehicles listing — no captcha, just an empty
  # result), rotate session + UA and retry once. This handles the "not
  # captcha but obviously blocked" state.
  $sweepHtml = $null
  $items = @()
  $attempt = 0
  while ($attempt -lt 2) {
    $attempt++
    try {
      $sweepHtml = Curl-Get $sweepUrl
      if (Test-Captcha $sweepHtml) {
        if ($attempt -eq 1) {
          Write-Host "    page 1: captcha — rotating session and retrying" -ForegroundColor Yellow
          Reset-Session
          continue
        } else {
          Write-Host "    page 1: still captcha after retry — skipping category" -ForegroundColor Yellow
          $sweepHtml = $null; break
        }
      }
      $items = Parse-Auctions $sweepHtml $cat.name
      if ($items.Count -eq 0 -and $attempt -eq 1) {
        Write-Host "    page 1: 0 items (silent block?) — rotating session and retrying" -ForegroundColor Yellow
        Reset-Session
        continue
      }
      break
    } catch {
      Write-Host ("    page 1 error: {0}" -f $_.Exception.Message) -ForegroundColor Yellow
      if ($attempt -eq 1) {
        Write-Host "    retrying after session reset" -ForegroundColor Yellow
        Reset-Session
        continue
      }
      $sweepHtml = $null; break
    }
  }
  if (-not $sweepHtml) { continue }
  $stamped = & $stampItems $items
  $sweepCatStamped += $stamped
  Write-Host ("    page 1: {0} items, +{1} stamped" -f $items.Count, $stamped)
  Start-Sleep -Milliseconds (Get-JitteredDelay)

  # Pages 2..N: postback to lbNext
  $sweepPage = 1
  while ($sweepPage -lt $SweepMaxPages) {
    if (Test-Budget) { break }
    if ($sweepHtml -notmatch 'id="cph_Base_lbNext"\s+class="page-link lnkPN"\s+href="javascript:__doPostBack') {
      Write-Host "    no more pages"; break
    }
    $sweepPage++
    $sf = Get-FormFields $sweepHtml
    $sweepBody = @{
      '__EVENTTARGET'                         = 'ctl00$cph_Base$lbNext'
      '__EVENTARGUMENT'                       = ''
      '__VIEWSTATE'                           = $sf.ViewState
      '__VIEWSTATEGENERATOR'                  = $sf.ViewStateGenerator
      '__EVENTVALIDATION'                     = $sf.EventValidation
      '__SCROLLPOSITIONX'                     = '0'
      '__SCROLLPOSITIONY'                     = '0'
      'ctl00$cph_Base$hdnCurrentAuctionID'    = '-1'
      'ctl00$cph_Base$hdnCaseId'              = '-1'
      'ctl00$cph_Base$hdnUserIdAuctionStatus' = '-1'
    }
    try {
      $next = Curl-PostForm $sweepUrl $sweepBody
    } catch { Write-Host ("    page {0} error: {1}" -f $sweepPage, $_.Exception.Message) -ForegroundColor Yellow; break }
    if (Test-Captcha $next) { Write-Host ("    page {0}: captcha — stopping sweep for this category" -f $sweepPage) -ForegroundColor Yellow; break }

    $nextItems = Parse-Auctions $next $cat.name
    $stamped = & $stampItems $nextItems
    $sweepCatStamped += $stamped
    Write-Host ("    page {0}: {1} items, +{2} stamped" -f $sweepPage, $nextItems.Count, $stamped)
    $sweepHtml = $next
    Start-Sleep -Milliseconds (Get-JitteredDelay)
  }

  Write-Host ("    → category total stamped: {0}" -f $sweepCatStamped) -ForegroundColor Green
  Save-All $true    # save after each category so partial progress survives
  $script:PagesSinceSave = 0
}
Write-Host ""
Write-Host "==== PASS B: deep walk per category ====" -ForegroundColor Magenta

foreach ($cat in $categories) {
  if (Test-Budget) { break }
  if ($OnlyCategory -and ($cat.name -notmatch $OnlyCategory)) {
    Write-Host ("Skipping category (filter): {0}" -f $cat.name) -ForegroundColor DarkGray
    continue
  }
  Write-Host ""
  Write-Host ("Scraping category: {0}  (target: {1})" -f $cat.name, $cat.totalCount) -ForegroundColor Cyan
  $catUrl = "$Base/AuctionsList.aspx?token=$($cat.token)"
  $script:CurrentToken = $cat.token
  # Lots of THIS category we have actually met on MoJ's listing during THIS run.
  #
  # This used to be a $seen set pre-seeded with every id we had ever recorded in
  # the category, and the walk stopped once $seen.Count reached $cat.totalCount.
  # But totalCount is what MoJ lists RIGHT NOW, while the pre-seeded set counted
  # years of history — vehicles read 1636 >= 308 and the deep walk exited on
  # page 1. Only PASS A's 12-page sweep did real work, so refresh was capped at
  # ~120 rows per category against the 1305 land lots MoJ actually publishes,
  # which is why endDates went stale and the active count drained between runs.
  #
  # Counting only what we have visited this run makes "collected all" mean what
  # it says, and makes the progress heuristics below measure real progress
  # through the listing rather than discovery of brand-new ids.
  $visited = New-Object 'System.Collections.Generic.HashSet[int]'
  if ($existingByCat.ContainsKey($cat.name)) {
    Write-Host ("  already hold {0} rows in this category (not a stop condition)" -f $existingByCat[$cat.name].Count) -ForegroundColor DarkGray
  }
  $resets = 0
  $zeroProgressWalks = 0

  :catLoop while ($true) {
    $html = Curl-Get $catUrl
    if (Test-Captcha $html) {
      Write-Host "  [captcha] hit on initial GET" -ForegroundColor Yellow
      $html = Wait-PastCaptcha $catUrl
      if ($null -eq $html) {
        Write-Host "  [captcha] giving up on this category" -ForegroundColor Red
        break
      }
    }

    $countBeforeWalk = $visited.Count
    $page = 1
    $stalePageStreak = 0
    $madeProgressThisWalk = $false
    $lastPageIds = $null
    $maxPagesPerWalk = 250
    while ($true) {
      $items = Parse-Auctions $html $cat.name
      $thisPageIds = New-Object 'System.Collections.Generic.HashSet[int]'
      foreach ($it in $items) { [void]$thisPageIds.Add([int]$it.id) }

      $newCount = 0
      $updatedCount = 0
      $visitedBeforePage = $visited.Count
      $nowIso = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
      foreach ($it in $items) {
        $itId = [int]$it.id
        # Gate the INSERT on $allById, which spans every category. A
        # per-category test would append a second row for anything we already
        # hold — whether PASS A found it this run, or it is filed under another
        # category — which is exactly how 139 duplicate rows accumulated.
        if (-not $allById.ContainsKey($itId)) {
          # Stamp the moment WE first saw this auction (ISO-8601 UTC). Drives
          # the "🆕 جديد" badge in the dashboard. Set on creation only; never
          # overwritten by later refreshes.
          if (-not $it.PSObject.Properties.Match('firstSeenAt').Count -or -not $it.firstSeenAt) {
            $it | Add-Member -MemberType NoteProperty -Name 'firstSeenAt' -Value $nowIso -Force
          }
          # Stamp lastSeenInListingAt immediately on the new item.
          $it | Add-Member -MemberType NoteProperty -Name 'lastSeenInListingAt' -Value $nowIso -Force
          [void]$visited.Add($itId)
          [void]$all.Add($it)
          $allById[$itId] = $it
          $newCount++
        } else {
          # Known row, but we still MET it on the listing this run — that is what
          # "collected all" and the progress heuristics are counting.
          [void]$visited.Add($itId)
          # Refresh mutable fields on already-known records (live bid + countdown + status).
          $existing = $allById[$itId]
          if ($null -ne $existing) {
            # Stamp lastSeenInListingAt on the existing record — confirms MoJ
            # is still showing this row right now, regardless of whether any
            # other field changed.
            if ($existing.PSObject.Properties.Match('lastSeenInListingAt').Count) {
              $existing.lastSeenInListingAt = $nowIso
            } else {
              $existing | Add-Member -MemberType NoteProperty -Name 'lastSeenInListingAt' -Value $nowIso -Force
            }
            $changed = $false
            # `announcement` and `announcementStart` refresh here because
            # extensions (Article 88 / اعلان تمديد) flip "الاعلان الاول" to
            # "اعلان تمديد/مادة 88" — without this the dashboard shows the
            # original announcement type forever even though MoJ updated it.
            foreach ($prop in 'currentAmount','numBids','endDate','status','header','image','announcement','announcementStart') {
              $newVal = $it.$prop
              if ($null -ne $newVal -and $newVal -ne '' -and $existing.$prop -ne $newVal) {
                $existing.$prop = $newVal
                $changed = $true
              }
            }
            # Backfill caseId (one-time-set field added later in the project)
            $newCid = $it.caseId
            if ($null -ne $newCid -and $newCid -gt 0 -and (-not $existing.PSObject.Properties.Match('caseId').Count -or $existing.caseId -in 0,$null)) {
              if ($existing.PSObject.Properties.Match('caseId').Count) { $existing.caseId = $newCid }
              else { $existing | Add-Member -MemberType NoteProperty -Name 'caseId' -Value $newCid -Force }
              $changed = $true
            }
            # Also refresh announcementEnd from the parsed details (some categories vary)
            if ($it.announcementEnd -and $existing.announcementEnd -ne $it.announcementEnd) {
              $existing.announcementEnd = $it.announcementEnd
              $changed = $true
            }
            # announcementSerial: rounds count from CurrentAnnouncementSerial_<id>.
            # Older rows don't have the property yet, so Add-Member (not plain
            # assignment, which throws under ErrorActionPreference=Stop).
            $newSer = $it.announcementSerial
            if ($null -ne $newSer -and $newSer -gt 0) {
              $hasSer = $existing.PSObject.Properties.Match('announcementSerial').Count -gt 0
              if (-not $hasSer -or $existing.announcementSerial -ne $newSer) {
                if ($hasSer) { $existing.announcementSerial = $newSer }
                else { $existing | Add-Member -MemberType NoteProperty -Name 'announcementSerial' -Value $newSer -Force }
                $changed = $true
              }
            }
            if ($changed) { $updatedCount++ }
          }
        }
      }
      # Progress means "this page showed us lots we had not met yet THIS RUN" —
      # not "this page contained ids we had never recorded". With the latter, a
      # deep refresh walk (every lot already known, so $newCount is 0 on every
      # page) counted as zero progress: the MaxKnownPages guard below would cut
      # the walk at page 15, reset, and pagination would restart at page 1, so
      # the walk could never reach page 16 and just re-fetched the same pages
      # until the reset cap, 90 seconds of cooldown at a time.
      $newlyVisited = $visited.Count - $visitedBeforePage
      if ($newlyVisited -gt 0) { $madeProgressThisWalk = $true }
      Write-Host ("  Page {0}: {1} items ({2} new, {3} refreshed, total this category: {4}/{5}, all={6})" -f $page, $items.Count, $newCount, $updatedCount, $visited.Count, $cat.totalCount, $all.Count)

      # Checkpoint periodically rather than after every page.
      #
      # This used to save on every page that returned items. Both files total
      # ~130 MB, so at the old ~60-page depth that was ~8 GB of writes per run;
      # once PASS B started walking the full ~237 pages it became ~38 GB, and
      # every rewrite is another window for an indexer or AV to collide with.
      # Saving every $SavePageInterval pages keeps the "a killed scrape still
      # keeps its progress" property - the most we now lose is that many pages
      # of lastSeenInListingAt stamps - while cutting the write volume ~10x.
      # End-of-category and end-of-run saves below are unconditional.
      if ($items.Count -gt 0) {
        $script:PagesSinceSave++
        if ($script:PagesSinceSave -ge $SavePageInterval) {
          Save-All $true
          $script:PagesSinceSave = 0
        }
      }

      if (-not $Refresh -and $cat.totalCount -gt 0 -and $visited.Count -ge $cat.totalCount) {
        Write-Host "  (collected all)" -ForegroundColor Green
        break catLoop
      }
      if ($MaxPagesPerCategory -gt 0 -and $page -ge $MaxPagesPerCategory) {
        Write-Host "  (page limit reached)"
        break catLoop
      }
      if ($items.Count -eq 0) {
        Write-Host "  (empty page)"
        break
      }
      if ($page -ge $maxPagesPerWalk) {
        Write-Host "  (max pages per walk reached)" -ForegroundColor Yellow
        break
      }
      # Cap how many pages we'll walk through already-visited territory before
      # giving up this walk — but only once there is nothing left to find.
      #
      # MoJ's pagination is sequential (lbNext only), so a walk interrupted at
      # page 60 cannot resume at 61: the next walk restarts at page 1 and has to
      # re-cross 60 visited pages before reaching new ground. Cutting it at page
      # 15 for "no progress" would strand every category whose listing is longer
      # than MaxKnownPages at ~150 lots, forever. While $visited is still short
      # of what MoJ lists, paging on is purposeful, and the identical-page check
      # below still catches genuinely blocked pagination.
      $moreToFind = ($cat.totalCount -gt 0 -and $visited.Count -lt $cat.totalCount)
      if (-not $madeProgressThisWalk -and $page -ge $MaxKnownPages -and -not $moreToFind) {
        Write-Host ("  (walked {0} pages without reaching any unvisited lot — reset)" -f $MaxKnownPages) -ForegroundColor DarkYellow
        break
      }
      # Identical-page detection ALWAYS fires — if the next-page POST returns the same
      # IDs we just saw, MoJ's anti-bot is silently rejecting our pagination requests
      # (instead of returning a captcha page we'd catch via Test-Captcha). Reset and
      # try again rather than burning 14 more identical pages before MaxKnownPages.
      if ($lastPageIds -and $thisPageIds.Count -gt 0 -and $thisPageIds.SetEquals($lastPageIds)) {
        Write-Host "  (same IDs as previous page — pagination silently blocked, will reset)" -ForegroundColor Yellow
        break
      }
      # The "3 pages in a row with no progress" stall, gated on having made some
      # progress in this walk first — otherwise a walk that opens on already
      # visited pages would bail immediately.
      if ($madeProgressThisWalk) {
        if ($newlyVisited -eq 0) {
          $stalePageStreak++
          if ($stalePageStreak -ge 3) {
            Write-Host "  (stale pagination — needs reset)" -ForegroundColor Yellow
            break
          }
        } else {
          $stalePageStreak = 0
        }
      }
      $lastPageIds = $thisPageIds

      if ($html -notmatch 'id="cph_Base_lbNext"\s+class="page-link lnkPN"\s+href="javascript:__doPostBack') {
        Write-Host "  (no more pages on this walk)"
        break
      }

      $f = Get-FormFields $html
      $body = @{
        '__EVENTTARGET'                         = 'ctl00$cph_Base$lbNext'
        '__EVENTARGUMENT'                       = ''
        '__VIEWSTATE'                           = $f.ViewState
        '__VIEWSTATEGENERATOR'                  = $f.ViewStateGenerator
        '__EVENTVALIDATION'                     = $f.EventValidation
        '__SCROLLPOSITIONX'                     = '0'
        '__SCROLLPOSITIONY'                     = '0'
        'ctl00$cph_Base$hdnCurrentAuctionID'    = '-1'
        'ctl00$cph_Base$hdnCaseId'              = '-1'
        'ctl00$cph_Base$hdnUserIdAuctionStatus' = '-1'
      }

      $sleepMs = Get-JitteredDelay
      if ($sleepMs -gt 0) { Start-Sleep -Milliseconds $sleepMs }

      try {
        $next = Curl-PostForm $catUrl $body
      } catch {
        Write-Host ("  ERROR posting next page: {0}" -f $_.Exception.Message) -ForegroundColor Red
        break
      }

      if (Test-Captcha $next) {
        Write-Host "  [captcha] hit mid-walk — rotating UA + resetting session, then retrying once" -ForegroundColor Yellow
        Reset-Session
        # Refetch the listing page from scratch with the new session, then
        # ask for the next page again. If still captcha'd, give up this walk.
        try {
          $reWarmed = Curl-Get $catUrl
          $f2 = Get-FormFields $reWarmed
          $body['__VIEWSTATE']          = $f2.ViewState
          $body['__VIEWSTATEGENERATOR'] = $f2.ViewStateGenerator
          $body['__EVENTVALIDATION']    = $f2.EventValidation
          Start-Sleep -Milliseconds (Get-JitteredDelay)
          $next = Curl-PostForm $catUrl $body
        } catch { $next = $null }
        if ((-not $next) -or (Test-Captcha $next)) {
          Write-Host "  [captcha] retry failed, breaking walk" -ForegroundColor DarkYellow
          break
        }
        Write-Host "  [captcha] recovered after reset" -ForegroundColor Green
      }

      $html = $next
      $page++

      # Optional preemptive session reset, OFF by default.
      #
      # This used to fire unconditionally every 12 pages, justified by a comment
      # claiming MoJ's anti-bot "typically trips after ~30-50 consecutive
      # requests". Measured on 2026-10-05 against the land listing, one session
      # with no reset: 96 consecutive requests succeeded, reaching 954 of 1305
      # lots in 10.9 minutes, before a transport timeout. The stated figure was
      # wrong by roughly 2x and the reset was firing eight times too early.
      #
      # It is off rather than merely raised because a reset re-fetches the
      # category URL, and MoJ's pagination is sequential (lbNext only) — so the
      # walk silently restarts at page 1 and loses its position. Resetting at
      # page 80 would cap the 131-page land listing at 80 just as firmly as 12
      # did. A reset only helps if it never fires before the wall, and at that
      # point the existing captcha/timeout handling does the same job having got
      # much further first.
      #
      # Request pacing ($DelayMs, jittered) and run frequency are the levers for
      # staying under the radar; throwing away pagination position is not.
      if ($ProactiveResetPages -gt 0 -and ($page % $ProactiveResetPages) -eq 0) {
        Write-Host "  [proactive] resetting session at page $page" -ForegroundColor DarkGray
        Reset-Session
        try {
          $rewarmed = Curl-Get $catUrl
          if (-not (Test-Captcha $rewarmed)) { $html = $rewarmed }
        } catch {}
      }
    }

    if ($cat.totalCount -gt 0 -and $visited.Count -ge $cat.totalCount) { break }
    if (Test-Budget) { break catLoop }
    $resets++
    if ($resets -gt $MaxResetsPerCategory) {
      Write-Host ("  Reset cap reached ({0}). Stopping at {1}/{2}." -f $MaxResetsPerCategory, $visited.Count, $cat.totalCount) -ForegroundColor Yellow
      break
    }
    $progressedThisWalk = ($visited.Count - $countBeforeWalk)
    if ($progressedThisWalk -eq 0) {
      $zeroProgressWalks++
      # In -Refresh mode we expect 0-new walks (refreshing existing items, not discovering new)
      $abortAfter = if ($Refresh) { 6 } else { 3 }
      if ($zeroProgressWalks -ge $abortAfter) {
        Write-Host ("  {0} consecutive walks visited 0 further lots. Aborting category at {1}/{2}." -f $abortAfter, $visited.Count, $cat.totalCount) -ForegroundColor Yellow
        break
      }
    } else {
      $zeroProgressWalks = 0
    }
    Write-Host ("  Resetting session (reset {0}/{1}, +{2} this walk)..." -f $resets, $MaxResetsPerCategory, $progressedThisWalk) -ForegroundColor Cyan
    Reset-Session
  }

  Save-All $true
  $script:PagesSinceSave = 0
  Write-Host ("  [saved] {0} auctions written so far" -f $all.Count) -ForegroundColor DarkGray
}

# (inListing is no longer stamped at end-of-run; lastSeenInListingAt is
# updated eagerly per page so partial scrapes survive a kill.)
Save-All $false
Write-Host ""
Write-Host ("TOTAL: {0} auctions" -f $all.Count) -ForegroundColor Green

# Invariant: exactly one row per auction id. This silently broke for a long
# time (PASS A inserted, PASS B inserted again) and only surfaced by accident,
# so check it out loud rather than trusting the fix to hold.
$distinctIds = ($all | ForEach-Object { [int]$_.id } | Sort-Object -Unique).Count
if ($distinctIds -ne $all.Count) {
  Write-Host ("WARNING: {0} rows but only {1} distinct ids — {2} duplicate row(s) written." -f $all.Count, $distinctIds, ($all.Count - $distinctIds)) -ForegroundColor Red
} else {
  Write-Host ("id invariant OK: {0} rows, {0} distinct ids" -f $all.Count) -ForegroundColor DarkGray
}

Write-Host ("Wrote {0}" -f $jsonPath)
Write-Host ("Wrote {0}" -f $jsPath)
