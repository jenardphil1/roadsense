Write-Host "========================================================" -ForegroundColor Cyan
Write-Host " RoadSense Web - Launching in Brave Browser" -ForegroundColor Cyan
Write-Host "========================================================" -ForegroundColor Cyan

$bravePath = "C:\Users\jenar\AppData\Local\BraveSoftware\Brave-Browser\Application\brave.exe"
if (-not (Test-Path $bravePath)) {
    Write-Host "[ERROR] Brave browser not found at: $bravePath" -ForegroundColor Red
    exit 1
}

$env:CHROME_EXECUTABLE = $bravePath
$env:PATH = "$env:PATH;C:\flutter\bin"

Set-Location -Path $PSScriptRoot

Write-Host "Brave Executable: $bravePath" -ForegroundColor Green
Write-Host "Starting Flutter Web debug session on port 8080..." -ForegroundColor Yellow
Write-Host "Press 'r' for hot reload, 'R' for hot restart, 'q' to quit." -ForegroundColor Gray
Write-Host ""

flutter run -d chrome -t lib/web_main.dart --web-port=8080
