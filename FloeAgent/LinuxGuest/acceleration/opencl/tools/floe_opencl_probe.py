#!/usr/bin/env python3
# SPDX-License-Identifier: MPL-2.0
"""Floe OpenCL ICD enumeration and verifiable device operation probe.

The probe talks to the system OpenCL loader (`libOpenCL.so.1`, normally
ocl-icd). It never writes an ICD, never creates a vendor from a filename and
never reports an installed runtime without a successful `clGetPlatformIDs`.
A device is reported only after `clGetDeviceIDs`. The compute check submits
real OpenCL commands (fill/write, copy, readback and map) and verifies the
bytes; a kernel is additionally built and executed when the selected device
reports a compiler.

Usage:
    floe-opencl-probe status
    floe-opencl-probe run [--device any|gpu|cpu] [--size N] [--kernel auto|on|off]

Exit codes:
    0   the query/compute completed; see the JSON for actual success
    2   invalid arguments
    3   OpenCL loader is unavailable
    4   loader present but no ICD platform is registered
    5   no device matched the request
    6   an OpenCL command failed
    7   readback verification failed
"""

from __future__ import annotations

import ctypes
import hashlib
import json
import os
import struct
import sys

SCHEMA_VERSION = 1
EXIT_USAGE = 2
EXIT_LOADER = 3
EXIT_PLATFORM = 4
EXIT_DEVICE = 5
EXIT_COMMAND = 6
EXIT_VERIFY = 7

CL_SUCCESS = 0
CL_DEVICE_NOT_FOUND = -1
CL_PLATFORM_NOT_FOUND_KHR = -1001

CL_DEVICE_TYPE = 0x1000
CL_DEVICE_MAX_COMPUTE_UNITS = 0x1002
CL_DEVICE_MAX_WORK_GROUP_SIZE = 0x1004
CL_DEVICE_GLOBAL_MEM_SIZE = 0x101F
CL_DEVICE_AVAILABLE = 0x1027
CL_DEVICE_COMPILER_AVAILABLE = 0x1028
CL_DEVICE_NAME = 0x102B
CL_DEVICE_VENDOR = 0x102C
CL_DEVICE_DRIVER_VERSION = 0x102D
CL_DEVICE_VERSION = 0x102F
CL_DEVICE_OPENCL_C_VERSION = 0x103D
CL_PLATFORM_PROFILE = 0x0900
CL_PLATFORM_VERSION = 0x0901
CL_PLATFORM_NAME = 0x0902
CL_PLATFORM_VENDOR = 0x0903
CL_PROGRAM_BUILD_LOG = 0x1183

CL_DEVICE_TYPE_CPU = 1 << 1
CL_DEVICE_TYPE_GPU = 1 << 2
CL_DEVICE_TYPE_ACCELERATOR = 1 << 3
CL_DEVICE_TYPE_CUSTOM = 1 << 4
CL_DEVICE_TYPE_ALL = 0xFFFFFFFF

CL_MEM_READ_WRITE = 1 << 0
CL_TRUE = 1
CL_MAP_READ = 1 << 0

DEFAULT_SIZE_WORDS = 1024
MAX_SIZE_WORDS = 1 << 20
KERNEL_SIZE_WORDS = 65536

ERROR_NAMES = {
    0: "CL_SUCCESS",
    -1: "CL_DEVICE_NOT_FOUND",
    -2: "CL_DEVICE_NOT_AVAILABLE",
    -3: "CL_COMPILER_NOT_AVAILABLE",
    -4: "CL_MEM_OBJECT_ALLOCATION_FAILURE",
    -5: "CL_OUT_OF_RESOURCES",
    -6: "CL_OUT_OF_HOST_MEMORY",
    -7: "CL_PROFILING_INFO_NOT_AVAILABLE",
    -8: "CL_MEM_COPY_OVERLAP",
    -9: "CL_IMAGE_FORMAT_MISMATCH",
    -10: "CL_IMAGE_FORMAT_NOT_SUPPORTED",
    -11: "CL_BUILD_PROGRAM_FAILURE",
    -12: "CL_MAP_FAILURE",
    -13: "CL_MISALIGNED_SUB_BUFFER_OFFSET",
    -14: "CL_EXEC_STATUS_ERROR_FOR_EVENTS_IN_WAIT_LIST",
    -30: "CL_INVALID_VALUE",
    -31: "CL_INVALID_DEVICE_TYPE",
    -32: "CL_INVALID_PLATFORM",
    -33: "CL_INVALID_DEVICE",
    -34: "CL_INVALID_CONTEXT",
    -35: "CL_INVALID_QUEUE_PROPERTIES",
    -36: "CL_INVALID_COMMAND_QUEUE",
    -37: "CL_INVALID_HOST_PTR",
    -38: "CL_INVALID_MEM_OBJECT",
    -39: "CL_INVALID_IMAGE_FORMAT_DESCRIPTOR",
    -40: "CL_INVALID_IMAGE_SIZE",
    -41: "CL_INVALID_SAMPLER",
    -42: "CL_INVALID_BINARY",
    -43: "CL_INVALID_BUILD_OPTIONS",
    -44: "CL_INVALID_PROGRAM",
    -45: "CL_INVALID_PROGRAM_EXECUTABLE",
    -46: "CL_INVALID_KERNEL_NAME",
    -47: "CL_INVALID_KERNEL_DEFINITION",
    -48: "CL_INVALID_KERNEL",
    -49: "CL_INVALID_ARG_INDEX",
    -50: "CL_INVALID_ARG_VALUE",
    -51: "CL_INVALID_ARG_SIZE",
    -52: "CL_INVALID_KERNEL_ARGS",
    -53: "CL_INVALID_WORK_DIMENSION",
    -54: "CL_INVALID_WORK_GROUP_SIZE",
    -55: "CL_INVALID_WORK_ITEM_SIZE",
    -56: "CL_INVALID_GLOBAL_OFFSET",
    -57: "CL_INVALID_EVENT_WAIT_LIST",
    -58: "CL_INVALID_EVENT",
    -59: "CL_INVALID_OPERATION",
    -60: "CL_INVALID_GL_OBJECT",
    -68: "CL_INVALID_OPERATION",
    -1001: "CL_PLATFORM_NOT_FOUND_KHR",
}


class OpenCLError(RuntimeError):
    def __init__(self, operation: str, code: int) -> None:
        self.code = code
        super().__init__("%s failed: %s (%d)" % (operation, ERROR_NAMES.get(code, "CL_ERROR"), code))


def _text(value: bytes | None) -> str:
    if not value:
        return ""
    return value.decode("utf-8", "replace").replace("\x00", "").strip()[:512]


def _json(value: object) -> None:
    sys.stdout.write(json.dumps(value, ensure_ascii=False, sort_keys=True) + "\n")


class Loader:
    """Minimal binding for the stable OpenCL 1.2 C API."""

    def __init__(self, library: ctypes.CDLL, name: str) -> None:
        self.lib = library
        self.name = name
        self._bind()

    @classmethod
    def open(cls) -> "Loader | None":
        override = os.environ.get("FLOE_OPENCL_LIBRARY", "")
        if override:
            candidates = [override]
        elif sys.platform.startswith("linux"):
            candidates = [
                "libOpenCL.so.1", "libOpenCL.so",
                "/usr/lib/aarch64-linux-gnu/libOpenCL.so.1",
                "/usr/lib/libOpenCL.so.1",
                "/usr/local/lib/libOpenCL.so.1",
            ]
        else:
            return None
        for name in candidates:
            try:
                return cls(ctypes.CDLL(name), os.path.basename(name))
            except (OSError, AttributeError):
                continue
        return None

    def _bind(self) -> None:
        lib = self.lib
        lib.clGetPlatformIDs.argtypes = [ctypes.c_uint, ctypes.POINTER(ctypes.c_void_p),
                                         ctypes.POINTER(ctypes.c_uint)]
        lib.clGetPlatformIDs.restype = ctypes.c_int
        lib.clGetPlatformInfo.argtypes = [ctypes.c_void_p, ctypes.c_uint, ctypes.c_size_t,
                                          ctypes.c_void_p, ctypes.POINTER(ctypes.c_size_t)]
        lib.clGetPlatformInfo.restype = ctypes.c_int
        lib.clGetDeviceIDs.argtypes = [ctypes.c_void_p, ctypes.c_ulonglong, ctypes.c_uint,
                                       ctypes.POINTER(ctypes.c_void_p), ctypes.POINTER(ctypes.c_uint)]
        lib.clGetDeviceIDs.restype = ctypes.c_int
        lib.clGetDeviceInfo.argtypes = [ctypes.c_void_p, ctypes.c_uint, ctypes.c_size_t,
                                        ctypes.c_void_p, ctypes.POINTER(ctypes.c_size_t)]
        lib.clGetDeviceInfo.restype = ctypes.c_int
        lib.clCreateContext.argtypes = [ctypes.c_void_p, ctypes.c_uint, ctypes.POINTER(ctypes.c_void_p),
                                        ctypes.c_void_p, ctypes.c_void_p, ctypes.POINTER(ctypes.c_int)]
        lib.clCreateContext.restype = ctypes.c_void_p
        lib.clCreateCommandQueue.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_ulonglong,
                                             ctypes.POINTER(ctypes.c_int)]
        lib.clCreateCommandQueue.restype = ctypes.c_void_p
        lib.clCreateBuffer.argtypes = [ctypes.c_void_p, ctypes.c_ulonglong, ctypes.c_size_t,
                                       ctypes.c_void_p, ctypes.POINTER(ctypes.c_int)]
        lib.clCreateBuffer.restype = ctypes.c_void_p
        lib.clEnqueueWriteBuffer.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_uint,
                                             ctypes.c_size_t, ctypes.c_size_t, ctypes.c_void_p,
                                             ctypes.c_uint, ctypes.c_void_p, ctypes.c_void_p]
        lib.clEnqueueWriteBuffer.restype = ctypes.c_int
        try:
            lib.clEnqueueFillBuffer.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p,
                                                ctypes.c_size_t, ctypes.c_size_t, ctypes.c_size_t,
                                                ctypes.c_uint, ctypes.c_void_p, ctypes.c_void_p]
            lib.clEnqueueFillBuffer.restype = ctypes.c_int
        except AttributeError:
            lib.clEnqueueFillBuffer = None
        lib.clEnqueueCopyBuffer.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p,
                                            ctypes.c_size_t, ctypes.c_size_t, ctypes.c_size_t,
                                            ctypes.c_uint, ctypes.c_void_p, ctypes.c_void_p]
        lib.clEnqueueCopyBuffer.restype = ctypes.c_int
        lib.clEnqueueReadBuffer.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_uint,
                                            ctypes.c_size_t, ctypes.c_size_t, ctypes.c_void_p,
                                            ctypes.c_uint, ctypes.c_void_p, ctypes.c_void_p]
        lib.clEnqueueReadBuffer.restype = ctypes.c_int
        lib.clEnqueueMapBuffer.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_uint,
                                           ctypes.c_ulonglong, ctypes.c_size_t, ctypes.c_size_t,
                                           ctypes.c_uint, ctypes.c_void_p, ctypes.c_void_p,
                                           ctypes.POINTER(ctypes.c_int)]
        lib.clEnqueueMapBuffer.restype = ctypes.c_void_p
        lib.clEnqueueUnmapMemObject.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p,
                                                ctypes.c_uint, ctypes.c_void_p, ctypes.c_void_p]
        lib.clEnqueueUnmapMemObject.restype = ctypes.c_int
        lib.clFinish.argtypes = [ctypes.c_void_p]
        lib.clFinish.restype = ctypes.c_int
        lib.clCreateProgramWithSource.argtypes = [ctypes.c_void_p, ctypes.c_uint,
                                                  ctypes.POINTER(ctypes.c_char_p),
                                                  ctypes.POINTER(ctypes.c_size_t),
                                                  ctypes.POINTER(ctypes.c_int)]
        lib.clCreateProgramWithSource.restype = ctypes.c_void_p
        lib.clBuildProgram.argtypes = [ctypes.c_void_p, ctypes.c_uint, ctypes.POINTER(ctypes.c_void_p),
                                       ctypes.c_char_p, ctypes.c_void_p, ctypes.c_void_p]
        lib.clBuildProgram.restype = ctypes.c_int
        lib.clGetProgramBuildInfo.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_uint,
                                              ctypes.c_size_t, ctypes.c_void_p,
                                              ctypes.POINTER(ctypes.c_size_t)]
        lib.clGetProgramBuildInfo.restype = ctypes.c_int
        lib.clCreateKernel.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.POINTER(ctypes.c_int)]
        lib.clCreateKernel.restype = ctypes.c_void_p
        lib.clSetKernelArg.argtypes = [ctypes.c_void_p, ctypes.c_uint, ctypes.c_size_t, ctypes.c_void_p]
        lib.clSetKernelArg.restype = ctypes.c_int
        lib.clEnqueueNDRangeKernel.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_uint,
                                               ctypes.POINTER(ctypes.c_size_t), ctypes.POINTER(ctypes.c_size_t),
                                               ctypes.POINTER(ctypes.c_size_t), ctypes.c_uint,
                                               ctypes.c_void_p, ctypes.c_void_p]
        lib.clEnqueueNDRangeKernel.restype = ctypes.c_int
        for name in ("clReleaseMemObject", "clReleaseCommandQueue", "clReleaseContext",
                     "clReleaseProgram", "clReleaseKernel"):
            function = getattr(lib, name)
            function.argtypes = [ctypes.c_void_p]
            function.restype = ctypes.c_int


def _info_bytes(loader: Loader, function_name: str, handle: int, parameter: int) -> tuple[str, int]:
    function = getattr(loader.lib, function_name)
    size = ctypes.c_size_t(0)
    code = function(handle, parameter, 0, None, ctypes.byref(size))
    if code != CL_SUCCESS or size.value == 0:
        return "", code
    buffer = ctypes.create_string_buffer(size.value)
    code = function(handle, parameter, size.value, buffer, ctypes.byref(size))
    if code != CL_SUCCESS:
        return "", code
    return _text(buffer.raw[:size.value]), CL_SUCCESS


def _info_uint(loader: Loader, function_name: str, handle: int, parameter: int,
               size: int = 4) -> tuple[int | None, int]:
    function = getattr(loader.lib, function_name)
    buffer = ctypes.create_string_buffer(size)
    code = function(handle, parameter, size, buffer, None)
    if code != CL_SUCCESS:
        return None, code
    if size == 8:
        return int.from_bytes(buffer.raw, sys.byteorder), CL_SUCCESS
    return int.from_bytes(buffer.raw, sys.byteorder), CL_SUCCESS


def _device_type_name(value: int) -> str:
    if value & CL_DEVICE_TYPE_GPU:
        return "gpu"
    if value & CL_DEVICE_TYPE_CPU:
        return "cpu"
    if value & CL_DEVICE_TYPE_ACCELERATOR:
        return "accelerator"
    if value & CL_DEVICE_TYPE_CUSTOM:
        return "custom"
    return "unknown"


def icd_summary() -> dict:
    entries = 0
    directories = 0
    for directory in ("/etc/OpenCL/vendors", "/usr/share/OpenCL/vendors"):
        try:
            names = os.listdir(directory)
        except OSError:
            continue
        directories += 1
        entries += sum(1 for name in names if name.endswith(".icd"))
    env_names = ("OCL_ICD_VENDORS", "OCL_ICD_FILENAMES", "OPENCL_VENDOR_PATH")
    present = [name for name in env_names if os.environ.get(name)]
    for name in present:
        value = os.environ.get(name, "")
        if os.path.isdir(value):
            try:
                entries += sum(1 for item in os.listdir(value) if item.endswith(".icd"))
            except OSError:
                pass
        elif os.path.isfile(value):
            entries += 1
    return {"entryCount": entries, "directoriesPresent": directories, "environmentNames": present}


def enumerate_platforms(loader: Loader) -> tuple[list[dict], int]:
    count = ctypes.c_uint(0)
    code = loader.lib.clGetPlatformIDs(0, None, ctypes.byref(count))
    if code != CL_SUCCESS:
        return [], code
    if count.value == 0:
        return [], 0
    platforms = (ctypes.c_void_p * count.value)()
    code = loader.lib.clGetPlatformIDs(count.value, platforms, None)
    if code != CL_SUCCESS:
        return [], code
    result = []
    for index, platform in enumerate(platforms):
        name, name_code = _info_bytes(loader, "clGetPlatformInfo", platform, CL_PLATFORM_NAME)
        vendor, _ = _info_bytes(loader, "clGetPlatformInfo", platform, CL_PLATFORM_VENDOR)
        version, _ = _info_bytes(loader, "clGetPlatformInfo", platform, CL_PLATFORM_VERSION)
        profile, _ = _info_bytes(loader, "clGetPlatformInfo", platform, CL_PLATFORM_PROFILE)
        device_count = ctypes.c_uint(0)
        device_code = loader.lib.clGetDeviceIDs(platform, CL_DEVICE_TYPE_ALL, 0, None, ctypes.byref(device_count))
        devices: list[dict] = []
        if device_code == CL_SUCCESS:
            identifiers = (ctypes.c_void_p * device_count.value)()
            if device_count.value:
                device_code = loader.lib.clGetDeviceIDs(platform, CL_DEVICE_TYPE_ALL, device_count.value,
                                                        identifiers, None)
            if device_code == CL_SUCCESS:
                for device_index, device in enumerate(identifiers):
                    described = describe_device(loader, device, device_index)
                    described["_id"] = device
                    limitation = compute_probe_limitation(name, described)
                    if limitation:
                        described["computeProbeLimitation"] = limitation
                    devices.append(described)
        entry = {
            "_id": platform,
            "index": index,
            "name": name,
            "vendor": vendor,
            "version": version,
            "profile": profile,
            "deviceCount": len(devices),
            "deviceQueryError": None if device_code in (CL_SUCCESS, CL_DEVICE_NOT_FOUND)
                                     else ERROR_NAMES.get(device_code, str(device_code)),
            "devices": devices,
        }
        if name_code != CL_SUCCESS:
            entry["nameError"] = ERROR_NAMES.get(name_code, str(name_code))
        result.append(entry)
    return result, CL_SUCCESS


def describe_device(loader: Loader, device: int, index: int) -> dict:
    name, _ = _info_bytes(loader, "clGetDeviceInfo", device, CL_DEVICE_NAME)
    vendor, _ = _info_bytes(loader, "clGetDeviceInfo", device, CL_DEVICE_VENDOR)
    version, _ = _info_bytes(loader, "clGetDeviceInfo", device, CL_DEVICE_VERSION)
    driver, _ = _info_bytes(loader, "clGetDeviceInfo", device, CL_DEVICE_DRIVER_VERSION)
    opencl_c, _ = _info_bytes(loader, "clGetDeviceInfo", device, CL_DEVICE_OPENCL_C_VERSION)
    device_type, _ = _info_uint(loader, "clGetDeviceInfo", device, CL_DEVICE_TYPE, 8)
    available, _ = _info_uint(loader, "clGetDeviceInfo", device, CL_DEVICE_AVAILABLE)
    compiler, _ = _info_uint(loader, "clGetDeviceInfo", device, CL_DEVICE_COMPILER_AVAILABLE)
    units, _ = _info_uint(loader, "clGetDeviceInfo", device, CL_DEVICE_MAX_COMPUTE_UNITS)
    work_group, _ = _info_uint(loader, "clGetDeviceInfo", device, CL_DEVICE_MAX_WORK_GROUP_SIZE, 8)
    memory, _ = _info_uint(loader, "clGetDeviceInfo", device, CL_DEVICE_GLOBAL_MEM_SIZE, 8)
    return {
        "index": index,
        "name": name,
        "vendor": vendor,
        "version": version,
        "driverVersion": driver,
        "openclCVersion": opencl_c,
        "type": _device_type_name(device_type or 0),
        "typeBits": device_type,
        "available": bool(available) if available is not None else None,
        "compilerAvailable": bool(compiler) if compiler is not None else None,
        "maxComputeUnits": units,
        "maxWorkGroupSize": work_group,
        "globalMemoryBytes": memory,
    }


class Probe:
    def __init__(self, loader: Loader) -> None:
        self.loader = loader
        self.context = None
        self.queue = None

    def close(self) -> None:
        lib = self.loader.lib
        if self.queue:
            lib.clReleaseCommandQueue(self.queue)
            self.queue = None
        if self.context:
            lib.clReleaseContext(self.context)
            self.context = None

    def open(self, device: int) -> None:
        code = ctypes.c_int(0)
        devices = (ctypes.c_void_p * 1)(device)
        self.context = self.loader.lib.clCreateContext(None, 1, devices, None, None, ctypes.byref(code))
        if not self.context:
            raise OpenCLError("clCreateContext", code.value)
        self.queue = self.loader.lib.clCreateCommandQueue(self.context, device, 0, ctypes.byref(code))
        if not self.queue:
            raise OpenCLError("clCreateCommandQueue", code.value)

    def buffer(self, size: int) -> int:
        code = ctypes.c_int(0)
        memory = self.loader.lib.clCreateBuffer(self.context, CL_MEM_READ_WRITE, size, None, ctypes.byref(code))
        if not memory:
            raise OpenCLError("clCreateBuffer", code.value)
        return memory

    def write(self, memory: int, data: bytes) -> None:
        code = self.loader.lib.clEnqueueWriteBuffer(
            self.queue, memory, CL_TRUE, 0, len(data), ctypes.c_char_p(data), 0, None, None)
        if code != CL_SUCCESS:
            raise OpenCLError("clEnqueueWriteBuffer", code)

    def fill(self, memory: int, pattern: bytes, size: int) -> int:
        if self.loader.lib.clEnqueueFillBuffer is None:
            return -59
        code = self.loader.lib.clEnqueueFillBuffer(
            self.queue, memory, ctypes.c_char_p(pattern), len(pattern), 0, size, 0, None, None)
        return code

    def copy(self, source: int, destination: int, size: int) -> None:
        code = self.loader.lib.clEnqueueCopyBuffer(
            self.queue, source, destination, 0, 0, size, 0, None, None)
        if code != CL_SUCCESS:
            raise OpenCLError("clEnqueueCopyBuffer", code)

    def read(self, memory: int, size: int) -> bytes:
        output = ctypes.create_string_buffer(size)
        code = self.loader.lib.clEnqueueReadBuffer(
            self.queue, memory, CL_TRUE, 0, size, output, 0, None, None)
        if code != CL_SUCCESS:
            raise OpenCLError("clEnqueueReadBuffer", code)
        return output.raw

    def map_read(self, memory: int, size: int) -> bytes:
        code = ctypes.c_int(0)
        pointer = self.loader.lib.clEnqueueMapBuffer(
            self.queue, memory, CL_TRUE, CL_MAP_READ, 0, size, 0, None, None, ctypes.byref(code))
        if not pointer:
            raise OpenCLError("clEnqueueMapBuffer", code.value)
        try:
            data = ctypes.string_at(pointer, size)
        finally:
            self.loader.lib.clEnqueueUnmapMemObject(self.queue, memory, pointer, 0, None, None)
        return data

    def finish(self) -> None:
        code = self.loader.lib.clFinish(self.queue)
        if code != CL_SUCCESS:
            raise OpenCLError("clFinish", code)

    def release(self, memory: int) -> None:
        self.loader.lib.clReleaseMemObject(memory)

    def kernel(self, device: int, values: list[float], factor: float) -> dict:
        source = (b"__kernel void floe_scale(__global float *values, const float factor) {"
                  b" size_t i = get_global_id(0); values[i] = values[i] * factor; }")
        source_pointer = ctypes.c_char_p(source)
        source_size = ctypes.c_size_t(len(source))
        code = ctypes.c_int(0)
        program = self.loader.lib.clCreateProgramWithSource(
            self.context, 1, ctypes.byref(source_pointer), ctypes.byref(source_size), ctypes.byref(code))
        if not program:
            raise OpenCLError("clCreateProgramWithSource", code.value)
        kernel = None
        try:
            devices = (ctypes.c_void_p * 1)(device)
            build_code = self.loader.lib.clBuildProgram(program, 1, devices, b"", None, None)
            if build_code != CL_SUCCESS:
                log_size = ctypes.c_size_t(0)
                self.loader.lib.clGetProgramBuildInfo(program, device, CL_PROGRAM_BUILD_LOG,
                                                      0, None, ctypes.byref(log_size))
                log = ""
                if log_size.value:
                    log_buffer = ctypes.create_string_buffer(log_size.value)
                    self.loader.lib.clGetProgramBuildInfo(program, device, CL_PROGRAM_BUILD_LOG,
                                                          log_size.value, log_buffer, None)
                    log = _text(log_buffer.raw)
                raise OpenCLError("clBuildProgram %s" % log[:300], build_code)
            kernel = self.loader.lib.clCreateKernel(program, b"floe_scale", ctypes.byref(code))
            if not kernel:
                raise OpenCLError("clCreateKernel", code.value)
            input_buffer = ctypes.c_float * len(values)
            host_values = input_buffer(*values)
            memory = self.buffer(len(values) * 4)
            try:
                self.write(memory, bytes(host_values))
                code = self.loader.lib.clSetKernelArg(
                    kernel, 0, ctypes.sizeof(ctypes.c_void_p),
                    ctypes.byref(ctypes.c_void_p(memory)))
                if code != CL_SUCCESS:
                    raise OpenCLError("clSetKernelArg(buffer)", code)
                factor_value = ctypes.c_float(factor)
                code = self.loader.lib.clSetKernelArg(
                    kernel, 1, ctypes.sizeof(ctypes.c_float), ctypes.byref(factor_value))
                if code != CL_SUCCESS:
                    raise OpenCLError("clSetKernelArg(factor)", code)
                global_size = ctypes.c_size_t(len(values))
                code = self.loader.lib.clEnqueueNDRangeKernel(
                    self.queue, kernel, 1, None, ctypes.byref(global_size), None, 0, None, None)
                if code != CL_SUCCESS:
                    raise OpenCLError("clEnqueueNDRangeKernel", code)
                self.finish()
                actual = self.read(memory, len(values) * 4)
                expected = b"".join(struct.pack("=f", value * factor) for value in values)
                if actual != expected:
                    raise OpenCLError("kernel readback verification", EXIT_VERIFY)
                return {"status": "passed", "workItems": len(values), "factor": factor}
            finally:
                self.release(memory)
        finally:
            if kernel:
                self.loader.lib.clReleaseKernel(kernel)
            self.loader.lib.clReleaseProgram(program)


def _verify(label: str, actual: bytes, expected: bytes) -> dict:
    if actual == expected:
        return {
            "name": label,
            "match": True,
            "bytes": len(expected),
            "expectedSHA256": hashlib.sha256(expected).hexdigest(),
            "actualSHA256": hashlib.sha256(actual).hexdigest(),
        }
    mismatch = next((index for index, (left, right) in enumerate(zip(actual, expected)) if left != right), 0)
    return {
        "name": label,
        "match": False,
        "bytes": len(expected),
        "firstMismatch": mismatch,
        "expectedByte": expected[mismatch] if mismatch < len(expected) else None,
        "actualByte": actual[mismatch] if mismatch < len(actual) else None,
        "expectedSHA256": hashlib.sha256(expected).hexdigest(),
        "actualSHA256": hashlib.sha256(actual).hexdigest(),
    }


def compute_probe_limitation(platform_name: str, device: dict) -> str | None:
    # This exact Rusticl/Zink combination can terminate the Venus host when
    # binding its compute pipeline. Enumeration remains available.
    if (platform_name.lower() == "rusticl" and device.get("type") == "gpu"
            and device.get("driverVersion") == "25.0.7-2+deb13u1"
            and "Virtio-GPU Venus (Apple M5 Pro)" in device.get("name", "")
            and device.get("name", "").startswith("zink ")):
        return ("This Rusticl driver cannot run the OpenCL compute check on this GPU. "
                "Select another OpenCL device or use the Vulkan matrix check.")
    return None


def select_device(platforms: list[dict], requested: str) -> tuple[dict | None, dict | None]:
    wanted = {"gpu": "gpu", "cpu": "cpu"}.get(requested)
    candidates = []
    for platform in platforms:
        for device in platform.get("devices", []):
            if device.get("available") is False:
                continue
            if wanted is None or device.get("type") == wanted:
                candidates.append((platform, device))
    if not candidates:
        return None, None
    candidates.sort(key=lambda item: (
        bool(item[1].get("computeProbeLimitation")), item[1].get("type") != "gpu"
    ))
    platform, device = candidates[0]
    return platform, device


def _base_report(loader_name: str | None) -> dict:
    return {
        "schemaVersion": SCHEMA_VERSION,
        "loaderInstalled": loader_name is not None,
        "loader": loader_name or "",
        "icd": icd_summary(),
        "enumerated": False,
        "platforms": [],
        "errors": [],
    }


def command_status() -> tuple[dict, int]:
    loader = Loader.open()
    report = _base_report(loader.name if loader else None)
    if loader is None:
        report["errors"].append("OpenCL loader libOpenCL.so.1 is not installed")
        return report, EXIT_LOADER
    try:
        platforms, code = enumerate_platforms(loader)
    except Exception as error:  # noqa: BLE001 - report a bounded diagnostic
        report["errors"].append("enumeration failed: %s" % str(error)[:300])
        return report, EXIT_COMMAND
    if code != CL_SUCCESS:
        report["errors"].append("clGetPlatformIDs: %s" % ERROR_NAMES.get(code, str(code)))
        return report, EXIT_PLATFORM
    report["platforms"] = platforms
    report["enumerated"] = True
    clean_handles(platforms)
    if not platforms:
        report["errors"].append("no OpenCL ICD platform is registered")
        return report, EXIT_PLATFORM
    return report, CL_SUCCESS


class Options:
    def __init__(self, argv: list[str]) -> None:
        self.device = "any"
        self.size = DEFAULT_SIZE_WORDS
        self.kernel = "auto"
        index = 0
        while index < len(argv):
            argument = argv[index]
            if argument in ("--device", "--size", "--kernel"):
                if index + 1 >= len(argv):
                    raise ValueError("%s requires a value" % argument)
                value = argv[index + 1]
                index += 2
                if argument == "--device":
                    if value not in ("any", "gpu", "cpu"):
                        raise ValueError("--device must be any, gpu or cpu")
                    self.device = value
                elif argument == "--size":
                    try:
                        self.size = int(value, 10)
                    except ValueError as error:
                        raise ValueError("--size must be an integer") from error
                    if self.size < 1 or self.size > MAX_SIZE_WORDS:
                        raise ValueError("--size must be between 1 and %d words" % MAX_SIZE_WORDS)
                else:
                    if value not in ("auto", "on", "off"):
                        raise ValueError("--kernel must be auto, on or off")
                    self.kernel = value
            else:
                raise ValueError("unknown argument %s" % argument)
        if len(argv) == 0:
            raise ValueError("missing operation")


def clean_handles(platforms: list[dict]) -> None:
    for platform in platforms:
        platform.pop("_id", None)
        for device in platform.get("devices", []):
            device.pop("_id", None)


def main(argv: list[str]) -> int:
    if len(argv) < 2 or argv[1] not in ("status", "run"):
        sys.stderr.write("usage: floe-opencl-probe status|run [OPTIONS]\n")
        return EXIT_USAGE
    if argv[1] == "status":
        if len(argv) != 2:
            sys.stderr.write("usage: floe-opencl-probe status\n")
            return EXIT_USAGE
        report, code = command_status()
        _json(report)
        return code
    try:
        options = Options(argv[2:])
        loader = Loader.open()
        if loader is None:
            report = _base_report(None)
            report["errors"].append("OpenCL loader libOpenCL.so.1 is not installed")
            _json(report)
            return EXIT_LOADER
        platforms, platform_code = enumerate_platforms(loader)
        if platform_code != CL_SUCCESS or not platforms:
            report = _base_report(loader.name)
            report["errors"].append("clGetPlatformIDs: %s" % ERROR_NAMES.get(platform_code, str(platform_code)))
            _json(report)
            return EXIT_PLATFORM
        # Re-run the full command path against the same enumeration.
        report, code = command_run_with(options, loader, platforms)
        clean_handles(platforms)
        _json(report)
        return code
    except ValueError as error:
        sys.stderr.write("floe-opencl-probe: %s\n" % error)
        return EXIT_USAGE
    except Exception as error:  # noqa: BLE001 - a probe must return bounded JSON
        report = _base_report(None)
        report["errors"].append("unexpected probe failure: %s" % str(error)[:300])
        _json(report)
        return EXIT_COMMAND


def command_run_with(options: Options, loader: Loader, platforms: list[dict]) -> tuple[dict, int]:
    report = _base_report(loader.name)
    report["platforms"] = platforms
    report["enumerated"] = True
    platform, device = select_device(platforms, options.device)
    if device is None or "_id" not in device:
        report["errors"].append("no %s OpenCL device is available" % options.device)
        return report, EXIT_DEVICE
    report["selectedPlatform"] = platform["index"]
    report["selectedDevice"] = {key: value for key, value in device.items() if not key.startswith("_")}
    report["compute"] = {"requested": True, "success": False, "operations": []}
    if limitation := device.get("computeProbeLimitation"):
        report["errors"].append(limitation)
        return report, EXIT_DEVICE
    words = max(1, min(options.size, MAX_SIZE_WORDS))
    size = words * 4
    # OpenCL requires a fill pattern of 1..128 bytes.
    pattern = bytes(range(128))
    probe = Probe(loader)
    try:
        try:
            probe.open(device["_id"])
        except OpenCLError as error:
            report["errors"].append(str(error))
            return report, EXIT_COMMAND
        source = probe.buffer(size)
        destination = probe.buffer(size)
        try:
            fill_code = probe.fill(source, pattern, size)
            if fill_code == CL_SUCCESS:
                report["compute"]["operations"].append("fill")
            else:
                probe.write(source, pattern * (size // len(pattern)) + pattern[:size % len(pattern)])
                report["compute"]["operations"].append("host-write-fallback")
                report["compute"]["fillError"] = ERROR_NAMES.get(fill_code, str(fill_code))
            probe.copy(source, destination, size)
            report["compute"]["operations"].append("copy")
            probe.finish()
            expected = pattern * (size // len(pattern)) + pattern[:size % len(pattern)]
            readback = _verify("readback", probe.read(destination, size), expected)
            report["compute"]["operations"].append("readback")
            mapping = _verify("map", probe.map_read(destination, size), expected)
            report["compute"]["operations"].append("map")
            report["compute"]["verification"] = [readback, mapping]
            if not readback["match"] or not mapping["match"]:
                return report, EXIT_VERIFY
            if options.kernel == "off":
                report["compute"]["kernel"] = "skipped-by-request"
            elif not device.get("compilerAvailable"):
                report["compute"]["kernel"] = "skipped-no-compiler"
                if options.kernel == "on":
                    return report, EXIT_COMMAND
            else:
                count = min(words, KERNEL_SIZE_WORDS)
                values = [float(index + 1) for index in range(count)]
                report["compute"]["kernel"] = probe.kernel(device["_id"], values, 2.0)
                report["compute"]["operations"].append("kernel")
            report["compute"]["success"] = True
            return report, CL_SUCCESS
        finally:
            probe.release(source)
            probe.release(destination)
    except OpenCLError as error:
        report["compute"]["success"] = False
        report["errors"].append(str(error))
        return report, EXIT_VERIFY if error.code == EXIT_VERIFY else EXIT_COMMAND
    finally:
        probe.close()


if __name__ == "__main__":
    sys.exit(main(sys.argv))
