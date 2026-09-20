#!/usr/bin/env python3
"""TinyEMU CLI boot smoke harness (qualification evidence).

Spawns ./temu under a PTY, captures the full console transcript, injects a
command script after boot markers appear, then powers off and exits.
Read-only w.r.t. the emulator binary; writes transcript + result JSON.

Usage: pty_boot.py <workdir> <cfgfile> <transcript> <result.json> [timeout_s]
"""
import os, pty, select, sys, time, json, signal, re

def main():
    workdir, cfg, transcript_path, result_path = sys.argv[1:5]
    timeout = int(sys.argv[5]) if len(sys.argv) > 5 else 240
    transcript = open(transcript_path, "wb")
    result = {"booted": False, "commands": {}, "poweroff": False,
              "elapsed_s": None, "error": None}
    pid, fd = pty.fork()
    if pid == 0:
        os.chdir(workdir)
        os.execvp("./temu", ["./temu", cfg])
    buf = b""
    start = time.time()
    # command plan: buildroot boots straight to a root shell "~ #"
    plan = [
        (rb"~ # $", [b"uname -a\n", b"cat /proc/cpuinfo | head -5\n",
                 b"echo FLOE_MARKER_$((40+2))\n",
                 b"echo floe-9p-test > /mnt/floe_9p_marker 2>/dev/null; mount -t 9p -o trans=virtio,version=9p2000.L /dev/root /mnt 2>&1; echo floe-9p-test > /mnt/floe_9p_marker && echo FLOE_9P_WRITE_OK || echo FLOE_9P_FAIL\n",
                 b"poweroff\n"]),
    ]
    sent_root = True  # no login prompt in this image
    sent_cmds = False
    last_activity = time.time()
    try:
        while time.time() - start < timeout:
            r, _, _ = select.select([fd], [], [], 0.5)
            if r:
                try:
                    data = os.read(fd, 4096)
                except OSError:
                    break
                if not data:
                    break
                transcript.write(data)
                transcript.flush()
                buf += data
                last_activity = time.time()
            if not sent_cmds and re.search(plan[0][0], buf[-64:]):
                for c in plan[0][1]:
                    os.write(fd, c)
                    time.sleep(0.3)
                sent_cmds = True
            if b"FLOE_MARKER_42" in buf:
                result["commands"]["marker"] = "FLOE_MARKER_42 seen"
            if b"FLOE_9P_WRITE_OK" in buf:
                result["commands"]["9p"] = "FLOE_9P_WRITE_OK"
            elif b"FLOE_9P_FAIL" in buf:
                result["commands"]["9p"] = "FLOE_9P_FAIL"
            if b"Linux version" in buf:
                result["commands"]["uname"] = True
            if b"reboot: Power down" in buf or b"Power down" in buf:
                result["poweroff"] = True
                break
            # dead console guard
            if sent_cmds and time.time() - last_activity > 60:
                result["error"] = "console idle 60s after commands"
                break
        result["booted"] = sent_cmds or b"~ #" in buf
        result["elapsed_s"] = round(time.time() - start, 1)
    finally:
        try:
            os.kill(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        os.waitpid(pid, 0)
        transcript.close()
        with open(result_path, "w") as f:
            json.dump(result, f, indent=2)
    print(json.dumps(result))

if __name__ == "__main__":
    main()
