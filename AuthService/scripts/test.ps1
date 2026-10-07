# Smoke tests for the deployed auth contour.
# A valid AD password is never stored here. The success-path check runs only when
# AUTHZ_TEST_USERNAME and AUTHZ_TEST_PASSWORD are already present in the process environment.
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "..\..\scripts\load-environment.ps1")
$base = "https://$AuthPublicHost"
$curl = Join-Path $env:WINDIR "System32\curl.exe"
$tmp = Join-Path $env:TEMP ("autz-test-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$failed = $false

function Invoke-Check {
    param(
        [string]$Name,
        [string[]]$CurlArgs,
        [int[]]$Expect,
        [string]$BodyContains,
        [string]$BodyMustNotContain
    )
    $hdr = Join-Path $tmp ($Name + ".hdr")
    $body = Join-Path $tmp ($Name + ".body")
    & $curl -sS -k --max-time 30 -D $hdr -o $body @CurlArgs | Out-Null
    $statusLine = (Get-Content $hdr -TotalCount 1)
    $code = 0
    if ($statusLine -match "\s(\d{3})\s") { $code = [int]$Matches[1] }
    $text = ""
    if (Test-Path $body) { $text = Get-Content $body -Raw -ErrorAction SilentlyContinue }
    $ok = $Expect -contains $code
    if ($BodyContains -and $text -notlike "*$BodyContains*") { $ok = $false }
    if ($BodyMustNotContain -and $text -like "*$BodyMustNotContain*") { $ok = $false }
    if ($ok) {
        Write-Output "PASS $Name HTTP $code"
    } else {
        Write-Output "FAIL $Name HTTP $code expected $($Expect -join '/')"
        if ($text) { Write-Output ($text.Substring(0, [Math]::Min(400, $text.Length))) }
        $script:failed = $true
    }
}

try {
    Invoke-Check "health" @("$base/auth/health") @(200) '"ok":true' $null
    Invoke-Check "me-anonymous" @("$base/auth/me") @(401) "Not authenticated" "password"
    Invoke-Check "services-anonymous" @("$base/auth/fps/services") @(401) "Not authenticated" $null
    Invoke-Check "logout-anonymous" @("-X", "POST", "-H", "Content-Type: application/json", "--data-binary", "{}", "$base/auth/logout") @(200) '"ok":true' $null

    $badFile = Join-Path $tmp "bad.json"
    [IO.File]::WriteAllText($badFile, '{"username":"EXAMPLE\\not-a-real-user","password":"wrong-password"}', (New-Object Text.UTF8Encoding $false))
    Invoke-Check "login-invalid" @(
        "-X", "POST",
        "-H", "Content-Type: application/json",
        "-H", "Accept: application/json",
        "--data-binary", "@$badFile",
        "$base/auth/ad/login"
    ) @(401) "Invalid username or password" "wrong-password"

    $hdr = Join-Path $tmp "login-invalid.hdr"
    $setCookie = Select-String -Path $hdr -Pattern "Set-Cookie:\s*authsid=" -Quiet
    if ($setCookie) {
        Write-Output "FAIL login-invalid set a session cookie"
        $failed = $true
    } else {
        Write-Output "PASS login-invalid has no session cookie"
    }

    Invoke-Check "sso" @("-H", "Accept: application/json", "$base/auth/sso/login") @(401, 302, 200) $null "password"
    Invoke-Check "pwa" @("$base/pwa-auth-test/") @(200) "adGate" "check.ashx"
    Invoke-Check "pwa-file" @("$base/pwa-auth-test/index.html") @(200) "Согласование ЗНО" $null
    Invoke-Check "tasks-no-auth" @("$base/UH_Medvedev_test/hs/mobile/api/tasks") @(401) $null $null

    if ($env:AUTHZ_TEST_USERNAME -and $env:AUTHZ_TEST_PASSWORD) {
        $goodFile = Join-Path $tmp "good.json"
        $payload = @{ username = $env:AUTHZ_TEST_USERNAME; password = $env:AUTHZ_TEST_PASSWORD } | ConvertTo-Json -Compress
        [IO.File]::WriteAllText($goodFile, $payload, (New-Object Text.UTF8Encoding $false))
        $jar = Join-Path $tmp "cookies.txt"
        Invoke-Check "login-valid" @(
            "-c", $jar,
            "-X", "POST",
            "-H", "Content-Type: application/json",
            "-H", "Accept: application/json",
            "--data-binary", "@$goodFile",
            "$base/auth/ad/login"
        ) @(200) '"authType":"AD_PASSWORD"' $env:AUTHZ_TEST_PASSWORD
        Invoke-Check "me-valid" @("-b", $jar, "$base/auth/me") @(200) $env:AUTHZ_TEST_USERNAME.Split('\')[-1] $null
        Invoke-Check "logout-valid" @("-b", $jar, "-c", $jar, "-X", "POST", "-H", "Content-Type: application/json", "--data-binary", "{}", "$base/auth/logout") @(200) '"ok":true' $null
        Invoke-Check "me-after-logout" @("-b", $jar, "$base/auth/me") @(401) "Not authenticated" $null
        Remove-Item $goodFile -Force -ErrorAction SilentlyContinue
    } else {
        Write-Output "SKIP login-valid (set AUTHZ_TEST_USERNAME and AUTHZ_TEST_PASSWORD in the process to run it)"
    }
}
finally {
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

if ($failed) { exit 1 }
Write-Output "TESTS COMPLETE"
