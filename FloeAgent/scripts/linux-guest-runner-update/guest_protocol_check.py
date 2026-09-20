#!/usr/bin/env python3
"""guest_protocol_check.py — focused protocol-3 guest check for the runner
update pipeline (NOT the full package/SMP/UI matrix).

generate: write the timed floe_vm_host script that drives one real guest boot
  through capability negotiation, concurrent one-shot commands, targeted and
  legacy cancellation with channel recovery, concurrent PTY sessions and the
  background-service control channel. Every frame is the exact wire format the
  host sends (base64 inline payloads, closing-mark control frames). It also
  writes the terminal marker the host must wait for (see below).

assert:   verify the boot transcript and the 9p share against the expected
  frames/markers and write a JSON verdict. Exit 1 on any failure and keep the
  evidence (the caller uploads it either way).

Marker honesty: guest markers are produced by printf commands assembled at
runtime; frame payloads are base64, so a transcript hit can only come from the
guest executing, never from the console echo of the input line.

Concurrency honesty: the four overlap commands only print their success marker
after all four start-files exist; a bounded wait expires into a distinct
FLOE_CC<n>_NO_OVERLAP marker plus exit 7. Sequential execution therefore fails
the check twice (forbidden marker and non-zero END), and the assert also
requires every FLOE-END cc<n> 0.

Terminal race: floe_vm_host stops on the first marker substring seen in the
guest console stream. Waiting for the guest-printed FLOE_P3_DONE can cut the
boot before the runner's terminal END frame is transcribed ("final end" then
fails); the terminal marker written for `--until` is therefore the runner's
own terminal frame, FLOE-END p3done 0, which the guest emits after its final
output. The assert still requires both the guest marker and that END.
"""
import argparse
import base64
import json
import os
import re
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import pipeline_contract  # noqa: E402  (sibling script directory)

MARK = b"\x1e"
MAX_LINE = 1000  # floe_vm_host script text buffer is 1024; keep a margin.
CAPS_FRAME = re.compile(rb"\x1eFLOE-CAPS (\S+) ([^\x1e]+)\x1e")


def payload(fields):
    body = struct.pack(">I", len(fields))
    for field in fields:
        data = field.encode("utf-8") if isinstance(field, str) else field
        body += struct.pack(">I", len(data)) + data
    return body


def inline(name, token, fields):
    return MARK + b"FLOE-" + name + b" " + token.encode() + b" " + base64.b64encode(payload(fields)) + b"\n"


def control(name, token, args=b""):
    frame = MARK + b"FLOE-" + name + b" " + token.encode()
    if args:
        frame += b" " + args
    return frame + MARK


def chunked(name, token, fields, chunk=512):
    """Chunked envelope (canonical for OPEN/SPAWN; also legal for EXEC).

    The protocol-3 runner only accepts inline payloads for FLOE-EXEC; OPEN and
    SPAWN MUST be chunked:
        \x1eFLOE-<name> <token> <payloadBytes> <chunkCount>\x1e
        \x1eFLOE-CHUNK <token> <index> <base64>\x1e
        \x1eFLOE-RUN <token>\x1e
    """
    body = payload(fields)
    parts = [body[i:i + chunk] for i in range(0, len(body), chunk)] or [b""]
    frames = [control(name, token, ("%d %d" % (len(body), len(parts))).encode())]
    for index, part in enumerate(parts):
        frames.append(control(b"CHUNK", token,
                              str(index).encode() + b" " + base64.b64encode(part)))
    frames.append(control(b"RUN", token))
    return frames


def pty_input(token, data):
    return MARK + b"FLOE-IN " + token.encode() + b" " + base64.b64encode(data) + b"\n"


def exec_frame(token, argv, cwd="/", stdin=""):
    return inline(b"EXEC", token, [cwd, stdin] + list(argv))


def sh(token, command):
    return exec_frame(token, ["/bin/sh", "-c", command])


# Concurrency barrier: each of the four commands drops its own start file in
# the 9p share and spins (bounded) until all four exist. The success marker is
# printed only after that condition was re-checked; the bounded wait expiring
# prints a distinct NO_OVERLAP marker and exits 7, so sequential execution can
# never pass (the marker text is built at runtime: $((3+1))).
CC_FILES = " && ".join("[ -f /floe/cc%d.start ]" % n for n in (1, 2, 3, 4))
CC_CMD = ("rm -f /floe/cc{0}.start; echo s >/floe/cc{0}.start; i=0; "
          "while [ $i -lt 100 ]; do {files} && break; "
          "i=$((i+1)); sleep 0.2; done; "
          "if {files}; then n=$((3+1)); printf 'FLOE_CC%d_OF_%d\\n' {0} $n; "
          "else printf 'FLOE_CC%d_%s\\n' {0} NO_OVERLAP; exit 7; fi").format(0, files=CC_FILES)

# The host's --until marker: the runner's terminal END frame, not the guest's
# own last printf (see the module docstring on the terminal race).
TERMINAL_TOKEN = "p3done"
TERMINAL_MARKER = "FLOE-END %s 0" % TERMINAL_TOKEN


def generate(out_path, terminal_out=None):
    """Write the timed script; also the marker the host must wait for."""
    lines = []

    def at(second, frame):
        if frame.endswith(b"\n"):
            frame = frame[:-1]
        if len(frame) > MAX_LINE:
            raise SystemExit("frame at @%d is %d bytes (> %d)" % (second, len(frame), MAX_LINE))
        lines.append(b"@%d " % second + frame)

    # 1. capability negotiation (protocol 3 gate).
    at(25, control(b"HELLO", "hello1"))
    # 2. four concurrent one-shot commands with a real overlap barrier.
    for n in (1, 2, 3, 4):
        at(30, sh("cc%d" % n, CC_CMD.format(n)))
    # 3. targeted cancellation of one command (TERM) while others finished.
    at(46, sh("cancelme", "sleep 300"))
    at(52, control(b"SIGNAL", "cancelme", b"TERM"))
    # 4. legacy 0x03 interrupt-all with two in-flight commands...
    at(58, sh("legacy1", "sleep 300"))
    at(58, sh("legacy2", "sleep 300"))
    at(66, b"\x03")
    # 5. ...and the channel must recover immediately afterwards.
    at(74, sh("recovery", "printf 'FLOE_RECOVERY_%s\\n' OK"))
    # 6. two concurrent PTY sessions with per-token input routing. OPEN must
    #    use the chunked envelope; IN is raw base64 bytes (not a payload).
    for sess in ("ptyA", "ptyB"):
        for frame in chunked(b"OPEN", sess, ["pty", "/", "80", "24", "/bin/sh"]):
            at(80, frame)
    at(88, pty_input("ptyA", b"printf 'FLOE_PTYA_%s\\n' OK\n"))
    at(88, pty_input("ptyB", b"printf 'FLOE_PTYB_%s\\n' OK\n"))
    at(96, control(b"CLOSE", "ptyA"))
    at(96, control(b"CLOSE", "ptyB"))
    # 7. background service: spawn a detached ticker logging to the 9p share
    #    (SPAWN must be chunked), plus honest negative answers for pids the
    #    runner never spawned.
    for frame in chunked(b"SPAWN", "svc1",
                         ["/", "/floe/svc1.log", "/bin/sh", "-c",
                          "i=0; while [ $i -lt 40 ]; do echo tick$i; i=$((i+1)); sleep 1; done"]):
        at(102, frame)
    at(110, control(b"ALIVE", "alivebad", b"999999"))
    at(110, control(b"KILL", "killbad", b"999999"))
    # 8. final guest marker plus the terminal END frame the host waits for.
    at(118, sh(TERMINAL_TOKEN, "printf 'FLOE_P3_%s\\n' DONE"))

    with open(out_path, "wb") as handle:
        handle.write(b"\n".join(lines) + b"\n")
    if terminal_out:
        with open(terminal_out, "w", encoding="utf-8") as handle:
            handle.write(TERMINAL_MARKER + "\n")
    print("wrote %s (%d timed lines, terminal marker %r)" % (out_path, len(lines), TERMINAL_MARKER))
    return 0


REQUIRED = [
    # (label, regex over the raw transcript bytes)
    ("boot clock applied", rb"floe-exec: clock set from floe\.epoch=[0-9]+"),
    ("HELLO answered", rb"FLOE-CAPS hello1 runner=[^\s]+ protocol=3 "
                       rb"maxCommands=[0-9]+ maxSessions=[0-9]+"),
    ("HELLO end", rb"FLOE-END hello1 0"),
    ("cc1 overlap", rb"FLOE_CC1_OF_4"), ("cc2 overlap", rb"FLOE_CC2_OF_4"),
    ("cc3 overlap", rb"FLOE_CC3_OF_4"), ("cc4 overlap", rb"FLOE_CC4_OF_4"),
    ("cc1 end", rb"FLOE-END cc1 0"), ("cc2 end", rb"FLOE-END cc2 0"),
    ("cc3 end", rb"FLOE-END cc3 0"), ("cc4 end", rb"FLOE-END cc4 0"),
    ("targeted TERM exit 143", rb"FLOE-END cancelme 143"),
    ("legacy cancel exit 130 (1)", rb"FLOE-END legacy1 130"),
    ("legacy cancel exit 130 (2)", rb"FLOE-END legacy2 130"),
    ("channel recovered", rb"FLOE_RECOVERY_OK"),
    ("recovery end", rb"FLOE-END recovery 0"),
    ("ptyA opened", rb"FLOE-BEGIN ptyA"), ("ptyB opened", rb"FLOE-BEGIN ptyB"),
    ("ptyA output", rb"FLOE_PTYA_OK"), ("ptyB output", rb"FLOE_PTYB_OK"),
    ("ptyA end", rb"FLOE-END ptyA [0-9]+"), ("ptyB end", rb"FLOE-END ptyB [0-9]+"),
    ("service pid frame", rb"FLOE-PID svc1 [0-9]+"),
    ("service spawn end", rb"FLOE-END svc1 0"),
    ("unknown alive honest 3", rb"FLOE-END alivebad 3"),
    ("unknown kill honest 3", rb"FLOE-END killbad 3"),
    ("final marker", rb"FLOE_P3_DONE"),
    ("final end", re.escape(TERMINAL_MARKER).encode()),
]

FORBIDDEN = [
    ("kernel panic", rb"Kernel panic"),
    ("quarantine frame", rb"FLOE-FAILED"),
    ("protocol-2 busy rejection", rb"guest is busy"),
    ("command table overflow", rb"command table full"),
    ("session table overflow", rb"session table full"),
    ("cancelme wrong exit", rb"FLOE-END cancelme (0|125|130)\b"),
    ("overlap barrier timeout", rb"FLOE_CC[0-9]_NO_OVERLAP"),
    ("overlap command non-zero exit", rb"FLOE-END cc[0-9] (?!0\b)[0-9]+"),
]


def run_assert(transcript_path, share_dir, out_path):
    with open(transcript_path, "rb") as handle:
        blob = handle.read()
    checks = []
    failed = 0
    for label, pattern in REQUIRED:
        seen = re.search(pattern, blob) is not None
        checks.append({"check": label, "expected": True, "seen": seen})
        if not seen:
            failed += 1
            print("MISSING: %s (%s)" % (label, pattern.decode("utf-8", "replace")))
        else:
            print("seen: %s" % label)
    for label, pattern in FORBIDDEN:
        seen = re.search(pattern, blob) is not None
        checks.append({"check": "absent: " + label, "expected": False, "seen": seen})
        if seen:
            failed += 1
            print("FORBIDDEN PRESENT: %s" % label)

    svc_log = os.path.join(share_dir, "svc1.log")
    ticks = 0
    if os.path.isfile(svc_log):
        with open(svc_log, "r", errors="replace") as handle:
            ticks = sum(1 for line in handle if line.startswith("tick"))
    checks.append({"check": "detached service wrote >=2 ticks to the 9p log", "expected": True, "seen": ticks >= 2,
                   "ticks": ticks})
    if ticks < 2:
        failed += 1
        print("MISSING: service log ticks (found %d)" % ticks)

    # Verbatim capability payload: the manifest's runnerCapabilities field is
    # this exact string, and the packaging step cross-checks it against the
    # runner source constants of the same commit, so the claim is not a regex
    # paraphrase of what the guest answered.
    caps_frame = CAPS_FRAME.search(blob)
    caps_payload = caps_frame.group(2).decode("ascii", "replace").strip() if caps_frame else None
    caps = pipeline_contract.parse_caps(caps_payload) if caps_payload else None
    extra = [
        ("HELLO token is hello1 and the answer is a framed 0x1e CAPS frame",
         caps_frame is not None and caps_frame.group(1) == b"hello1"),
        ("CAPS payload parses as runner=/protocol=/maxCommands=/maxSessions=", caps is not None),
        ("CAPS protocol is exactly 3", caps is not None and caps["protocol"] == 3),
        ("CAPS allows >=4 concurrent commands (4-way overlap check)",
         caps is not None and caps["maxCommands"] >= 4),
        ("CAPS allows >=2 concurrent PTY sessions", caps is not None and caps["maxSessions"] >= 2),
        ("CAPS runner version is non-empty", caps is not None and bool(caps["runner"])),
    ]
    for label, seen in extra:
        checks.append({"check": label, "expected": True, "seen": seen})
        if not seen:
            failed += 1
            print("MISSING: %s" % label)

    verdict = {"schema": "floe-linux-guest-runner-update-check/v1",
               "transcriptBytes": len(blob), "serviceTicks": ticks,
               "capsPayload": caps["payload"] if caps else caps_payload,
               "runnerVersion": caps["runner"] if caps else None,
               "protocol": caps["protocol"] if caps else None,
               "maxCommands": caps["maxCommands"] if caps else None,
               "maxSessions": caps["maxSessions"] if caps else None,
               "checks": checks, "failures": failed}
    with open(out_path, "w", encoding="utf-8") as handle:
        json.dump(verdict, handle, indent=2)
        handle.write("\n")
    print("guest protocol check: %d failure(s); wrote %s" % (failed, out_path))
    if failed:
        sys.stdout.flush()
        sys.stderr.write("\n--- last 4000 bytes of the transcript ---\n")
        sys.stderr.buffer.write(blob[-4000:])
        sys.stderr.write("\n")
    return 1 if failed else 0


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    gen = sub.add_parser("generate", help="write the timed floe_vm_host script")
    gen.add_argument("--out", required=True)
    gen.add_argument("--terminal-out", default=None,
                     help="write the exact --until marker for the host (terminal END frame)")
    chk = sub.add_parser("assert", help="verify the transcript + 9p share, write the JSON verdict")
    chk.add_argument("--transcript", required=True)
    chk.add_argument("--share", required=True)
    chk.add_argument("--out", required=True)
    args = parser.parse_args(argv)
    if args.command == "generate":
        return generate(args.out, args.terminal_out)
    return run_assert(args.transcript, args.share, args.out)


if __name__ == "__main__":
    sys.exit(main())
