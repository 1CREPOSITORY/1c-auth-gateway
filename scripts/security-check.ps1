$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $here "test.ps1")
if ($LASTEXITCODE -ne 0) { throw "Smoke tests failed." }

. (Join-Path $here "load-environment.ps1")
$base = "https://$AuthPublicHost"
$curl = Join-Path $env:WINDIR "System32\curl.exe"
$sw = & $curl -sS -k --max-time 30 "$base/pwa-auth-test/service-worker.js"
if ($sw -notmatch "/auth") { throw "Service worker does not bypass /auth." }
if ($sw -notmatch "no-store") { throw "Service worker does not force no-store for /auth." }

Write-Output "SECURITY CHECK COMPLETE"
