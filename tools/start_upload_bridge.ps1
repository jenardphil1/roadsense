param([string]$Device = '106283739E000667')
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path $PSScriptRoot -Parent
$configuration = Get-Content (Join-Path $projectRoot 'dart_defines.local.json') -Raw | ConvertFrom-Json
if ([string]::IsNullOrWhiteSpace($configuration.AZURE_STORAGE_CONNECTION_STRING)) {
    throw 'Missing AZURE_STORAGE_CONNECTION_STRING in gitignored dart_defines.local.json.'
}
$adb = 'C:/Andriod/Sdk/platform-tools/adb.exe'
& $adb -s $Device reverse tcp:5001 tcp:5001
if ($LASTEXITCODE -ne 0) { throw 'USB port forwarding failed.' }
$previousConnection = $env:AZURE_STORAGE_CONNECTION_STRING
try {
    $env:AZURE_STORAGE_CONNECTION_STRING = $configuration.AZURE_STORAGE_CONNECTION_STRING
    & node (Join-Path $projectRoot 'functions/local_server.js')
} finally {
    $env:AZURE_STORAGE_CONNECTION_STRING = $previousConnection
}
