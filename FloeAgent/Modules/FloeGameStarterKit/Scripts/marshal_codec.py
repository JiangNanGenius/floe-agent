#!/usr/bin/env python3
# SPDX-License-Identifier: MPL-2.0
"""Bounded Ruby Marshal 4.8 reader/writer used by the starter-fixture generator.

This is a build-time fixture tool, not a game runtime. It implements the
subset used by standard RPG Maker XP/VX/VX Ace project data: nil, booleans,
integers, floats, strings with encoding ivars, symbols, arrays, hashes,
user-defined objects (Table/Color/Tone), and ordinary Ruby objects. The reader
also understands Marshal object links so it can validate existing project data.

The writer intentionally emits fresh objects and symbols instead of links. That
is valid Marshal (the reader numbers objects as it encounters them) and keeps
the generated starter data deterministic and free of shared mutable objects.
"""

from __future__ import annotations

from dataclasses import dataclass, field
import struct
from typing import Any


class MarshalError(ValueError):
    pass


@dataclass
class RString:
    data: bytes
    encoding: str = "binary"  # "binary", "utf8", "usascii"


@dataclass
class RSymbol:
    name: str


@dataclass
class RObject:
    class_name: str
    ivars: list[tuple[str, Any]] = field(default_factory=list)

    def get(self, name: str, default: Any = None) -> Any:
        for key, value in self.ivars:
            if key == name:
                return value
        return default

    def set(self, name: str, value: Any) -> None:
        for index, (key, _) in enumerate(self.ivars):
            if key == name:
                self.ivars[index] = (name, value)
                return
        self.ivars.append((name, value))


@dataclass
class RUserDefined:
    class_name: str
    data: bytes


@dataclass
class RHash:
    pairs: list[tuple[Any, Any]] = field(default_factory=list)
    default: Any = None
    has_default: bool = False


@dataclass
class RTable:
    dimensions: int
    x_size: int
    y_size: int
    z_size: int
    values: list[int]

    def as_user_defined(self) -> RUserDefined:
        expected = self.x_size * self.y_size * self.z_size
        if len(self.values) != expected:
            raise MarshalError(f"table count {len(self.values)} != {expected}")
        payload = struct.pack("<5I", self.dimensions, self.x_size, self.y_size,
                              self.z_size, len(self.values))
        payload += struct.pack("<" + "h" * len(self.values), *self.values)
        return RUserDefined("Table", payload)


@dataclass
class RColor:
    red: float
    green: float
    blue: float
    alpha: float

    def as_user_defined(self) -> RUserDefined:
        return RUserDefined("Color", struct.pack("<4d", self.red, self.green,
                                                   self.blue, self.alpha))


@dataclass
class RTone:
    red: float
    green: float
    blue: float
    gray: float

    def as_user_defined(self) -> RUserDefined:
        return RUserDefined("Tone", struct.pack("<4d", self.red, self.green,
                                                 self.blue, self.gray))


def _w_long(value: int) -> bytes:
    """Exact Ruby w_long encoding for fixnums."""
    if value == 0:
        return b"\x00"
    if 0 < value < 123:
        return bytes([value + 5])
    if -124 < value < 0:
        return bytes([(value - 5) & 0xFF])
    out = bytearray()
    for index in range(1, 9):
        out.append(value & 0xFF)
        value >>= 8
        if value == 0:
            return bytes([index]) + bytes(out)
        if value == -1:
            return bytes([(-index) & 0xFF]) + bytes(out)
    raise MarshalError("integer does not fit Marshal fixnum")


def _r_long(data: bytes, offset: int) -> tuple[int, int]:
    if offset >= len(data):
        raise MarshalError("truncated long")
    first = data[offset]
    offset += 1
    signed = first if first < 128 else first - 256
    if signed == 0:
        return 0, offset
    if signed > 0:
        if signed > 4 and signed < 128:
            return signed - 5, offset
        count = signed
        if offset + count > len(data):
            raise MarshalError("truncated long payload")
        value = int.from_bytes(data[offset:offset + count], "little", signed=True)
        return value, offset + count
    if signed > -129 and signed < -4:
        return signed + 5, offset
    count = -signed
    if offset + count > len(data):
        raise MarshalError("truncated long payload")
    value = int.from_bytes(data[offset:offset + count], "little", signed=True)
    return value, offset + count


def _length_prefixed(data: bytes, offset: int) -> tuple[bytes, int]:
    length, offset = _r_long(data, offset)
    if length < 0 or offset + length > len(data):
        raise MarshalError("invalid length-prefixed payload")
    return data[offset:offset + length], offset + length


class Writer:
    def __init__(self) -> None:
        self.output = bytearray(b"\x04\x08")

    def dump(self, value: Any) -> bytes:
        self._emit(value)
        return bytes(self.output)

    def _emit(self, value: Any) -> None:
        if value is None:
            self.output.append(0x30)
        elif value is True:
            self.output.append(0x54)
        elif value is False:
            self.output.append(0x46)
        elif isinstance(value, int):
            if value < -(1 << 30) or value > (1 << 30) - 1:
                self._emit_bignum(value)
            else:
                self.output.append(0x69)
                self.output += _w_long(value)
        elif isinstance(value, float):
            text = format(value, ".16g").encode("ascii")
            self.output.append(0x66)
            self.output += _w_long(len(text))
            self.output += text
        elif isinstance(value, RSymbol):
            self._emit_symbol(value.name)
        elif isinstance(value, RString):
            if value.encoding == "utf8":
                self.output.append(0x49)  # I
                self.output.append(0x22)  # "
                self.output += _w_long(len(value.data))
                self.output += value.data
                self.output += _w_long(1)
                self._emit_symbol("E")
                self.output.append(0x54)
            elif value.encoding == "usascii":
                self.output.append(0x49)
                self.output.append(0x22)
                self.output += _w_long(len(value.data))
                self.output += value.data
                self.output += _w_long(1)
                self._emit_symbol("E")
                self.output.append(0x46)
            else:
                self.output.append(0x22)
                self.output += _w_long(len(value.data))
                self.output += value.data
        elif isinstance(value, str):
            self._emit(RString(value.encode("utf-8"), "utf8"))
        elif isinstance(value, (list, tuple)):
            self.output.append(0x5B)  # [
            self.output += _w_long(len(value))
            for item in value:
                self._emit(item)
        elif isinstance(value, RHash):
            self.output.append(0x7D if value.has_default else 0x7B)
            self.output += _w_long(len(value.pairs))
            for key, item in value.pairs:
                self._emit(key)
                self._emit(item)
            if value.has_default:
                self._emit(value.default)
        elif isinstance(value, RObject):
            self.output.append(0x6F)  # o
            self._emit_symbol(value.class_name)
            self.output += _w_long(len(value.ivars))
            for name, item in value.ivars:
                self._emit_symbol(name)
                self._emit(item)
        elif isinstance(value, RUserDefined):
            self.output.append(0x75)  # u
            self._emit_symbol(value.class_name)
            self.output += _w_long(len(value.data))
            self.output += value.data
        elif isinstance(value, RTable):
            self._emit(value.as_user_defined())
        elif isinstance(value, RColor):
            self._emit(value.as_user_defined())
        elif isinstance(value, RTone):
            self._emit(value.as_user_defined())
        else:
            raise MarshalError(f"unsupported Marshal value: {type(value)!r}")

    def _emit_symbol(self, name: str) -> None:
        raw = name.encode("utf-8")
        self.output.append(0x3A)  # :
        self.output += _w_long(len(raw))
        self.output += raw

    def _emit_bignum(self, value: int) -> None:
        self.output.append(0x6C)  # l
        self.output.append(0x2D if value < 0 else 0x2B)
        magnitude = abs(value)
        words: list[int] = []
        while magnitude:
            words.append(magnitude & 0xFFFF)
            magnitude >>= 16
        if not words:
            words = [0]
        self.output += _w_long(len(words))
        for word in words:
            self.output.append(word & 0xFF)
            self.output.append((word >> 8) & 0xFF)


class Reader:
    """Strict-enough reader for validation and cross-checking fixtures."""

    def __init__(self, data: bytes) -> None:
        if data[:2] != b"\x04\x08":
            raise MarshalError("not a Marshal 4.8 stream")
        self.data = data
        self.offset = 2
        self.objects: list[Any] = []
        self.symbols: list[str] = []

    def load(self) -> Any:
        value = self._read()
        if self.offset != len(self.data):
            raise MarshalError(f"trailing bytes at {self.offset}/{len(self.data)}")
        return value

    def _read(self) -> Any:
        if self.offset >= len(self.data):
            raise MarshalError("truncated object")
        tag = self.data[self.offset]
        self.offset += 1
        if tag == 0x30:
            return None
        if tag == 0x54:
            return True
        if tag == 0x46:
            return False
        if tag == 0x69:
            value, self.offset = _r_long(self.data, self.offset)
            return value
        if tag == 0x40:  # @ link
            index, self.offset = _r_long(self.data, self.offset)
            if not 0 <= index < len(self.objects):
                raise MarshalError(f"object link {index} out of range")
            return self.objects[index]
        if tag == 0x3B:  # ; symbol link
            index, self.offset = _r_long(self.data, self.offset)
            if not 0 <= index < len(self.symbols):
                raise MarshalError(f"symbol link {index} out of range")
            return RSymbol(self.symbols[index])
        if tag == 0x3A:  # : symbol
            raw, self.offset = _length_prefixed(self.data, self.offset)
            name = raw.decode("utf-8")
            self.symbols.append(name)
            return RSymbol(name)
        if tag == 0x49:  # I ivar wrapper
            wrapped = self._read()
            ivar_count, self.offset = _r_long(self.data, self.offset)
            ivars: list[tuple[str, Any]] = []
            for _ in range(ivar_count):
                name = self._read_symbol()
                ivars.append((name, self._read()))
            if isinstance(wrapped, RString) and len(ivars) == 1 and ivars[0][0] == "E":
                if ivars[0][1] is True:
                    wrapped.encoding = "utf8"
                elif ivars[0][1] is False:
                    wrapped.encoding = "usascii"
            return wrapped
        if tag == 0x66:  # f
            raw, self.offset = _length_prefixed(self.data, self.offset)
            return float(raw.decode("ascii"))
        if tag == 0x22:  # "
            raw, self.offset = _length_prefixed(self.data, self.offset)
            value = RString(raw, "binary")
            self.objects.append(value)
            return value
        if tag == 0x6C:  # l bignum
            sign = self.data[self.offset]
            self.offset += 1
            count, self.offset = _r_long(self.data, self.offset)
            if sign not in (0x2B, 0x2D) or count < 0 or self.offset + count * 2 > len(self.data):
                raise MarshalError("invalid bignum")
            magnitude = 0
            for index in range(count):
                magnitude |= int.from_bytes(self.data[self.offset + index * 2:self.offset + index * 2 + 2], "little") << (16 * index)
            self.offset += count * 2
            return -magnitude if sign == 0x2D else magnitude
        if tag == 0x5B:  # [
            count, self.offset = _r_long(self.data, self.offset)
            result: list[Any] = []
            self.objects.append(result)
            for _ in range(count):
                result.append(self._read())
            return result
        if tag in (0x7B, 0x7D):  # { }
            count, self.offset = _r_long(self.data, self.offset)
            result = RHash([], None, tag == 0x7D)
            self.objects.append(result)
            for _ in range(count):
                result.pairs.append((self._read(), self._read()))
            if result.has_default:
                result.default = self._read()
            return result
        if tag in (0x6F, 0x53):  # o S
            class_name = self._read_symbol()
            count, self.offset = _r_long(self.data, self.offset)
            result = RObject(class_name, [])
            self.objects.append(result)
            for _ in range(count):
                name = self._read_symbol()
                result.ivars.append((name, self._read()))
            return result
        if tag == 0x75:  # u
            class_name = self._read_symbol()
            raw, self.offset = _length_prefixed(self.data, self.offset)
            result = RUserDefined(class_name, raw)
            self.objects.append(result)
            return result
        if tag == 0x55:  # U
            class_name = self._read_symbol()
            result = RObject(class_name, [("__marshal_dump__", None)])
            self.objects.append(result)
            result.ivars[0] = ("__marshal_dump__", self._read())
            return result
        if tag == 0x65:  # e
            _ = self._read_symbol()
            return self._read()
        if tag in (0x63, 0x6D):  # c m
            raw, self.offset = _length_prefixed(self.data, self.offset)
            result = RObject(raw.decode("utf-8"), [])
            self.objects.append(result)
            return result
        raise MarshalError(f"unsupported Marshal tag 0x{tag:02x} at {self.offset - 1}")

    def _read_symbol(self) -> str:
        value = self._read()
        if not isinstance(value, RSymbol):
            raise MarshalError("expected symbol")
        return value.name


def dump(value: Any) -> bytes:
    return Writer().dump(value)


def load(data: bytes) -> Any:
    return Reader(data).load()


def decode_table(user_defined: RUserDefined) -> RTable:
    if user_defined.class_name != "Table":
        raise MarshalError("not a Table")
    data = user_defined.data
    if len(data) < 20:
        raise MarshalError("table header too short")
    dimensions, x_size, y_size, z_size, count = struct.unpack("<5I", data[:20])
    expected = x_size * y_size * z_size
    if dimensions not in (1, 2, 3) or count != expected or len(data) != 20 + count * 2:
        raise MarshalError("invalid table payload")
    values = list(struct.unpack("<" + "h" * count, data[20:]))
    return RTable(dimensions, x_size, y_size, z_size, values)


def find_ivars(obj: Any) -> dict[str, Any]:
    if isinstance(obj, RObject):
        return dict(obj.ivars)
    raise MarshalError("not an object")
