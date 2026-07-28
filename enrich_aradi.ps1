<#
.SYNOPSIS
  Pre-fetch aradi.io parcel polygons for land auctions and embed them into
  auctions.json / auctions.js.

.DESCRIPTION
  aradi.io's /api/plot endpoint doesn't send CORS headers, so the browser
  can't call it directly from projectsarta.github.io. But PowerShell has no
  same-origin restriction, so we look up the polygon from here and bake it
  into the auction record. The dashboard then renders a.aradiPlot without
  any runtime aradi call.

  For each active auction with all four land fields (المحافظة / المديرية /
  القرية / الحوض) plus رقم القطعة, we:
    1. Resolve village/block/plot codes against aradi's public index
    2. Call https://aradi.io/api/plot/{v}/{b}/{p}
    3. If 200, store the GeoJSON polygon in a.aradiPlot
    4. If 500 (aradi's shorthand for "not found") or lookup fails, stamp
       a.aradiPlot = {status: 'none'} so we don't retry every run

  Idempotent — skips rows already enriched unless -Force.

.PARAMETER Force
  Re-fetch even if a.aradiPlot already exists.

.PARAMETER MaxItems
  Cap on how many auctions to enrich in one run (default 500).

.PARAMETER DelayMs
  Base delay between plot API calls (default 400 ms).
#>
[CmdletBinding()]
param(
  [switch]$Force,
  [int]$MaxItems = 500,
  [int]$DelayMs = 400
)

$ErrorActionPreference = 'Stop'
$CurlExe   = 'C:\Windows\System32\curl.exe'
$JsonPath  = Join-Path $PSScriptRoot 'auctions.json'
$JsPath    = Join-Path $PSScriptRoot 'auctions.js'
$ARADI_BASE_CDN = 'https://cdn.aradi.io/json/2019-12-25/indices'
$ARADI_PLOT_API = 'https://aradi.io/api/plot'

function Get-Json([string]$url) {
  $tmp = [System.IO.Path]::GetTempFileName()
  try {
    & $CurlExe --silent --insecure --location --max-time 15 --compressed `
      --user-agent 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/124.0.0.0 Safari/537.36' `
      --header 'Accept: application/json' `
      --header 'Referer: https://aradi.io/' `
      --output $tmp $url | Out-Null
    if ($LASTEXITCODE -ne 0) { return $null }
    $txt = [System.IO.File]::ReadAllText($tmp, [System.Text.UTF8Encoding]::new($false))
    if ([string]::IsNullOrWhiteSpace($txt)) { return $null }
    return ($txt | ConvertFrom-Json)
  } catch { return $null }
  finally { if (Test-Path $tmp) { Remove-Item $tmp -Force } }
}

Write-Host "Loading aradi indices..." -ForegroundColor Cyan
$idxD    = Get-Json "$ARADI_BASE_CDN/district.json"
$idxDept = Get-Json "$ARADI_BASE_CDN/department.json"
$idxVill = Get-Json "$ARADI_BASE_CDN/village.json"
$idxHod  = Get-Json "$ARADI_BASE_CDN/hod.json"
if (-not $idxD -or -not $idxDept -or -not $idxVill -or -not $idxHod) {
  throw "Failed to load aradi indices from $ARADI_BASE_CDN"
}
Write-Host ("  districts:{0} depts:{1} villages:{2} blocks:{3}" -f $idxD.Count, $idxDept.Count, $idxVill.Count, $idxHod.Count)

# Build lookup hashes for faster resolution
$distByName = @{}
foreach ($d in $idxD) { $distByName[$d.DISTRECT_ANAME.Trim()] = $d }

function Resolve-Codes([object]$a) {
  $det = $a.details
  if (-not $det) { return $null }
  $govRaw = [string]$det.'المحافظة'
  if (-not $govRaw) { return $null }
  $gov = ($govRaw -replace '^محافظة\s+','').Trim()
  $district = $distByName[$gov]
  if (-not $district) { return $null }

  $dirRaw = [string]$det.'المديرية'
  if (-not $dirRaw) { return $null }
  $dept = $idxDept | Where-Object { $_.DEPT_ANAME.Trim() -eq $dirRaw.Trim() -and $_.DISTRECT_CODE -eq $district.DISTRECT_CODE } | Select-Object -First 1
  if (-not $dept) { return $null }

  $villRaw = [string]$det.'القرية'
  if (-not $villRaw) { return $null }
  $village = $idxVill | Where-Object { $_.VILL_ANAME.Trim() -eq $villRaw.Trim() -and $_.DEPT_CODE -eq $dept.DEPT_CODE } | Select-Object -First 1
  if (-not $village) { return $null }

  $basinRaw = [string]$det.'الحوض'
  if (-not $basinRaw) { return $null }
  $parts = $basinRaw -split '/', 2
  $blockCodeStr = $parts[0].Trim()
  $blockName    = if ($parts.Count -ge 2) { $parts[1].Trim() } else { '' }
  $blockCode    = 0
  [void][int]::TryParse($blockCodeStr, [ref]$blockCode)
  $block = if ($blockCode -gt 0) { $idxHod | Where-Object { $_.VILL_CODE -eq $village.VILL_CODE -and $_.HOD_CODE -eq $blockCode } | Select-Object -First 1 } else { $null }
  if (-not $block -and $blockName) {
    $block = $idxHod | Where-Object { $_.VILL_CODE -eq $village.VILL_CODE -and $_.HOD_ANAME.Trim() -eq $blockName } | Select-Object -First 1
  }
  if (-not $block) { return $null }

  $plotRaw = [string]$det.'رقم القطعة'
  $plot = 0
  [void][int]::TryParse($plotRaw, [ref]$plot)
  if ($plot -le 0) { return $null }
  return @{ v = $village.VILL_CODE; b = $block.HOD_CODE; p = $plot }
}

# Load auctions
$data = Get-Content $JsonPath -Raw -Encoding UTF8 | ConvertFrom-Json
$now = [DateTime]::UtcNow

# Pick candidates: active + not already enriched (unless -Force)
$candidates = @($data.auctions | Where-Object {
  $_.lastSeenInListingAt -and
  ([DateTime]::Parse($_.lastSeenInListingAt).ToUniversalTime() -gt $now.AddDays(-7)) -and
  $_.endDate -and ([DateTime]::Parse($_.endDate) -gt (Get-Date)) -and
  $_.details -and $_.details.'المحافظة'
})
if (-not $Force) {
  $candidates = @($candidates | Where-Object { -not $_.PSObject.Properties.Match('aradiPlot').Count })
}
Write-Host ("Candidates: {0} (Force={1})" -f $candidates.Count, [bool]$Force)

$enriched = 0; $noMatch = 0; $noPlot = 0; $errored = 0; $i = 0
foreach ($a in $candidates) {
  if ($i -ge $MaxItems) { break }
  $i++
  $codes = Resolve-Codes $a
  if (-not $codes) {
    $a | Add-Member -MemberType NoteProperty -Name 'aradiPlot' -Value ([pscustomobject]@{status='no-codes'}) -Force
    $noMatch++
    continue
  }
  $url = "$ARADI_PLOT_API/$($codes.v)/$($codes.b)/$($codes.p)"
  $resp = Get-Json $url
  if ($resp -and $resp.result -eq 'success' -and $resp.plot -and $resp.plot.geometry) {
    $a | Add-Member -MemberType NoteProperty -Name 'aradiPlot' -Value ([pscustomobject]@{
      status = 'ok'
      village = $codes.v
      block = $codes.b
      plot = $codes.p
      geometry = $resp.plot.geometry
      properties = $resp.plot.properties
    }) -Force
    $enriched++
    Write-Host ("  [{0,3}/{1}] id={2} v={3} b={4} p={5} → OK" -f $i, [Math]::Min($MaxItems, $candidates.Count), $a.id, $codes.v, $codes.b, $codes.p) -ForegroundColor Green
  } else {
    $a | Add-Member -MemberType NoteProperty -Name 'aradiPlot' -Value ([pscustomobject]@{status='no-plot'; village=$codes.v; block=$codes.b; plot=$codes.p}) -Force
    $noPlot++
    Write-Host ("  [{0,3}/{1}] id={2} v={3} b={4} p={5} → no plot" -f $i, [Math]::Min($MaxItems, $candidates.Count), $a.id, $codes.v, $codes.b, $codes.p) -ForegroundColor DarkYellow
  }
  Start-Sleep -Milliseconds ($DelayMs + (Get-Random -Minimum 0 -Maximum $DelayMs))
}

# Save
$out = $data | ConvertTo-Json -Depth 12
[System.IO.File]::WriteAllText($JsonPath, $out, [System.Text.UTF8Encoding]::new($false))
[System.IO.File]::WriteAllText($JsPath,   "window.AUCTION_DATA = $out;", [System.Text.UTF8Encoding]::new($false))

Write-Host ""
Write-Host "--- Summary ---" -ForegroundColor Cyan
Write-Host ("  enriched (polygon found):  {0}" -f $enriched)
Write-Host ("  no-plot  (500 / missing):  {0}" -f $noPlot)
Write-Host ("  no-codes (lookup miss):    {0}" -f $noMatch)
Write-Host ("  errored:                   {0}" -f $errored)
