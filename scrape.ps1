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
  [switch]$Refresh                   # don't early-exit when already-complete; keep walking to refresh bids/numBids/endDate
)

if ($Full) { $MaxPagesPerCategory = 0 }
$ScriptStart = Get-Date

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

function Save-Progress($path, $jsPath, $payload) {
  $json = $payload | ConvertTo-Json -Depth 12
  [System.IO.File]::WriteAllText($path, $json, [System.Text.UTF8Encoding]::new($false))
  [System.IO.File]::WriteAllText($jsPath, "window.AUCTION_DATA = $json;", [System.Text.UTF8Encoding]::new($false))
}

# --- 1. Index → categories ---
Write-Host "Fetching index page..."
$idxHtml = Curl-Get "$Base/index.aspx"

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
Write-Host ("Found {0} categories:" -f $categories.Count)
$categories | ForEach-Object { Write-Host ("  - {0} ({1})" -f $_.name, $_.totalCount) }

# Captcha-failed index parse → preserve previously known categories so we don't
# corrupt the saved file (the dashboard depends on this metadata for tokens, stats,
# and the aradi.io map lookup).
if ($categories.Count -eq 0 -and -not $Fresh -and (Test-Path $jsonPath)) {
  try {
    $prev = Get-Content $jsonPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($prev.categories -and $prev.categories.Count -gt 0) {
      $categories = $prev.categories
      Write-Host ("Index returned captcha; reusing {0} categories from existing auctions.json" -f $categories.Count) -ForegroundColor Yellow
    }
  } catch { }
}
if ($categories.Count -eq 0) {
  Write-Host "ERROR: no categories available (captcha + no cached metadata). Aborting before save." -ForegroundColor Red
  exit 2
}

# --- 2. Scrape each category ---
$all = New-Object System.Collections.ArrayList
$jsonPath = Join-Path $PSScriptRoot 'auctions.json'
$jsPath   = Join-Path $PSScriptRoot 'auctions.js'

# Pre-seed from existing data so reruns only ADD new auctions and never lose what we already have.
$existingByCat = @{}
$allById = @{}            # id -> record (for fast in-place updates of currentAmount, numBids, etc.)
if (-not $Fresh -and (Test-Path $jsonPath)) {
  try {
    $prev = Get-Content $jsonPath -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($a in $prev.auctions) {
      [void]$all.Add($a)
      $allById[[int]$a.id] = $a
      if (-not $existingByCat.ContainsKey($a.category)) {
        $existingByCat[$a.category] = New-Object 'System.Collections.Generic.HashSet[int]'
      }
      [void]$existingByCat[$a.category].Add([int]$a.id)
    }
    Write-Host ("Pre-seeded with {0} existing auctions from auctions.json" -f $all.Count) -ForegroundColor DarkGray
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

# We stamp `lastSeenInListingAt` (ISO-8601 UTC) on every auction we see on
# MoJ during this run — immediately as each item is parsed, not at the end.
# Why immediately: deeper pagination keeps getting silently rejected past
# ~150 items per category, so the scrape often dies mid-walk. By stamping
# eagerly, partial runs still contribute useful "this row was on MoJ this
# morning" data. The dashboard's "active" filter accepts anything seen in
# the last 48h, so stale rows naturally fall out without a separate cleanup.
foreach ($cat in $categories) {
  if ($OnlyCategory -and ($cat.name -notmatch $OnlyCategory)) {
    Write-Host ("Skipping category (filter): {0}" -f $cat.name) -ForegroundColor DarkGray
    continue
  }
  Write-Host ""
  Write-Host ("Scraping category: {0}  (target: {1})" -f $cat.name, $cat.totalCount) -ForegroundColor Cyan
  $catUrl = "$Base/AuctionsList.aspx?token=$($cat.token)"
  $script:CurrentToken = $cat.token
  $seen = New-Object 'System.Collections.Generic.HashSet[int]'
  if ($existingByCat.ContainsKey($cat.name)) {
    foreach ($id in $existingByCat[$cat.name]) { [void]$seen.Add($id) }
    Write-Host ("  pre-seeded {0} existing IDs for this category" -f $seen.Count) -ForegroundColor DarkGray
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

    $countBeforeWalk = $seen.Count
    $page = 1
    $stalePageStreak = 0
    $seenNewThisWalk = $false
    $lastPageIds = $null
    $maxPagesPerWalk = 250
    while ($true) {
      $items = Parse-Auctions $html $cat.name
      $thisPageIds = New-Object 'System.Collections.Generic.HashSet[int]'
      foreach ($it in $items) { [void]$thisPageIds.Add([int]$it.id) }

      $newCount = 0
      $updatedCount = 0
      $nowIso = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
      foreach ($it in $items) {
        $itId = [int]$it.id
        if (-not $seen.Contains($itId)) {
          # Stamp the moment WE first saw this auction (ISO-8601 UTC). Drives
          # the "🆕 جديد" badge in the dashboard. Set on creation only; never
          # overwritten by later refreshes.
          if (-not $it.PSObject.Properties.Match('firstSeenAt').Count -or -not $it.firstSeenAt) {
            $it | Add-Member -MemberType NoteProperty -Name 'firstSeenAt' -Value $nowIso -Force
          }
          # Stamp lastSeenInListingAt immediately on the new item.
          $it | Add-Member -MemberType NoteProperty -Name 'lastSeenInListingAt' -Value $nowIso -Force
          [void]$seen.Add($itId)
          [void]$all.Add($it)
          $allById[$itId] = $it
          $newCount++
        } else {
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
            foreach ($prop in 'currentAmount','numBids','endDate','status','header','image') {
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
            if ($changed) { $updatedCount++ }
          }
        }
      }
      if ($newCount -gt 0) { $seenNewThisWalk = $true }
      Write-Host ("  Page {0}: {1} items ({2} new, {3} refreshed, total this category: {4}/{5}, all={6})" -f $page, $items.Count, $newCount, $updatedCount, $seen.Count, $cat.totalCount, $all.Count)

      # Save after every page that processed at least one item — even pages
      # where nothing visibly "changed" still updated lastSeenInListingAt on
      # every row we saw, which the dashboard's "active" filter cares about.
      if ($items.Count -gt 0) { Save-All $true }

      if (-not $Refresh -and $cat.totalCount -gt 0 -and $seen.Count -ge $cat.totalCount) {
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
      # Cap how many pages we'll walk through already-known territory before giving up
      # this walk. Without this we burn requests + risk hard IP-ban from rate limiter.
      if (-not $seenNewThisWalk -and $page -ge $MaxKnownPages) {
        Write-Host ("  (walked {0} pages of known territory without new items — reset)" -f $MaxKnownPages) -ForegroundColor DarkYellow
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
      # The "0 new items for 3 pages in a row" stall is still gated on having seen new
      # items in this walk — otherwise a refresh-only walk through known territory
      # would bail immediately.
      if ($seenNewThisWalk) {
        if ($newCount -eq 0) {
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

      # Periodic preemptive session reset. MoJ's anti-bot typically trips
      # after ~30-50 consecutive requests on the same session — refresh
      # cookies + UA every 12 pages so we stay under the radar.
      if (($page % 12) -eq 0) {
        Write-Host "  [proactive] resetting session at page $page" -ForegroundColor DarkGray
        Reset-Session
        try {
          $rewarmed = Curl-Get $catUrl
          if (-not (Test-Captcha $rewarmed)) { $html = $rewarmed }
        } catch {}
      }
    }

    if ($cat.totalCount -gt 0 -and $seen.Count -ge $cat.totalCount) { break }
    if ($MaxMinutes -gt 0 -and ((Get-Date) - $ScriptStart).TotalMinutes -ge $MaxMinutes) {
      Write-Host ("  Time budget reached ({0} min). Stopping." -f $MaxMinutes) -ForegroundColor Yellow
      break
    }
    $resets++
    if ($resets -gt $MaxResetsPerCategory) {
      Write-Host ("  Reset cap reached ({0}). Stopping at {1}/{2}." -f $MaxResetsPerCategory, $seen.Count, $cat.totalCount) -ForegroundColor Yellow
      break
    }
    $progressedThisWalk = ($seen.Count - $countBeforeWalk)
    if ($progressedThisWalk -eq 0) {
      $zeroProgressWalks++
      # In -Refresh mode we expect 0-new walks (refreshing existing items, not discovering new)
      $abortAfter = if ($Refresh) { 6 } else { 3 }
      if ($zeroProgressWalks -ge $abortAfter) {
        Write-Host ("  {0} consecutive walks added 0 new items. Aborting category at {1}/{2}." -f $abortAfter, $seen.Count, $cat.totalCount) -ForegroundColor Yellow
        break
      }
    } else {
      $zeroProgressWalks = 0
    }
    Write-Host ("  Resetting session (reset {0}/{1}, +{2} this walk)..." -f $resets, $MaxResetsPerCategory, $progressedThisWalk) -ForegroundColor Cyan
    Reset-Session
  }

  Save-All $true
  Write-Host ("  [saved] {0} auctions written so far" -f $all.Count) -ForegroundColor DarkGray
}

# (inListing is no longer stamped at end-of-run; lastSeenInListingAt is
# updated eagerly per page so partial scrapes survive a kill.)
Save-All $false
Write-Host ""
Write-Host ("TOTAL: {0} auctions" -f $all.Count) -ForegroundColor Green
Write-Host ("Wrote {0}" -f $jsonPath)
Write-Host ("Wrote {0}" -f $jsPath)
