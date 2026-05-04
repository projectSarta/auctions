<#
.SYNOPSIS
  Run the scraper and publish auctions.js + dashboard.html to GitHub Pages.

.DESCRIPTION
  1) Runs scrape.ps1 (full or quick).
  2) Stages auctions.js, auctions.json, dashboard.html, worker.js.
  3) Commits and pushes to the configured GitHub remote.
  GitHub Pages will then redeploy your site automatically.

.PARAMETER QuickScrape
  Skip full re-scrape — just publish whatever auctions.js you have.

.EXAMPLE
  ./publish.ps1                # full scrape + publish
  ./publish.ps1 -QuickScrape   # publish current data only
#>
[CmdletBinding()]
param(
  [switch]$QuickScrape,
  [string]$RemoteUrl = 'https://github.com/projectSarta/auctions.git'
)

$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot

# ---- 1. Scrape ----
if (-not $QuickScrape) {
  Write-Host "Running scrape.ps1 -Full ..." -ForegroundColor Cyan
  & powershell.exe -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'scrape.ps1') -Full
  if ($LASTEXITCODE -ne 0) {
    Write-Host "Scrape exited with non-zero code; continuing anyway with whatever was saved." -ForegroundColor Yellow
  }
}

# ---- 2. Verify artefacts ----
foreach ($f in 'auctions.js','dashboard.html') {
  if (-not (Test-Path (Join-Path $PSScriptRoot $f))) { throw "Missing required file: $f" }
}

# ---- 3. Init git repo if needed ----
if (-not (Test-Path (Join-Path $PSScriptRoot '.git'))) {
  Write-Host "First-time setup: initialising git repo..." -ForegroundColor Cyan
  Write-Host ("Using remote: {0}" -f $RemoteUrl) -ForegroundColor DarkGray

  git init | Out-Null
  git branch -M main
  git remote add origin $RemoteUrl

  # .gitignore — don't publish cookie jars or scrape logs
  @"
cookies*.txt
scrape_full.log
refresh.log
refresh.err
probe*.html
postbody.txt
list1.html
sample_block.html
index.html
index_clean.html
info1.html
"@ | Set-Content -Encoding utf8 -Path (Join-Path $PSScriptRoot '.gitignore')

  # Tiny index.html that just redirects to dashboard.html
  @'
<!doctype html><meta charset="utf-8"><meta http-equiv="refresh" content="0;url=dashboard.html"><title>Redirecting</title>
<a href="dashboard.html">dashboard.html</a>
'@ | Set-Content -Encoding utf8 -Path (Join-Path $PSScriptRoot 'index.html')
}

# ---- 4. Stage + commit + push ----
git add auctions.js auctions.json dashboard.html worker.js index.html .gitignore 2>$null
$status = git status --porcelain
if (-not $status) {
  Write-Host "Nothing to commit." -ForegroundColor Yellow
  exit 0
}

$ts = (Get-Date).ToString('yyyy-MM-dd HH:mm')
git commit -m "Update auctions data ($ts)" | Out-Null
Write-Host "Pushing to origin/main..." -ForegroundColor Cyan
git push -u origin main

Write-Host ""
Write-Host "Done." -ForegroundColor Green
$origin = (git remote get-url origin) 2>$null
if ($origin -match 'github\.com[:/]([^/]+)/([^/.]+)') {
  $user = $matches[1]; $repo = $matches[2]
  Write-Host ("Site URL (after enabling Pages):  https://{0}.github.io/{1}/" -f $user, $repo) -ForegroundColor Green
}
