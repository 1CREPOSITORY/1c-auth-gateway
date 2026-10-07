$ErrorActionPreference = "Stop"
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "Administrator privileges are required."
}
$source = "D:\+SERG\WS\AUTZ\pwa-auth-test"
$target = "C:\inetpub\wwwroot\pwa-auth-test"
New-Item -ItemType Directory -Force -Path $target | Out-Null
Copy-Item (Join-Path $source "*") $target -Force
Copy-Item "D:\+SERG\WS\AUTZ\auth-test\index.html" "C:\inetpub\wwwroot\auth-test\index.html" -Force
Write-Output "PWA SYNCED"
