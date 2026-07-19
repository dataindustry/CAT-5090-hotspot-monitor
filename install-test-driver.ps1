$ErrorActionPreference = 'Stop'

$principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'This script must run as administrator.'
}

$expectedBar0 = [Convert]::ToUInt64('D8000000', 16)
$gpuAllocation = Get-CimInstance Win32_PnPAllocatedResource |
    Where-Object {
        $_.Dependent.DeviceID -like 'PCI\VEN_10DE&DEV_2B85*' -and
        $_.Antecedent.CimClass.CimClassName -eq 'Win32_DeviceMemoryAddress'
    } |
    Sort-Object { [uint64]$_.Antecedent.StartingAddress } |
    Select-Object -First 1
if (-not $gpuAllocation) {
    throw 'RTX 5090 memory resources were not found.'
}
$actualBar0 = [uint64]$gpuAllocation.Antecedent.StartingAddress
if ($actualBar0 -ne $expectedBar0) {
    throw ('BAR0 mismatch: expected 0x{0:X}, actual 0x{1:X}. Refusing to load.' -f $expectedBar0, $actualBar0)
}

$startOptions = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control').SystemStartOptions
if ($startOptions -notmatch 'TESTSIGNING') {
    throw 'Windows is not currently booted with TESTSIGNING enabled.'
}

& (Join-Path $PSScriptRoot 'build.ps1')

$subject = 'CN=CAT Blackwell BJT Experimental Test Certificate'
$certificate = Get-ChildItem Cert:\LocalMachine\My |
    Where-Object { $_.Subject -eq $subject -and $_.HasPrivateKey -and $_.NotAfter -gt (Get-Date).AddDays(1) } |
    Sort-Object NotAfter -Descending |
    Select-Object -First 1
if (-not $certificate) {
    $certificate = New-SelfSignedCertificate `
        -Type CodeSigningCert `
        -Subject $subject `
        -CertStoreLocation Cert:\LocalMachine\My `
        -KeyAlgorithm RSA `
        -KeyLength 3072 `
        -HashAlgorithm SHA256 `
        -KeyExportPolicy Exportable `
        -NotAfter (Get-Date).AddYears(2)
}

$certificatePath = Join-Path $PSScriptRoot 'build\cat_bjt_test_certificate.cer'
Export-Certificate -Cert $certificate -FilePath $certificatePath -Force | Out-Null
Import-Certificate -FilePath $certificatePath -CertStoreLocation Cert:\LocalMachine\Root | Out-Null
Import-Certificate -FilePath $certificatePath -CertStoreLocation Cert:\LocalMachine\TrustedPublisher | Out-Null

$kitBinRoot = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\bin'
$signTool = Get-ChildItem -LiteralPath $kitBinRoot -Directory |
    Where-Object { Test-Path (Join-Path $_.FullName 'x64\signtool.exe') } |
    Sort-Object Name -Descending |
    ForEach-Object { Join-Path $_.FullName 'x64\signtool.exe' } |
    Select-Object -First 1
if (-not $signTool) {
    throw 'SignTool was not found.'
}
$builtDriver = Join-Path $PSScriptRoot 'build\cat_bjt_readonly.sys'
& $signTool sign /v /fd sha256 /s My /sm /sha1 $certificate.Thumbprint $builtDriver
if ($LASTEXITCODE -ne 0) {
    throw "Driver signing failed with exit code $LASTEXITCODE."
}
& $signTool verify /v /pa $builtDriver
if ($LASTEXITCODE -ne 0) {
    throw "Authenticode signature verification failed with exit code $LASTEXITCODE."
}

$installedDriver = Join-Path $env:SystemRoot 'System32\drivers\cat_bjt_readonly.sys'
& sc.exe stop CatBjtReadOnly 2>$null | Out-Null
& sc.exe delete CatBjtReadOnly 2>$null | Out-Null
Start-Sleep -Milliseconds 300
Copy-Item -LiteralPath $builtDriver -Destination $installedDriver -Force
& sc.exe create CatBjtReadOnly type= kernel start= demand binPath= $installedDriver DisplayName= 'CAT Blackwell BJT Read-Only Experiment'
if ($LASTEXITCODE -ne 0) {
    throw "Service creation failed with exit code $LASTEXITCODE."
}
& sc.exe start CatBjtReadOnly
if ($LASTEXITCODE -ne 0) {
    $events = Get-WinEvent -FilterHashtable @{ LogName = 'Microsoft-Windows-CodeIntegrity/Operational'; StartTime = (Get-Date).AddMinutes(-5) } -ErrorAction SilentlyContinue |
        Select-Object -First 5 TimeCreated, Id, LevelDisplayName, Message |
        Format-List |
        Out-String
    throw "Driver start failed with exit code $LASTEXITCODE.`n$events"
}

[pscustomobject]@{
    Service = 'CatBjtReadOnly'
    State = (Get-Service CatBjtReadOnly).Status
    Bar0 = ('0x{0:X16}' -f $actualBar0)
    CertificateThumbprint = $certificate.Thumbprint
    Driver = $installedDriver
} | Format-List
