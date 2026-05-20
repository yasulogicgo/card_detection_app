# One-time project setup: local API token file + git hook to block secret commits.
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Set-Location $root

if (-not (Test-Path "env.json")) {
    Copy-Item "env.json.example" "env.json"
    Write-Host "Created env.json - open it and paste your HF_API_TOKEN once."
} else {
    Write-Host "env.json already exists (not overwritten)."
}

git config core.hooksPath .githooks
Write-Host "Git hooks enabled (.githooks/pre-commit blocks hf_ tokens)."

Write-Host ""
Write-Host "Done. Run from VS Code using the launch config,"
Write-Host "or: flutter run --dart-define-from-file=env.json"
