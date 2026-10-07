param([switch]$Force)

$ErrorActionPreference = "Stop"
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "Administrator privileges are required."
}

$workspace = "D:\+SERG\WS\AUTZ"
$dest = "D:\+SERG\WS\AUTZ-snapshots\AuthService_MVP_WORKING_2026-10-07"
$siteName = "Default Web Site"
if ((Test-Path $dest) -and -not $Force) {
    throw "Snapshot already exists: $dest"
}
if (Test-Path $dest) { Remove-Item $dest -Recurse -Force }
New-Item -ItemType Directory -Force -Path $dest | Out-Null
$log = Join-Path $dest "snapshot.log"
function Write-Log([string]$Message) {
    $line = (Get-Date).ToString("s") + " " + $Message
    Add-Content -Path $log -Value $line -Encoding UTF8
    Write-Output $line
}

Write-Log "SNAPSHOT START"

$workspaceDest = Join-Path $dest "workspace"
New-Item -ItemType Directory -Force -Path $workspaceDest | Out-Null
& robocopy $workspace $workspaceDest /E /R:1 /W:1 /NFL /NDL /NP | Out-Null
if ($LASTEXITCODE -ge 8) { throw "robocopy workspace failed: $LASTEXITCODE" }
Write-Log "Workspace copied, robocopy=$LASTEXITCODE"

$inetpubDirs = @(
    "C:\inetpub\wwwroot\auth",
    "C:\inetpub\wwwroot\authservice",
    "C:\inetpub\wwwroot\pwa-auth-test",
    "C:\inetpub\wwwroot\auth-test",
    "C:\inetpub\wwwroot\zno",
    "C:\inetpub\wwwroot\UH_Medvedev_test",
    "C:\inetpub\wwwroot\UH_Medvedev_test_osauth"
)
foreach ($dir in $inetpubDirs) {
    if (-not (Test-Path $dir)) {
        Write-Log "MISSING $dir"
        continue
    }
    $name = Split-Path $dir -Leaf
    $target = Join-Path $dest "inetpub\$name"
    New-Item -ItemType Directory -Force -Path (Split-Path $target -Parent) | Out-Null
    & robocopy $dir $target /E /R:1 /W:1 /NFL /NDL /NP | Out-Null
    if ($LASTEXITCODE -ge 8) { throw "robocopy $dir failed: $LASTEXITCODE" }
    Write-Log "Copied $dir"
}

$dataDir = "C:\inetpub\authservice-data"
$dataInfo = Join-Path $dest "authservice-data-listing.txt"
if (Test-Path $dataDir) {
    $names = Get-ChildItem $dataDir -Force | ForEach-Object { $_.Name + "`t" + $_.Length }
    Set-Content -Path $dataInfo -Value $names -Encoding UTF8
    Write-Log "Listed authservice-data without copying log contents"
} else {
    Set-Content -Path $dataInfo -Value "MISSING" -Encoding UTF8
}

$iis = Join-Path $dest "iis"
New-Item -ItemType Directory -Force -Path $iis | Out-Null
$appcmd = Join-Path $env:WINDIR "System32\inetsrv\appcmd.exe"
function Save-AppCmd {
    param([string]$File, [string[]]$AppArgs)
    $out = & $appcmd @AppArgs
    $out | Set-Content -Path (Join-Path $iis $File) -Encoding UTF8
    Write-Log "appcmd $File"
}
Save-AppCmd "site.xml" @("list", "site", $siteName, "/config", "/xml")
Save-AppCmd "apps.xml" @("list", "app", "/site.name:$siteName", "/xml")
Save-AppCmd "vdirs.xml" @("list", "vdir", "/app.name:$siteName/", "/xml")
Save-AppCmd "pool-authservice.xml" @("list", "apppool", "AuthService", "/config", "/xml")
Save-AppCmd "pool-default.xml" @("list", "apppool", "DefaultAppPool", "/config", "/xml")

$locations = @(
    "$siteName/auth",
    "$siteName/auth/sso",
    "$siteName/UH_Medvedev_test",
    "$siteName/UH_Medvedev_test_osauth",
    "$siteName/pwa-auth-test"
)
foreach ($location in $locations) {
    $safe = ($location -replace "[^A-Za-z0-9]", "_")
    foreach ($section in @(
        "system.webServer/security/authentication/anonymousAuthentication",
        "system.webServer/security/authentication/basicAuthentication",
        "system.webServer/security/authentication/windowsAuthentication",
        "system.webServer/security/ipSecurity",
        "system.webServer/security/authorization",
        "system.webServer/security/access"
    )) {
        $leaf = ($section -replace ".*/", "")
        try {
            $out = & $appcmd list config $location "/section:$section"
            $out | Set-Content -Path (Join-Path $iis "$safe-$leaf.txt") -Encoding UTF8
        } catch {
            Set-Content -Path (Join-Path $iis "$safe-$leaf.txt") -Value $_.Exception.Message -Encoding UTF8
        }
    }
}

Import-Module WebAdministration
function Read-Flag($location, $section) {
    try {
        $value = Get-WebConfigurationProperty -PSPath "MACHINE/WEBROOT/APPHOST" -Location $location -Filter "system.webServer/security/authentication/$section" -Name enabled -ErrorAction Stop
        return [bool]$value.Value
    } catch {
        return $null
    }
}
function Read-Providers($location) {
    try {
        $items = Get-WebConfiguration -PSPath "MACHINE/WEBROOT/APPHOST" -Location $location -Filter "system.webServer/security/authentication/windowsAuthentication/providers/*" -ErrorAction Stop
        return @($items | ForEach-Object { [string]$_.GetAttributeValue("value") })
    } catch {
        return @()
    }
}
function Read-TokenChecking($location) {
    try {
        $value = Get-WebConfigurationProperty -PSPath "MACHINE/WEBROOT/APPHOST" -Location $location -Filter "system.webServer/security/authentication/windowsAuthentication/extendedProtection" -Name tokenChecking -ErrorAction Stop
        return [string]$value.Value
    } catch {
        return ""
    }
}

$pool = Get-Item "IIS:\AppPools\AuthService"
$bindings = @(Get-WebBinding -Name $siteName | ForEach-Object {
    [ordered]@{
        protocol = $_.protocol
        bindingInformation = $_.bindingInformation
        certificateHash = [string]$_.certificateHash
        certificateStoreName = [string]$_.certificateStoreName
    }
})
$apps = @(Get-WebApplication -Site $siteName | ForEach-Object {
    [ordered]@{ path = $_.path; physicalPath = $_.PhysicalPath; applicationPool = $_.applicationPool }
})

$settings = [ordered]@{
    capturedAt = (Get-Date).ToString("s")
    site = $siteName
    bindings = $bindings
    applications = $apps
    authServicePool = [ordered]@{
        runtime = [string]$pool.managedRuntimeVersion
        pipeline = [string]$pool.managedPipelineMode
        state = [string]$pool.state
        maxProcesses = [int]$pool.processModel.maxProcesses
        identityType = [string]$pool.processModel.identityType
    }
    authentication = [ordered]@{}
    windowsProviders = [ordered]@{}
    extendedProtection = [ordered]@{}
}
foreach ($location in @("$siteName/auth", "$siteName/auth/sso", "$siteName/UH_Medvedev_test", "$siteName/UH_Medvedev_test_osauth")) {
    $settings.authentication[$location] = [ordered]@{
        anonymous = (Read-Flag $location "anonymousAuthentication")
        basic = (Read-Flag $location "basicAuthentication")
        windows = (Read-Flag $location "windowsAuthentication")
    }
    $settings.windowsProviders[$location] = @(Read-Providers $location)
    $settings.extendedProtection[$location] = (Read-TokenChecking $location)
}
$settings | ConvertTo-Json -Depth 8 | Set-Content -Path (Join-Path $iis "settings.json") -Encoding UTF8
Write-Log "settings.json written"

$hashes = @()
$hashFiles = @(
    "D:\+SERG\WS\AUTZ\AuthService\bin\AuthService.dll",
    "D:\+SERG\WS\AUTZ\AuthService\src\AuthModule.cs",
    "C:\inetpub\wwwroot\authservice\bin\AuthService.dll",
    "C:\inetpub\wwwroot\authservice\web.config",
    "C:\inetpub\wwwroot\pwa-auth-test\index.html",
    "C:\inetpub\wwwroot\UH_Medvedev_test\default.vrd",
    "C:\inetpub\wwwroot\UH_Medvedev_test\web.config",
    "C:\inetpub\wwwroot\UH_Medvedev_test_osauth\default.vrd",
    "C:\inetpub\wwwroot\UH_Medvedev_test_osauth\web.config"
)
foreach ($file in $hashFiles) {
    if (-not (Test-Path $file)) { throw "Required file missing: $file" }
    $hash = (Get-FileHash -Algorithm SHA256 -Path $file).Hash
    $hashes += ($hash + "  " + $file)
}
$copyPairs = @(
    @("D:\+SERG\WS\AUTZ\AuthService\src\AuthModule.cs", (Join-Path $workspaceDest "AuthService\src\AuthModule.cs")),
    @("C:\inetpub\wwwroot\authservice\bin\AuthService.dll", (Join-Path $dest "inetpub\authservice\bin\AuthService.dll")),
    @("C:\inetpub\wwwroot\UH_Medvedev_test\default.vrd", (Join-Path $dest "inetpub\UH_Medvedev_test\default.vrd")),
    @("C:\inetpub\wwwroot\UH_Medvedev_test_osauth\default.vrd", (Join-Path $dest "inetpub\UH_Medvedev_test_osauth\default.vrd")),
    @("C:\inetpub\wwwroot\pwa-auth-test\index.html", (Join-Path $dest "inetpub\pwa-auth-test\index.html"))
)
foreach ($pair in $copyPairs) {
    if (-not (Test-Path $pair[1])) { throw "Snapshot copy missing: $($pair[1])" }
    $left = (Get-FileHash -Algorithm SHA256 -Path $pair[0]).Hash
    $right = (Get-FileHash -Algorithm SHA256 -Path $pair[1]).Hash
    if ($left -ne $right) { throw "Hash mismatch: $($pair[0])" }
    $hashes += ($right + "  COPY-OK  " + $pair[1])
}
if (-not (Test-Path (Join-Path $iis "settings.json"))) { throw "settings.json missing" }
if ((Get-Item (Join-Path $iis "site.xml")).Length -lt 50) { throw "site.xml is empty" }
Set-Content -Path (Join-Path $dest "SHA256.txt") -Value $hashes -Encoding UTF8
Copy-Item (Join-Path $workspace "scripts\rollback-to-mvp.ps1") (Join-Path $dest "rollback-to-mvp.ps1") -Force
Set-Content -Path (Join-Path $dest "VERIFY-OK.txt") -Value "verified $((Get-Date).ToString('s'))" -Encoding ASCII
Write-Log "SNAPSHOT VERIFIED"
