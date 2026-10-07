param([switch]$NonInteractive, [int]$Index = 0)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "Installer.Common.ps1")

function Read-Yes([string]$Prompt) {
    if ($NonInteractive) { return $true }
    $answer = Read-Host $Prompt
    return $answer -match '^(y|Y|д|Д)$'
}

if (-not (Test-InstallerAdmin)) {
    Write-Output "Запустите PowerShell от имени Administrator."
    exit 1
}

$root = Join-Path $PSScriptRoot "backups"
$manifests = @(Get-ChildItem -Path $root -Recurse -Filter manifest.json -ErrorAction SilentlyContinue | Sort-Object FullName -Descending)
if ($manifests.Count -eq 0) { throw "Backup с manifest.json не найден в $root" }

Write-Output "===================================================="
Write-Output " AuthService Rollback"
Write-Output "===================================================="
Write-Output ""
$items = @()
$n = 1
foreach ($file in $manifests) {
    $manifest = Get-Content $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($manifest.InstallerVersion -ne "1.0") { continue }
    $items += [ordered]@{ File = $file.FullName; Dir = $file.Directory.FullName; Manifest = $manifest }
    Write-Output ("[" + $n + "] " + $manifest.Created)
    Write-Output ("    Server: " + $manifest.Server)
    Write-Output ("    Publication: " + $manifest.PrimaryPublication)
    Write-Output ("    UI: " + $manifest.UiEndpoint)
    Write-Output ""
    $n++
}
if ($items.Count -eq 0) { throw "Подходящих backup нет." }
if ($Index -lt 1) {
    $Index = [int](Read-Host "Выберите backup")
}
if ($Index -lt 1 -or $Index -gt $items.Count) { throw "Неверный номер backup." }
$chosen = $items[$Index - 1]
$manifest = $chosen.Manifest

Write-Output "Будут восстановлены:"
Write-Output ""
Write-Output "- IIS authentication выбранных приложений"
Write-Output "- файлы AuthService, если приложение уже было"
Write-Output "- настройки AppPool, если пул уже был"
Write-Output "- default.vrd и web.config основной публикации из backup"
Write-Output "- файлы Windows-публикации, если она уже была"
Write-Output ""
if (-not $manifest.ObjectsBeforeInstall.AuthApplicationExisted) { Write-Output "Приложение AuthService до установки не существовало и будет удалено." }
if (-not $manifest.ObjectsBeforeInstall.AuthAppPoolExisted) { Write-Output "AppPool до установки не существовал и будет удалён." }
if (-not $manifest.ObjectsBeforeInstall.OsAuthPublicationExisted) { Write-Output "Windows-публикация до установки не существовала и будет удалена." }
Write-Output ""
Write-Output "Текущее состояние этих объектов будет перезаписано."
Write-Output "Перед этим будет сохранён аварийный backup текущего состояния."
Write-Output ""
if (-not (Read-Yes "Продолжить rollback? [Y/N]")) {
    Write-Output "Rollback отменён. Ничего не изменено."
    exit 0
}

$logDir = Join-Path $PSScriptRoot "logs"
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$log = Join-Path $logDir ("rollback-" + (Get-Date -Format "yyyyMMdd-HHmmss") + ".log")
$errors = New-Object System.Collections.Generic.List[string]
try {
    $prePlan = New-AuthServicePlan -Server $manifest.Server -Site $manifest.Site -Publication $manifest.PrimaryPublication -UiEndpoint $manifest.UiEndpoint -OsAuthPublication $manifest.OsAuthPublication -AuthPath $manifest.AuthApplication -AppPoolName $manifest.AuthAppPool
    $pre = Backup-InstallState -Plan $prePlan -BackupRoot (Join-Path $PSScriptRoot "backups")
    Add-Content $log ("PRE-ROLLBACK " + $pre)
    Write-Output ("Аварийный backup: " + $pre)
} catch {
    $errors.Add("Аварийный backup не создан: " + $_.Exception.Message)
    Add-Content $log $_.Exception.Message
}
try {
    Restore-AuthBackup -BackupDir $chosen.Dir -LogPath $log | Out-Null
} catch {
    $errors.Add($_.Exception.Message)
    Add-Content $log $_.Exception.Message
}
try {
    $curl = Join-Path $env:WINDIR "System32\curl.exe"
    $health = & $curl -sS -k --max-time 30 -w "`nHTTP_CODE:%{http_code}" ("https://" + $manifest.Server + $manifest.AuthApplication + "/health")
    Add-Content $log ($health | Out-String)
    Write-Output ($health | Out-String)
} catch {
    $errors.Add("Health check: " + $_.Exception.Message)
}
if ($errors.Count -gt 0) {
    Write-Output "ROLLBACK COMPLETED WITH ERRORS"
    $errors | ForEach-Object { Write-Output $_ }
    exit 1
}
Add-Content $log "ROLLBACK COMPLETE"
Write-Output "ROLLBACK COMPLETE"
Write-Output $log
