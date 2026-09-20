#!/usr/bin/env python3
"""Print only diagnostic codes and image offsets, never raw tester feedback."""
import json
import re
import sys
from pathlib import Path


def image_name(value):
    # Fixed diagnostic categories: never print a caller-supplied image/path.
    name = str(value).rsplit("/", 1)[-1].lower()
    for needle, label in (
        ("floe", "Floe"), ("git", "Git"), ("mlx", "MLX"),
        ("metal", "Metal"), ("agx", "AGX"), ("collabora", "Office"),
        ("mergedlo", "Office"), ("swift", "Swift"), ("libsystem", "System"),
        ("uikit", "UIKit"), ("foundation", "Foundation"),
    ):
        if needle in name:
            return label
    return "Other"


def code(value):
    text = str(value)
    return text if re.fullmatch(r"[A-Za-z0-9_(), .:+-]{1,120}", text) else "omitted"


def symbol_name(value):
    # Compiler identifier only; discard arguments, literals and path suffixes.
    match = re.match(r"(?:closure #\d+ in )?([A-Za-z_$][A-Za-z0-9_$.:]{0,159})", str(value))
    return match.group(1) if match else "omitted"


def summarize(log):
    # Modern .ips consists of one header JSON followed by one report JSON.
    decoder = json.JSONDecoder()
    cursor = 0
    report = None
    while cursor < len(log):
        while cursor < len(log) and log[cursor].isspace():
            cursor += 1
        try:
            item, end = decoder.raw_decode(log, cursor)
        except ValueError:
            break
        cursor = end
        if isinstance(item, dict) and "threads" in item:
            report = item
    if report is not None:
        exception = report.get("exception", {})
        termination = report.get("termination", {})
        for label, value in (("exception", exception.get("type")),
                             ("signal", exception.get("signal")),
                             ("terminationNamespace", termination.get("namespace")),
                             ("terminationCode", termination.get("code"))):
            if value is not None:
                print(label + "=" + code(value))
        images = report.get("usedImages", [])
        threads = report.get("threads", [])
        faulting = report.get("faultingThread")
        for index, thread in enumerate(threads):
            if index != faulting and not thread.get("triggered"):
                continue
            for frame in thread.get("frames", [])[:48]:
                image_index = frame.get("imageIndex")
                image = images[image_index] if isinstance(image_index, int) and 0 <= image_index < len(images) else {}
                offset = frame.get("imageOffset")
                if isinstance(offset, int):
                    uuid = image.get("uuid", "")
                    uuid = uuid if re.fullmatch(r"[0-9A-Fa-f-]{32,36}", uuid) else "unknown"
                    print(f"frame image={image_name(image.get('name', image.get('path', '')))} offset={offset} imageUUID={uuid} symbol={symbol_name(frame.get('symbol', ''))}")
        return
    # Older text reports: no comments, paths, exception reasons or raw symbols.
    in_crashed_thread = False
    emitted = 0
    for line in log.splitlines():
        match = re.fullmatch(r"(Exception Type|Exception Codes|Termination Reason):\s*([A-Z0-9_(), .:+-]{1,120})", line)
        if match:
            print(match.group(1) + "=" + match.group(2))
        if re.match(r"Thread \d+ Crashed:", line):
            in_crashed_thread = True
            continue
        if in_crashed_thread and (not line.strip() or line.startswith("Thread ")):
            in_crashed_thread = False
        if in_crashed_thread and emitted < 48:
            match = re.match(r"\s*\d+\s+(\S+)\s+(0x[0-9a-fA-F]+)", line)
            if match:
                print(f"frame image={image_name(match.group(1))} address={match.group(2)}")
                emitted += 1


if __name__ == "__main__":
    payload = json.loads(Path(sys.argv[1]).read_text())
    log = payload.get("data", {}).get("attributes", {}).get("logText")
    if isinstance(log, str):
        summarize(log)
    else:
        print("crash-log-unavailable")
