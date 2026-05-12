<#
.SYNOPSIS
  Shrink images/ to web-thumbnail size in place.

.DESCRIPTION
  GitHub Pages is unhappy with hundreds of MB of raw photos. The dashboard
  renders these as small cards, so we resize anything over MaxWidth wide
  to MaxWidth (preserving aspect), re-encoded as JPEG at quality 75. Files
  already smaller than MaxWidth are left untouched.

  Originals are NOT preserved — if you want big images, re-run enrich_images.ps1.

.PARAMETER MaxWidth  Target max width in px. Default 600.
.PARAMETER Quality   JPEG quality 0-100. Default 75.
.PARAMETER MinBytes  Skip files smaller than this many bytes (already small). Default 80000.
#>
[CmdletBinding()]
param(
  [int]$MaxWidth = 600,
  [int]$Quality  = 75,
  [int]$MinBytes = 80000
)

Add-Type -AssemblyName System.Drawing
$ImagesDir = Join-Path $PSScriptRoot 'images'
if (-not (Test-Path $ImagesDir)) { throw "No images dir at $ImagesDir" }

$jpegCodec = [System.Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() | Where-Object { $_.MimeType -eq 'image/jpeg' } | Select-Object -First 1
$encParams = New-Object System.Drawing.Imaging.EncoderParameters 1
$encParams.Param[0] = New-Object System.Drawing.Imaging.EncoderParameter([System.Drawing.Imaging.Encoder]::Quality, [int64]$Quality)

$files = Get-ChildItem $ImagesDir -File | Where-Object { $_.Extension -in '.jpg','.jpeg','.png','.gif','.bmp' }
$total = $files.Count
$resized = 0; $skipped = 0; $saved = 0L; $i = 0

foreach ($f in $files) {
  $i++
  if ($f.Length -lt $MinBytes) { $skipped++; continue }
  $beforeBytes = $f.Length

  $img = $null; $bmp = $null; $g = $null
  try {
    $img = [System.Drawing.Image]::FromFile($f.FullName)
    if ($img.Width -le $MaxWidth) {
      # already small dimensionally; only worth recompressing if it's still big in bytes
      if ($f.Extension -ieq '.png' -and $f.Length -gt 300000) {
        $newW = $img.Width; $newH = $img.Height
      } else {
        $skipped++; $img.Dispose(); continue
      }
    } else {
      $newW = $MaxWidth
      $newH = [int]([Math]::Round($img.Height * ($MaxWidth / [double]$img.Width)))
    }
    $bmp = New-Object System.Drawing.Bitmap $newW, $newH
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g.SmoothingMode     = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
    $g.PixelOffsetMode   = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $g.DrawImage($img, 0, 0, $newW, $newH)

    # Always save as .jpg (smaller for photos). If original was PNG, switch extension and remove old PNG.
    $targetPath = [System.IO.Path]::ChangeExtension($f.FullName, '.jpg')

    # Dispose source before overwriting
    $img.Dispose(); $img = $null

    $bmp.Save($targetPath, $jpegCodec, $encParams)
    $g.Dispose(); $bmp.Dispose(); $bmp = $null

    if ($targetPath -ne $f.FullName -and (Test-Path $f.FullName)) {
      Remove-Item $f.FullName -Force
    }

    $afterBytes = (Get-Item $targetPath).Length
    $saved += ($beforeBytes - $afterBytes)
    $resized++
    if ($resized % 50 -eq 0) {
      Write-Host ("  [{0,4}/{1}] resized so far: {2}, bytes saved: {3:N0}" -f $i, $total, $resized, $saved)
    }
  } catch {
    Write-Host ("  ! {0}: {1}" -f $f.Name, $_.Exception.Message) -ForegroundColor DarkYellow
  } finally {
    if ($g)   { $g.Dispose() }
    if ($bmp) { $bmp.Dispose() }
    if ($img) { $img.Dispose() }
  }
}

# After resizing, refresh extensions in auctions.json (PNG -> JPG remappings)
$JsonPath = Join-Path $PSScriptRoot 'auctions.json'
$JsPath   = Join-Path $PSScriptRoot 'auctions.js'
$data = Get-Content $JsonPath -Raw -Encoding UTF8 | ConvertFrom-Json
$fixed = 0
foreach ($a in $data.auctions) {
  if (-not $a.image) { continue }
  $localName = [System.IO.Path]::GetFileName([string]$a.image)
  $localPath = Join-Path $ImagesDir $localName
  if (-not (Test-Path $localPath)) {
    # Probably renamed .png -> .jpg by the resizer
    $alt = [System.IO.Path]::ChangeExtension($localPath, '.jpg')
    if (Test-Path $alt) {
      $a.image = 'images/' + [System.IO.Path]::GetFileName($alt)
      $fixed++
    }
  }
}
if ($fixed -gt 0) {
  $json = $data | ConvertTo-Json -Depth 12
  [System.IO.File]::WriteAllText($JsonPath, $json, [System.Text.UTF8Encoding]::new($false))
  [System.IO.File]::WriteAllText($JsPath,   "window.AUCTION_DATA = $json;", [System.Text.UTF8Encoding]::new($false))
  Write-Host "  retagged $fixed image paths from .png to .jpg in auctions.json" -ForegroundColor Cyan
}

""
"--- Summary ---"
"  total files:   $total"
"  resized:       $resized"
"  skipped small: $skipped"
"  bytes saved:   $([math]::Round($saved/1MB,1)) MB"
$newTot = ((Get-ChildItem $ImagesDir -File | Measure-Object -Property Length -Sum).Sum)
"  new dir size:  $([math]::Round($newTot/1MB,1)) MB"
