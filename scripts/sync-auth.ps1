$ErrorActionPreference = "Stop"
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw "Administrator privileges are required." }
& "D:\+SERG\WS\AUTZ\AuthService\scripts\build.ps1"
New-Item -ItemType Directory -Force -Path "C:\inetpub\wwwroot\authservice\bin" | Out-Null
Copy-Item "D:\+SERG\WS\AUTZ\AuthService\bin\AuthService.dll" "C:\inetpub\wwwroot\authservice\bin\AuthService.dll" -Force
Copy-Item "D:\+SERG\WS\AUTZ\AuthService\web.config" "C:\inetpub\wwwroot\authservice\web.config" -Force
Copy-Item "D:\+SERG\WS\AUTZ\pwa-auth-test\*" "C:\inetpub\wwwroot\pwa-auth-test\" -Force
if (Test-Path "C:\inetpub\wwwroot\web.config") {
    $text = Get-Content "C:\inetpub\wwwroot\web.config" -Raw
    if ($text -match "AuthServiceModule") { Remove-Item "C:\inetpub\wwwroot\web.config" -Force }
}
Import-Module WebAdministration
Restart-WebAppPool "AuthService"
Write-Output "AUTH SYNCED"
