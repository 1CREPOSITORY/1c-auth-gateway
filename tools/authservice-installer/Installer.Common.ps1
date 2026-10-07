Set-StrictMode -Version 2
$ErrorActionPreference = "Stop"

function Test-InstallerAdmin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-InstallerFqdn {
    try {
        $cs = Get-CimInstance Win32_ComputerSystem
        $name = [string]$cs.DNSHostName
        $domain = [string]$cs.Domain
        if ($domain -and $domain -ne "WORKGROUP") { return ($name + "." + $domain) }
        return $name
    } catch {
        return [Net.Dns]::GetHostName()
    }
}

function Assert-LocalServer([string]$Expected) {
    $local = Get-InstallerFqdn
    $short = $env:COMPUTERNAME
    $ok = $Expected -eq $local -or $Expected -eq $short
    if (-not $ok) {
        try {
            $entry = [Net.Dns]::GetHostEntry($Expected)
            $localIps = @([Net.Dns]::GetHostAddresses($local) | ForEach-Object { $_.ToString() })
            $ok = @($entry.AddressList | Where-Object { $localIps -contains $_.ToString() }).Count -gt 0
        } catch {
            $ok = $false
        }
    }
    if (-not $ok) {
        throw "Installer запускается только локально на IIS-сервере. Указан '$Expected', этот компьютер '$local'. Запустите скрипт на нужном сервере."
    }
}

function Import-InstallerIis {
    Import-Module WebAdministration -ErrorAction Stop
}

function Get-InstallerSites {
    Import-InstallerIis
    return @(Get-Website | ForEach-Object { $_.Name })
}

function Get-AuthFlag {
    param([string]$Location, [string]$Section)
    try {
        $value = Get-WebConfigurationProperty -PSPath "MACHINE/WEBROOT/APPHOST" -Location $Location -Filter "system.webServer/security/authentication/$Section" -Name enabled -ErrorAction Stop
        return [bool]$value.Value
    } catch {
        return $null
    }
}

function Set-AuthFlag {
    param([string]$Location, [string]$Section, [bool]$Enabled)
    Set-WebConfigurationProperty -PSPath "MACHINE/WEBROOT/APPHOST" -Location $Location -Filter "system.webServer/security/authentication/$Section" -Name enabled -Value $Enabled
}

function Get-WebAppByPath {
    param([string]$Site, [string]$Path)
    if (-not $Path.StartsWith("/")) { $Path = "/" + $Path }
    return Get-WebApplication -Site $Site | Where-Object { $_.path -eq $Path } | Select-Object -First 1
}

function Read-PublicationVrd {
    param([string]$VrdPath, [string]$PublicationName)
    if (-not (Test-Path $VrdPath)) { throw "default.vrd не найден: $VrdPath" }
    [xml]$xml = Get-Content -Path $VrdPath -Raw -Encoding UTF8
    $root = $xml.DocumentElement
    $base = [string]$root.GetAttribute("base")
    $ib = [string]$root.GetAttribute("ib")
    if ($base -ne ("/" + $PublicationName)) {
        throw "base в default.vrd равен '$base', ожидался '/$PublicationName'. Установщик не подменяет это сам."
    }
    $server = $null
    $database = $null
    $serverMatch = [regex]::Match($ib, 'Srvr="([^"]+)"')
    $refMatch = [regex]::Match($ib, 'Ref="([^"]+)"')
    if ($serverMatch.Success) { $server = $serverMatch.Groups[1].Value }
    if ($refMatch.Success) { $database = $refMatch.Groups[1].Value }
    if (-not $server -or -not $database) {
        throw "Из default.vrd не удалось прочитать Srvr и Ref. Строка подключения: $ib"
    }
    $http = $root.GetElementsByTagName("httpServices") | Select-Object -First 1
    $publishByDefault = $false
    if ($http -and $http.GetAttribute("publishExtensionsByDefault") -eq "true") { $publishByDefault = $true }
    $serviceNames = @()
    if ($http) {
        foreach ($node in $http.ChildNodes) {
            if ($node.LocalName -eq "service") {
                $serviceNames += [string]$node.GetAttribute("name")
                $serviceNames += [string]$node.GetAttribute("rootUrl")
            }
        }
    }
    return [ordered]@{
        Base = $base
        Ib = $ib
        Server = $server
        Database = $database
        PublishHttpByDefault = $publishByDefault
        ServiceNames = @($serviceNames | Where-Object { $_ })
    }
}

function Test-HttpServicePublished {
    param($VrdInfo, [string]$ServiceName)
    if ($VrdInfo.PublishHttpByDefault) { return $true }
    return @($VrdInfo.ServiceNames | Where-Object { $_ -eq $ServiceName }).Count -gt 0
}

function Parse-UiEndpoint {
    param([string]$Value, [string]$Publication)
    $text = $Value.Trim()
    if ($text -match '^[a-zA-Z][a-zA-Z0-9+\.-]*://') {
        throw "UI endpoint задаётся путём без схемы и имени сервера. Пример: /$Publication/hs/mobile/ui"
    }
    if ($text -notmatch '^/([^/]+)/hs/([^/]+)/ui$') {
        throw "Неверный UI endpoint '$text'. Формат: /<publication>/hs/<http-service>/ui"
    }
    $endpointPublication = $Matches[1]
    $service = $Matches[2]
    if ($endpointPublication -ne $Publication) {
        throw "Публикация в UI endpoint '$endpointPublication' не совпадает с выбранной '$Publication'."
    }
    return [ordered]@{
        Raw = $text
        Publication = $endpointPublication
        HttpService = $service
        ServiceBase = "/$endpointPublication/hs/$service"
    }
}

function Get-SiteCertificateThumbprint {
    param([string]$Site)
    $binding = Get-WebBinding -Name $Site -Protocol https | Select-Object -First 1
    if (-not $binding) { return "" }
    return ([string]$binding.certificateHash).Replace(" ", "")
}

function Get-WindowsProviders {
    param([string]$Location)
    try {
        $nodes = Get-WebConfiguration -PSPath "MACHINE/WEBROOT/APPHOST" -Location $Location -Filter "system.webServer/security/authentication/windowsAuthentication/providers"
        return @($nodes | ForEach-Object { [string]$_.value } | Where-Object { $_ })
    } catch {
        return @()
    }
}

function Set-WindowsProviders {
    param([string]$Location, [string[]]$Providers)
    $filter = "system.webServer/security/authentication/windowsAuthentication/providers"
    Clear-WebConfiguration -PSPath "MACHINE/WEBROOT/APPHOST" -Location $Location -Filter $filter
    foreach ($name in $Providers) {
        Add-WebConfiguration -PSPath "MACHINE/WEBROOT/APPHOST" -Location $Location -Filter $filter -Value @{ value = $name }
    }
}

function Get-WindowsAuthInstalled {
    Import-Module ServerManager -ErrorAction Stop
    $feature = Get-WindowsFeature Web-Windows-Auth
    return $feature.InstallState -eq "Installed"
}

function New-AuthServicePlan {
    param(
        [string]$Server,
        [string]$Site,
        [string]$Publication,
        [string]$UiEndpoint,
        [string]$OsAuthPublication,
        [string]$AuthPath,
        [string]$AppPoolName
    )
    Import-InstallerIis
    if (-not $AuthPath.StartsWith("/")) { $AuthPath = "/" + $AuthPath }
    $primary = Get-WebAppByPath -Site $Site -Path ("/" + $Publication)
    if (-not $primary) { throw "Приложение IIS '/$Publication' на сайте '$Site' не найдено." }
    $physical = [string]$primary.PhysicalPath
    $vrd = Join-Path $physical "default.vrd"
    $web = Join-Path $physical "web.config"
    if (-not (Test-Path $physical)) { throw "Каталог публикации не найден: $physical" }
    if (-not (Test-Path $web)) { throw "web.config публикации не найден: $web" }
    $handler = Get-Content -Path $web -Raw
    if ($handler -notmatch "wsisapi\.dll") { throw "В web.config публикации нет обработчика 1С wsisapi.dll." }
    $dllMatch = [regex]::Match($handler, 'scriptProcessor="([^"]+wsisapi\.dll)"')
    if (-not $dllMatch.Success) { throw "Не удалось прочитать путь wsisapi.dll из web.config." }
    $wsisapi = $dllMatch.Groups[1].Value
    if (-not (Test-Path $wsisapi)) { throw "wsisapi.dll не найден: $wsisapi" }
    $vrdInfo = Read-PublicationVrd -VrdPath $vrd -PublicationName $Publication
    $ui = Parse-UiEndpoint -Value $UiEndpoint -Publication $Publication
    if (-not (Test-HttpServicePublished -VrdInfo $vrdInfo -ServiceName $ui.HttpService)) {
        throw "HTTP-сервис '$($ui.HttpService)' не найден в default.vrd и publishExtensionsByDefault не включён."
    }
    $osApp = Get-WebAppByPath -Site $Site -Path ("/" + $OsAuthPublication)
    $authApp = Get-WebAppByPath -Site $Site -Path $AuthPath
    $poolExists = Test-Path ("IIS:\AppPools\" + $AppPoolName)
    $authLeaf = $AuthPath.Trim("/")
    $authPhysical = "C:\inetpub\wwwroot\authservice"
    if ($AuthPath -ne "/auth") { $authPhysical = Join-Path "C:\inetpub\wwwroot" $authLeaf }
    $osPhysical = Join-Path "C:\inetpub\wwwroot" $OsAuthPublication
    $thumb = Get-SiteCertificateThumbprint -Site $Site
    $fqdn = $Server
    return [ordered]@{
        Server = $Server
        Site = $Site
        Publication = $Publication
        PhysicalPath = $physical
        OneCServer = $vrdInfo.Server
        OneCDatabase = $vrdInfo.Database
        Ib = $vrdInfo.Ib
        Base = $vrdInfo.Base
        UiEndpoint = $ui.Raw
        HttpService = $ui.HttpService
        ServiceBase = $ui.ServiceBase
        PublishHttpByDefault = $vrdInfo.PublishHttpByDefault
        Wsisapi = $wsisapi
        PrimaryPool = [string]$primary.applicationPool
        OsAuthPublication = $OsAuthPublication
        OsAuthPhysical = $osPhysical
        OsAuthExisted = [bool]($null -ne $osApp)
        AuthPath = $AuthPath
        AuthPhysical = $authPhysical
        AuthExisted = [bool]($null -ne $authApp)
        AppPoolName = $AppPoolName
        AppPoolExisted = [bool]$poolExists
        CertificateThumbprint = $thumb
        BasicBase = "https://$fqdn$($ui.ServiceBase)"
        OsAuthBase = "https://127.0.0.1/$OsAuthPublication/hs/$($ui.HttpService)"
        AllowedOrigin = "https://$fqdn"
        WindowsAuthInstalled = (Get-WindowsAuthInstalled)
        PrimaryAuth = [ordered]@{
            anonymous = (Get-AuthFlag "$Site/$Publication" "anonymousAuthentication")
            windows = (Get-AuthFlag "$Site/$Publication" "windowsAuthentication")
            basic = (Get-AuthFlag "$Site/$Publication" "basicAuthentication")
        }
        AuthAuth = [ordered]@{
            anonymous = (Get-AuthFlag "$Site$AuthPath" "anonymousAuthentication")
            windows = (Get-AuthFlag "$Site$AuthPath" "windowsAuthentication")
            basic = (Get-AuthFlag "$Site$AuthPath" "basicAuthentication")
        }
        SsoAuth = [ordered]@{
            anonymous = (Get-AuthFlag "$Site$AuthPath/sso" "anonymousAuthentication")
            windows = (Get-AuthFlag "$Site$AuthPath/sso" "windowsAuthentication")
            basic = (Get-AuthFlag "$Site$AuthPath/sso" "basicAuthentication")
            providers = @(Get-WindowsProviders "$Site$AuthPath/sso")
        }
        OsAuthAuth = [ordered]@{
            anonymous = (Get-AuthFlag "$Site/$OsAuthPublication" "anonymousAuthentication")
            windows = (Get-AuthFlag "$Site/$OsAuthPublication" "windowsAuthentication")
            basic = (Get-AuthFlag "$Site/$OsAuthPublication" "basicAuthentication")
            providers = @(Get-WindowsProviders "$Site/$OsAuthPublication")
        }
    }
}

function Format-AuthPlan {
    param($Plan, [string]$BackupPath)
    $httpNote = "найден в default.vrd"
    if ($Plan.PublishHttpByDefault) { $httpNote = "publishExtensionsByDefault=true" }
    $osState = "будет создана"
    if ($Plan.OsAuthExisted) { $osState = "уже есть, будет обновлена" }
    $authState = "будет создано"
    if ($Plan.AuthExisted) { $authState = "уже есть, будет обновлено" }
    $poolState = "будет создан"
    if ($Plan.AppPoolExisted) { $poolState = "уже есть, параметры будут проверены" }
    $win = "уже установлен"
    if (-not $Plan.WindowsAuthInstalled) { $win = "будет установлен компонент Web-Windows-Auth (нужен для SSO и Windows-публикации)" }
    $lines = @(
        "====================================================",
        " ПЛАН УСТАНОВКИ AUTHSERVICE",
        "====================================================",
        "",
        "IIS server:",
        $Plan.Server,
        "",
        "IIS Site:",
        $Plan.Site,
        "",
        "Основная публикация:",
        $Plan.Publication,
        "",
        "Physical Path:",
        $Plan.PhysicalPath,
        "",
        "1C Server:",
        $Plan.OneCServer,
        "",
        "1C Database:",
        $Plan.OneCDatabase,
        "",
        "UI endpoint:",
        $Plan.UiEndpoint,
        "",
        "HTTP service:",
        ($Plan.HttpService + " (" + $httpNote + ")"),
        "",
        "Будет создана Windows publication:",
        ($Plan.OsAuthPublication + " (" + $osState + ")"),
        "",
        "AuthService:",
        ($Plan.AuthPath + " (" + $authState + ")"),
        "",
        "AuthService AppPool:",
        ($Plan.AppPoolName + " (" + $poolState + ")"),
        "",
        "Каталог AuthService:",
        $Plan.AuthPhysical,
        "",
        "wsisapi:",
        $Plan.Wsisapi,
        "",
        "Windows Authentication:",
        $win,
        "",
        "Основная публикация:",
        "Anonymous = ON",
        "Windows = OFF",
        "IIS Basic = OFF",
        "",
        "Windows publication:",
        "Anonymous = OFF",
        "Windows = ON",
        "Basic = OFF",
        "Providers: Negotiate, NTLM",
        "",
        "SSO:",
        ($Plan.AuthPath + "/sso"),
        "Anonymous = OFF",
        "Windows = ON",
        "",
        "Downstream Basic:",
        $Plan.BasicBase,
        "",
        "Downstream Windows:",
        $Plan.OsAuthBase,
        "",
        "IP restrictions и роль Web-IP-Security не используются.",
        ""
    )
    if ($BackupPath) {
        $lines += @(
            "----------------------------------------------------",
            "ПЕРЕД ИЗМЕНЕНИЯМИ БУДЕТ СОЗДАН BACKUP:",
            $BackupPath,
            "",
            "В backup попадут IIS-настройки и файлы, которые installer изменит.",
            ""
        )
    }
    return ($lines -join [Environment]::NewLine)
}

function Get-RepoRoot {
    return (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
}

function Backup-InstallState {
    param($Plan, [string]$BackupRoot)
    $stamp = Get-Date -Format "yyyy-MM-dd_HHmmss"
    $dir = Join-Path $BackupRoot $stamp
    New-Item -ItemType Directory -Force -Path (Join-Path $dir "iis"), (Join-Path $dir "files"), (Join-Path $dir "logs") | Out-Null
    $appcmd = Join-Path $env:WINDIR "System32\inetsrv\appcmd.exe"
    $locations = @(
        $Plan.Site,
        ($Plan.Site + "/" + $Plan.Publication),
        ($Plan.Site + "/" + $Plan.OsAuthPublication),
        ($Plan.Site + $Plan.AuthPath),
        ($Plan.Site + $Plan.AuthPath + "/sso")
    )
    foreach ($location in $locations) {
        $safe = ($location -replace "[^A-Za-z0-9]", "_")
        foreach ($section in @(
            "system.webServer/security/authentication/anonymousAuthentication",
            "system.webServer/security/authentication/basicAuthentication",
            "system.webServer/security/authentication/windowsAuthentication"
        )) {
            $leaf = ($section -replace ".*/", "")
            try {
                & $appcmd list config $location "/section:$section" | Set-Content -Path (Join-Path $dir "iis\$safe-$leaf.txt") -Encoding UTF8
            } catch {
                Set-Content -Path (Join-Path $dir "iis\$safe-$leaf.txt") -Value $_.Exception.Message -Encoding UTF8
            }
        }
    }
    & $appcmd list site $Plan.Site /config /xml | Set-Content (Join-Path $dir "iis\site.xml") -Encoding UTF8
    if ($Plan.AppPoolExisted) {
        & $appcmd list apppool $Plan.AppPoolName /config /xml | Set-Content (Join-Path $dir "iis\pool.xml") -Encoding UTF8
    }
    Copy-Item (Join-Path $Plan.PhysicalPath "default.vrd") (Join-Path $dir "files\primary-default.vrd") -Force
    Copy-Item (Join-Path $Plan.PhysicalPath "web.config") (Join-Path $dir "files\primary-web.config") -Force
    if ($Plan.OsAuthExisted -and (Test-Path $Plan.OsAuthPhysical)) {
        New-Item -ItemType Directory -Force -Path (Join-Path $dir "files\osauth") | Out-Null
        Copy-Item (Join-Path $Plan.OsAuthPhysical "*") (Join-Path $dir "files\osauth") -Force
    }
    if ($Plan.AuthExisted -and (Test-Path $Plan.AuthPhysical)) {
        New-Item -ItemType Directory -Force -Path (Join-Path $dir "files\auth") | Out-Null
        Copy-Item (Join-Path $Plan.AuthPhysical "*") (Join-Path $dir "files\auth") -Recurse -Force
    }
    $poolBefore = $null
    if ($Plan.AppPoolExisted) {
        $pool = Get-Item ("IIS:\AppPools\" + $Plan.AppPoolName)
        $poolBefore = [ordered]@{
            runtime = [string]$pool.managedRuntimeVersion
            pipeline = [string]$pool.managedPipelineMode
            maxProcesses = [int]$pool.processModel.maxProcesses
            identityType = [string]$pool.processModel.identityType
        }
    }
    $manifest = [ordered]@{
        Created = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ss")
        InstallerVersion = "1.0"
        Server = $Plan.Server
        Site = $Plan.Site
        PrimaryPublication = $Plan.Publication
        OsAuthPublication = $Plan.OsAuthPublication
        UiEndpoint = $Plan.UiEndpoint
        HttpService = $Plan.HttpService
        AuthApplication = $Plan.AuthPath
        AuthAppPool = $Plan.AppPoolName
        AuthPhysical = $Plan.AuthPhysical
        OsAuthPhysical = $Plan.OsAuthPhysical
        PrimaryPhysical = $Plan.PhysicalPath
        PrimaryPool = $Plan.PrimaryPool
        OneCServer = $Plan.OneCServer
        OneCDatabase = $Plan.OneCDatabase
        ObjectsBeforeInstall = [ordered]@{
            AuthApplicationExisted = $Plan.AuthExisted
            AuthAppPoolExisted = $Plan.AppPoolExisted
            OsAuthPublicationExisted = $Plan.OsAuthExisted
        }
        PoolBefore = $poolBefore
        PrimaryAuthBefore = $Plan.PrimaryAuth
        AuthAuthBefore = $Plan.AuthAuth
        SsoAuthBefore = $Plan.SsoAuth
        OsAuthAuthBefore = $Plan.OsAuthAuth
    }
    $manifest | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $dir "manifest.json") -Encoding UTF8
    return $dir
}

function Publish-OsAuthFromPrimary {
    param($Plan)
    New-Item -ItemType Directory -Force -Path $Plan.OsAuthPhysical | Out-Null
    $bytes = [IO.File]::ReadAllBytes((Join-Path $Plan.PhysicalPath "default.vrd"))
    $text = [Text.Encoding]::UTF8.GetString($bytes)
    $old = 'base="' + $Plan.Base + '"'
    $neu = 'base="/' + $Plan.OsAuthPublication + '"'
    if ($text.IndexOf($old) -lt 0) { throw "В default.vrd нет $old" }
    $text = $text.Replace($old, $neu)
    if ($text.IndexOf('Ref="' + $Plan.OneCDatabase + '"') -lt 0 -and $text.IndexOf("Ref=&quot;" + $Plan.OneCDatabase + "&quot;") -lt 0) {
        throw "После замены base строка базы больше не содержит Ref исходной публикации."
    }
    [IO.File]::WriteAllText((Join-Path $Plan.OsAuthPhysical "default.vrd"), $text, (New-Object Text.UTF8Encoding $false))
    Copy-Item (Join-Path $Plan.PhysicalPath "web.config") (Join-Path $Plan.OsAuthPhysical "web.config") -Force
    $osApp = Get-WebAppByPath -Site $Plan.Site -Path ("/" + $Plan.OsAuthPublication)
    if (-not $osApp) {
        New-WebApplication -Name $Plan.OsAuthPublication -Site $Plan.Site -PhysicalPath $Plan.OsAuthPhysical -ApplicationPool $Plan.PrimaryPool | Out-Null
    } else {
        Set-ItemProperty ("IIS:\Sites\" + $Plan.Site + "\" + $Plan.OsAuthPublication) -Name applicationPool -Value $Plan.PrimaryPool
        Set-ItemProperty ("IIS:\Sites\" + $Plan.Site + "\" + $Plan.OsAuthPublication) -Name physicalPath -Value $Plan.OsAuthPhysical
    }
}

function Write-AuthRuntimeConfig {
    param($Plan)
    $repo = Get-RepoRoot
    $template = Join-Path $repo "AuthService\web.config"
    [xml]$xml = Get-Content -Path $template -Raw -Encoding UTF8
    $settings = $xml.configuration.appSettings
    function Set-Key([string]$Key, [string]$Value) {
        $node = $settings.add | Where-Object { $_.key -eq $Key } | Select-Object -First 1
        if ($node) { $node.value = $Value }
        else {
            $add = $xml.CreateElement("add")
            $add.SetAttribute("key", $Key)
            $add.SetAttribute("value", $Value)
            [void]$settings.AppendChild($add)
        }
    }
    Set-Key "DataDirectory" "C:\inetpub\authservice-data"
    Set-Key "OneCBasicBase" $Plan.BasicBase
    Set-Key "OneCOsAuthBase" $Plan.OsAuthBase
    Set-Key "ExpectedCertThumbprint" $Plan.CertificateThumbprint
    Set-Key "UiEndpoint" $Plan.UiEndpoint
    Set-Key "AllowedOrigin" $Plan.AllowedOrigin
    Set-Key "PrimaryPublication" $Plan.Publication
    Set-Key "OsAuthPublication" $Plan.OsAuthPublication
    Set-Key "HttpService" $Plan.HttpService
    $bin = Join-Path $Plan.AuthPhysical "bin"
    New-Item -ItemType Directory -Force -Path $bin | Out-Null
    $xml.Save((Join-Path $Plan.AuthPhysical "web.config"))
    Copy-Item (Join-Path $repo "AuthService\bin\AuthService.dll") (Join-Path $bin "AuthService.dll") -Force
}

function Install-AuthServicePlan {
    param($Plan, [string]$LogPath)
    function Write-Log([string]$Message) {
        Add-Content -Path $LogPath -Value ((Get-Date).ToString("s") + " " + $Message) -Encoding UTF8
        Write-Output $Message
    }
    Import-InstallerIis
    if (-not $Plan.WindowsAuthInstalled) {
        Write-Log "Installing Web-Windows-Auth"
        Import-Module ServerManager
        Install-WindowsFeature Web-Windows-Auth | Out-Null
    }
    $repo = Get-RepoRoot
    & (Join-Path $repo "AuthService\scripts\build.ps1")
    if (-not (Test-Path ("IIS:\AppPools\" + $Plan.AppPoolName))) {
        New-WebAppPool $Plan.AppPoolName | Out-Null
    }
    Set-ItemProperty ("IIS:\AppPools\" + $Plan.AppPoolName) -Name managedRuntimeVersion -Value "v4.0"
    Set-ItemProperty ("IIS:\AppPools\" + $Plan.AppPoolName) -Name managedPipelineMode -Value "Integrated"
    Set-ItemProperty ("IIS:\AppPools\" + $Plan.AppPoolName) -Name processModel.maxProcesses -Value 1
    New-Item -ItemType Directory -Force -Path $Plan.AuthPhysical | Out-Null
    $authApp = Get-WebAppByPath -Site $Plan.Site -Path $Plan.AuthPath
    $authName = $Plan.AuthPath.Trim("/")
    if (-not $authApp) {
        New-WebApplication -Name $authName -Site $Plan.Site -PhysicalPath $Plan.AuthPhysical -ApplicationPool $Plan.AppPoolName | Out-Null
    } else {
        Set-ItemProperty ("IIS:\Sites\" + $Plan.Site + "\" + $authName) -Name applicationPool -Value $Plan.AppPoolName
        Set-ItemProperty ("IIS:\Sites\" + $Plan.Site + "\" + $authName) -Name physicalPath -Value $Plan.AuthPhysical
    }
    Write-AuthRuntimeConfig -Plan $Plan
    $data = "C:\inetpub\authservice-data"
    New-Item -ItemType Directory -Force -Path $data | Out-Null
    icacls $data /grant:r "NT AUTHORITY\SYSTEM:(OI)(CI)F" "BUILTIN\Administrators:(OI)(CI)F" "IIS AppPool\$($Plan.AppPoolName):(OI)(CI)M" | Out-Null
    $authLoc = $Plan.Site + $Plan.AuthPath
    Set-AuthFlag $authLoc "anonymousAuthentication" $true
    Set-AuthFlag $authLoc "basicAuthentication" $false
    Set-AuthFlag $authLoc "windowsAuthentication" $false
    $ssoLoc = $authLoc + "/sso"
    Set-AuthFlag $ssoLoc "anonymousAuthentication" $false
    Set-AuthFlag $ssoLoc "basicAuthentication" $false
    Set-AuthFlag $ssoLoc "windowsAuthentication" $true
    Set-WindowsProviders $ssoLoc @("Negotiate", "NTLM")
    $primaryLoc = $Plan.Site + "/" + $Plan.Publication
    Set-AuthFlag $primaryLoc "anonymousAuthentication" $true
    Set-AuthFlag $primaryLoc "basicAuthentication" $false
    Set-AuthFlag $primaryLoc "windowsAuthentication" $false
    Publish-OsAuthFromPrimary -Plan $Plan
    $osLoc = $Plan.Site + "/" + $Plan.OsAuthPublication
    Set-AuthFlag $osLoc "anonymousAuthentication" $false
    Set-AuthFlag $osLoc "basicAuthentication" $false
    Set-AuthFlag $osLoc "windowsAuthentication" $true
    Set-WindowsProviders $osLoc @("Negotiate", "NTLM")
    try {
        Set-WebConfigurationProperty -PSPath "MACHINE/WEBROOT/APPHOST" -Location $authLoc -Filter "system.webServer/httpErrors" -Name existingResponse -Value "PassThrough"
    } catch {
        Write-Log "httpErrors PassThrough skipped"
    }
    Restart-WebAppPool $Plan.AppPoolName
    Start-Sleep -Seconds 3
    Write-Log "INSTALL ACTIONS DONE"
}

function Invoke-InstallerChecks {
    param($Plan)
    $curl = Join-Path $env:WINDIR "System32\curl.exe"
    $base = "https://" + $Plan.Server
    $script:InstallerChecksFailed = $false
    function Check([string]$Name, [string[]]$Args, [int[]]$Expect, [string]$Contains) {
        $out = & $curl -sS -k --max-time 40 -D - @Args
        $text = $out | Out-String
        $code = 0
        if ($text -match "HTTP/1\.[01] (\d{3})") { $code = [int]$Matches[1] }
        $ok = $Expect -contains $code
        if ($Contains -and $text -notlike ("*" + $Contains + "*")) { $ok = $false }
        if ($ok) { Write-Output "PASS $Name HTTP $code" }
        else {
            Write-Output "FAIL $Name HTTP $code expected $($Expect -join '/')"
            $script:InstallerChecksFailed = $true
        }
    }
    Check "health" @("$base$($Plan.AuthPath)/health") @(200) '"ok":true'
    Check "me" @("$base$($Plan.AuthPath)/me") @(401) "SESSION_EXPIRED"
    Check "debug" @("$base$($Plan.AuthPath)/debug/identity") @(404) "Not found"
    Check "sso" @("-H","Accept: application/json","$base$($Plan.AuthPath)/sso/login") @(401,302,200) "Negotiate"
    Check "osauth" @("$base/$($Plan.OsAuthPublication)/hs/$($Plan.HttpService)/api/tasks") @(401) "Negotiate"
    Check "ui" @("$base$($Plan.UiEndpoint)") @(200,401,302) $null
    $bad = Join-Path $env:TEMP "authservice-installer-bad.json"
    [IO.File]::WriteAllText($bad, '{"username":"EXAMPLE\\not-a-real-user","password":"wrong-password"}')
    Check "login-ad" @("-X","POST","-H","Content-Type: application/json","--data-binary","@$bad","$base$($Plan.AuthPath)/login") @(401) "Invalid username or password"
    [IO.File]::WriteAllText($bad, '{"username":"not-a-real-1c-user","password":"wrong-password"}')
    Check "login-1c" @("-X","POST","-H","Content-Type: application/json","--data-binary","@$bad","$base$($Plan.AuthPath)/login") @(401) "Invalid username or password"
    [IO.File]::WriteAllText($bad, ('{"username":"x","password":"' + ("a" * 9000) + '"}'))
    Check "login-large" @("-X","POST","-H","Content-Type: application/json","--data-binary","@$bad","$base$($Plan.AuthPath)/login") @(400) "required"
    Check "origin" @("-X","POST","-H","Origin: https://evil.example","-H","Content-Type: application/json","--data-binary","{}","$base$($Plan.AuthPath)/logout") @(403) "INVALID_ORIGIN"
    Check "proxy" @("$base$($Plan.AuthPath)/zno/not-an-api") @(400,404) $null
    Remove-Item $bad -Force -ErrorAction SilentlyContinue
    Write-Output ""
    Write-Output "MANUAL TESTS REQUIRED"
    Write-Output "AD correct password, 1C correct password, SSO on a domain client, approve/reject and the phone UI are not run by this installer."
    if ($script:InstallerChecksFailed) { throw "One or more automatic checks failed." }
}

function Restore-AuthBackup {
    param([string]$BackupDir, [string]$LogPath)
    function Write-Log([string]$Message) {
        Add-Content -Path $LogPath -Value ((Get-Date).ToString("s") + " " + $Message) -Encoding UTF8
        Write-Output $Message
    }
    $manifest = Get-Content (Join-Path $BackupDir "manifest.json") -Raw -Encoding UTF8 | ConvertFrom-Json
    Import-InstallerIis
    $errors = New-Object System.Collections.Generic.List[string]
    if (Test-Path ("IIS:\AppPools\" + $manifest.AuthAppPool)) {
        Stop-WebAppPool $manifest.AuthAppPool
        Start-Sleep -Seconds 2
    }
    $authFiles = Join-Path $BackupDir "files\auth"
    if ($manifest.ObjectsBeforeInstall.AuthApplicationExisted) {
        if (Test-Path $authFiles) {
            New-Item -ItemType Directory -Force -Path $manifest.AuthPhysical | Out-Null
            Copy-Item (Join-Path $authFiles "*") $manifest.AuthPhysical -Recurse -Force
            Write-Log "Restored AuthService files"
        }
    } else {
        $name = ([string]$manifest.AuthApplication).Trim("/")
        $app = Get-WebAppByPath -Site $manifest.Site -Path $manifest.AuthApplication
        if ($app) { Remove-WebApplication -Name $name -Site $manifest.Site }
        if (Test-Path $manifest.AuthPhysical) { Remove-Item $manifest.AuthPhysical -Recurse -Force }
        Write-Log "Removed AuthService application created by installer"
    }
    if ($manifest.ObjectsBeforeInstall.AuthAppPoolExisted -and $manifest.PoolBefore) {
        if (-not (Test-Path ("IIS:\AppPools\" + $manifest.AuthAppPool))) { New-WebAppPool $manifest.AuthAppPool | Out-Null }
        Set-ItemProperty ("IIS:\AppPools\" + $manifest.AuthAppPool) -Name managedRuntimeVersion -Value $manifest.PoolBefore.runtime
        Set-ItemProperty ("IIS:\AppPools\" + $manifest.AuthAppPool) -Name managedPipelineMode -Value $manifest.PoolBefore.pipeline
        Set-ItemProperty ("IIS:\AppPools\" + $manifest.AuthAppPool) -Name processModel.maxProcesses -Value $manifest.PoolBefore.maxProcesses
        if ($manifest.PoolBefore.identityType) {
            Set-ItemProperty ("IIS:\AppPools\" + $manifest.AuthAppPool) -Name processModel.identityType -Value ([string]$manifest.PoolBefore.identityType)
        }
    } elseif (-not $manifest.ObjectsBeforeInstall.AuthAppPoolExisted) {
        if (Test-Path ("IIS:\AppPools\" + $manifest.AuthAppPool)) {
            Remove-WebAppPool $manifest.AuthAppPool
            Write-Log "Removed AppPool created by installer"
        }
    }
    $primaryVrd = Join-Path $BackupDir "files\primary-default.vrd"
    if (Test-Path $primaryVrd) {
        Copy-Item $primaryVrd (Join-Path $manifest.PrimaryPhysical "default.vrd") -Force
        Copy-Item (Join-Path $BackupDir "files\primary-web.config") (Join-Path $manifest.PrimaryPhysical "web.config") -Force
    }
    function Restore-Flags($Before, [string]$Location, [bool]$Providers) {
        if (-not $Before) { return }
        if ($null -ne $Before.anonymous) { Set-AuthFlag $Location "anonymousAuthentication" ([bool]$Before.anonymous) }
        if ($null -ne $Before.windows) { Set-AuthFlag $Location "windowsAuthentication" ([bool]$Before.windows) }
        if ($null -ne $Before.basic) { Set-AuthFlag $Location "basicAuthentication" ([bool]$Before.basic) }
        if ($Providers -and $Before.providers) {
            $names = @($Before.providers | ForEach-Object { [string]$_ } | Where-Object { $_ })
            if ($names.Count -gt 0) { Set-WindowsProviders $Location $names }
        }
    }
    Restore-Flags $manifest.PrimaryAuthBefore ($manifest.Site + "/" + $manifest.PrimaryPublication) $false
    if ($manifest.ObjectsBeforeInstall.AuthApplicationExisted) {
        Restore-Flags $manifest.AuthAuthBefore ($manifest.Site + $manifest.AuthApplication) $false
        Restore-Flags $manifest.SsoAuthBefore ($manifest.Site + $manifest.AuthApplication + "/sso") $true
    }
    if ($manifest.ObjectsBeforeInstall.OsAuthPublicationExisted) {
        Restore-Flags $manifest.OsAuthAuthBefore ($manifest.Site + "/" + $manifest.OsAuthPublication) $true
    }
    $osFiles = Join-Path $BackupDir "files\osauth"
    if ($manifest.ObjectsBeforeInstall.OsAuthPublicationExisted) {
        if (Test-Path $osFiles) {
            New-Item -ItemType Directory -Force -Path $manifest.OsAuthPhysical | Out-Null
            Copy-Item (Join-Path $osFiles "*") $manifest.OsAuthPhysical -Force
            Write-Log "Restored Windows publication files"
        }
    } else {
        $os = Get-WebAppByPath -Site $manifest.Site -Path ("/" + $manifest.OsAuthPublication)
        if ($os) { Remove-WebApplication -Name $manifest.OsAuthPublication -Site $manifest.Site }
        if (Test-Path $manifest.OsAuthPhysical) { Remove-Item $manifest.OsAuthPhysical -Recurse -Force }
        Write-Log "Removed Windows publication created by installer"
    }
    if (Test-Path ("IIS:\AppPools\" + $manifest.AuthAppPool)) { Start-WebAppPool $manifest.AuthAppPool }
    return $errors
}
