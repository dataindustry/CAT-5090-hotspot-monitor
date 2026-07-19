$ErrorActionPreference = 'Stop'

$principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'This script must run as administrator.'
}

& sc.exe stop CatBjtReadOnly 2>$null | Out-Null
& sc.exe delete CatBjtReadOnly 2>$null | Out-Null
Start-Sleep -Milliseconds 300
$installedDriver = Join-Path $env:SystemRoot 'System32\drivers\cat_bjt_readonly.sys'
if (Test-Path -LiteralPath $installedDriver) {
    Remove-Item -LiteralPath $installedDriver -Force
}
Write-Output 'CatBjtReadOnly service and installed driver file were removed.'
