<#
.SYNOPSIS
    Runs the RoadSense Mobile App locally with optional gitignored dart_defines.local.json.
.PARAMETER Device
    Optional Flutter device ID (e.g. from `flutter devices`).
.PARAMETER Release
    Run in release mode instead of debug mode.
.PARAMETER ExtraArgs
    Any additional arguments forwarded to `flutter run`.
#>
param(
    [string]$Device,
    [switch]$Release,
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$ExtraArgs
)

Set-Location -Path $PSScriptRoot

if (-not (Get-Command flutter -ErrorAction SilentlyContinue)) {
    if (Test-Path "C:\flutter\bin") {
        $env:PATH = "$env:PATH;C:\flutter\bin"
    }
}

$argsList = @('run', '-t', 'lib/main.dart')
if ($Device) {
    $argsList += @('-d', $Device)
}
if ($Release) {
    $argsList += '--release'
}

$definesFile = Join-Path $PSScriptRoot 'dart_defines.local.json'
if (Test-Path $definesFile) {
    Write-Host "[OK] Loading build defines from dart_defines.local.json" -ForegroundColor Green
    $argsList += "--dart-define-from-file=$definesFile"
} else {
    Write-Host "[WARN] dart_defines.local.json not found; Azure upload will remain disabled." -ForegroundColor Yellow
}

if ($ExtraArgs) {
    $argsList += $ExtraArgs
}

& flutter @argsList
