"""Poll the fixed read-only CAT Blackwell BJT test driver."""

from __future__ import annotations

import argparse
import ctypes
import json
import struct
import time
from ctypes import wintypes
from datetime import datetime, timezone
from pathlib import Path


DEVICE = r"\\.\CatBjtReadOnly"
DEVICE_TYPE = 0x8337
FUNCTION = 0x800
METHOD_BUFFERED = 0
FILE_READ_ACCESS = 1
IOCTL_CAT_BJT_READ = (
    (DEVICE_TYPE << 16)
    | (FILE_READ_ACCESS << 14)
    | (FUNCTION << 2)
    | METHOD_BUFFERED
)
RESPONSE = struct.Struct("<11I")
INVALID_HANDLE_VALUE = ctypes.c_void_p(-1).value


kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
kernel32.CreateFileW.argtypes = [
    wintypes.LPCWSTR,
    wintypes.DWORD,
    wintypes.DWORD,
    wintypes.LPVOID,
    wintypes.DWORD,
    wintypes.DWORD,
    wintypes.HANDLE,
]
kernel32.CreateFileW.restype = wintypes.HANDLE
kernel32.DeviceIoControl.argtypes = [
    wintypes.HANDLE,
    wintypes.DWORD,
    wintypes.LPVOID,
    wintypes.DWORD,
    wintypes.LPVOID,
    wintypes.DWORD,
    ctypes.POINTER(wintypes.DWORD),
    wintypes.LPVOID,
]
kernel32.DeviceIoControl.restype = wintypes.BOOL
kernel32.CloseHandle.argtypes = [wintypes.HANDLE]
kernel32.CloseHandle.restype = wintypes.BOOL


def read_once(handle: int) -> dict[str, object]:
    output = ctypes.create_string_buffer(RESPONSE.size)
    returned = wintypes.DWORD()
    ok = kernel32.DeviceIoControl(
        handle,
        IOCTL_CAT_BJT_READ,
        None,
        0,
        output,
        len(output),
        ctypes.byref(returned),
        None,
    )
    if not ok:
        raise ctypes.WinError(ctypes.get_last_error())
    if returned.value != RESPONSE.size:
        raise RuntimeError(f"unexpected response size: {returned.value}")

    version, size, bar0_low, bar0_high, valid_mask, *raw_values = RESPONSE.unpack(output.raw)
    if version != 1 or size != RESPONSE.size:
        raise RuntimeError(f"unsupported driver response: version={version}, size={size}")

    temperatures = [
        (raw & 0xFFFF) / 256.0 if valid_mask & (1 << index) else None
        for index, raw in enumerate(raw_values)
    ]
    valid_temperatures = [value for value in temperatures if value is not None]
    return {
        "timestamp": datetime.now(timezone.utc).isoformat(timespec="milliseconds"),
        "bar0": f"0x{((bar0_high << 32) | bar0_low):016X}",
        "validMask": f"0x{valid_mask:02X}",
        "raw": [f"0x{value:08X}" for value in raw_values],
        "temperaturesC": temperatures,
        "hotSpotC": max(valid_temperatures) if valid_temperatures else None,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--interval", type=float, default=1.0)
    parser.add_argument("--count", type=int, default=0, help="0 means run until interrupted")
    parser.add_argument("--output", type=Path, help="also write UTF-8 NDJSON to this file")
    args = parser.parse_args()
    if args.interval <= 0 or args.count < 0:
        parser.error("interval must be positive and count must be non-negative")

    handle = kernel32.CreateFileW(
        DEVICE,
        0x80000000,
        0x00000001 | 0x00000002,
        None,
        3,
        0,
        None,
    )
    if handle == INVALID_HANDLE_VALUE:
        raise ctypes.WinError(ctypes.get_last_error())

    output_file = args.output.open("w", encoding="utf-8", newline="\n") if args.output else None
    try:
        completed = 0
        while args.count == 0 or completed < args.count:
            payload = json.dumps(read_once(handle), ensure_ascii=True, separators=(",", ":"))
            print(payload, flush=True)
            if output_file is not None:
                output_file.write(f"{payload}\n")
                output_file.flush()
            completed += 1
            if args.count == 0 or completed < args.count:
                time.sleep(args.interval)
    finally:
        if output_file is not None:
            output_file.close()
        kernel32.CloseHandle(handle)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
