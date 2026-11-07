"""Shared validation and encoding helpers for the trusted biology worker.

No I/O beyond the host-configured scoped work directory, no eval/exec/pickle/subprocess.
Every helper fails closed with ValueError and a precise message.
"""
import base64
import binascii
import math
import os
import pathlib
import re
import contextvars
import contextlib
import hashlib
import io
import stat

WORKSPACE = contextvars.ContextVar('biology_workspace', default=None)

class _NamedReader:
    """Preserve the verified descriptor while supplying a textual name to
    scientific libraries that cannot accept fdopen's integer .name value."""
    def __init__(self,stream,path):self.stream=stream;self.name=str(path)
    def __getattr__(self,key):return getattr(self.stream,key)

@contextlib.contextmanager
def source_file(asset):
    """Only a trusted CLI workspace can resolve a file identity. Model-supplied
    paths are never used. Hash verification streams bounded chunks before any
    scientific parser sees the bytes, including compressed/TIFF/HDF5 inputs."""
    ref = asset.get('fileReference')
    if not ref:
        raw = base64.b64decode(asset['originalData'], validate=True)
        if len(raw) > 16*1024*1024:
            raise ValueError('Inline original exceeds its input budget')
        with io.BytesIO(raw) as stream:
            yield stream
        return
    root = WORKSPACE.get()
    if root is None:
        raise ValueError('File input requires the host-configured worker workspace')
    digest = hex_digest(ref['sha256'], 'file digest')
    size = bounded_integer(ref['byteCount'], 1, 512*1024**3, 'file bytes')
    root = pathlib.Path(root).absolute()
    folder = root/'inputs'
    candidate = folder/(digest+'.bin')
    if root.resolve() != root or folder.resolve() != folder or candidate.resolve() != candidate:
        raise ValueError('Scientific input traverses a symbolic link')
    fd = os.open(candidate, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(fd, 'rb') as stream:
        info = os.fstat(stream.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_size != size:
            raise ValueError('File size or type changed')
        if hashlib.file_digest(stream, 'sha256').hexdigest() != digest:
            raise ValueError('File digest changed')
        stream.seek(0)
        yield _NamedReader(stream,candidate)

MAX_ENVELOPE_BYTES = 64 * 1024 * 1024
MAX_DATA_BYTES = 32 * 1024 * 1024
MAX_DECODED_BINARY_BYTES = 24 * 1024 * 1024
MAX_OUTPUT_BYTES = 64 * 1024 * 1024
CONTROL_CHARS = re.compile(r'[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]')
HEX64 = re.compile(r'[0-9a-f]{64}')


def strict_json(source):
    """Parse JSON rejecting NaN/Infinity at any depth, with a nesting cap."""
    def reject(value):
        raise ValueError('Non-finite JSON number')
    import json
    def unique(pairs):
        out = {}
        for key, item in pairs:
            if key in out:
                raise ValueError('Duplicate JSON key')
            out[key] = item
        return out
    value = json.loads(source, parse_constant=reject, object_pairs_hook=unique)

    def check(node, depth=0):
        if depth > 64:
            raise ValueError('JSON nesting limit exceeded')
        if isinstance(node, float) and not math.isfinite(node):
            raise ValueError('Non-finite JSON number')
        if isinstance(node, dict):
            for item in node.values():
                check(item, depth + 1)
        elif isinstance(node, list):
            for item in node:
                check(item, depth + 1)
    check(value)
    return value


def finite_number(value, low, high, name):
    if isinstance(value, bool) or not isinstance(value, (int, float)) \
            or not math.isfinite(value) or not low <= value <= high:
        raise ValueError('Invalid ' + name)
    return value


def bounded_integer(value, low, high, name):
    if isinstance(value, bool) or not isinstance(value, int) or not low <= value <= high:
        raise ValueError('Invalid ' + name)
    return value


def text_id(value, name, max_length=256):
    if not isinstance(value, str) or not 0 < len(value) <= max_length \
            or CONTROL_CHARS.search(value):
        raise ValueError('Invalid ' + name)
    return value


def hex_digest(value, name):
    if not isinstance(value, str) or HEX64.fullmatch(value) is None:
        raise ValueError('Invalid ' + name)
    return value


def decode_base64(value, name, max_bytes=MAX_DECODED_BINARY_BYTES):
    if not isinstance(value, str) or not 0 < len(value.encode()) <= MAX_DATA_BYTES:
        raise ValueError('Invalid ' + name)
    try:
        raw = base64.b64decode(value.encode(), validate=True)
    except (binascii.Error, ValueError):
        raise ValueError('Invalid base64 ' + name)
    if not 0 < len(raw) <= max_bytes:
        raise ValueError(name + ' exceeds the worker size limit')
    return raw


def scoped_file_bytes(relative, max_bytes):
    """Resolve a host-relative path under the configured work directory, with containment."""
    root = os.environ.get('BIOLOGY_WORK_DIRECTORY')
    if not root:
        raise ValueError('This environment has no configured biology work directory; inline data is required')
    root_path = pathlib.Path(root).resolve()
    if not root_path.is_dir():
        raise ValueError('The configured biology work directory is not usable')
    if pathlib.Path(relative).is_absolute() or '..' in pathlib.Path(relative).parts:
        raise ValueError('File path must be relative to the configured directory')
    candidate = pathlib.Path(root_path, relative)
    try:
        resolved = candidate.resolve(strict=False)
    except OSError:
        raise ValueError('Invalid file path')
    if not resolved.is_relative_to(root_path) or resolved != candidate:
        raise ValueError('File path escapes or traverses a symbolic link')
    if not resolved.is_file():
        raise ValueError('Input file does not exist in the configured work directory')
    size = resolved.stat().st_size
    if not 0 < size <= max_bytes:
        raise ValueError('Input file exceeds the worker size limit')
    return resolved.read_bytes()


def payload_bytes(request, max_bytes=MAX_DECODED_BINARY_BYTES):
    """Binary payload from inline base64 data or a scoped host file."""
    if 'file' in request and request['file']:
        text_id(request['file'], 'file path', 1024)
        return scoped_file_bytes(request['file'], max_bytes)
    return decode_base64(request.get('data', ''), 'binary payload', max_bytes)


def payload_text(request, max_bytes=MAX_DATA_BYTES):
    if 'file' in request and request['file']:
        text_id(request['file'], 'file path', 1024)
        raw = scoped_file_bytes(request['file'], max_bytes)
        return raw.decode('utf-8')
    data = request.get('data', '')
    if not isinstance(data, str) or len(data.encode()) > max_bytes:
        raise ValueError('Invalid or oversized text payload')
    return data


def rle_encode(labels):
    """Flat run-length encoding of an integer label image: [[value, start, length], ...]."""
    flat = labels.reshape(-1)
    runs = []
    if flat.size == 0:
        return runs
    start = 0
    current = int(flat[0])
    for index in range(1, flat.size):
        value = int(flat[index])
        if value != current:
            runs.append([current, start, index - start])
            start = index
            current = value
    runs.append([current, start, flat.size - start])
    return runs


def rle_decode(runs, expected_size):
    import numpy as np
    if not isinstance(runs, list) or len(runs) > expected_size:
        raise ValueError('Invalid label run-length encoding')
    out = np.zeros(expected_size, dtype=np.uint32)
    for run in runs:
        if not isinstance(run, list) or len(run) != 3:
            raise ValueError('Invalid label run')
        value, start, length = (bounded_integer(run[0], 0, 2**32 - 1, 'label value'),
                                bounded_integer(run[1], 0, expected_size, 'run start'),
                                bounded_integer(run[2], 0, expected_size, 'run length'))
        if start + length > expected_size:
            raise ValueError('Label run exceeds the image size')
        if value:
            out[start:start + length] = value
    return out


def rounded(value, digits=10):
    return round(float(value), digits)
