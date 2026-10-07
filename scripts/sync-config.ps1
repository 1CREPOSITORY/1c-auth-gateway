$ErrorActionPreference = "Stop"
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw "Administrator privileges are required." }
Copy-Item "D:\+SERG\WS\AUTZ\AuthService\bin\AuthService.dll" "C:\inetpub\wwwroot\bin\AuthService.dll" -Force
Copy-Item "D:\+SERG\WS\AUTZ\AuthService\root.web.config" "C:\inetpub\wwwroot\web.config" -Force
Remove-Item "C:\inetpub\wwwroot\auth\web.config" -Force -ErrorAction SilentlyContinue
Remove-Item "C:\inetpub\wwwroot\zno\web.config" -Force -ErrorAction SilentlyContinue
Copy-Item "D:\+SERG\WS\AUTZ\pwa-auth-test\*" "C:\inetpub\wwwroot\pwa-auth-test\" -Force
Import-Module WebAdministration
Restart-WebAppPool "DefaultAppPool"
Start-Sleep -Seconds 3
Write-Output "SYNCED"
