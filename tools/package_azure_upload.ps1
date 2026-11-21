$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path $PSScriptRoot -Parent
$packageRoot = Join-Path $projectRoot '.dart_tool/azure-upload/package'
New-Item -ItemType Directory -Path $packageRoot -Force | Out-Null
foreach ($file in @('azure_upload_handler.js', 'azure_upload_server.js', 'upload_url_service.js')) {
    Copy-Item -LiteralPath (Join-Path $projectRoot "functions/$file") -Destination $packageRoot -Force
}
$dependencies = Get-Content (Join-Path $projectRoot 'functions/package.json') -Raw | ConvertFrom-Json
$package = @{
    name = 'roadsense-azure-upload'
    private = $true
    engines = @{ node = '>=22' }
    scripts = @{ start = 'node azure_upload_server.js' }
    dependencies = @{ 'firebase-admin' = $dependencies.dependencies.'firebase-admin' }
} | ConvertTo-Json -Depth 4
[IO.File]::WriteAllText((Join-Path $packageRoot 'package.json'), $package, [Text.UTF8Encoding]::new($false))
$archive = Join-Path $projectRoot '.dart_tool/azure-upload/backend.zip'
Compress-Archive -Path (Join-Path $packageRoot '*.js'), (Join-Path $packageRoot 'package.json') -DestinationPath $archive -Force
Write-Output $archive
