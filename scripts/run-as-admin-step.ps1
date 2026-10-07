$ErrorActionPreference = "Stop"
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "Administrator privileges are required."
}

. (Join-Path $PSScriptRoot "load-environment.ps1")
$publicBase = "https://$AuthPublicHost"
$workspace = Split-Path $PSScriptRoot -Parent
$log = Join-Path $workspace "backup\run-as-admin-step.log"
function Write-Log([string]$Message) {
    Add-Content -Path $log -Value ((Get-Date).ToString("s") + " " + $Message) -Encoding UTF8
    Write-Output $Message
}
Set-Content -Path $log -Value "start" -Encoding UTF8
Import-Module WebAdministration
$curl = Join-Path $env:WINDIR "System32\curl.exe"

& (Join-Path $workspace "scripts\deploy.ps1")
if ($LASTEXITCODE -ne 0) { throw "deploy.ps1 failed: $LASTEXITCODE" }

& (Join-Path $workspace "scripts\security-check.ps1")
if ($LASTEXITCODE -ne 0) { throw "security-check.ps1 failed: $LASTEXITCODE" }

$probe = (& $curl -sS -D - -o NUL --max-time 30 -H "IBSession: start" "$publicBase/UH_Medvedev_test/hs/mobile/api/tasks" | Out-String)
Set-Content -Path (Join-Path $workspace "backup\ibsession-probe.txt") -Value $probe -Encoding UTF8
if ($probe -match "(?i)ibsession") { Write-Log "IBSESSION header observed" } else { Write-Log "IBSESSION not issued without completed 1C login" }

$negotiate = (& $curl -sS --negotiate -u : -D - -o NUL --max-time 40 "$publicBase/UH_Medvedev_test_osauth/hs/mobile/api/tasks" | Out-String)
Set-Content -Path (Join-Path $workspace "backup\phase7-negotiate.txt") -Value $negotiate -Encoding UTF8
$negotiateCode = "none"
if ($negotiate -match "HTTP/1\.[01] (\d{3})") { $negotiateCode = $Matches[1] }
Write-Log "HOSTNAME-NEGOTIATE HTTP $negotiateCode"
if ($negotiateCode -eq "401") {
    Write-Log "Kept OneCOsAuthBase on 127.0.0.1 with certificate thumbprint pin. Extended Protection was not changed."
} else {
    $deployed = "C:\inetpub\wwwroot\authservice\web.config"
    $source = Join-Path $workspace "AuthService\web.config"
    foreach ($file in @($deployed, $source)) {
        $text = [IO.File]::ReadAllText($file)
        $text = $text.Replace("https://127.0.0.1/UH_Medvedev_test_osauth/hs/mobile", "$publicBase/UH_Medvedev_test_osauth/hs/mobile")
        [IO.File]::WriteAllText($file, $text)
    }
    Restart-WebAppPool "AuthService"
    Start-Sleep -Seconds 4
    $health = (& $curl -sS --max-time 30 -w "`nHTTP_CODE:%{http_code}" "$publicBase/auth/health" | Out-String)
    Write-Log $health
    if ($health -notmatch "HTTP_CODE:200") {
        foreach ($file in @($deployed, $source)) {
            $text = [IO.File]::ReadAllText($file)
            $text = $text.Replace("$publicBase/UH_Medvedev_test_osauth/hs/mobile", "https://127.0.0.1/UH_Medvedev_test_osauth/hs/mobile")
            [IO.File]::WriteAllText($file, $text)
        }
        Restart-WebAppPool "AuthService"
        throw "Hostname downstream switch failed health check and was reverted."
    }
    Write-Log "OneCOsAuthBase switched to the certificate hostname"
}

$epa = (& (Join-Path $env:WINDIR "System32\inetsrv\appcmd.exe") list config "Default Web Site/UH_Medvedev_test_osauth" "/section:system.webServer/security/authentication/windowsAuthentication" | Out-String)
Set-Content -Path (Join-Path $workspace "backup\extended-protection.txt") -Value $epa -Encoding UTF8
Write-Log "Extended Protection left unchanged"
Write-Log "ADMIN STEP COMPLETE"
