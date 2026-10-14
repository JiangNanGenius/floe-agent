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
    return text if re.fullmatch(r"[A-Za-z0-9_(), .:+#-]{1,160}", text) else "omitted"


def uuid_text(value):
    # Canonical UUID only; anything unexpected becomes "unknown".
    text = str(value)
    if not re.fullmatch(
        r"[0-9A-Fa-f]{32}"
        r"|[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}",
        text,
    ):
        return "unknown"
    plain = text.replace("-", "").upper()
    return f"{plain[:8]}-{plain[8:12]}-{plain[12:16]}-{plain[16:20]}-{plain[20:32]}"


def binary_images(log):
    """Map load-address ranges to UUIDs and anonymized image categories.

    Paths, tester text and anything else outside the fixed category vocabulary
    stay inside this function; callers only see safe diagnostic identifiers.
    """
    images = []
    in_section = False
    for line in log.splitlines():
        if line.startswith("Binary Images:"):
            in_section = True
            continue
        if not in_section:
            continue
        # Address rows first, regardless of indentation: legacy records may be
        # unindented. Blank rows are harmless inside the section; the first
        # non-blank row that is not an address row ends it.
        match = re.match(r"\s*(0x[0-9a-fA-F]+)\s*-\s*(0x[0-9a-fA-F]+)\s+(\S.*)$", line)
        if not match:
            if line.strip():
                in_section = False
            continue
        start = int(match.group(1), 16)
        end = int(match.group(2), 16)
        rest = match.group(3)
        uuid_match = (re.search(r"[<(]([0-9A-Fa-f-]{32,36})[>)]", rest)
                      or re.search(r"\b([0-9A-Fa-f]{32})\b", rest))
        source = rest[: uuid_match.start()] if uuid_match else rest
        if uuid_match:
            tail = rest[uuid_match.end() :].strip()
            if tail.startswith("/"):
                source = tail  # Full path, including spaces in the bundle name.
        images.append(
            {
                "start": start,
                "end": end,
                "uuid": uuid_text(uuid_match.group(1)) if uuid_match else "unknown",
                "image": image_name(source),
            }
        )
    return images


def symbol_name(value):
    # Compiler identifier only; discard arguments, literals and path suffixes.
    objc = re.match(r"[+-]\[([A-Za-z_][A-Za-z0-9_]* [A-Za-z_][A-Za-z0-9_:]*)\]", str(value))
    if objc:
        return objc.group(0)
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
                    uuid = uuid_text(image.get("uuid", ""))
                    print(f"frame image={image_name(image.get('name', image.get('path', '')))} offset={offset} imageUUID={uuid} symbol={symbol_name(frame.get('symbol', ''))}")
        return
    # Older text reports: no comments, paths, exception reasons or raw symbols.
    images = binary_images(log)
    in_crashed_thread = False
    emitted = 0
    for line in log.splitlines():
        match = re.fullmatch(r"(Exception Type|Exception Codes|Termination Reason):\s*([A-Za-z0-9_(), .:+#-]{1,160})", line)
        if match:
            print(match.group(1) + "=" + match.group(2))
        if re.match(r"Thread \d+ Crashed:", line):
            in_crashed_thread = True
            continue
        if in_crashed_thread and (not line.strip() or line.startswith("Thread ")):
            in_crashed_thread = False
        if in_crashed_thread and emitted < 48:
            match = re.match(r"\s*\d+\s+(.+?)\s+(0x[0-9a-fA-F]+)\s*(.*)", line)
            if match:
                address = int(match.group(2), 16)
                # Drop an optional "imageBase + imageOffset" column pair so the
                # remaining text is the (already sanitized) symbol.
                detail = re.sub(r"^0x[0-9a-fA-F]+\s*\+\s*(?:0x)?[0-9a-fA-F]+\s*", "", match.group(3))
                image = next((item for item in images if item["start"] <= address <= item["end"]), None)
                if image is not None:
                    # Load-address-relative offset plus the image UUID are enough
                    # to symbolicate against the matching dSYM without the slide.
                    print(f"frame image={image['image']} offset={address - image['start']} imageUUID={image['uuid']} symbol={symbol_name(detail)}")
                else:
                    print(f"frame image={image_name(match.group(1))} address=0x{address:x} symbol={symbol_name(detail)}")
                emitted += 1


if __name__ == "__main__":
    payload = json.loads(Path(sys.argv[1]).read_text())
    log = payload.get("data", {}).get("attributes", {}).get("logText")
    if isinstance(log, str):
        summarize(log)
    else:
        print("crash-log-unavailable")
