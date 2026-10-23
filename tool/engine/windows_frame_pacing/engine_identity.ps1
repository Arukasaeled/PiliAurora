function Get-WindowsFramePacingEngineIdentity {
    param(
        [Parameter(Mandatory = $true)][string]$LibraryPath,
        [Parameter(Mandatory = $true)][ValidateSet('profile', 'release')][string]$Mode,
        [switch]$RequireNativeTests
    )
    $identityScript = Join-Path $PSScriptRoot '../engine_identity.py'
    $output = & python $identityScript --library $LibraryPath --profile windowsDwmPaced --mode $Mode
    if ($LASTEXITCODE -ne 0) { throw 'Windows 自编引擎身份校验失败。' }
    return ($output | ConvertFrom-Json).identity
}
