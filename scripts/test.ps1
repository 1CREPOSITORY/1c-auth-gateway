$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "load-environment.ps1")
$base = "https://$AuthPublicHost"
$curl = Join-Path $env:WINDIR "System32\curl.exe"
$tmp = Join-Path $env:TEMP ("autz-test-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$failed = $false

function Invoke-Check {
    param([string]$Name, [string[]]$CurlArgs, [int[]]$Expect, [string]$BodyContains, [string]$BodyMustNotContain)
    $hdr = Join-Path $tmp ($Name + ".hdr")
    $body = Join-Path $tmp ($Name + ".body")
    & $curl -sS -k --max-time 40 -D $hdr -o $body @CurlArgs | Out-Null
    $statusLine = Get-Content $hdr -TotalCount 1
    $code = 0
    if ($statusLine -match "\s(\d{3})\s") { $code = [int]$Matches[1] }
    $text = ""
    if (Test-Path $body) { $text = [IO.File]::ReadAllText($body) }
    $headerText = ""
    if (Test-Path $hdr) { $headerText = [IO.File]::ReadAllText($hdr) }
    $ok = $Expect -contains $code
    if ($BodyContains -and ($text + $headerText) -notlike "*$BodyContains*") { $ok = $false }
    if ($BodyMustNotContain -and ($text + $headerText) -like "*$BodyMustNotContain*") { $ok = $false }
    if ($ok) { Write-Output "PASS $Name HTTP $code" }
    else {
        Write-Output "FAIL $Name HTTP $code expected $($Expect -join '/')"
        if ($text) { Write-Output $text.Substring(0, [Math]::Min(300, $text.Length)) }
        $script:failed = $true
    }
}

try {
    Invoke-Check "health" @("$base/auth/health") @(200) '"ok":true' $null
    Invoke-Check "me-anonymous" @("$base/auth/me") @(401) "SESSION_EXPIRED" "401.5"
    Invoke-Check "me-clears-legacy-cookie" @("-H","Cookie: authsid=deadbeef","$base/auth/me") @(401) "authsid=;" $null
    Invoke-Check "debug-absent" @("$base/auth/debug/identity") @(404) "Not found" "windowsIdentity"
    Invoke-Check "health-headers" @("$base/auth/health") @(200) "X-Frame-Options: DENY" "Strict-Transport-Security"
    Invoke-Check "origin-rejected" @("-X","POST","-H","Origin: https://evil.example","-H","Content-Type: application/json","--data-binary","{}","$base/auth/logout") @(403) "INVALID_ORIGIN" $null
    Invoke-Check "proxy-absolute" @("$base/auth/zno/https://evil.example/api/tasks") @(404) "Not found" $null
    Invoke-Check "proxy-not-api" @("$base/auth/zno/not-an-api") @(404) "Not found" $null
    Invoke-Check "zno-anonymous" @("$base/auth/zno/api/tasks") @(401) "Not authenticated" "401.5"
    Invoke-Check "logout" @("-X","POST","-H","Content-Type: application/json","--data-binary","{}","$base/auth/logout") @(200) '"ok":true' $null

    $badAd = Join-Path $tmp "bad-ad.json"
    [IO.File]::WriteAllText($badAd, '{"username":"EXAMPLE\\not-a-real-user","password":"wrong-password"}', (New-Object Text.UTF8Encoding $false))
    Invoke-Check "login-ad-invalid" @("-X","POST","-H","Content-Type: application/json","--data-binary","@$badAd","$base/auth/login") @(401) "Invalid username or password" "wrong-password"

    $bad1c = Join-Path $tmp "bad-1c.json"
    [IO.File]::WriteAllText($bad1c, '{"username":"not-a-real-1c-user","password":"wrong-password"}', (New-Object Text.UTF8Encoding $false))
    Invoke-Check "login-1c-invalid" @("-X","POST","-H","Content-Type: application/json","--data-binary","@$bad1c","$base/auth/login") @(401) "Invalid username or password" "wrong-password"
    $big = Join-Path $tmp "big.json"
    [IO.File]::WriteAllText($big, ('{"username":"x","password":"' + ("a" * 9000) + '"}'), (New-Object Text.UTF8Encoding $false))
    Invoke-Check "login-too-large" @("-X","POST","-H","Content-Type: application/json","--data-binary","@$big","$base/auth/login") @(400) "required" $null

    Invoke-Check "sso" @("-H","Accept: application/json","$base/auth/sso/login") @(401,302,200) $null "password"
    Invoke-Check "pwa" @("$base/pwa-auth-test/") @(200) "frame-ancestors" "1C user name"
    Invoke-Check "osauth-challenge" @("$base/UH_Medvedev_test_osauth/hs/mobile/api/tasks") @(401) "Negotiate" "401.5"
}
finally {
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

if ($failed) { exit 1 }
Write-Output "TESTS COMPLETE"
