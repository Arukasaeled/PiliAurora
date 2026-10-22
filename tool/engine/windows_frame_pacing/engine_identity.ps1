function Get-WindowsFramePacingEngineIdentity {
    param(
        [Parameter(Mandatory = $true)]
        [string]$LibraryPath,
        [Parameter(Mandatory = $true)]
        [ValidateSet('profile', 'release')]
        [string]$Mode,
        [switch]$RequireNativeTests
    )

    $identityPath = Join-Path (Split-Path $LibraryPath -Parent) 'engine-identity.json'
    $identity = Get-Content -LiteralPath $identityPath -Raw | ConvertFrom-Json
    $patchPath = Join-Path $PSScriptRoot 'engine.patch'
    if ($identity.engineCommit -ne 'af7e796e161ae0bb1ff0758c71a7105418bd9ded' -or
        $identity.mode -ne $Mode -or $identity.architecture -ne 'x64' -or
        $identity.patchSha256 -ne (Get-FileHash -LiteralPath $patchPath -Algorithm SHA256).Hash -or
        $identity.sha256 -ne (Get-FileHash -LiteralPath $LibraryPath -Algorithm SHA256).Hash) {
        throw '自编引擎身份、模式、补丁或 DLL 摘要不匹配。'
    }
    if ($RequireNativeTests -and $identity.nativeTestsPassed -ne $true) {
        throw '应用构建要求自编引擎已通过原生回归测试。'
    }
    return $identity
}
