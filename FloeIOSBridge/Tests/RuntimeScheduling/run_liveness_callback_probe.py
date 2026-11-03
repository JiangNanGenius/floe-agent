#!/usr/bin/env python3
"""Exercise the real Darwin timer callback shape; this is not iOS acceptance."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import resource
import signal
import subprocess

ROOT = Path(__file__).resolve().parents[3]
SOURCE = ROOT / "FloeIOSBridge/Sources/BridgeHost/BridgeLivenessMonitor.swift"
LEGACY = """        let store = self.store
        dispatchTimer.setEventHandler {
            store.recordDispatchBeat()
        }
"""
HARNESS = r'''
import Foundation
import Dispatch
import Darwin

private final class ProbeStore: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var onMain = false
    func recordDispatchBeat() {
        lock.lock()
        count += 1
        onMain = onMain || Thread.isMainThread
        lock.unlock()
    }
    func snapshot() -> (Int, Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (count, onMain)
    }
}

@MainActor private final class Owner {
    private let store = ProbeStore()
    private let queue = DispatchQueue(label: "org.floeagent.iosbridge.liveness.callback-probe")
    private let dispatchTimer: DispatchSourceTimer
    init() { dispatchTimer = DispatchSource.makeTimerSource(queue: queue) }
    func run() -> Int32 {
        dispatchTimer.schedule(deadline: .now(), repeating: .milliseconds(20))
__HANDLER__
        dispatchTimer.resume()
        let began = DispatchTime.now().uptimeNanoseconds
        // Deliberately do not service MainActor/the main run loop here.
        usleep(300_000)
        dispatchTimer.cancel()
        let (count, onMain) = store.snapshot()
        let elapsed = (DispatchTime.now().uptimeNanoseconds - began) / 1_000_000
        let passed = Thread.isMainThread && count >= 3 && !onMain && elapsed >= 250
        let report: [String: Any] = ["passed": passed, "callbackCount": count,
            "callbackOnMain": onMain, "mainThread": Thread.isMainThread,
            "mainActorBlockedMilliseconds": elapsed]
        let data = try! JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
        print(String(decoding: data, as: UTF8.self))
        return passed ? 0 : 2
    }
}
@main private struct Probe {
    @MainActor static func main() { exit(Owner().run()) }
}
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--scratch", type=Path, default=ROOT / "Local/Scratch/ios-bridge-20261031/liveness-callback-repair")
    parser.add_argument("--output", type=Path, default=ROOT / "Local/Private/ios-bridge-20261031/liveness-callback-repair")
    args = parser.parse_args()
    args.scratch.mkdir(parents=True, exist_ok=True)
    args.output.mkdir(parents=True, exist_ok=True)
    text = SOURCE.read_text()
    start = text.index("        let store = self.store\n")
    end = text.index("        dispatchTimer.resume()", start)
    fixed = text[start:end]
    environment = dict(os.environ)
    environment.setdefault("DEVELOPER_DIR", "/Applications/Xcode-27.1.app/Contents/Developer")
    results = {}
    commands = []
    for name, handler in (("legacy", LEGACY), ("fixed", fixed)):
        source = args.output / (name + "-callback.swift")
        source.write_text(HARNESS.replace("__HANDLER__", handler))
        binary = args.scratch / ("FloeBridgeCallbackProbe-" + name)
        command = ["xcrun", "--sdk", "macosx", "swiftc", "-parse-as-library", "-O",
                   "-swift-version", "6", "-strict-concurrency=complete", "-warnings-as-errors",
                   str(source), "-o", str(binary)]
        commands.append(command)
        compiled = subprocess.run(command, env=environment, capture_output=True, text=True)
        (args.output / (name + "-compile.log")).write_text(compiled.stdout + compiled.stderr)
        if compiled.returncode:
            raise RuntimeError(name + " compilation failed; original log preserved")
        # Limit this child's core dumps without changing host crash settings.
        def no_core():
            resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
        ran = subprocess.run([str(binary)], env=environment, capture_output=True,
                             text=True, timeout=10, preexec_fn=no_core)
        (args.output / (name + "-stdout.log")).write_text(ran.stdout)
        (args.output / (name + "-stderr.log")).write_text(ran.stderr)
        results[name] = {"compileExit": compiled.returncode, "runtimeExit": ran.returncode,
                         "handlerSHA256": hashlib.sha256(handler.encode()).hexdigest(),
                         "binarySHA256": hashlib.sha256(binary.read_bytes()).hexdigest(),
                         "binaryKind": subprocess.check_output(["file", "-b", str(binary)], text=True).strip()}
        if name == "fixed" and ran.returncode == 0:
            results[name]["observation"] = json.loads(ran.stdout)
    results["sourceSHA256"] = hashlib.sha256(text.encode()).hexdigest()
    results["legacyFixture"] = "Exact four-line Build 9 handler in a MainActor owner; fixed handler extracted from current source."
    results["passed"] = (results["legacy"]["runtimeExit"] == -signal.SIGTRAP
                         and results["fixed"]["runtimeExit"] == 0
                         and results["fixed"].get("observation", {}).get("passed") is True)
    (args.output / "runtime-result.json").write_text(json.dumps(results, indent=2) + "\n")
    (args.output / "runtime-commands.json").write_text(json.dumps(commands, indent=2) + "\n")
    print(json.dumps(results, indent=2))
    return 0 if results["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
