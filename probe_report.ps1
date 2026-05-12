# Probe the page reached by the lbtnDetails postback — should contain the
# الإعلان / الصور / تقرير الخبرة tabs + the "تحميل التقرير" button URL.
[CmdletBinding()] param([int]$Id = 50878)

$CurlExe   = 'C:\Windows\System32\curl.exe'
$Base      = 'https://auctions.moj.gov.jo'
$UA        = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/124.0.0.0 Safari/537.36'
$Root      = $PSScriptRoot
$CookieJar = Join-Path $Root 'cookies_report.txt'
if (Test-Path $CookieJar) { Remove-Item $CookieJar -Force }

$data = Get-Content (Join-Path $Root 'auctions.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$a   = $data.auctions | Where-Object id -eq $Id | Select-Object -First 1
$tok = ($data.categories | Where-Object name -eq $a.category).token
"target id=$Id cat=$($a.category) caseId=$($a.caseId)"

# Warm session
[void](& $CurlExe --silent --insecure --location --compressed --user-agent $UA --cookie-jar $CookieJar --cookie $CookieJar "$Base/index.aspx" --output (Join-Path $Root 'probe_idx.html'))

# Get listing for VIEWSTATE
$listUrl = "$Base/AuctionsList.aspx?token=$tok"
& $CurlExe --silent --insecure --location --compressed --user-agent $UA --cookie-jar $CookieJar --cookie $CookieJar $listUrl --output (Join-Path $Root 'probe_list.html') | Out-Null
$listing = Get-Content (Join-Path $Root 'probe_list.html') -Raw -Encoding UTF8
$vs  = [regex]::Match($listing, 'name="__VIEWSTATE"\s+id="__VIEWSTATE"\s+value="([^"]*)"').Groups[1].Value
$vsg = [regex]::Match($listing, 'name="__VIEWSTATEGENERATOR"\s+id="__VIEWSTATEGENERATOR"\s+value="([^"]*)"').Groups[1].Value
$ev  = [regex]::Match($listing, 'name="__EVENTVALIDATION"\s+id="__EVENTVALIDATION"\s+value="([^"]*)"').Groups[1].Value
"viewstate len: $($vs.Length)"

# Try the lbtnDetails postback
$form = @{
  '__EVENTTARGET'        = 'ctl00$cph_Base$AuctionsListRepeater$ctl00$lbtnDetails'
  '__EVENTARGUMENT'      = ''
  '__VIEWSTATE'          = $vs
  '__VIEWSTATEGENERATOR' = $vsg
  '__EVENTVALIDATION'    = $ev
  '__SCROLLPOSITIONX'    = '0'
  '__SCROLLPOSITIONY'    = '0'
  'ctl00$cph_Base$hdnCurrentAuctionID'    = [string]$a.id
  'ctl00$cph_Base$hdnCaseId'              = [string]$a.caseId
  'ctl00$cph_Base$hdnUserIdAuctionStatus' = '-1'
}
$bodyFile = [System.IO.Path]::GetTempFileName()
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
  --header 'Accept: text/html' --header 'Content-Type: application/x-www-form-urlencoded' `
  --header "Referer: $listUrl" --cookie-jar $CookieJar --cookie $CookieJar `
  --data "@$bodyFile" --output (Join-Path $Root 'probe_report.html') $listUrl | Out-Null
Remove-Item $bodyFile -Force

$resp = Get-Content (Join-Path $Root 'probe_report.html') -Raw -Encoding UTF8
"response size: $($resp.Length)"

# Look for the report-download button + its href token
$m = [regex]::Match($resp, 'frmDownloadReports\.aspx\?token=([^"''&\s]+)')
if ($m.Success) {
  "FOUND token (len=$($m.Groups[1].Length)): $($m.Groups[1].Value.Substring(0, [Math]::Min(60, $m.Groups[1].Length)))..."
} else {
  "no frmDownloadReports token in response"
}

# Search for "Download Report" / report tab via UTF-8 byte patterns
$bytes = [System.IO.File]::ReadAllBytes((Join-Path $Root 'probe_report.html'))
$txt   = [System.Text.Encoding]::UTF8.GetString($bytes)
"contains 'frmDownloadReports': $($txt.Contains('frmDownloadReports'))"
"contains 'lbtnDownloadReport':  $($txt.Contains('lbtnDownloadReport'))"
$m2 = [regex]::Match($txt, 'frmDownloadReports\.aspx\?token=([^"''&\s]+)')
if ($m2.Success) { "TOKEN: $($m2.Groups[1].Value)" } else { "no direct token" }
