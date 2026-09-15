#!/usr/bin/env python3
"""Reproduce the sole OCCT WASM modification; input/output paths are explicit."""
import hashlib
import sys
from pathlib import Path

data = Path(sys.argv[1]).read_bytes()
assert hashlib.sha256(data).hexdigest() == '33391fc9d94ea5c869a6718488bf0a9a464222bac9bdc764dfe1690cef281952'

def read(offset):
    value = shift = 0
    while True:
        byte = data[offset]
        offset += 1
        value |= (byte & 127) << shift
        if byte < 128:
            return value, offset
        shift += 7

def encode(value):
    output = []
    while value >= 128:
        output.append((value & 127) | 128)
        value >>= 7
    return bytes(output + [value])

offset = 8
result = None
while offset < len(data):
    section = data[offset]
    length, start = read(offset + 1)
    end = start + length
    if section == 5:
        count, cursor = read(start)
        flags, cursor = read(cursor)
        initial, cursor = read(cursor)
        maximum, cursor = read(cursor)
        assert count == 1 and flags == 1 and cursor == end
        assert initial <= 6144 and maximum == 32768 and result is None
        payload = encode(count) + encode(flags) + encode(initial) + encode(6144)
        result = data[:offset] + bytes([5]) + encode(len(payload)) + payload + data[end:]
    offset = end
assert result is not None
assert hashlib.sha256(result).hexdigest() == 'ebf53ff1364f1ad0c82c6efc745fbb94677dd88ecd5588622c37ac3a9ba711da'
Path(sys.argv[2]).write_bytes(result)
