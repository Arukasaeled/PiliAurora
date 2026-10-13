[CmdletBinding()]
param([string]$CMake = 'cmake')
$ErrorActionPreference = 'Stop'
$workspace = (Resolve-Path "$PSScriptRoot/../..").Path
$buildDir = Join-Path $workspace 'build/nativeapi'
& $CMake -S $PSScriptRoot -B $buildDir -A x64
if ($LASTEXITCODE) { throw 'nativeapi configure failed' }
& $CMake --build $buildDir --config Release --parallel 4
if ($LASTEXITCODE) { throw 'nativeapi build failed' }
python "$PSScriptRoot/package.py" package "$buildDir/nativeapi/Release/cnativeapi.dll"
if ($LASTEXITCODE) { throw 'nativeapi packaging failed' }
