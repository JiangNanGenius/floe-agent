#!/bin/bash
# Compile and run the desktop shell session-pump host harness.
#
# The harness splices the current working-tree SessionIO out of
# FloeApp/Execution/IOSSystemShellBackend.swift into the marked block of
# feedback_shell_session_io_host.swift, so it exercises the real pump code on
# real pipes (EOF flush ordering, descriptor close exactly once, EAGAIN
# retries, input rejection after EOF) without the app target or SwiftPM
# dependencies. Extraction also asserts the source-level invariants of the
# contract, so a shape change that silently drops the checks fails loudly.
# This is a host check, not an iOS/device qualification.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
BUILD="${HARNESS_SCRATCH:-$ROOT/Local/Private/feedback-shell-session-io}"
mkdir -p "$BUILD"

SOURCE="${HARNESS_SESSION_IO_SOURCE:-$ROOT/FloeAgent/FloeApp/Execution/IOSSystemShellBackend.swift}"
TEMPLATE="$SCRIPT_DIR/feedback_shell_session_io_host.swift"
GENERATED="$BUILD/feedback_shell_session_io_host.generated.swift"

python3 - "$TEMPLATE" "$SOURCE" "$GENERATED" <<'PY'
import re
import sys

template_path, source_path, out_path = sys.argv[1:4]
template = open(template_path, encoding="utf-8").read()
source = open(source_path, encoding="utf-8").read()
lines = source.splitlines()

start = None
for index, line in enumerate(lines):
    if "private final class SessionIO" in line:
        start = index
        break
if start is None:
    sys.exit("extraction failed: SessionIO not found in %s" % source_path)

depth = 0
end = None
for index in range(start, len(lines)):
    for character in lines[index]:
        if character == "{":
            depth += 1
        elif character == "}":
            depth -= 1
            if depth == 0:
                end = index
                break
    if end is not None:
        break
if end is None:
    sys.exit("extraction failed: unbalanced braces from the SessionIO declaration")

snippet = lines[start:end + 1]
dedented = "\n".join(line[4:] if line.startswith("    ") else line for line in snippet)
for required in ("func enqueue", "func sendEOF", "func start", "closeInputDescriptorLocked"):
    if required not in dedented:
        sys.exit("extraction failed: SessionIO no longer declares %s" % required)

# Source-level contract checks: the pump must own the single stdin close, EOF
# must be a request (not an immediate close), input after EOF must be refused,
# and EAGAIN/EINTR/EWOULDBLOCK must retain the queued bytes.
def function_body(text, signature):
    position = text.find(signature)
    if position < 0:
        sys.exit("contract failed: %s not found" % signature)
    brace = text.find("{", position)
    stops = [stop for stop in (text.find("\n    func ", brace), text.find("\n    /// ", brace)) if stop > 0]
    return text[brace:min(stops) if stops else len(text)]

if "eofRequested" not in dedented:
    sys.exit("contract failed: sendEOF has no independent eofRequested state")
eof_body = function_body(dedented, "func sendEOF() throws")
if "Darwin.close(input)" in eof_body:
    sys.exit("contract failed: sendEOF still closes stdin immediately")
if "eofRequested = true" not in eof_body:
    sys.exit("contract failed: sendEOF does not record the EOF request")
enqueue_body = function_body(dedented, "func enqueue")
if "eofRequested" not in enqueue_body:
    sys.exit("contract failed: enqueue does not refuse input after the EOF request")
if "errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR" not in dedented:
    sys.exit("contract failed: the write retry set no longer excludes EAGAIN/EWOULDBLOCK/EINTR")
if dedented.count("closeInputDescriptorLocked()") < 4:
    sys.exit("contract failed: the hard-error, EOF-flush and teardown paths must share the single-close helper")

begin_marker = "// >>> SESSION-IO-SOURCE"
end_marker = "// <<< SESSION-IO-SOURCE"
if begin_marker not in template or end_marker not in template:
    sys.exit("template failed: SessionIO splice markers missing")
head = template[:template.index(begin_marker) + len(begin_marker)]
tail = template[template.index(end_marker):]
open(out_path, "w", encoding="utf-8").write(head + "\n" + dedented + "\n" + tail)
print("extracted SessionIO: %d lines" % len(snippet))
PY

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-beta.app/Contents/Developer}"

echo "== building shell session-io host"
xcrun swiftc -swift-version 5 -Onone -g -o "$BUILD/feedback_shell_session_io_host" "$GENERATED"

echo "== running shell session-io host"
"$BUILD/feedback_shell_session_io_host"
