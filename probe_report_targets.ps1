# Compare what report-download URL each postback target reveals for the
# same auction. We want to find a target that yields a per-auction token
# (different for 45712 vs 45713) rather than the case-level token we
# currently get from lbtnDetails.
[CmdletBinding()] param()

$CurlExe   = 'C:\Windows\System32\curl.exe'
$Base      = 'https://auctions.moj.gov.jo'
$UA        = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/124.0.0.0 Safari/537.36'
$Root      = $PSScriptRoot

$data = Get-Content (Join-Path $Root 'auctions.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$ids = 45712, 45713
$targets = 'LinkButton1', 'lbtnDetails', 'lbtnViewAllImages'

foreach ($id in $ids) {
  $a = $data.auctions | Where-Object { $_.id -eq $id } | Select-Object -First 1
  $tok = ($data.categories | Where-Object name -eq $a.category).token
  Write-Host ""
  Write-Host "===== auction $id (caseId=$($a.caseId)) =====" -ForegroundColor Cyan

  foreach ($targetBtn in $targets) {
    # Fresh session per probe so cookies don't carry over
    $cookieJar = Join-Path $Root "cookies_probe_$id_$targetBtn.txt"
    if (Test-Path $cookieJar) { Remove-Item $cookieJar -Force }

    # Warm + grab ViewState
    $tmp = [System.IO.Path]::GetTempFileName()
    & $CurlExe --silent --insecure --location --compressed --user-agent $UA `
      --cookie-jar $cookieJar --cookie $cookieJar --output $tmp "$Base/AuctionsList.aspx?token=$tok" | Out-Null
    $listing = [System.IO.File]::ReadAllText($tmp, [System.Text.UTF8Encoding]::new($false))
    Remove-Item $tmp -Force

    $vs  = [regex]::Match($listing, 'name="__VIEWSTATE"\s+id="__VIEWSTATE"\s+value="([^"]*)"').Groups[1].Value
    $vsg = [regex]::Match($listing, 'name="__VIEWSTATEGENERATOR"\s+id="__VIEWSTATEGENERATOR"\s+value="([^"]*)"').Groups[1].Value
    $ev  = [regex]::Match($listing, 'name="__EVENTVALIDATION"\s+id="__EVENTVALIDATION"\s+value="([^"]*)"').Groups[1].Value

    # Postback
    $form = @{
      '__EVENTTARGET'        = "ctl00`$cph_Base`$AuctionsListRepeater`$ctl00`$$targetBtn"
      '__EVENTARGUMENT'      = ''
      '__VIEWSTATE'          = $vs
      '__VIEWSTATEGENERATOR' = $vsg
      '__EVENTVALIDATION'    = $ev
      'ctl00$cph_Base$hdnCurrentAuctionID'    = [string]$a.id
      'ctl00$cph_Base$hdnCaseId'              = [string]$a.caseId
      'ctl00$cph_Base$hdnUserIdAuctionStatus' = '-1'
    }

    $bodyFile = [System.IO.Path]::GetTempFileName()
    $outFile  = [System.IO.Path]::GetTempFileName()
    $sb = New-Object System.Text.StringBuilder
    $first = $true
    foreach ($k in $form.Keys) {
      if (-not $first) { [void]$sb.Append('&') }
      [void]$sb.Append([System.Uri]::EscapeDataString($k))
      [void]$sb.Append('=')
      [void]$sb.Append([System.Uri]::EscapeDataString([string]$form[$k]))
      $first = $false
    }
    [System.IO.File]::WriteAllText($bodyFile, $sb.ToString(), [System.Text.UTF8Encoding]::new($false))
    & $CurlExe --silent --insecure --location --compressed --user-agent $UA `
      --header 'Content-Type: application/x-www-form-urlencoded' `
      --header "Referer: $Base/AuctionsList.aspx?token=$tok" `
      --cookie-jar $cookieJar --cookie $cookieJar `
      --data "@$bodyFile" --output $outFile "$Base/AuctionsList.aspx?token=$tok" | Out-Null
    $resp = [System.IO.File]::ReadAllText($outFile, [System.Text.UTF8Encoding]::new($false))
    Remove-Item $bodyFile -Force; Remove-Item $outFile -Force

    $m = [regex]::Match($resp, 'frmDownloadReports\.aspx\?token=([^"''&\s<]+)')
    $tokenStr = if ($m.Success) { $m.Groups[1].Value } else { '(none)' }
    $tail = if ($tokenStr.Length -ge 30) { $tokenStr.Substring($tokenStr.Length - 30) } else { $tokenStr }
    $size = $resp.Length
    Write-Host ("  {0,-22} size={1,6} report-token tail: {2}" -f $targetBtn, $size, $tail)

    if (Test-Path $cookieJar) { Remove-Item $cookieJar -Force }
  }
}
