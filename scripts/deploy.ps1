$ErrorActionPreference = "Stop"
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "Administrator privileges are required."
}

. (Join-Path $PSScriptRoot "load-environment.ps1")
$workspace = Split-Path $PSScriptRoot -Parent
$siteName = "Default Web Site"
$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$backup = Join-Path $workspace "backup\inetpub-$stamp"
$physicalAuth = "C:\inetpub\wwwroot\auth"
$physicalZno = "C:\inetpub\wwwroot\zno"
$physicalBin = "C:\inetpub\wwwroot\bin"
$physicalOs = "C:\inetpub\wwwroot\UH_Medvedev_test_osauth"
$sourcePub = "C:\inetpub\wwwroot\UH_Medvedev_test"
$dataDir = "C:\inetpub\authservice-data"

Write-Output "Building AuthService..."
& (Join-Path $workspace "AuthService\scripts\build.ps1")

New-Item -ItemType Directory -Force -Path $backup | Out-Null
foreach ($dir in @($physicalAuth, $physicalZno, "C:\inetpub\wwwroot\pwa-auth-test", "C:\inetpub\wwwroot\auth-test", "C:\inetpub\wwwroot\authservice", $physicalOs)) {
    if (Test-Path $dir) {
        Copy-Item $dir (Join-Path $backup (Split-Path $dir -Leaf)) -Recurse -Force
        Write-Output "Backed up $dir"
    }
}
if (Test-Path (Join-Path $physicalBin "AuthService.dll")) {
    New-Item -ItemType Directory -Force -Path (Join-Path $backup "bin") | Out-Null
    Copy-Item (Join-Path $physicalBin "AuthService.dll") (Join-Path $backup "bin\AuthService.dll") -Force
}

Import-Module ServerManager
$winAuth = Get-WindowsFeature Web-Windows-Auth
if ($winAuth.InstallState -ne "Installed") {
    Write-Output "Installing Web-Windows-Auth..."
    Install-WindowsFeature Web-Windows-Auth | Out-String | Write-Output
}

Import-Module WebAdministration
$rootPool = (Get-Item "IIS:\Sites\$siteName").applicationPool
$oneCApp = Get-WebApplication -Site $siteName | Where-Object { $_.path -eq "/UH_Medvedev_test" }
if (-not $oneCApp) { throw "UH_Medvedev_test application was not found. Publication was not modified." }
$oneCPool = $oneCApp.applicationPool

$authApp = Get-WebApplication -Site $siteName | Where-Object { $_.path -eq "/auth" }
$removedAuthApp = $false
$removedAuthPhysical = ""
$removedAuthPool = ""
$authPhysical = "C:\inetpub\wwwroot\authservice"
if (-not (Test-Path "IIS:\AppPools\AuthService")) {
    New-WebAppPool "AuthService" | Out-Null
}
Set-ItemProperty "IIS:\AppPools\AuthService" -Name managedRuntimeVersion -Value "v4.0"
Set-ItemProperty "IIS:\AppPools\AuthService" -Name managedPipelineMode -Value "Integrated"
if (-not $authApp) {
    New-WebApplication -Name "auth" -Site $siteName -PhysicalPath $authPhysical -ApplicationPool "AuthService" | Out-Null
    Write-Output "Created IIS application /auth"
} else {
    Set-ItemProperty "IIS:\Sites\$siteName\auth" -Name applicationPool -Value "AuthService"
    Set-ItemProperty "IIS:\Sites\$siteName\auth" -Name physicalPath -Value $authPhysical
    Write-Output "Updated IIS application /auth"
}

New-Item -ItemType Directory -Force -Path $physicalAuth, $physicalZno, $physicalBin, $dataDir | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $authPhysical "bin") | Out-Null
Copy-Item (Join-Path $workspace "AuthService\bin\AuthService.dll") (Join-Path $authPhysical "bin\AuthService.dll") -Force
Copy-Item (Join-Path $workspace "AuthService\web.config") (Join-Path $authPhysical "web.config") -Force
if (Test-Path "C:\inetpub\wwwroot\web.config") {
    $rootConfig = Get-Content "C:\inetpub\wwwroot\web.config" -Raw
    if ($rootConfig -match "AuthServiceModule") { Remove-Item "C:\inetpub\wwwroot\web.config" -Force }
}
Remove-Item (Join-Path $physicalAuth "web.config") -Force -ErrorAction SilentlyContinue
Remove-Item (Join-Path $physicalZno "web.config") -Force -ErrorAction SilentlyContinue
Copy-Item (Join-Path $workspace "pwa-auth-test\*") "C:\inetpub\wwwroot\pwa-auth-test\" -Force
Copy-Item (Join-Path $workspace "auth-test\index.html") "C:\inetpub\wwwroot\auth-test\index.html" -Force

icacls $dataDir /inheritance:r | Out-Null
icacls $dataDir /grant:r "NT AUTHORITY\SYSTEM:(OI)(CI)F" "BUILTIN\Administrators:(OI)(CI)F" "IIS AppPool\AuthService:(OI)(CI)M" "IIS AppPool\${rootPool}:(OI)(CI)M" | Out-Null

$createdOsAuth = $false
if (-not (Test-Path $sourcePub)) { throw "Source publication is missing." }
New-Item -ItemType Directory -Force -Path $physicalOs | Out-Null
$vrdBytes = [IO.File]::ReadAllBytes((Join-Path $sourcePub "default.vrd"))
$vrd = [Text.Encoding]::UTF8.GetString($vrdBytes)
$vrd = $vrd.Replace('base="/UH_Medvedev_test"', 'base="/UH_Medvedev_test_osauth"')
[IO.File]::WriteAllText((Join-Path $physicalOs "default.vrd"), $vrd, (New-Object Text.UTF8Encoding $false))
Copy-Item (Join-Path $sourcePub "web.config") (Join-Path $physicalOs "web.config") -Force
$osApp = Get-WebApplication -Site $siteName | Where-Object { $_.path -eq "/UH_Medvedev_test_osauth" }
if (-not $osApp) {
    New-WebApplication -Name "UH_Medvedev_test_osauth" -Site $siteName -PhysicalPath $physicalOs -ApplicationPool $oneCPool | Out-Null
    $createdOsAuth = $true
    Write-Output "Created IIS application /UH_Medvedev_test_osauth in pool $oneCPool"
} else {
    Set-ItemProperty "IIS:\Sites\$siteName\UH_Medvedev_test_osauth" -Name applicationPool -Value $oneCPool
    Set-ItemProperty "IIS:\Sites\$siteName\UH_Medvedev_test_osauth" -Name physicalPath -Value $physicalOs
    Write-Output "Updated IIS application /UH_Medvedev_test_osauth"
}

function Set-IisAuth {
    param([string]$Location, [string]$Section, [bool]$Enabled)
    try {
        Set-WebConfigurationProperty -PSPath "MACHINE/WEBROOT/APPHOST" -Location $Location -Filter "system.webServer/security/authentication/$Section" -Name enabled -Value $Enabled
        Write-Output "$Location $Section=$Enabled"
    } catch {
        Write-Output "SKIP $Location $Section"
    }
}

Set-IisAuth "$siteName/auth" "anonymousAuthentication" $true
Set-IisAuth "$siteName/auth" "basicAuthentication" $false
Set-IisAuth "$siteName/auth" "windowsAuthentication" $false
Set-IisAuth "$siteName/zno" "anonymousAuthentication" $true
Set-IisAuth "$siteName/zno" "basicAuthentication" $false
Set-IisAuth "$siteName/zno" "windowsAuthentication" $false
Set-IisAuth "$siteName/auth/sso" "anonymousAuthentication" $false
Set-IisAuth "$siteName/auth/sso" "windowsAuthentication" $true
Set-IisAuth "$siteName/UH_Medvedev_test_osauth" "anonymousAuthentication" $false
Set-IisAuth "$siteName/UH_Medvedev_test_osauth" "basicAuthentication" $false
Set-IisAuth "$siteName/UH_Medvedev_test_osauth" "windowsAuthentication" $true

foreach ($location in @("$siteName/auth", "$siteName/zno")) {
    try {
        Set-WebConfigurationProperty -PSPath "MACHINE/WEBROOT/APPHOST" -Location $location -Filter "system.webServer/httpErrors" -Name existingResponse -Value "PassThrough"
    } catch {
        Write-Output "Could not set httpErrors for $location"
    }
}

$manifest = @{
    backup = $backup
    removedAuthApp = $removedAuthApp
    removedAuthPhysical = $removedAuthPhysical
    removedAuthPool = $removedAuthPool
    createdOsAuth = $createdOsAuth
    oneCPool = $oneCPool
    rootPool = $rootPool
    deployedAt = (Get-Date).ToString("s")
} | ConvertTo-Json
Set-Content (Join-Path $backup "deploy-manifest.json") $manifest -Encoding UTF8
Set-Content (Join-Path $workspace "backup\inetpub-latest.txt") $backup -Encoding ASCII

Restart-WebAppPool "AuthService"
if (Test-Path "IIS:\AppPools\$rootPool") { Restart-WebAppPool $rootPool }
Write-Output "Recycled application pools"
Start-Sleep -Seconds 3

$curl = Join-Path $env:WINDIR "System32\curl.exe"
$health = (& $curl -sS -k --max-time 30 -w "`nHTTP_CODE:%{http_code}" "https://$AuthPublicHost/auth/health" | Out-String)
Write-Output $health
if ($health -notmatch '"ok"\s*:\s*true' -or $health -notmatch "HTTP_CODE:200") { throw "Health check failed." }

$osHeaders = (& $curl -sS -k -D - -o NUL --max-time 30 "https://$AuthPublicHost/UH_Medvedev_test_osauth/hs/mobile/api/tasks" | Out-String)
Write-Output $osHeaders
if ($osHeaders -notmatch "HTTP/1\.[01] 401") { throw "OS-auth publication did not challenge." }
Write-Output "DEPLOYED"
