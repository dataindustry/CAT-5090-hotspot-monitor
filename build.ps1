$ErrorActionPreference = 'Stop'

$vsRoot = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\2022\BuildTools'
$msvcRoot = Get-ChildItem (Join-Path $vsRoot 'VC\Tools\MSVC') -Directory |
    Sort-Object Name -Descending |
    Select-Object -First 1
if (-not $msvcRoot) {
    throw 'MSVC x64 tools were not found.'
}

$kitRoot = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10'
$kitVersion = Get-ChildItem (Join-Path $kitRoot 'Include') -Directory |
    Where-Object { Test-Path (Join-Path $_.FullName 'km\ntddk.h') } |
    Sort-Object Name -Descending |
    Select-Object -First 1
if (-not $kitVersion) {
    throw 'Windows Driver Kit kernel headers were not found.'
}

$cl = Join-Path $msvcRoot.FullName 'bin\Hostx64\x64\cl.exe'
$link = Join-Path $msvcRoot.FullName 'bin\Hostx64\x64\link.exe'
$includeRoot = $kitVersion.FullName
$libRoot = Join-Path $kitRoot "Lib\$($kitVersion.Name)\km\x64"
$outputRoot = Join-Path $PSScriptRoot 'build'
$objectRoot = Join-Path $PSScriptRoot 'obj'
New-Item -ItemType Directory -Force -Path $outputRoot, $objectRoot | Out-Null

$objectPath = Join-Path $objectRoot 'driver.obj'
$sysPath = Join-Path $outputRoot 'cat_bjt_readonly.sys'
$pdbPath = Join-Path $outputRoot 'cat_bjt_readonly.pdb'

& $cl /nologo /c /kernel /Zl /W4 /WX /O2 /Oi /GS- /Gy /Gm- /GR- /EHs-c- `
    /D_AMD64_ /DAMD64 /DNTDDI_VERSION=0x0A00000C /D_WIN32_WINNT=0x0A00 `
    "/I$(Join-Path $msvcRoot.FullName 'include')" `
    "/I$(Join-Path $includeRoot 'km')" `
    "/I$(Join-Path $includeRoot 'shared')" `
    "/I$(Join-Path $includeRoot 'ucrt')" `
    "/Fo$objectPath" `
    (Join-Path $PSScriptRoot 'driver.c')
if ($LASTEXITCODE -ne 0) {
    throw "Driver compilation failed with exit code $LASTEXITCODE."
}

& $link /nologo /driver /subsystem:native /entry:DriverEntry /machine:x64 `
    /nodefaultlib /incremental:no /opt:ref /opt:icf /debug `
    "/out:$sysPath" "/pdb:$pdbPath" "/libpath:$libRoot" `
    $objectPath ntoskrnl.lib hal.lib wdmsec.lib BufferOverflowK.lib
if ($LASTEXITCODE -ne 0) {
    throw "Driver link failed with exit code $LASTEXITCODE."
}

Get-Item $sysPath | Select-Object FullName, Length, LastWriteTime
