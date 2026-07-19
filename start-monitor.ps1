param(
    [ValidateRange(0.1, 3600.0)]
    [double]$IntervalSeconds = 1.0,
    [string]$OutputPath = (Join-Path $PSScriptRoot 'live-bjt-samples.ndjson')
)

$ErrorActionPreference = 'Stop'

$principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'This script must run as administrator.'
}

$queryText = (& sc.exe query CatBjtReadOnly 2>&1) -join "`n"
if ($LASTEXITCODE -ne 0) {
    throw 'CatBjtReadOnly is not installed. Run install-test-driver.ps1 first.'
}
if ($queryText -notmatch 'STATE\s+:\s+4\s+RUNNING') {
    & sc.exe start CatBjtReadOnly
    if ($LASTEXITCODE -ne 0) {
        throw "CatBjtReadOnly could not be started (exit code $LASTEXITCODE)."
    }
}

$probe = Join-Path $PSScriptRoot 'read_bjt_temperatures.py'
Write-Output "Monitoring every $IntervalSeconds second(s). Press Ctrl+C to stop."
Write-Output "UTF-8 NDJSON output: $OutputPath"
& python $probe --interval $IntervalSeconds --count 0 --output $OutputPath
exit $LASTEXITCODE
