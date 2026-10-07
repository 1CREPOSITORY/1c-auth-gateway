param(
    [switch]$PlanOnly,
    [switch]$NonInteractive,
    [string]$Publication,
    [string]$UiEndpoint,
    [string]$OsAuthPublication,
    [string]$SiteName,
    [string]$AuthPath = "/auth",
    [string]$AppPoolName = "AuthService"
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "Installer.Common.ps1")

function Read-Yes([string]$Prompt) {
    if ($NonInteractive) { return $true }
    $answer = Read-Host $Prompt
    return $answer -match '^(y|Y|д|Д)$'
}

function Read-Required([string]$Prompt) {
    if ($NonInteractive) { throw "Не хватает параметра для неинтерактивного запуска." }
    $value = ""
    while ([string]::IsNullOrWhiteSpace($value)) { $value = Read-Host $Prompt }
    return $value.Trim()
}

if (-not (Test-InstallerAdmin)) {
    Write-Output "Запустите PowerShell от имени Administrator."
    exit 1
}

$server = Get-InstallerFqdn
Write-Output "===================================================="
Write-Output " AuthService Installer"
Write-Output "===================================================="
Write-Output ""
Write-Output "Определён IIS-сервер:"
Write-Output ""
Write-Output $server
Write-Output ""
if (-not (Read-Yes "Это правильный сервер? [Y/N]")) {
    $typed = Read-Required "Введите правильное имя IIS-сервера. Пример: IIS-SERVER-01.domain.com"
    Assert-LocalServer $typed
    $server = Get-InstallerFqdn
}

$sites = @(Get-InstallerSites)
if ($sites.Count -eq 0) { throw "На этом компьютере не найден сайт IIS." }
if ($NonInteractive -and $SiteName) {
    $site = $SiteName
} elseif ($sites.Count -eq 1) {
    Write-Output ""
    Write-Output "IIS Site:"
    Write-Output $sites[0]
    if (Read-Yes "Использовать? [Y/N]") { $site = $sites[0] }
    else { throw "Выберите сайт повторным запуском. Других сайтов нет." }
} else {
    if ($NonInteractive -and -not $SiteName -and ($sites -contains "Default Web Site")) { $site = "Default Web Site" }
    elseif ($SiteName -and ($sites -contains $SiteName)) { $site = $SiteName }
    else {
        Write-Output ""
        for ($i = 0; $i -lt $sites.Count; $i++) { Write-Output ("[" + ($i + 1) + "] " + $sites[$i]) }
        $pick = Read-Required "Номер сайта"
        $index = [int]$pick - 1
        if ($index -lt 0 -or $index -ge $sites.Count) { throw "Неверный номер сайта." }
        $site = $sites[$index]
    }
}
if ($sites -notcontains $site) { throw "Сайт '$site' не найден." }

Write-Output ""
if (-not $Publication) { $Publication = Read-Required "Введите имя существующей публикации 1С. Пример: UH_Medvedev_test" }
$primary = Get-WebAppByPath -Site $site -Path ("/" + $Publication)
if (-not $primary) { throw "Приложение IIS '/$Publication' на сайте '$site' не найдено." }
$physical = [string]$primary.PhysicalPath
$found = Read-PublicationVrd -VrdPath (Join-Path $physical "default.vrd") -PublicationName $Publication
Write-Output ""
Write-Output "Публикация найдена."
Write-Output ""
Write-Output "Publication:"
Write-Output $Publication
Write-Output ""
Write-Output "Physical Path:"
Write-Output $physical
Write-Output ""
Write-Output "1C Server:"
Write-Output $found.Server
Write-Output ""
Write-Output "1C Database:"
Write-Output $found.Database
Write-Output ""
if (-not $UiEndpoint) {
    Write-Output "Введите UI endpoint."
    Write-Output "Пример: /$Publication/hs/mobile/ui"
    $UiEndpoint = Read-Required ">"
}
if (-not $OsAuthPublication) { $OsAuthPublication = $Publication + "_osauth" }
Write-Output ""
Write-Output "Windows publication будет:"
Write-Output $OsAuthPublication
if (-not (Read-Yes "Использовать? [Y/N]")) {
    $OsAuthPublication = Read-Required "Имя Windows-auth публикации"
}
Write-Output ""
Write-Output "AuthService будет установлен как:"
Write-Output $AuthPath
Write-Output ""
Write-Output "AppPool:"
Write-Output $AppPoolName
if (-not (Read-Yes "Использовать? [Y/N]")) {
    $AuthPath = Read-Required "Путь приложения, например /auth"
    $AppPoolName = Read-Required "Имя пула, например AuthService"
}

$plan = New-AuthServicePlan -Server $server -Site $site -Publication $Publication -UiEndpoint $UiEndpoint -OsAuthPublication $OsAuthPublication -AuthPath $AuthPath -AppPoolName $AppPoolName
$backupHint = Join-Path $PSScriptRoot ("backups\" + (Get-Date -Format "yyyy-MM-dd_HHmmss"))
$planText = Format-AuthPlan -Plan $plan -BackupPath $backupHint
Write-Output ""
Write-Output $planText
if ($PlanOnly) {
    $planDir = Join-Path $PSScriptRoot "logs"
    New-Item -ItemType Directory -Force -Path $planDir | Out-Null
    $planFile = Join-Path $planDir "plan-only.txt"
    Set-Content -Path $planFile -Value ($planText + [Environment]::NewLine + "PlanOnly: backup не создан, IIS и файлы не изменены.") -Encoding UTF8
    Write-Output "PlanOnly: backup не создан, IIS и файлы не изменены."
    Write-Output $planFile
    exit 0
}
if (-not (Read-Yes "Продолжить? [Y/N]")) {
    Write-Output "Установка отменена. Ничего не изменено."
    exit 0
}

$logDir = Join-Path $PSScriptRoot "logs"
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$log = Join-Path $logDir ("install-" + (Get-Date -Format "yyyyMMdd-HHmmss") + ".log")
$backup = Backup-InstallState -Plan $plan -BackupRoot (Join-Path $PSScriptRoot "backups")
Add-Content $log ("BACKUP " + $backup)
Write-Output ""
Write-Output "Backup:"
Write-Output $backup
Install-AuthServicePlan -Plan $plan -LogPath $log
Invoke-InstallerChecks -Plan $plan
Add-Content $log "INSTALL COMPLETE"
Write-Output ""
Write-Output "INSTALL COMPLETE"
Write-Output $log
