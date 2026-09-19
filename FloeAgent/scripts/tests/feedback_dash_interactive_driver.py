#!/usr/bin/env python3
"""Drive the host-built real DashIOS binary through an interactive session.

Usage: feedback_dash_interactive_driver.py /path/to/dash

The binary was compiled from the tracked ThirdParty/DashIOS sources against
fixtures/dash_host/ios_system_stub.c. The stub reads FLOE_DASH_STDIN_FD before
main and publishes that descriptor as ios_system's thread_stdin, mirroring how
the app binds a session pipe to the engine thread. The process fd 0 is
deliberately /dev/null in the regression case, so only dash reading the
session's thread_stdin (the input.c INIT patch) can receive our input.

Checks:
  1. thread_stdin case: `dash -i` receives "printf 'interactive-ok\\n'" through
     the thread_stdin pipe and prints interactive-ok.
  2. fd-0 control: without FLOE_DASH_STDIN_FD the same input piped nowhere is
     never read, dash hits EOF on /dev/null and exits with no such output.
"""
import os
import subprocess
import sys
import time

failures = 0
checks = 0


def check(condition, label):
    global failures, checks
    checks += 1
    print(f"{'PASS' if condition else 'FAIL'}  {label}")
    if not condition:
        failures += 1


def run_interactive(dash, use_thread_stdin, command_text, marker):
    read_fd, write_fd = os.pipe()
    env = dict(os.environ)
    if use_thread_stdin:
        env["FLOE_DASH_STDIN_FD"] = str(read_fd)
    process = subprocess.Popen(
        [dash, "-i"],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        env=env,
        pass_fds=(read_fd,),
    )
    os.close(read_fd)
    os.write(write_fd, command_text)
    os.close(write_fd)
    output = b""
    deadline = time.time() + 10
    while time.time() < deadline:
        chunk = process.stdout.read1(4096)
        if chunk:
            output += chunk
        if process.poll() is not None:
            break
    process.wait(timeout=10)
    output += process.stdout.read() or b""
    return process.returncode, output.decode("utf-8", errors="replace")


def main():
    dash = sys.argv[1]
    if not os.path.isfile(dash):
        print(f"dash binary not found: {dash}", file=sys.stderr)
        return 2

    code, output = run_interactive(
        dash, True, b"printf 'interactive-ok\\n'\nexit\n", "interactive-ok")
    check(code == 0, f"thread_stdin session exits cleanly (rc={code})")
    check("interactive-ok" in output,
          f"dash -i receives shell.exchange-style input via thread_stdin, not fd 0: {output!r}")

    code, output = run_interactive(
        dash, False, b"echo should-not-appear\nexit\n", "should-not-appear")
    check(code == 0, f"fd-0 control session exits cleanly (rc={code})")
    check("should-not-appear" not in output,
          f"without thread_stdin the input is never read (fd 0 is /dev/null): {output!r}")

    print(f"\n{checks - failures}/{checks} dash interactive host checks passed")
    return 0 if failures == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
