# Push this repo to a PRIVATE GitHub repository and trigger the unsigned-IPA build.
# Usage:
#   .\push-to-github.ps1
#   .\push-to-github.ps1 -RepoUrl "https://github.com/YOURNAME/dsnovel-ios27.git"
# Requires: git, and either GitHub CLI (gh, logged in) or an existing empty private repo.

param(
    [string]$RepoUrl = ""
)

$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot

if (-not (Test-Path ".git")) {
    Write-Host "ERROR: not a git repository. Run this inside DSNovel-iOS27-SwiftUI." -ForegroundColor Red
    exit 1
}

if ($RepoUrl -eq "") {
    $gh = Get-Command gh -ErrorAction SilentlyContinue
    if ($gh) {
        gh auth status 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Write-Host "GitHub CLI detected. Creating a PRIVATE repo and pushing..." -ForegroundColor Cyan
            gh repo create dsnovel-ios27 --private --source=. --push
            if ($LASTEXITCODE -ne 0) {
                Write-Host "ERROR: gh repo create failed. Create the repo manually and pass -RepoUrl." -ForegroundColor Red
                exit 1
            }
            $remote = (git remote get-url origin)
        }
        else {
            Write-Host "gh is installed but not logged in." -ForegroundColor Yellow
        }
    }
    if (-not $remote) {
        Write-Host ""
        Write-Host "No logged-in GitHub CLI found. Do this instead:" -ForegroundColor Yellow
        Write-Host "  1. Open https://github.com/new  -> name: dsnovel-ios27  -> PRIVATE -> do NOT add README/.gitignore"
        Write-Host "  2. Copy the repo URL, then run:"
        Write-Host '     .\push-to-github.ps1 -RepoUrl "https://github.com/YOURNAME/dsnovel-ios27.git"'
        Write-Host ""
        exit 0
    }
}
else {
    $existing = git remote get-url origin 2>$null
    if ($existing) { git remote set-url origin $RepoUrl }
    else { git remote add origin $RepoUrl }
    git push -u origin main
    if ($LASTEXITCODE -ne 0) {
        Write-Host "ERROR: push failed. Check the URL and your GitHub login." -ForegroundColor Red
        exit 1
    }
    $remote = $RepoUrl
}

Write-Host ""
Write-Host "Push done: $remote" -ForegroundColor Green
Write-Host ""
Write-Host "Next steps:"
Write-Host "  1. Open the Actions tab of the repo; workflow 'Build DSNovel iOS IPA' runs automatically on push."
Write-Host "     (If it did not start, open the workflow and click 'Run workflow'.)"
Write-Host "  2. Wait for the green check, then open the run -> Artifacts -> 'DSNovel-iOS27-IPA'."
Write-Host "  3. The downloaded file is DSNovel-iOS27-v7.0-unsigned.ipa (UNSIGNED, cannot be installed directly)."
Write-Host ""
