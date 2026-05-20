# Run app with token from gitignored env.json
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Set-Location $root

if (-not (Test-Path "env.json")) {
    Write-Host "Missing env.json. Run: .\scripts\setup.ps1"
    exit 1
}

flutter run --dart-define-from-file=env.json @args
