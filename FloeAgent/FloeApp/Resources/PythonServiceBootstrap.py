"""Invocation-local setup for a managed Python service sub-interpreter.

Injected values: _floe_context, _floe_source, _floe_cancelled(),
_floe_write(channel, text). This is lifecycle and path virtualization, not a
security boundary against native code in the same process.
"""
import builtins
import functools
import io
import os
import sys
import threading
import traceback
import socket


def _install_context(context):
    cwd = os.path.abspath(context["workingDirectory"])
    if not os.path.isdir(cwd):
        raise ValueError("Service working directory does not exist")
    # os.environ normally calls the process-wide putenv. Services must not
    # change the environment of the app or the foreground interpreter.
    os.environ = dict(context.get("environment", {}))
    os.putenv = lambda name, value: os.environ.__setitem__(os.fsdecode(name), os.fsdecode(value))
    os.unsetenv = lambda name: os.environ.pop(os.fsdecode(name), None)

    def absolute(value):
        if value is None:
            return cwd
        if isinstance(value, int):
            return value
        path = os.fspath(value)
        base = os.fsencode(cwd) if isinstance(path, bytes) else cwd
        return path if os.path.isabs(path) else os.path.join(base, path)

    original_isdir = os.path.isdir

    def chdir(path):
        nonlocal cwd
        target = os.fsdecode(absolute(path))
        if not original_isdir(target):
            raise NotADirectoryError(target)
        cwd = os.path.normpath(target)

    os.getcwd = lambda: cwd
    os.getcwdb = lambda: os.fsencode(cwd)
    os.chdir = chdir
    # A raw fchdir would change the shared process cwd. Callers can use a
    # pathname with chdir; do not pretend this operation is isolated.
    def unsupported(*args, **kwargs):
        raise RuntimeError("This process-wide operation is unavailable in a managed Python service")
    os.fchdir = unsupported
    os._exit = unsupported

    def wrap(function, positions=(0,), keywords=("path",), default_path=False):
        @functools.wraps(function)
        def call(*args, **kwargs):
            values = list(args)
            if default_path and not values and not any(key in kwargs for key in keywords):
                values.append(cwd)
            for index in positions:
                if index < len(values):
                    # Relative paths paired with an explicit descriptor are
                    # already anchored by the OS and must stay relative.
                    fd_key = "dir_fd" if len(positions) == 1 else ("src_dir_fd" if index == 0 else "dst_dir_fd")
                    if kwargs.get(fd_key) is None:
                        values[index] = absolute(values[index])
            for key in keywords:
                if key in kwargs:
                    fd_key = "src_dir_fd" if key == "src" else "dst_dir_fd" if key == "dst" else "dir_fd"
                    if kwargs.get(fd_key) is None:
                        kwargs[key] = absolute(kwargs[key])
            return function(*values, **kwargs)
        return call

    builtins.open = wrap(builtins.open, keywords=("file",))
    io.open = wrap(io.open, keywords=("file",))
    for name in ("open", "stat", "lstat", "access", "mkdir", "rmdir", "remove", "unlink", "chmod", "chown", "readlink", "utime", "truncate"):
        if hasattr(os, name):
            setattr(os, name, wrap(getattr(os, name)))
    for name in ("listdir", "scandir"):
        setattr(os, name, wrap(getattr(os, name), default_path=True))
    for name in ("rename", "replace", "link"):
        setattr(os, name, wrap(getattr(os, name), positions=(0, 1), keywords=("src", "dst")))
    os.symlink = wrap(os.symlink, positions=(1,), keywords=("dst",))
    sys.path[:0] = [cwd] + [p for p in os.environ.get("PYTHONPATH", "").split(os.pathsep) if p]
    # Preview services are local to this device. Do not accidentally publish
    # an author-supplied 0.0.0.0 listener to the user's network.
    original_bind = socket.socket.bind
    def loopback_bind(sock, address):
        if sock.family in (socket.AF_INET, socket.AF_INET6):
            if not isinstance(address, tuple) or address[0] not in ("127.0.0.1", "::1", "localhost"):
                raise ValueError("Preview services must bind to 127.0.0.1 or ::1")
        else:
            raise ValueError("Preview services support only loopback TCP/UDP sockets")
        return original_bind(sock, address)
    socket.socket.bind = loopback_bind
    sys.argv = context.get("arguments", ["service.py"])
    sys.stdin = io.StringIO(context.get("standardInput", ""))


class _ServiceOutput:
    encoding = "utf-8"
    errors = "replace"
    def __init__(self, channel):
        self.channel = channel
    def write(self, text):
        value = str(text)
        _floe_write(self.channel, value)
        return len(value)
    def flush(self):
        pass
    def isatty(self):
        return False


def _service_trace(frame, event, arg):
    if _floe_cancelled():
        raise InterruptedError("Python service stopped")
    return _service_trace


_install_context(_floe_context)
sys.stdout = _ServiceOutput("stdout")
sys.stderr = _ServiceOutput("stderr")
# Pure Python HTTP servers may use worker threads. Trace their Python code
# too; native blocking work is still retained until it actually exits.
threading.settrace(_service_trace)
sys.settrace(_service_trace)
try:
    namespace = {"__builtins__": builtins, "__name__": "__main__", "__file__": os.path.join(os.getcwd(), "service.py")}
    exec(compile(_floe_source, namespace["__file__"], "exec"), namespace, namespace)
except InterruptedError:
    if not _floe_cancelled():
        raise
except BaseException:
    traceback.print_exc()
    raise
finally:
    sys.settrace(None)
    threading.settrace(None)
