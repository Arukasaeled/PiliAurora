[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$workspacePath = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$packageConfigPath = Join-Path $workspacePath '.dart_tool/package_config.json'
if (-not (Test-Path -LiteralPath $packageConfigPath)) {
    throw '请先通过固定 Flutter SDK 准备项目依赖。'
}

$packageConfig = Get-Content -LiteralPath $packageConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
$flutterPackage = $packageConfig.packages | Where-Object name -EQ 'flutter'
if (-not $flutterPackage) {
    throw 'package_config.json 中未找到 Flutter SDK。'
}
$flutterUri = [Uri]::new([Uri]::new($packageConfigPath), [string]$flutterPackage.rootUri)
$flutterRoot = (Resolve-Path (Join-Path $flutterUri.LocalPath '../..')).Path
$expectedVersion = (Get-Content -LiteralPath (Join-Path $workspacePath '.fvmrc') -Raw -Encoding UTF8 | ConvertFrom-Json).flutter
$versionPath = Join-Path $flutterRoot 'bin/cache/flutter.version.json'
$actualVersion = (Get-Content -LiteralPath $versionPath -Raw -Encoding UTF8 | ConvertFrom-Json).frameworkVersion
if ($actualVersion -ne $expectedVersion) {
    throw "Flutter SDK 不匹配：项目要求 $expectedVersion，依赖来自 $actualVersion。"
}

$wrapperSource = Join-Path $flutterRoot 'engine/src/flutter/shell/platform/android/io/flutter/embedding/engine/renderer/SurfaceTextureWrapper.java'
if (-not (Test-Path -LiteralPath $wrapperSource)) {
    throw "固定 Flutter SDK 中缺少 SurfaceTextureWrapper 源码：$wrapperSource"
}
$javacPath = (Get-Command javac -ErrorAction Stop).Source
$javaPath = (Get-Command java -ErrorAction Stop).Source
$outputPath = Join-Path $workspacePath 'build/probe-validation/android'
New-Item -ItemType Directory -Path $outputPath -Force | Out-Null

$probeRoot = Join-Path $workspacePath 'tool/probes/android'
$productionRoot = Join-Path $workspacePath 'third_party/media_kit_video/android/src/main/java/com/alexmercerind/media_kit_video'
$sources = @(
    (Get-ChildItem -LiteralPath (Join-Path $probeRoot 'video_surface_texture') -Filter '*.java' -Recurse).FullName
    (Join-Path $productionRoot 'VideoSurfaceTexture.java')
    (Join-Path $productionRoot 'VideoFrameSamples.java')
    (Join-Path $productionRoot 'SurfaceFrameFence.java')
    (Join-Path $productionRoot 'OutputOperationToken.java')
    (Join-Path $productionRoot 'OutputOperationGate.java')
    (Join-Path $probeRoot 'VideoFrameSamplesProbe.java')
    (Join-Path $probeRoot 'SurfaceFrameFenceProbe.java')
    (Join-Path $probeRoot 'OutputOperationGateProbe.java')
    $wrapperSource
)

Write-Host "Checking Android host probes with Flutter $actualVersion..."
& $javacPath -d $outputPath @sources
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

foreach ($probe in @('SurfaceFrameFenceProbe', 'VideoFrameSamplesProbe', 'OutputOperationGateProbe', 'VideoSurfaceTextureProbe', 'VideoSurfaceTextureRequestProbe', 'VideoSurfaceTextureAcquireProbe')) {
    & $javaPath -cp $outputPath "com.alexmercerind.media_kit_video.$probe"
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}
& python (Join-Path $probeRoot 'video_output_release_probe.py')
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
Write-Host 'Android host probes completed successfully (7 probes).'
