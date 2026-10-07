# Roll back the last AuthService deployment recorded by deploy.ps1.
# Does not modify UH_Medvedev_test or any other IIS application.
$ErrorActionPreference = "Stop"

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "Administrator privileges are required."
}

$root = Split-Path -Parent $PSScriptRoot
$workspace = Split-Path -Parent $root
$pointer = Join-Path $workspace "backup\inetpub-latest.txt"
if (-not (Test-Path $pointer)) { throw "No deployment pointer: $pointer" }
$backup = (Get-Content $pointer -Raw).Trim()
$manifestPath = Join-Path $backup "deploy-manifest.json"
if (-not (Test-Path $manifestPath)) { throw "Manifest not found: $manifestPath" }
$manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json
$appcmd = Join-Path $env:WINDIR "System32\inetsrv\appcmd.exe"

if ($manifest.createdApp) {
    & $appcmd delete app ($manifest.app)
    Write-Output "Removed IIS application $($manifest.app)"
}

$targets = @(
    @{ Name = "auth"; Path = "C:\inetpub\wwwroot\auth" },
    @{ Name = "pwa-auth-test"; Path = "C:\inetpub\wwwroot\pwa-auth-test" },
    @{ Name = "auth-test"; Path = "C:\inetpub\wwwroot\auth-test" },
    @{ Name = "authservice"; Path = "C:\inetpub\wwwroot\authservice" }
)

foreach ($target in $targets) {
    $source = Join-Path $backup $target.Name
    if (Test-Path $source) {
        if (Test-Path $target.Path) { Remove-Item $target.Path -Recurse -Force }
        Copy-Item $source $target.Path -Recurse -Force
        Write-Output "Restored $($target.Path)"
    } elseif ($target.Name -eq "authservice" -and (Test-Path $target.Path)) {
        Remove-Item $target.Path -Recurse -Force
        Write-Output "Removed $($target.Path)"
    }
}

if ($manifest.createdPool -or $manifest.removePoolIfUnused) {
    $ErrorActionPreference = "Continue"
    $stillUsed = & $appcmd list app "/apppool.name:$($manifest.pool)" 2>$null
    $ErrorActionPreference = "Stop"
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace(($stillUsed | Out-String))) {
        & $appcmd delete apppool ($manifest.pool)
        Write-Output "Removed application pool $($manifest.pool)"
    } else {
        Write-Output "Pool $($manifest.pool) is still used. Left in place."
    }
}

Write-Output "ROLLBACK COMPLETE from $backup"
