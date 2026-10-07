param([switch]$Confirm)

$ErrorActionPreference = "Stop"
if (-not $Confirm) {
    throw "Refusing to restore. Run: powershell -File scripts\rollback-to-mvp.ps1 -Confirm"
}
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "Administrator privileges are required."
}

. (Join-Path $PSScriptRoot "load-environment.ps1")
$snapshot = "D:\+SERG\WS\AUTZ-snapshots\AuthService_MVP_WORKING_2026-10-07"
$verify = Join-Path $snapshot "VERIFY-OK.txt"
if (-not (Test-Path $verify)) { throw "Verified snapshot was not found: $snapshot" }
$workspace = Split-Path $PSScriptRoot -Parent
$siteName = "Default Web Site"
$settingsPath = Join-Path $snapshot "iis\settings.json"
$settings = Get-Content $settingsPath -Raw -Encoding UTF8 | ConvertFrom-Json

Import-Module WebAdministration
if (Test-Path "IIS:\AppPools\AuthService") {
    Stop-WebAppPool "AuthService"
    $deadline = (Get-Date).AddSeconds(30)
    while ((Get-WebAppPoolState "AuthService").Value -ne "Stopped" -and (Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 1
    }
}

function Restore-Tree($source, $target) {
    if (-not (Test-Path $source)) { throw "Snapshot folder missing: $source" }
    New-Item -ItemType Directory -Force -Path $target | Out-Null
    & robocopy $source $target /E /R:1 /W:1 /NFL /NDL /NP | Out-Null
    if ($LASTEXITCODE -ge 8) { throw "robocopy failed for $target ($LASTEXITCODE)" }
    Write-Output "Restored $target"
}

Restore-Tree (Join-Path $snapshot "workspace\AuthService") (Join-Path $workspace "AuthService")
Restore-Tree (Join-Path $snapshot "workspace\pwa-auth-test") (Join-Path $workspace "pwa-auth-test")
Restore-Tree (Join-Path $snapshot "workspace\auth-test") (Join-Path $workspace "auth-test")
Restore-Tree (Join-Path $snapshot "inetpub\authservice") "C:\inetpub\wwwroot\authservice"
Restore-Tree (Join-Path $snapshot "inetpub\pwa-auth-test") "C:\inetpub\wwwroot\pwa-auth-test"
Restore-Tree (Join-Path $snapshot "inetpub\auth-test") "C:\inetpub\wwwroot\auth-test"
if (Test-Path (Join-Path $snapshot "inetpub\UH_Medvedev_test")) {
    Restore-Tree (Join-Path $snapshot "inetpub\UH_Medvedev_test") "C:\inetpub\wwwroot\UH_Medvedev_test"
}
if (Test-Path (Join-Path $snapshot "inetpub\UH_Medvedev_test_osauth")) {
    Restore-Tree (Join-Path $snapshot "inetpub\UH_Medvedev_test_osauth") "C:\inetpub\wwwroot\UH_Medvedev_test_osauth"
}

$pool = $settings.authServicePool
Set-ItemProperty "IIS:\AppPools\AuthService" -Name managedRuntimeVersion -Value $pool.runtime
Set-ItemProperty "IIS:\AppPools\AuthService" -Name managedPipelineMode -Value $pool.pipeline
Set-ItemProperty "IIS:\AppPools\AuthService" -Name processModel.maxProcesses -Value $pool.maxProcesses

function Set-Flag($location, $section, $enabled) {
    if ($null -eq $enabled) { return }
    Set-WebConfigurationProperty -PSPath "MACHINE/WEBROOT/APPHOST" -Location $location -Filter "system.webServer/security/authentication/$section" -Name enabled -Value ([bool]$enabled)
    Write-Output "$location $section=$enabled"
}

foreach ($entry in $settings.authentication.PSObject.Properties) {
    Set-Flag $entry.Name "anonymousAuthentication" $entry.Value.anonymous
    Set-Flag $entry.Name "basicAuthentication" $entry.Value.basic
    Set-Flag $entry.Name "windowsAuthentication" $entry.Value.windows
    $token = $settings.extendedProtection.($entry.Name)
    if ($token) {
        try {
            Set-WebConfigurationProperty -PSPath "MACHINE/WEBROOT/APPHOST" -Location $entry.Name -Filter "system.webServer/security/authentication/windowsAuthentication/extendedProtection" -Name tokenChecking -Value $token
            Write-Output "$($entry.Name) extendedProtection=$token"
        } catch {
            Write-Output "SKIP extendedProtection $($entry.Name)"
        }
    }
}

Start-WebAppPool "AuthService"
Start-Sleep -Seconds 3
$curl = Join-Path $env:WINDIR "System32\curl.exe"
$health = (& $curl -sS -k --max-time 30 -w "`nHTTP_CODE:%{http_code}" "https://$AuthPublicHost/auth/health" | Out-String)
Write-Output $health
if ($health -notmatch '"ok"\s*:\s*true' -or $health -notmatch "HTTP_CODE:200") {
    throw "Health check failed after rollback."
}
Write-Output "MVP RESTORED"
