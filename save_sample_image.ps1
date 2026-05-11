# Decode the user-supplied base64 sample and save as images/41524.jpg
# (data URL header lied about PNG but the bytes start with /9j/ = JPEG)
[CmdletBinding()] param([string]$Base64Path = "$PSScriptRoot\sample_b64.txt", [int]$Id = 41524)
$b64 = Get-Content $Base64Path -Raw
$b64 = $b64 -replace 'data:image/[a-z]+;base64,', '' -replace '\s+', ''
$bytes = [System.Convert]::FromBase64String($b64)
$out = Join-Path $PSScriptRoot "images\$Id.jpg"
if (-not (Test-Path "$PSScriptRoot\images")) { New-Item -ItemType Directory -Path "$PSScriptRoot\images" | Out-Null }
[System.IO.File]::WriteAllBytes($out, $bytes)
"Saved $($bytes.Length) bytes to $out"
