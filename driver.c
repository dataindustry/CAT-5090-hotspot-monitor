#include <ntddk.h>
#include <wdmsec.h>

#include "cat_bjt_readonly.h"

#define CAT_RTX5090_BAR0_PHYSICAL 0x00000000D8000000ULL
#define CAT_BJT_PAGE_OFFSET 0x00AD0000ULL
#define CAT_BJT_MAP_SIZE PAGE_SIZE

static const ULONG CatBjtOffsets[CAT_BJT_SENSOR_COUNT] = {
    0x00000A90U,
    0x00000A94U,
    0x00000A98U,
    0x00000A9CU,
    0x00000AA0U,
    0x00000AA4U,
};

static const GUID CatBjtDeviceClassGuid = {
    0x8af4792b,
    0x2282,
    0x4ac6,
    {0x98, 0xc4, 0xe1, 0x60, 0x0c, 0x2a, 0x63, 0x32},
};

DRIVER_INITIALIZE DriverEntry;

static NTSTATUS CatBjtCompleteIrp(PIRP irp, NTSTATUS status, ULONG_PTR information)
{
    irp->IoStatus.Status = status;
    irp->IoStatus.Information = information;
    IoCompleteRequest(irp, IO_NO_INCREMENT);
    return status;
}

static NTSTATUS CatBjtCreateClose(PDEVICE_OBJECT deviceObject, PIRP irp)
{
    UNREFERENCED_PARAMETER(deviceObject);
    return CatBjtCompleteIrp(irp, STATUS_SUCCESS, 0U);
}

static NTSTATUS CatBjtUnsupported(PDEVICE_OBJECT deviceObject, PIRP irp)
{
    UNREFERENCED_PARAMETER(deviceObject);
    return CatBjtCompleteIrp(irp, STATUS_INVALID_DEVICE_REQUEST, 0U);
}

static NTSTATUS CatBjtReadSensors(PCAT_BJT_READ_RESPONSE response)
{
    PHYSICAL_ADDRESS physicalAddress;
    volatile UCHAR *mappedPage;
    ULONG index;

    RtlZeroMemory(response, sizeof(*response));
    response->Version = CAT_BJT_PROTOCOL_VERSION;
    response->Size = sizeof(*response);
    response->Bar0Low = (ULONG)(CAT_RTX5090_BAR0_PHYSICAL & 0xFFFFFFFFULL);
    response->Bar0High = (ULONG)(CAT_RTX5090_BAR0_PHYSICAL >> 32);

    physicalAddress.QuadPart = CAT_RTX5090_BAR0_PHYSICAL + CAT_BJT_PAGE_OFFSET;
    mappedPage = (volatile UCHAR *)MmMapIoSpaceEx(
        physicalAddress,
        CAT_BJT_MAP_SIZE,
        PAGE_READONLY | PAGE_NOCACHE);
    if (mappedPage == NULL) {
        return STATUS_INSUFFICIENT_RESOURCES;
    }

    for (index = 0U; index < CAT_BJT_SENSOR_COUNT; ++index) {
        const ULONG raw = READ_REGISTER_ULONG(
            (volatile ULONG *)(mappedPage + CatBjtOffsets[index]));
        response->Raw[index] = raw;
        if ((raw & (1UL << 30)) != 0U) {
            response->ValidMask |= (1UL << index);
        }
    }

    MmUnmapIoSpace((PVOID)mappedPage, CAT_BJT_MAP_SIZE);
    return STATUS_SUCCESS;
}

static NTSTATUS CatBjtDeviceControl(PDEVICE_OBJECT deviceObject, PIRP irp)
{
    const PIO_STACK_LOCATION stack = IoGetCurrentIrpStackLocation(irp);
    const ULONG controlCode = stack->Parameters.DeviceIoControl.IoControlCode;
    const ULONG inputLength = stack->Parameters.DeviceIoControl.InputBufferLength;
    const ULONG outputLength = stack->Parameters.DeviceIoControl.OutputBufferLength;
    PCAT_BJT_READ_RESPONSE response;
    NTSTATUS status;

    UNREFERENCED_PARAMETER(deviceObject);

    if (controlCode != IOCTL_CAT_BJT_READ || inputLength != 0U) {
        return CatBjtCompleteIrp(irp, STATUS_INVALID_DEVICE_REQUEST, 0U);
    }
    if (outputLength < sizeof(CAT_BJT_READ_RESPONSE)) {
        return CatBjtCompleteIrp(irp, STATUS_BUFFER_TOO_SMALL, 0U);
    }

    response = (PCAT_BJT_READ_RESPONSE)irp->AssociatedIrp.SystemBuffer;
    if (response == NULL) {
        return CatBjtCompleteIrp(irp, STATUS_INVALID_USER_BUFFER, 0U);
    }

    status = CatBjtReadSensors(response);
    return CatBjtCompleteIrp(
        irp,
        status,
        NT_SUCCESS(status) ? sizeof(*response) : 0U);
}

static VOID CatBjtUnload(PDRIVER_OBJECT driverObject)
{
    UNICODE_STRING symbolicLink;

    RtlInitUnicodeString(&symbolicLink, L"\\DosDevices\\CatBjtReadOnly");
    IoDeleteSymbolicLink(&symbolicLink);
    if (driverObject->DeviceObject != NULL) {
        IoDeleteDevice(driverObject->DeviceObject);
    }
}

NTSTATUS DriverEntry(PDRIVER_OBJECT driverObject, PUNICODE_STRING registryPath)
{
    UNICODE_STRING deviceName;
    UNICODE_STRING symbolicLink;
    UNICODE_STRING sddl;
    PDEVICE_OBJECT deviceObject = NULL;
    ULONG majorFunction;
    NTSTATUS status;

    UNREFERENCED_PARAMETER(registryPath);

    RtlInitUnicodeString(&deviceName, L"\\Device\\CatBjtReadOnly");
    RtlInitUnicodeString(&symbolicLink, L"\\DosDevices\\CatBjtReadOnly");
    RtlInitUnicodeString(&sddl, L"D:P(A;;GA;;;SY)(A;;GR;;;BA)");

    for (majorFunction = 0U; majorFunction <= IRP_MJ_MAXIMUM_FUNCTION; ++majorFunction) {
        driverObject->MajorFunction[majorFunction] = CatBjtUnsupported;
    }
    driverObject->MajorFunction[IRP_MJ_CREATE] = CatBjtCreateClose;
    driverObject->MajorFunction[IRP_MJ_CLOSE] = CatBjtCreateClose;
    driverObject->MajorFunction[IRP_MJ_DEVICE_CONTROL] = CatBjtDeviceControl;
    driverObject->DriverUnload = CatBjtUnload;

    status = IoCreateDeviceSecure(
        driverObject,
        0U,
        &deviceName,
        CAT_BJT_DEVICE_TYPE,
        FILE_DEVICE_SECURE_OPEN,
        FALSE,
        &sddl,
        &CatBjtDeviceClassGuid,
        &deviceObject);
    if (!NT_SUCCESS(status)) {
        return status;
    }

    deviceObject->Flags |= DO_BUFFERED_IO;
    status = IoCreateSymbolicLink(&symbolicLink, &deviceName);
    if (!NT_SUCCESS(status)) {
        IoDeleteDevice(deviceObject);
        return status;
    }

    deviceObject->Flags &= ~DO_DEVICE_INITIALIZING;
    return STATUS_SUCCESS;
}
