#!/usr/bin/env python3
# SPDX-License-Identifier: MPL-2.0
"""Floe OpenGL/GLX and headless EGL probe.

This program only uses the Linux graphics libraries already installed in the
project guest. It does not install packages, start a display server or fall
back to the native host. A successful report means a real context was created
and a real pixel readback matched; renderer names alone are not acceleration
proof.

Usage:
    floe-gl-probe glx       # needs DISPLAY and libGL/libX11
    floe-gl-probe egl       # headless surfaceless/platform EGL

Output is a single JSON object on stdout. Exit codes:
    0   context created, render submitted and readback verified
    2   invalid arguments
    69  required display/library/platform is unavailable
    70  the context/render/readback failed
"""

from __future__ import annotations

import ctypes
import json
import os
import sys

SCHEMA_VERSION = 1
EXIT_USAGE = 2
EXIT_MISSING = 69
EXIT_FAILED = 70

# GL constants (public Khronos values; no OpenGL headers are required).
GL_VENDOR = 0x1F00
GL_RENDERER = 0x1F01
GL_VERSION = 0x1F02
GL_COLOR_BUFFER_BIT = 0x00004000
GL_FRAMEBUFFER = 0x8D40
GL_RENDERBUFFER = 0x8D41
GL_COLOR_ATTACHMENT0 = 0x8CE0
GL_FRAMEBUFFER_COMPLETE = 0x8CD5
GL_RGBA = 0x1908
GL_RGBA8 = 0x8058
GL_UNSIGNED_BYTE = 0x1401
GL_PACK_ALIGNMENT = 0x0D05
GL_READ_FRAMEBUFFER = 0x8CA8
GL_DRAW_FRAMEBUFFER = 0x8CA9
GL_BACK = 0x0405
GL_FRONT = 0x0404
GL_NO_ERROR = 0

# GLX constants.
GLX_X_RENDERABLE = 0x8012
GLX_DRAWABLE_TYPE = 0x8010
GLX_PBUFFER_BIT = 0x00000004
GLX_RENDER_TYPE = 0x8011
GLX_RGBA_BIT = 0x00000001
GLX_RED_SIZE = 8
GLX_GREEN_SIZE = 9
GLX_BLUE_SIZE = 10
GLX_ALPHA_SIZE = 11
GLX_PBUFFER_WIDTH = 0x8041
GLX_PBUFFER_HEIGHT = 0x8040
GLX_RGBA_TYPE = 0x8014

# EGL constants.
EGL_DEFAULT_DISPLAY = ctypes.c_void_p(0)
EGL_NO_CONTEXT = ctypes.c_void_p(0)
EGL_NO_SURFACE = ctypes.c_void_p(0)
EGL_NONE = 0x3038
EGL_VENDOR = 0x3053
EGL_VERSION = 0x3054
EGL_CLIENT_APIS = 0x308D
EGL_SURFACE_TYPE = 0x3033
EGL_PBUFFER_BIT = 0x0001
EGL_RENDERABLE_TYPE = 0x3040
EGL_OPENGL_ES2_BIT = 0x0004
EGL_OPENGL_ES3_BIT = 0x00000040
EGL_RED_SIZE = 0x3024
EGL_GREEN_SIZE = 0x3023
EGL_BLUE_SIZE = 0x3022
EGL_ALPHA_SIZE = 0x3021
EGL_WIDTH = 0x3057
EGL_HEIGHT = 0x3056
EGL_CONTEXT_CLIENT_VERSION = 0x3098
EGL_OPENGL_ES_API = 0x30A0
EGL_PLATFORM_SURFACELESS_MESA = 0x31DD

SOFTWARE_MARKERS = ("llvmpipe", "softpipe", "swrast", "software rasterizer", "lavapipe", "mesa offscreen")
HARDWARE_MARKERS = ("venus", "virtio", "apple", "mali", "adreno", "powervr", "intel", "amd", "nvidia", "radeon")

SIZE = 16
EXPECTED = bytes((64, 128, 191, 255))


class ProbeError(RuntimeError):
    def __init__(self, message: str, code: int = EXIT_FAILED) -> None:
        super().__init__(message)
        self.code = code


def _text(value: bytes | None) -> str:
    if not value:
        return ""
    return value.decode("utf-8", "replace").replace("\x00", "").strip()[:512]


def classify(renderer: str) -> tuple[bool | None, bool | None]:
    """Return (hardware, software). Unknown is None, never a guess."""
    lowered = renderer.lower()
    if any(marker in lowered for marker in SOFTWARE_MARKERS):
        return False, True
    if any(marker in lowered for marker in HARDWARE_MARKERS):
        return True, False
    return None, None


def _json(value: object) -> None:
    sys.stdout.write(json.dumps(value, ensure_ascii=False, sort_keys=True) + "\n")


def _report(probe: str, **fields: object) -> dict:
    base = {
        "schemaVersion": SCHEMA_VERSION,
        "probe": probe,
        "available": False,
        "rendered": False,
        "api": "OpenGL ES" if probe == "egl" else "OpenGL",
        "vendor": "",
        "renderer": "",
        "version": "",
        "hardware": None,
        "software": None,
        "readback": None,
        "error": "",
    }
    base.update(fields)
    renderer = str(base.get("renderer") or "")
    if renderer:
        hardware, software = classify(renderer)
        if base.get("hardware") is None:
            base["hardware"] = hardware
        if base.get("software") is None:
            base["software"] = software
    return base


def _check_pixel(pixels: bytes) -> dict:
    if len(pixels) < SIZE * SIZE * 4:
        raise ProbeError("readback returned fewer pixels than requested")
    mismatches = 0
    first = -1
    for index in range(SIZE * SIZE):
        actual = pixels[index * 4:index * 4 + 4]
        if actual != EXPECTED:
            mismatches += 1
            if first < 0:
                first = index
    if mismatches:
        raise ProbeError(
            "readback mismatch: %d/%d pixels differ (first=%d, actual=%s, expected=%s)"
            % (mismatches, SIZE * SIZE, first,
               list(pixels[first * 4:first * 4 + 4]) if first >= 0 else [],
               list(EXPECTED)))
    return {
        "width": SIZE,
        "height": SIZE,
        "expectedRGBA": list(EXPECTED),
        "actualRGBA": list(pixels[:4]),
        "match": True,
    }


def _gl_functions(get_proc: ctypes._CFuncPtr, names: dict[str, tuple],
                  optional: tuple[str, ...] = ()) -> dict[str, object]:
    result: dict[str, object] = {}
    for name, signature in names.items():
        address = get_proc(name.encode("ascii"))
        if not address:
            if name in optional:
                result[name] = None
                continue
            raise ProbeError("required GL function %s is unavailable" % name)
        result[name] = ctypes.CFUNCTYPE(*signature)(address)
    return result


FBO_FUNCTIONS = (
    "glGenFramebuffers", "glBindFramebuffer", "glGenRenderbuffers",
    "glBindRenderbuffer", "glRenderbufferStorage", "glFramebufferRenderbuffer",
    "glCheckFramebufferStatus", "glDeleteRenderbuffers", "glDeleteFramebuffers",
)
OPTIONAL_GL = FBO_FUNCTIONS + ("glReadBuffer",)


def _string(fn: object, name: int) -> str:
    return _text(fn(name))  # type: ignore[operator]


def _render_fbo(gl: dict[str, object]) -> dict:
    if any(gl.get(name) is None for name in FBO_FUNCTIONS):
        raise ProbeError("framebuffer functions are unavailable")
    fbo = ctypes.c_uint(0)
    rbo = ctypes.c_uint(0)
    gl["glGenFramebuffers"](1, ctypes.byref(fbo))  # type: ignore[index]
    gl["glBindFramebuffer"](GL_FRAMEBUFFER, fbo)  # type: ignore[index]
    gl["glGenRenderbuffers"](1, ctypes.byref(rbo))  # type: ignore[index]
    gl["glBindRenderbuffer"](GL_RENDERBUFFER, rbo)  # type: ignore[index]
    gl["glRenderbufferStorage"](GL_RENDERBUFFER, GL_RGBA8, SIZE, SIZE)  # type: ignore[index]
    gl["glFramebufferRenderbuffer"](GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER, rbo)  # type: ignore[index]
    status = gl["glCheckFramebufferStatus"](GL_FRAMEBUFFER)  # type: ignore[index]
    if status != GL_FRAMEBUFFER_COMPLETE:
        raise ProbeError("framebuffer is incomplete (0x%04x)" % status)
    try:
        gl["glViewport"](0, 0, SIZE, SIZE)  # type: ignore[index]
        gl["glClearColor"](0.25, 0.5, 0.75, 1.0)  # type: ignore[index]
        gl["glClear"](GL_COLOR_BUFFER_BIT)  # type: ignore[index]
        gl["glFinish"]()  # type: ignore[index]
        pixels = ctypes.create_string_buffer(SIZE * SIZE * 4)
        gl["glPixelStorei"](GL_PACK_ALIGNMENT, 1)  # type: ignore[index]
        gl["glReadPixels"](0, 0, SIZE, SIZE, GL_RGBA, GL_UNSIGNED_BYTE, pixels)  # type: ignore[index]
        gl["glFinish"]()  # type: ignore[index]
        error = gl["glGetError"]()  # type: ignore[index]
        if error != GL_NO_ERROR:
            raise ProbeError("GL error 0x%04x after readback" % error)
        return _check_pixel(pixels.raw)
    finally:
        gl["glBindFramebuffer"](GL_FRAMEBUFFER, ctypes.c_uint(0))  # type: ignore[index]
        if rbo.value:
            gl["glDeleteRenderbuffers"](1, ctypes.byref(rbo))  # type: ignore[index]
        if fbo.value:
            gl["glDeleteFramebuffers"](1, ctypes.byref(fbo))  # type: ignore[index]


def _render_pbuffer(gl: dict[str, object], read_buffer: int | None = None) -> dict:
    gl["glViewport"](0, 0, SIZE, SIZE)  # type: ignore[index]
    if read_buffer is not None and gl.get("glReadBuffer") is not None:
        gl["glReadBuffer"](read_buffer)  # type: ignore[index]
    gl["glClearColor"](0.25, 0.5, 0.75, 1.0)  # type: ignore[index]
    gl["glClear"](GL_COLOR_BUFFER_BIT)  # type: ignore[index]
    gl["glFinish"]()  # type: ignore[index]
    pixels = ctypes.create_string_buffer(SIZE * SIZE * 4)
    gl["glPixelStorei"](GL_PACK_ALIGNMENT, 1)  # type: ignore[index]
    gl["glReadPixels"](0, 0, SIZE, SIZE, GL_RGBA, GL_UNSIGNED_BYTE, pixels)  # type: ignore[index]
    gl["glFinish"]()  # type: ignore[index]
    error = gl["glGetError"]()  # type: ignore[index]
    if error != GL_NO_ERROR:
        raise ProbeError("GL error 0x%04x after pbuffer readback" % error)
    return _check_pixel(pixels.raw)


GL_CORE = {
    "glGetString": (ctypes.c_char_p, ctypes.c_uint),
    "glGetError": (ctypes.c_uint,),
    "glViewport": (None, ctypes.c_int, ctypes.c_int, ctypes.c_int, ctypes.c_int),
    "glClearColor": (None, ctypes.c_float, ctypes.c_float, ctypes.c_float, ctypes.c_float),
    "glClear": (None, ctypes.c_uint),
    "glFinish": (None,),
    "glReadPixels": (None, ctypes.c_int, ctypes.c_int, ctypes.c_int, ctypes.c_int,
                     ctypes.c_uint, ctypes.c_uint, ctypes.c_void_p),
    "glPixelStorei": (None, ctypes.c_uint, ctypes.c_int),
    "glReadBuffer": (None, ctypes.c_uint),
    "glGenFramebuffers": (None, ctypes.c_int, ctypes.POINTER(ctypes.c_uint)),
    "glBindFramebuffer": (None, ctypes.c_uint, ctypes.c_uint),
    "glGenRenderbuffers": (None, ctypes.c_int, ctypes.POINTER(ctypes.c_uint)),
    "glBindRenderbuffer": (None, ctypes.c_uint, ctypes.c_uint),
    "glRenderbufferStorage": (None, ctypes.c_uint, ctypes.c_uint, ctypes.c_int, ctypes.c_int),
    "glFramebufferRenderbuffer": (None, ctypes.c_uint, ctypes.c_uint, ctypes.c_uint, ctypes.c_uint),
    "glCheckFramebufferStatus": (ctypes.c_uint, ctypes.c_uint),
    "glDeleteRenderbuffers": (None, ctypes.c_int, ctypes.POINTER(ctypes.c_uint)),
    "glDeleteFramebuffers": (None, ctypes.c_int, ctypes.POINTER(ctypes.c_uint)),
}


def probe_glx() -> dict:
    display_name = os.environ.get("DISPLAY", "")
    if not display_name:
        raise ProbeError("DISPLAY is not set. Open Screen in Floe first.", EXIT_MISSING)
    try:
        x11 = ctypes.CDLL("libX11.so.6")
        gl = ctypes.CDLL("libGL.so.1")
    except OSError as error:
        raise ProbeError("OpenGL/X11 libraries are unavailable: %s" % error, EXIT_MISSING)

    x11.XOpenDisplay.argtypes = [ctypes.c_char_p]
    x11.XOpenDisplay.restype = ctypes.c_void_p
    x11.XCloseDisplay.argtypes = [ctypes.c_void_p]
    x11.XFree.argtypes = [ctypes.c_void_p]
    gl.glXQueryVersion.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_int), ctypes.POINTER(ctypes.c_int)]
    gl.glXQueryVersion.restype = ctypes.c_int
    gl.glXChooseFBConfig.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.POINTER(ctypes.c_int),
                                     ctypes.POINTER(ctypes.c_int)]
    gl.glXChooseFBConfig.restype = ctypes.POINTER(ctypes.c_void_p)
    gl.glXCreateNewContext.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_int, ctypes.c_void_p, ctypes.c_int]
    gl.glXCreateNewContext.restype = ctypes.c_void_p
    gl.glXCreatePbuffer.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.POINTER(ctypes.c_int)]
    gl.glXCreatePbuffer.restype = ctypes.c_ulong
    gl.glXMakeContextCurrent.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.c_ulong, ctypes.c_void_p]
    gl.glXMakeContextCurrent.restype = ctypes.c_int
    gl.glXDestroyPbuffer.argtypes = [ctypes.c_void_p, ctypes.c_ulong]
    gl.glXDestroyContext.argtypes = [ctypes.c_void_p, ctypes.c_void_p]
    gl.glXGetProcAddressARB.argtypes = [ctypes.c_char_p]
    gl.glXGetProcAddressARB.restype = ctypes.c_void_p

    display = x11.XOpenDisplay(display_name.encode("utf-8"))
    if not display:
        raise ProbeError("cannot open X display %s" % display_name, EXIT_MISSING)
    context = ctypes.c_void_p(0)
    pbuffer = ctypes.c_ulong(0)
    try:
        major = ctypes.c_int(0)
        minor = ctypes.c_int(0)
        if not gl.glXQueryVersion(display, ctypes.byref(major), ctypes.byref(minor)):
            raise ProbeError("glXQueryVersion failed")
        attributes = (ctypes.c_int * 17)(
            GLX_X_RENDERABLE, 1, GLX_DRAWABLE_TYPE, GLX_PBUFFER_BIT,
            GLX_RENDER_TYPE, GLX_RGBA_BIT, GLX_RED_SIZE, 8, GLX_GREEN_SIZE, 8,
            GLX_BLUE_SIZE, 8, GLX_ALPHA_SIZE, 8, 0, 0, 0)
        count = ctypes.c_int(0)
        configs = gl.glXChooseFBConfig(display, 0, attributes, ctypes.byref(count))
        if not configs or count.value < 1:
            raise ProbeError("no GLX framebuffer configuration is available")
        config = ctypes.c_void_p(configs[0])
        context = ctypes.c_void_p(gl.glXCreateNewContext(display, config, GLX_RGBA_TYPE, None, 1))
        if not context:
            raise ProbeError("glXCreateNewContext failed")
        pbuffer_attributes = (ctypes.c_int * 5)(GLX_PBUFFER_WIDTH, SIZE, GLX_PBUFFER_HEIGHT, SIZE, 0)
        pbuffer = ctypes.c_ulong(gl.glXCreatePbuffer(display, config, pbuffer_attributes))
        if not pbuffer:
            raise ProbeError("glXCreatePbuffer failed")
        if not gl.glXMakeContextCurrent(display, pbuffer, pbuffer, context):
            raise ProbeError("glXMakeContextCurrent failed")
        functions = _gl_functions(gl.glXGetProcAddressARB, GL_CORE, OPTIONAL_GL)
        renderer = _string(functions["glGetString"], GL_RENDERER)
        version = _string(functions["glGetString"], GL_VERSION)
        vendor = _string(functions["glGetString"], GL_VENDOR)
        if not renderer:
            raise ProbeError("GL_RENDERER is empty")
        try:
            readback = _render_fbo(functions)
        except ProbeError:
            readback = _render_pbuffer(functions, GL_FRONT)
        return _report("glx", available=True, rendered=True, vendor=vendor, renderer=renderer,
                       version=version, display=display_name,
                       glxVersion="%d.%d" % (major.value, minor.value), readback=readback)
    finally:
        gl.glXMakeContextCurrent(display, 0, 0, None)
        if pbuffer.value:
            gl.glXDestroyPbuffer(display, pbuffer)
        if context:
            gl.glXDestroyContext(display, context)
        x11.XCloseDisplay(display)


def _egl_function(egl: ctypes.CDLL, name: str, signature: tuple):
    address = egl.eglGetProcAddress(name.encode("ascii"))
    if not address:
        raise ProbeError("required EGL function %s is unavailable" % name, EXIT_MISSING)
    return ctypes.CFUNCTYPE(*signature)(address)


def probe_egl() -> dict:
    try:
        egl = ctypes.CDLL("libEGL.so.1")
    except OSError as error:
        raise ProbeError("EGL library is unavailable: %s" % error, EXIT_MISSING)
    egl.eglGetProcAddress.argtypes = [ctypes.c_char_p]
    egl.eglGetProcAddress.restype = ctypes.c_void_p
    egl.eglGetDisplay.argtypes = [ctypes.c_void_p]
    egl.eglGetDisplay.restype = ctypes.c_void_p
    egl.eglInitialize.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_int), ctypes.POINTER(ctypes.c_int)]
    egl.eglInitialize.restype = ctypes.c_uint
    egl.eglQueryString.argtypes = [ctypes.c_void_p, ctypes.c_int]
    egl.eglQueryString.restype = ctypes.c_char_p
    egl.eglBindAPI.argtypes = [ctypes.c_uint]
    egl.eglBindAPI.restype = ctypes.c_uint
    egl.eglChooseConfig.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_int),
                                    ctypes.POINTER(ctypes.c_void_p), ctypes.c_int,
                                    ctypes.POINTER(ctypes.c_int)]
    egl.eglChooseConfig.restype = ctypes.c_uint
    egl.eglCreateContext.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p,
                                     ctypes.POINTER(ctypes.c_int)]
    egl.eglCreateContext.restype = ctypes.c_void_p
    egl.eglCreatePbufferSurface.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.POINTER(ctypes.c_int)]
    egl.eglCreatePbufferSurface.restype = ctypes.c_void_p
    egl.eglMakeCurrent.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p]
    egl.eglMakeCurrent.restype = ctypes.c_uint
    egl.eglDestroySurface.argtypes = [ctypes.c_void_p, ctypes.c_void_p]
    egl.eglDestroyContext.argtypes = [ctypes.c_void_p, ctypes.c_void_p]
    egl.eglTerminate.argtypes = [ctypes.c_void_p]

    display = None
    platform = None
    try:
        get_platform = _egl_function(egl, "eglGetPlatformDisplayEXT",
                                     (ctypes.c_void_p, ctypes.c_uint, ctypes.c_void_p))
        platform = get_platform(EGL_PLATFORM_SURFACELESS_MESA, None, None)
    except ProbeError:
        platform = None
    if not platform:
        platform = egl.eglGetDisplay(EGL_DEFAULT_DISPLAY)
    if not platform:
        raise ProbeError("EGL cannot obtain a headless display", EXIT_MISSING)
    display = platform
    major = ctypes.c_int(0)
    minor = ctypes.c_int(0)
    if not egl.eglInitialize(display, ctypes.byref(major), ctypes.byref(minor)):
        raise ProbeError("eglInitialize failed (0x%04x)" % ctypes.get_errno(), EXIT_MISSING)
    if not egl.eglBindAPI(EGL_OPENGL_ES_API):
        raise ProbeError("eglBindAPI(OpenGL ES) failed")
    configs = (ctypes.c_void_p * 1)()
    count = ctypes.c_int(0)
    chosen = None
    for renderable in (EGL_OPENGL_ES3_BIT, EGL_OPENGL_ES2_BIT):
        attributes = (ctypes.c_int * 15)(
            EGL_SURFACE_TYPE, EGL_PBUFFER_BIT,
            EGL_RENDERABLE_TYPE, renderable,
            EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8, EGL_ALPHA_SIZE, 8,
            EGL_NONE, 0, 0)
        if egl.eglChooseConfig(display, attributes, configs, 1, ctypes.byref(count)) and count.value >= 1:
            chosen = configs[0]
            break
    if not chosen:
        raise ProbeError("no headless EGL configuration is available")
    context = None
    surface = None
    try:
        for client_version in (3, 2):
            context_attributes = (ctypes.c_int * 3)(EGL_CONTEXT_CLIENT_VERSION, client_version, EGL_NONE)
            context = egl.eglCreateContext(display, chosen, EGL_NO_CONTEXT, context_attributes)
            if context:
                break
        if not context:
            raise ProbeError("eglCreateContext failed")
        surface_attributes = (ctypes.c_int * 5)(EGL_WIDTH, SIZE, EGL_HEIGHT, SIZE, EGL_NONE)
        surface = egl.eglCreatePbufferSurface(display, chosen, surface_attributes)
        if not surface:
            raise ProbeError("eglCreatePbufferSurface failed")
        if not egl.eglMakeCurrent(display, surface, surface, context):
            raise ProbeError("eglMakeCurrent failed")
        functions = _gl_functions(egl.eglGetProcAddress, GL_CORE, OPTIONAL_GL)
        renderer = _string(functions["glGetString"], GL_RENDERER)
        version = _string(functions["glGetString"], GL_VERSION)
        vendor = _string(functions["glGetString"], GL_VENDOR)
        if not renderer:
            raise ProbeError("GL_RENDERER is empty")
        try:
            readback = _render_fbo(functions)
        except ProbeError:
            readback = _render_pbuffer(functions)
        return _report("egl", available=True, rendered=True, vendor=vendor, renderer=renderer,
                       version=version, display="surfaceless",
                       eglVersion=_text(egl.eglQueryString(display, EGL_VERSION)),
                       eglVendor=_text(egl.eglQueryString(display, EGL_VENDOR)),
                       eglClientAPIs=_text(egl.eglQueryString(display, EGL_CLIENT_APIS)),
                       readback=readback)
    finally:
        egl.eglMakeCurrent(display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT)
        if surface:
            egl.eglDestroySurface(display, surface)
        if context:
            egl.eglDestroyContext(display, context)
        egl.eglTerminate(display)


def main(argv: list[str]) -> int:
    if len(argv) != 2 or argv[1] not in ("glx", "egl"):
        sys.stderr.write("usage: floe-gl-probe glx|egl\n")
        return EXIT_USAGE
    probe = argv[1]
    try:
        report = probe_glx() if probe == "glx" else probe_egl()
        _json(report)
        return 0
    except ProbeError as error:
        _json(_report(probe, error=str(error)[:512]))
        return error.code
    except Exception as error:  # noqa: BLE001 - a probe must not traceback
        _json(_report(probe, error="unexpected probe failure: %s" % str(error)[:512]))
        return EXIT_FAILED


if __name__ == "__main__":
    sys.exit(main(sys.argv))
