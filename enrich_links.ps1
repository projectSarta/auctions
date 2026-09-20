<#
.SYNOPSIS
  Harvest a real per-lot permalink (AuctionInfo.aspx?token=...) for each auction.

.DESCRIPTION
  MoJ's listing page has no <a href> to an individual lot — the green button is
  an ASP.NET postback (LinkButton2) whose response carries
  `window.open('/AuctionInfo.aspx?token=<perLotToken>')`. That token is an
  encrypted blob we cannot forge, but it IS deterministic: the same lot yields
  a byte-identical token across sessions and days. So we harvest it once and
  cache it on the row as `detailUrl`.

  Cost is one postback (~470 KB, ~2 s) per lot, so this runs as a separate
  enrichment pass rather than inside scrape.ps1. Rows that already carry a
  detailUrl are skipped, making repeat runs cheap (only new lots).

.PARAMETER ActiveOnly
  Only harvest lots whose endDate is still in the future (default: on).

.PARAMETER MaxLots
  Stop after this many successful harvests. 0 = no limit.

.EXAMPLE
  ./enrich_links.ps1                    # all active lots missing a permalink
  ./enrich_links.ps1 -MaxLots 50        # small batch
  ./enrich_links.ps1 -ActiveOnly:$false # backfill the whole archive (slow)
#>
[CmdletBinding()]
param(
  [switch]$ActiveOnly = $true,
  [int]$MaxLots = 0,
  [int]$MaxPagesPerCategory = 60,
  [int]$DelayMs = 1200,
  [int]$MaxMinutes = 0
)

$ErrorActionPreference = 'Stop'
$CurlExe = 'C:\Windows\System32\curl.exe'
$Base    = 'https://auctions.moj.gov.jo'
$Start   = Get-Date

$UserAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36'
$CookieJar = Join-Path $PSScriptRoot 'cookies_links.txt'
if (Test-Path $CookieJar) { Remove-Item $CookieJar -Force }

function Curl-Get([string]$url) {
  $tmp = [System.IO.Path]::GetTempFileName()
  try {
    & $CurlExe --silent --insecure --location --compressed --user-agent $UserAgent `
      --header 'Accept: text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8' `
      --header 'Accept-Language: ar,en;q=0.8' `
      --cookie-jar $CookieJar --cookie $CookieJar --output $tmp $url | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "curl GET failed (exit $LASTEXITCODE)" }
    return [System.IO.File]::ReadAllText($tmp, [System.Text.UTF8Encoding]::new($false))
  } finally { if (Test-Path $tmp) { Remove-Item $tmp -Force } }
}

function Curl-PostForm([string]$url, [hashtable]$form) {
  $bodyFile = [System.IO.Path]::GetTempFileName()
  $outFile  = [System.IO.Path]::GetTempFileName()
  try {
    # EscapeDataString throws above ~65k chars; ViewState routinely exceeds it.
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
      [void]$sb.Append((& $encode $k)); [void]$sb.Append('='); [void]$sb.Append((& $encode ([string]$form[$k])))
      $first = $false
    }
    [System.IO.File]::WriteAllText($bodyFile, $sb.ToString(), [System.Text.UTF8Encoding]::new($false))
    & $CurlExe --silent --insecure --location --compressed --user-agent $UserAgent `
      --header 'Accept: text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8' `
      --header 'Accept-Language: ar,en;q=0.8' `
      --header 'Content-Type: application/x-www-form-urlencoded' `
      --cookie-jar $CookieJar --cookie $CookieJar --data "@$bodyFile" --output $outFile $url | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "curl POST failed (exit $LASTEXITCODE)" }
    return [System.IO.File]::ReadAllText($outFile, [System.Text.UTF8Encoding]::new($false))
  } finally {
    if (Test-Path $bodyFile) { Remove-Item $bodyFile -Force }
    if (Test-Path $outFile)  { Remove-Item $outFile  -Force }
  }
}

function Get-FormFields([string]$html) {
  $vs  = [regex]::Match($html, 'id="__VIEWSTATE"\s+value="([^"]*)"')
  $vsg = [regex]::Match($html, 'id="__VIEWSTATEGENERATOR"\s+value="([^"]*)"')
  $ev  = [regex]::Match($html, 'id="__EVENTVALIDATION"\s+value="([^"]*)"')
  [pscustomobject]@{
    ViewState          = $vs.Groups[1].Value
    ViewStateGenerator = $vsg.Groups[1].Value
    EventValidation    = $ev.Groups[1].Value
  }
}

# Lots in repeater order (ctl00, ctl01, ...). Each lot emits the marker three
# times (images / details / bid buttons) so dedupe while preserving order.
function Get-PageLots([string]$html) {
  $seen = New-Object 'System.Collections.Generic.HashSet[string]'
  $list = New-Object System.Collections.ArrayList
  foreach ($m in [regex]::Matches($html, 'SetCurrentAuctionID\((\d+)\)\s*;\s*SetAuctionData\((\d+)')) {
    $id = $m.Groups[1].Value
    if ($seen.Add($id)) {
      [void]$list.Add([pscustomobject]@{ id = [int]$id; caseId = $m.Groups[2].Value })
    }
  }
  ,$list
}

# Same test scrape.ps1 uses. Matching a bare "captcha" is wrong — the listing
# page always references a captcha widget; only the challenge page carries
# 'Validation request' / 'captcha_resp', and a truncated body means blocked.
function Test-Captcha([string]$html) {
  if ($null -eq $html) { return $true }
  if ($html.Length -lt 5000) { return $true }
  if ($html.Contains('Validation request') -or $html.Contains('captcha_resp')) { return $true }
  return $false
}

# ---- load ----
$jsonPath = Join-Path $PSScriptRoot 'auctions.json'
$jsPath   = Join-Path $PSScriptRoot 'auctions.js'
if (-not (Test-Path $jsonPath)) { throw "auctions.json not found" }
$data = Get-Content $jsonPath -Raw -Encoding UTF8 | ConvertFrom-Json

$now = Get-Date
$needById = @{}
foreach ($a in $data.auctions) {
  $has = $a.PSObject.Properties.Match('detailUrl').Count -gt 0 -and $a.detailUrl
  if ($has) { continue }
  if ($ActiveOnly) {
    if (-not $a.endDate) { continue }
    $dt = [datetime]::MinValue
    if (-not [datetime]::TryParse($a.endDate, [ref]$dt)) { continue }
    if ($dt -lt $now) { continue }
  }
  $needById[[int]$a.id] = $a
}
Write-Host ("lots needing a permalink: {0}" -f $needById.Count) -ForegroundColor Cyan
if ($needById.Count -eq 0) { Write-Host "nothing to do"; return }

$allById = @{}
foreach ($a in $data.auctions) { $allById[[int]$a.id] = $a }

$script:harvested = 0
$script:failed    = 0

function Save-All {
  $json = $data | ConvertTo-Json -Depth 12
  [System.IO.File]::WriteAllText($jsonPath, $json, [System.Text.UTF8Encoding]::new($false))
  [System.IO.File]::WriteAllText($jsPath, "window.AUCTION_DATA = $json;", [System.Text.UTF8Encoding]::new($false))
}

foreach ($cat in $data.categories) {
  if ($MaxLots -gt 0 -and $script:harvested -ge $MaxLots) { break }
  if ($MaxMinutes -gt 0 -and ((Get-Date) - $Start).TotalMinutes -ge $MaxMinutes) { break }

  # How many lots in THIS category still need a token. Once we've found them
  # all we stop paging immediately — أرض/ مجمع alone is ~129 pages, so walking
  # to the page limit every night would cost minutes for nothing.
  $catNeed = 0
  foreach ($k in $needById.Keys) { if ($needById[$k].category -eq $cat.name) { $catNeed++ } }
  if ($catNeed -eq 0) { Write-Host ("== category: {0} == (nothing needed)" -f $cat.name) -ForegroundColor DarkGray; continue }

  Write-Host ("== category: {0} == ({1} needed)" -f $cat.name, $catNeed) -ForegroundColor Magenta
  $catUrl = "$Base/AuctionsList.aspx?token=$($cat.token)"
  try { $html = Curl-Get $catUrl } catch { Write-Host ("  GET failed: {0}" -f $_.Exception.Message) -ForegroundColor Yellow; continue }
  if (Test-Captcha $html) { Write-Host "  captcha on page 1 - skipping category" -ForegroundColor Yellow; continue }

  $page = 1
  while ($true) {
    $lots = Get-PageLots $html
    $fields = Get-FormFields $html
    $wanted = @()
    for ($i = 0; $i -lt $lots.Count; $i++) {
      if ($needById.ContainsKey($lots[$i].id)) { $wanted += $i }
    }
    Write-Host ("  page {0}: {1} lots, {2} wanted" -f $page, $lots.Count, $wanted.Count)

    foreach ($i in $wanted) {
      if ($MaxLots -gt 0 -and $script:harvested -ge $MaxLots) { break }
      if ($MaxMinutes -gt 0 -and ((Get-Date) - $Start).TotalMinutes -ge $MaxMinutes) { break }
      $lot = $lots[$i]
      # Replay the ORIGINAL page ViewState for every lot on this page - ASP.NET
      # accepts it, and it keeps server-side paging state untouched.
      $body = @{
        '__EVENTTARGET'                         = ('ctl00$cph_Base$AuctionsListRepeater$ctl{0:D2}$LinkButton2' -f $i)
        '__EVENTARGUMENT'                       = ''
        '__VIEWSTATE'                           = $fields.ViewState
        '__VIEWSTATEGENERATOR'                  = $fields.ViewStateGenerator
        '__EVENTVALIDATION'                     = $fields.EventValidation
        '__SCROLLPOSITIONX'                     = '0'
        '__SCROLLPOSITIONY'                     = '0'
        'ctl00$cph_Base$hdnCurrentAuctionID'    = [string]$lot.id
        'ctl00$cph_Base$hdnCaseId'              = [string]$lot.caseId
        'ctl00$cph_Base$hdnUserIdAuctionStatus' = '-1'
      }
      try { $resp = Curl-PostForm $catUrl $body }
      catch { Write-Host ("    {0}: post failed" -f $lot.id) -ForegroundColor Yellow; $script:failed++; continue }

      $tm = [regex]::Match($resp, "window\.open\('/AuctionInfo\.aspx\?token=([A-Za-z0-9_\-]+)'")
      if (-not $tm.Success) {
        Write-Host ("    {0}: no token in response" -f $lot.id) -ForegroundColor Yellow
        $script:failed++
      } else {
        $url = "$Base/AuctionInfo.aspx?token=$($tm.Groups[1].Value)"
        $row = $allById[$lot.id]
        if ($row.PSObject.Properties.Match('detailUrl').Count) { $row.detailUrl = $url }
        else { $row | Add-Member -MemberType NoteProperty -Name 'detailUrl' -Value $url -Force }
        [void]$needById.Remove($lot.id)
        $catNeed--
        $script:harvested++
        Write-Host ("    {0}: ok ({1})" -f $lot.id, $script:harvested) -ForegroundColor Green
      }
      if ($DelayMs -gt 0) { Start-Sleep -Milliseconds $DelayMs }
    }

    if ($wanted.Count -gt 0) { Save-All }
    if ($catNeed -le 0) { Write-Host "  all lots for this category found - moving on" -ForegroundColor DarkGray; break }
    if ($MaxLots -gt 0 -and $script:harvested -ge $MaxLots) { break }
    if ($page -ge $MaxPagesPerCategory) { break }
    if ($html -notmatch 'id="cph_Base_lbNext"\s+class="page-link lnkPN"\s+href="javascript:__doPostBack') { break }

    $page++
    $nf = Get-FormFields $html
    $nextBody = @{
      '__EVENTTARGET'                         = 'ctl00$cph_Base$lbNext'
      '__EVENTARGUMENT'                       = ''
      '__VIEWSTATE'                           = $nf.ViewState
      '__VIEWSTATEGENERATOR'                  = $nf.ViewStateGenerator
      '__EVENTVALIDATION'                     = $nf.EventValidation
      '__SCROLLPOSITIONX'                     = '0'
      '__SCROLLPOSITIONY'                     = '0'
      'ctl00$cph_Base$hdnCurrentAuctionID'    = '-1'
      'ctl00$cph_Base$hdnCaseId'              = '-1'
      'ctl00$cph_Base$hdnUserIdAuctionStatus' = '-1'
    }
    try { $html = Curl-PostForm $catUrl $nextBody }
    catch { Write-Host "  pagination failed" -ForegroundColor Yellow; break }
    if (Test-Captcha $html) { Write-Host "  captcha - stopping category" -ForegroundColor Yellow; break }
    Start-Sleep -Milliseconds $DelayMs
  }
}

Save-All
Write-Host ("harvested {0} permalinks, {1} failed, {2} still missing" -f $script:harvested, $script:failed, $needById.Count) -ForegroundColor Cyan
