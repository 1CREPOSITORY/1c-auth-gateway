$AuthPublicHost = "1c.domain.com"
$repoRoot = Split-Path $PSScriptRoot -Parent
$localEnvironment = Join-Path $repoRoot "environment.local.ps1"
if (Test-Path $localEnvironment) {
    . $localEnvironment
}
