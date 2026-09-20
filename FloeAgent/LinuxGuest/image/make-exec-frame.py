#!/usr/bin/env python3
"""make-exec-frame.py — build one inline FLOE-EXEC frame for the Floe guest
runner (the exact bytes LinuxGuestCommandChannel.execEnvelope sends).

Usage:
    make-exec-frame.py --token bootA [--cwd /] [--stdin ""] argv0 [argv1 ...]

Writes the raw frame (no trailing newline) to stdout, so a qualification
script line can be composed as:  @20 <frame>

Payload layout (big-endian, matches FloeAgent/Sources/FloeExecution/Linux/
LinuxGuestCommandChannel.swift):  u32 fieldCount, then per field
u32 byteLength + bytes; fields are [cwd, stdin, argv0, argv1, ...].

The frame is deliberately base64: the console echo of the input line can then
never contain a guest marker string.
"""
import argparse
import base64
import struct
import sys


def build_payload(fields):
    payload = struct.pack(">I", len(fields))
    for field in fields:
        data = field.encode("utf-8")
        payload += struct.pack(">I", len(data)) + data
    return payload


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--token", required=True, help="frame token (echoed back in BEGIN/END)")
    parser.add_argument("--cwd", default="/", help="guest working directory")
    parser.add_argument("--stdin", default="", help="stdin text for the command")
    parser.add_argument("argv", nargs="+", help="argv[0] [argv1 ...] executed verbatim with execvp")
    args = parser.parse_args(argv)

    payload = build_payload([args.cwd, args.stdin] + list(args.argv))
    frame = b"\x1eFLOE-EXEC " + args.token.encode("ascii") + b" " + base64.b64encode(payload) + b"\n"
    sys.stdout.buffer.write(frame)
    return 0


if __name__ == "__main__":
    sys.exit(main())
