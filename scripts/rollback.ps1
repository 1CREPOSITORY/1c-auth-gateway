$ErrorActionPreference = "Stop"
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "Administrator privileges are required."
}

$pointer = "D:\+SERG\WS\AUTZ\backup\inetpub-latest.txt"
if (-not (Test-Path $pointer)) { throw "No deployment pointer." }
$backup = (Get-Content $pointer -Raw).Trim()
$manifest = Get-Content (Join-Path $backup "deploy-manifest.json") -Raw | ConvertFrom-Json
Import-Module WebAdministration

if ($manifest.createdOsAuth) {
    $osApp = Get-WebApplication -Site "Default Web Site" | Where-Object { $_.path -eq "/UH_Medvedev_test_osauth" }
    if ($osApp) {
        Remove-WebApplication -Name "UH_Medvedev_test_osauth" -Site "Default Web Site"
        Write-Output "Removed /UH_Medvedev_test_osauth"
    }
    if (Test-Path "C:\inetpub\wwwroot\UH_Medvedev_test_osauth") {
        Remove-Item "C:\inetpub\wwwroot\UH_Medvedev_test_osauth" -Recurse -Force
    }
}

$targets = @(
    @{ Name = "auth"; Path = "C:\inetpub\wwwroot\auth" },
    @{ Name = "zno"; Path = "C:\inetpub\wwwroot\zno" },
    @{ Name = "pwa-auth-test"; Path = "C:\inetpub\wwwroot\pwa-auth-test" },
    @{ Name = "auth-test"; Path = "C:\inetpub\wwwroot\auth-test" },
    @{ Name = "authservice"; Path = "C:\inetpub\wwwroot\authservice" }
)
foreach ($target in $targets) {
    $source = Join-Path $backup $target.Name
    if (Test-Path $target.Path) { Remove-Item $target.Path -Recurse -Force }
    if (Test-Path $source) {
        Copy-Item $source $target.Path -Recurse -Force
        Write-Output "Restored $($target.Path)"
    }
}
$dllBackup = Join-Path $backup "bin\AuthService.dll"
$dllTarget = "C:\inetpub\wwwroot\bin\AuthService.dll"
if (Test-Path $dllBackup) {
    Copy-Item $dllBackup $dllTarget -Force
} elseif (Test-Path $dllTarget) {
    Remove-Item $dllTarget -Force
}

if ($manifest.removedAuthApp -and $manifest.removedAuthPhysical) {
    $existing = Get-WebApplication -Site "Default Web Site" | Where-Object { $_.path -eq "/auth" }
    if (-not $existing) {
        New-WebApplication -Name "auth" -Site "Default Web Site" -PhysicalPath $manifest.removedAuthPhysical -ApplicationPool $manifest.removedAuthPool | Out-Null
        Write-Output "Restored IIS application /auth"
    }
}

$rootConfig = "C:\inetpub\wwwroot\web.config"
if ((Test-Path $rootConfig) -and (Select-String -Path $rootConfig -Pattern "AuthServiceModule" -Quiet)) {
    Remove-Item $rootConfig -Force
    Write-Output "Removed AuthService root web.config"
}
if ($manifest.rootPool) { Restart-WebAppPool $manifest.rootPool }
Write-Output "ROLLBACK COMPLETE from $backup"
