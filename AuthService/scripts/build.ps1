$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$bin = Join-Path $root "bin"
New-Item -ItemType Directory -Force -Path $bin | Out-Null
$csc = Join-Path $env:WINDIR "Microsoft.NET\Framework64\v4.0.30319\csc.exe"
if (-not (Test-Path $csc)) { throw "csc.exe not found: $csc" }
$out = Join-Path $bin "AuthService.dll"
& $csc /nologo /optimize+ /t:library /out:$out `
    /r:System.dll /r:System.Core.dll /r:System.Web.dll /r:System.Configuration.dll `
    (Join-Path $root "src\AuthModule.cs")
if ($LASTEXITCODE -ne 0) { throw "csc failed with exit code $LASTEXITCODE" }
Write-Output "BUILT $out"
