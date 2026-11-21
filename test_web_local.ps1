<#
.SYNOPSIS
    Tests and runs the RoadSense Web App locally.
.PARAMETER Port
    Port number to serve the web application (default: 8080).
.PARAMETER Headless
    Run using headless 'web-server' device instead of opening a browser window.
.PARAMETER SkipAnalyze
    Skip running static analysis check before launching.
#>
param(
    [int]$Port = 8080,
    [switch]$Headless,
    [switch]$SkipAnalyze
)

Write-Host "========================================================" -ForegroundColor Cyan
Write-Host " RoadSense Web - Local Test & Run Runner" -ForegroundColor Cyan
Write-Host "========================================================" -ForegroundColor Cyan

# 1. Ensure Flutter is on PATH
if (-not (Get-Command flutter -ErrorAction SilentlyContinue)) {
    if (Test-Path "C:\flutter\bin") {
        $env:PATH = "$env:PATH;C:\flutter\bin"
    }
}

Set-Location -Path $PSScriptRoot

# 2. Run static analysis verification if requested
if (-not $SkipAnalyze) {
    Write-Host "`n[1/2] Verifying Web App files compile cleanly..." -ForegroundColor Yellow
    flutter analyze lib/web_main.dart lib/web_map_screen.dart lib/web_profile_screen.dart
    Write-Host "[OK] Verification complete.`n" -ForegroundColor Green
}

# 3. Detect browser
$device = "edge"
$bravePaths = @(
    "$env:LOCALAPPDATA\BraveSoftware\Brave-Browser\Application\brave.exe",
    "C:\Program Files\BraveSoftware\Brave-Browser\Application\brave.exe"
)
$chromePaths = @(
    "C:\Program Files\Google\Chrome\Application\chrome.exe",
    "C:\Program Files (x86)\Google\Chrome\Application\chrome.exe"
)

if ($Headless) {
    $device = "web-server"
    Write-Host "[INFO] Headless mode selected (web-server)." -ForegroundColor Magenta
} else {
    $foundBrave = $bravePaths | Where-Object { Test-Path $_ } | Select-Object -First 1
    if ($foundBrave) {
        $env:CHROME_EXECUTABLE = $foundBrave
        $device = "chrome"
        Write-Host "[OK] Using Brave Browser: $foundBrave" -ForegroundColor Green
    } else {
        $foundChrome = $chromePaths | Where-Object { Test-Path $_ } | Select-Object -First 1
        if ($foundChrome) {
            $env:CHROME_EXECUTABLE = $foundChrome
            $device = "chrome"
            Write-Host "[OK] Using Google Chrome: $foundChrome" -ForegroundColor Green
        } else {
            $device = "edge"
            Write-Host "[INFO] Chrome/Brave not found, using Microsoft Edge." -ForegroundColor Yellow
        }
    }
}

Write-Host "`n[2/2] Starting Flutter Web session..." -ForegroundColor Yellow
Write-Host " Target : lib/web_main.dart" -ForegroundColor Gray
Write-Host " URL    : http://localhost:$Port" -ForegroundColor Cyan
Write-Host " Device : $device" -ForegroundColor Gray
Write-Host " Controls: [r] Hot reload | [R] Hot restart | [q] Quit`n" -ForegroundColor DarkGray

flutter run -d $device -t lib/web_main.dart --web-port=$Port --web-hostname=localhost
