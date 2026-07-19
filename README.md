# RTX 5090 Blackwell 六路 BJT 温度只读探针

这是一个独立于 CAT 的 Windows 实验项目。它使用自建、测试签名的最小 WDM 内核驱动，只读访问本机 RTX 5090 BAR0 中六个 Blackwell BJT 温度寄存器；Python 负责持续轮询、解码六路温度并计算其中最大值作为 Hot Spot。

该方案已经在当前机器上端到端跑通。它不依赖 CPU-Z、HWMonitor、WinRing0、RyzenAdj、LibreHardwareMonitor 或 Afterburner。

## 适用范围

- 操作系统：Windows 11 x64。
- 显卡：当前机器的 `PCI\VEN_10DE&DEV_2B85`，NVIDIA GeForce RTX 5090。
- 当前 BAR0 物理基址：`0xD8000000`。
- 目标寄存器：`BAR0 + 0xAD0A90` 至 `BAR0 + 0xAD0AA4`，共六个，步长 4 字节。
- 温度换算：bit 30 有效时，`(raw & 0xFFFF) / 256` °C。
- Hot Spot：本次采样中六路有效温度的最大值。

这不是通用可分发驱动。安装脚本会在加载前重新读取 RTX 5090 的 PnP 资源；只要 BAR0 不等于 `0xD8000000` 就直接拒绝加载，绝不猜测地址。

## 安全边界

- 驱动只映射 `BAR0 + 0x00AD0000` 的一页物理内存。
- 映射属性为 `PAGE_READONLY | PAGE_NOCACHE`。
- 只读取六个写死的寄存器。
- 只有一个无输入、`FILE_READ_ACCESS`、`METHOD_BUFFERED` IOCTL。
- 用户态不能传入地址、偏移、长度或数据。
- 不存在写 IOCTL，也不包含任意物理内存访问入口。
- 设备 ACL 只允许 SYSTEM 完全访问和管理员只读访问。
- 服务使用 `DEMAND_START`，不会开机自动加载。
- 驱动内部没有轮询线程、定时器或持久状态。

## 需要安装的软件

### 1. Visual Studio Build Tools 2022

需要安装 MSVC x64 C/C++ 编译工具。可以从管理员 PowerShell 执行：

```powershell
winget install --id Microsoft.VisualStudio.2022.BuildTools -e --override "--passive --wait --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended"
```

本项目不需要完整 Visual Studio IDE，也不依赖 Visual Studio 的 WDK 项目扩展；`build.ps1` 直接调用官方 MSVC `cl.exe` 和 `link.exe`。

### 2. Windows Driver Kit

已验证版本为 WDK `10.0.26100.6584`，头文件和库版本为 `10.0.26100.0`：

```powershell
winget install --id Microsoft.WindowsWDK.10.0.26100 -e
```

安装后应存在：

```text
C:\Program Files (x86)\Windows Kits\10\Include\10.0.26100.0\km\ntddk.h
C:\Program Files (x86)\Windows Kits\10\Lib\10.0.26100.0\km\x64\ntoskrnl.lib
C:\Program Files (x86)\Windows Kits\10\bin\10.0.26100.0\x64\signtool.exe
```

### 3. Python

需要 Python 3.10 或更高版本；当前验证使用 Python 3.12。轮询器只使用标准库，不需要安装 pip 依赖。

## Windows 启动设置

测试签名驱动要求关闭 Secure Boot，并启用 Windows TESTSIGNING。该设置会降低系统的驱动签名保护强度，只应在开发机上使用。

1. 在主板 UEFI/BIOS 中关闭 Secure Boot。
2. 打开管理员 PowerShell：

```powershell
bcdedit /set testsigning on
```

3. 重启 Windows。
4. 重启后可以检查启动选项：

```powershell
(Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control').SystemStartOptions
```

输出中必须包含 `TESTSIGNING`。本机在 Memory Integrity/HVCI 保持启用的情况下也已成功加载该测试签名驱动。

## 文件说明

| 文件 | 职责 |
|---|---|
| `driver.c` | 最小 WDM 驱动、设备 ACL、固定六路 MMIO 读取。 |
| `cat_bjt_readonly.h` | 唯一 IOCTL 和固定响应合同。 |
| `build.ps1` | 定位 MSVC/WDK，编译和链接 x64 `.sys`。 |
| `install-test-driver.ps1` | 校验管理员权限、TESTSIGNING、GPU 和 BAR0，创建测试证书、签名、安装并启动驱动。 |
| `read_bjt_temperatures.py` | 轮询驱动、输出六路温度和 Hot Spot。 |
| `start-monitor.ps1` | 启动按需驱动并持续轮询，按 Ctrl+C 停止。 |
| `remove-test-driver.ps1` | 停止服务并删除已安装驱动。 |
| `实验结果.md` | 当前机器的端到端验证结论。 |

## 构建

普通 PowerShell 即可编译：

```powershell
cd C:\path\to\CAT-5090-hotspot-monitor
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\build.ps1
```

输出位于：

```text
build\cat_bjt_readonly.sys
build\cat_bjt_readonly.pdb
```

编译启用了 `/W4 /WX`，任何编译警告都会导致失败。

## 签名、安装和启动

在管理员 PowerShell 中执行：

```powershell
cd C:\path\to\CAT-5090-hotspot-monitor
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install-test-driver.ps1
```

脚本会依次：

1. 核对管理员令牌。
2. 核对当前启动包含 TESTSIGNING。
3. 查找 RTX 5090 并确认 BAR0 为 `0xD8000000`。
4. 重新编译驱动。
5. 创建或复用 `CAT Blackwell BJT Experimental Test Certificate` 本机代码签名证书。
6. 将证书导入本机 Root 和 TrustedPublisher。
7. 使用 SHA-256 签名并验证驱动文件。
8. 将驱动复制到 `C:\Windows\System32\drivers\cat_bjt_readonly.sys`。
9. 创建并启动 `CatBjtReadOnly` 手动内核服务。

查看状态：

```powershell
sc.exe query CatBjtReadOnly
sc.exe qc CatBjtReadOnly
```

## 轮询六路温度

设备 ACL 要求管理员令牌，因此必须在管理员 PowerShell 中运行 Python。

采样十次，每秒一次：

```powershell
python .\read_bjt_temperatures.py --interval 1 --count 10
```

持续采样，直到按 Ctrl+C：

```powershell
python .\read_bjt_temperatures.py --interval 1 --count 0
```

也可以在管理员 PowerShell 中使用持续监控入口，它会自动启动已经安装的按需驱动，并写入 `live-bjt-samples.ndjson`：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\start-monitor.ps1
```

同时保存 UTF-8 NDJSON：

```powershell
python .\read_bjt_temperatures.py --interval 1 --count 0 --output .\bjt-samples.ndjson
```

每行输出示例：

```json
{"timestamp":"2026-07-19T05:59:20.171+00:00","bar0":"0x00000000D8000000","validMask":"0x3F","raw":["0x40003210","0x40002ED0","0x40003018","0x40003318","0x40003318","0x40003060"],"temperaturesC":[50.0625,46.8125,48.09375,51.09375,51.09375,48.375],"hotSpotC":51.09375}
```

- `validMask=0x3F` 表示六路全部有效。
- `raw` 是驱动原样返回的六个 32 位寄存器值。
- `temperaturesC` 是六路解码温度。
- `hotSpotC` 是本次读取六路有效温度的最大值。

## 停止和卸载

在管理员 PowerShell 中执行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\remove-test-driver.ps1
```

该脚本会停止并删除 `CatBjtReadOnly` 服务，并删除 `C:\Windows\System32\drivers\cat_bjt_readonly.sys`。测试证书会保留，以便重复实验。

如果不再进行驱动开发，可以删除测试证书：

```powershell
$subject = 'CN=CAT Blackwell BJT Experimental Test Certificate'
Get-ChildItem Cert:\LocalMachine\My, Cert:\LocalMachine\Root, Cert:\LocalMachine\TrustedPublisher |
    Where-Object Subject -eq $subject |
    Remove-Item
```

然后恢复正常驱动签名策略并重启：

```powershell
bcdedit /set testsigning off
Restart-Computer
```

重新启用 Secure Boot 前，应先确认 Windows 已不再处于 TESTSIGNING 模式。

## 常见错误

### `WinError 5` / 拒绝访问

Python 没有管理员令牌。请从管理员 PowerShell 运行。

### `Windows is not currently booted with TESTSIGNING enabled`

执行 `bcdedit /set testsigning on` 后尚未重启，或者 Secure Boot 阻止了测试签名模式。

### `BAR0 mismatch`

当前 PCI 资源分配与已验证机器不同。脚本会安全拒绝加载；不要通过删除检查或猜测地址来强行运行。

### `Driver start failed`

检查：

```powershell
Get-WinEvent -LogName 'Microsoft-Windows-CodeIntegrity/Operational' -MaxEvents 20 |
    Format-List TimeCreated, Id, LevelDisplayName, Message
```

常见原因是 Secure Boot 未关闭、TESTSIGNING 未生效、测试证书不受信任，或者驱动文件在签名后又被修改。
