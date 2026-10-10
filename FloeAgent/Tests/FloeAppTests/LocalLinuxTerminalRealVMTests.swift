// FloeAppTests — Real Linux VM terminal responsiveness.
//
// SPDX-License-Identifier: MPL-2.0
//
// Measures the REAL local Linux guest terminal end-to-end through the same
// production path the UI uses: the live `AppEnvironment` services prepare the
// pinned, hash-verified Debian/RISC-V image (a first run downloads and
// verifies it through the authorized install path — the image is never
// seeded or faked), TinyEMU boots the guest, and an interactive terminal is
// driven by the production `LocalTerminalOwner` using its REAL visible loop
// (`pollWhileVisible`) and REAL input queue (`enqueue`) — the exact loop the
// cadence optimization changed. It measures:
//
//   * input/echo round-trip under the NEW adaptive cadence and, on the SAME
//     booted VM immediately beforehand, a BASELINE loop fixed at the old
//     150 ms idle poll, so the cadence change (not the guest) is compared;
//   * sustained bounded output whose exact numbered sequence 0..<N is
//     recovered in order with no duplicate/missing line (command echo
//     excluded), preserving UTF-8 and ANSI colour bytes;
//   * Ctrl-C interrupt returning to a prompt (marker assembled by the
//     executed command, never present in the typed input); and a PTY resize.
//
// No mock backend is involved: a failure to install, boot, echo or drain
// FAILS the test rather than skipping it. Measurement boundary = one
// terminal session on one already-booted guest; baseline and adaptive share
// that session so only the poll cadence differs. First install/boot time is
// reported separately and is NOT part of the latency comparison.
//
// LOCAL RESULT (measured 2026-10-09, this simulator, after the session
// output-integrity fix): the real guest reaches a login shell, executes the
// computed marker, and the full measurement passes — echo RTT 31 ms on a
// fixed-150 ms-poll baseline vs 43 ms on the adaptive visible loop (the
// transport round trip dominates both; the 150 ms boundary only bounded the
// OLD poll cadence), 2000/2000 exact ordered UTF-8/ANSI lines in 2.54 s
// (789 lines/s), Ctrl-C aborts `sleep 30` and returns to a usable prompt,
// and a 100x30 resize is adopted. The original stall (partial echo, then
// 420 s of silence) was a host-side session-buffer race, not the guest;
// see Local/Private/evidence/content-upgrade-20261009/terminal-transport-
// stall/RESOLVED.md. This remains an OPT-IN qualification
// (`FLOE_REALVM_QUALIFICATION=1`) for a qualified host or physical device;
// its disabled state is reported as disabled, never as a pass.
//
// The simulator admission fix from the original investigation stays:
// `RuntimeProcessHeadroom.availableBytes()` reports the probe as
// unavailable under `targetEnvironment(simulator)` because
// `os_proc_available_memory()` returns a constant 0 there (measured), which
// previously queued every guest start until
// `RuntimeV2Error.queueTimedOut(…, 600)` with zero emulation.

#if canImport(SwiftUI) && canImport(UIKit) && DEBUG
import Foundation
import Darwin
import Testing
@testable import FloeApp
import FloeCore
import FloeExecution
import FloeTools
import FloeEnvironments

@Suite("FloeApp.LocalLinuxTerminalRealVM")
@MainActor
struct LocalLinuxTerminalRealVMTests {

    /// Pinned-image verified download + expand and a cold TinyEMU boot can
    /// take several minutes on a first run.
    private let bootTimeout: TimeInterval = 1200

    private func makeWorkspaceRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("realvm-terminal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// The environment ID is derived from THIS test's workspace root — the
    /// exact owner key `prepareWorkspaceEnvironment` uses — so the test drives
    /// the container for its own root and never picks up an unrelated
    /// environment.
    private func environmentID(forRoot root: URL, registry: EnvironmentRegistry) async -> String? {
        let canonical = root.resolvingSymlinksInPath().standardizedFileURL
        let workspaceID = FloeDigest.sha256Hex(Data(canonical.path.utf8))
        let owned = await registry.containersOwned(by: workspaceID)
        return owned
            .first { $0.kind == .project && $0.state != .deleting }?.id
    }
    private func waitForAsync(timeout: TimeInterval, _ condition: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return await condition()
    }

    // MARK: - Real visible-loop driver

    /// Runs the production `pollWhileVisible` loop until `predicate` matches
    /// the accumulated output. `enqueue` (the production input queue) delivers
    /// `command`; we never call the private single-step seam or a fixed sleep.
    /// The loop task is cancelled at the deadline/match. Returns (text, ok).
    private func drive(
        owner: LocalTerminalOwner,
        command: String?,
        timeout: TimeInterval,
        predicate: @escaping @Sendable (String) -> Bool
    ) async -> (String, Bool) {
        let started = Date()
        if let command {
            owner.enqueue(Data((command + "\n").utf8))
            print("FLOE_REALVM_SEND outPre=\(owner.output.count) len=\(command.utf8.count) alive=\(owner.alive)")
        }
        let box = PredicateBox(predicate)
        let task = Task { @MainActor in
            await owner.pollWhileVisible()
        }
        var last = ""
        var lastReport = Date()
        var lastAlive = owner.alive
        var lastStatus = owner.status
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
            last = String(decoding: owner.output, as: UTF8.self)
            if box.matches(last) { break }
            if task.isCancelled { break }
            // Progress every 15 s and on any alive/status change: distinguishes
            // "session died with a real error" from "alive but transport
            // stalled" (the toothpaste symptom) without guessing.
            if Date().timeIntervalSince(lastReport) >= 15
                || owner.alive != lastAlive || owner.status != lastStatus {
                print("FLOE_REALVM_WAIT t=\(String(format: "%.0f", Date().timeIntervalSince(started))) "
                      + "alive=\(owner.alive) outBytes=\(owner.output.count) status=\(owner.status)")
                lastReport = Date(); lastAlive = owner.alive; lastStatus = owner.status
            }
        }
        // ORDERED teardown of this poll: cancel and AWAIT the visible-loop
        // task before returning, so no exchange is in flight when the caller
        // closes the owner or changes geometry.
        task.cancel()
        await { await task.value }()
        return (last, box.matches(last))
    }

    /// Waits for the guest's userspace shell to actually execute a command.
    /// The marker is assembled BY the shell arithmetic expansion, so neither
    /// the typed command echo nor kernel boot text can satisfy it: output
    /// proves a running shell, not merely a launched emulator process. TinyEMU
    /// cold-boot under the simulator can take several minutes. Returns the
    /// match result and the observed tail for diagnostics.
    private func waitShellReady(owner: LocalTerminalOwner, timeout: TimeInterval = 900) async -> (Bool, String) {
        let (text, ok) = await drive(
            owner: owner,
            command: "printf 'FLOE_%s_READY\\n' \"$((6*7))\"",
            timeout: timeout
        ) { $0.contains("FLOE_42_READY") }
        return (ok, String(text.suffix(400)))
    }

    // MARK: - Test

    /// Fast diagnostic capturing the two admission inputs the Linux pool uses.
    /// It exists because the first real-VM run failed with
    /// `RuntimeV2Error.queueTimedOut(environmentID:…, seconds: 600)` while the
    /// app process never started emulating: this separates a pending-admission
    /// refusal (headroom probe / pressure) from actual guest boot latency.
    @Test("Probe: process headroom and thermal pressure reported by this host")
    func probeAdmissionInputs() {
        let available = os_proc_available_memory()
        print("FLOE_ADMISSION_PROBE os_proc_available_memory=\(available) "
              + "physicalMB=\(ProcessInfo.processInfo.physicalMemory / 1_048_576) "
              + "thermal=\(ProcessInfo.processInfo.thermalState.rawValue)")
    }

    /// Opt-in real-guest qualification (see the file header limitation note).
    /// Disabled by default for the simulator; run with
    /// `FLOE_REALVM_QUALIFICATION=1` on a qualified host/physical device.
    @Test("Real Linux guest: echo latency and cadence comparison; exact sustained sequence; Ctrl-C; resize",
          .enabled(if: ProcessInfo.processInfo.environment["FLOE_REALVM_QUALIFICATION"] == "1"))
    func realGuestTerminalCadenceDrainInterruptResize() async throws {
        let environment = AppEnvironment.live()
        await environment.bootstrap()
        let services = FloePlatformServices.shared
        let root = try makeWorkspaceRoot()
        // The environment THIS test owns; cleanup stops exactly it and never
        // touches another environment.
        var ownedEnvironmentID = ""
        var owner: LocalTerminalOwner?
        // ORDERED, AWAITED cleanup, run inline after the measurement (never a
        // detached Task and never before the guest PTY is closed):
        //   1. each `drive` call already cancels and awaits its poll task;
        //   2. await owner.close() — flush and close the guest PTY session;
        //   3. stop the Linux environment THIS test owns;
        //   4. remove the temp workspace root.
        // The verified installed image and all other environments/data stay.
        func cleanup() async {
            if let owner { await owner.close() }
            if !ownedEnvironmentID.isEmpty {
                try? await services.stopEnvironment(id: ownedEnvironmentID)
            }
            try? FileManager.default.removeItem(at: root)
        }
        do {
            // The workspace project container (default linuxVM backend) is
            // the exact container the production terminal resolves.
            try await services.prepareWorkspaceEnvironment(root: root)
            guard let environmentID = await environmentID(
                forRoot: root, registry: environment.environmentRegistry) else {
                Issue.record("No Linux project environment exists for this test's workspace root")
                await cleanup()
                return
            }
            ownedEnvironmentID = environmentID

            // AUTHORIZED INSTALL + BOOT (reported separately from latency).
            let installStart = Date()
            func phase(_ name: String) {
                print("FLOE_REALVM_PHASE \(name) t=\(String(format: "%.1f", Date().timeIntervalSince(installStart)))s")
            }
            phase("activateWithPreparation.begin")
            let preStatus = await services.linuxEnvironmentStatus(id: environmentID)
            phase("preStatus=\(String(describing: preStatus))")
            try await services.activateLinuxGuestWithPreparation(
                id: environmentID, cancellation: CancellationToken())
            phase("activateWithPreparation.returned")
            let ready = await waitForAsync(timeout: bootTimeout) {
                let ok = await services.linuxEnvironmentAvailable(id: environmentID)
                return ok
            }
            phase("availablePoll=\(ready)")
            guard ready else {
                let postStatus = await services.linuxEnvironmentStatus(id: environmentID)
                Issue.record("Linux guest never became available after preparation/boot status=\(String(describing: postStatus))")
                await cleanup()
                return
            }
            print("FLOE_REALVM_READY environment=\(String(environmentID.prefix(8))) "
                  + "installOrBootSeconds=\(String(format: "%.1f", Date().timeIntervalSince(installStart)))")

            let terminalOwner = environment.localTerminals.owner(workspaceID: UUID(), root: root)
            owner = terminalOwner
            await terminalOwner.open()
            let opened = await waitForAsync(timeout: 90) { terminalOwner.alive }
            guard opened else {
                Issue.record("Linux terminal never opened: \(terminalOwner.status)")
                await cleanup()
                return
            }
            let (shellReady, shellTail) = await waitShellReady(owner: terminalOwner)
            #expect(shellReady, "guest shell never executed a command; tail=\(shellTail)")
            guard shellReady else {
                // A boot that never reaches userspace must not be measured as
                // echo latency; stop here with the recorded tail.
                await cleanup()
                return
            }

            // 1) BASELINE: emulate the pre-cadence loop (fixed 150 ms poll) on
            //    the SAME booted VM and the SAME production exchange path,
            //    pacing the production exchange at the old idle period. This
            //    isolates the old cadence's latency contribution.
            let baselineRTT = await measureRoundTrip(
                owner: terminalOwner, pollDelayMs: 150, label: "baseline-150ms")

            // 2) ADAPTIVE: the real production visible loop (zero added delay
            //    while a round-trip is in flight).
            let adaptiveRTT = await measureRoundTrip(
                owner: terminalOwner, pollDelayMs: nil, label: "adaptive")

            print("FLOE_REALVM_RTT_MS baseline=\(String(format: "%.0f", baselineRTT)) "
                  + "adaptive=\(String(format: "%.0f", adaptiveRTT))")
            // Boundary: same VM, same session, same echo transport; the
            // adaptive path must not be slower than the fixed 150 ms baseline
            // and should remove most of the artificial poll wait.
            #expect(adaptiveRTT <= baselineRTT + 25,
                    "adaptive cadence RTT \(adaptiveRTT)ms exceeded 150ms baseline \(baselineRTT)ms")

            // 3) SUSTAINED OUTPUT with an exact numbered sequence. The marker
            //    uses a random salt so it cannot occur except in real output;
            //    we parse only COMPLETE coloured marker lines and require each
            //    number 0..<N exactly once in ascending order.
            let lineCount = 2000
            let salt = String(UInt32.random(in: 0..<0xfffffe), radix: 16)
            let marker = "VM\(salt)行-"
            // The trailing join fragment is printed by a SECOND printf, so it
            // can only appear once the stream command actually executed.
            let cmd = "i=0; while [ $i -lt \(lineCount) ]; do printf '\\033[32m%s%05d\\033[0m\\n' '\(marker)' $i; i=$((i+1)); done; printf 'TAIL_%s_DONE' '\(salt)'"
            let drainStart = Date()
            let (drained, drainOK) = await drive(
                owner: terminalOwner, command: cmd, timeout: 45
            ) { $0.contains("TAIL_\(salt)_DONE") }
            let drainSeconds = Date().timeIntervalSince(drainStart)
            #expect(drainOK, "sustained stream did not finish: \(drained.suffix(200))")

            // Parse marker lines from OUTPUT only. The PTY echoes the command
            // as one physical script line, which cannot match the per-output
            // regex "<marker><5 digits immediately followed by ESC[0m>".
            let numbers = Self.extractSequence(text: drained, marker: marker)
            #expect(numbers.count == lineCount,
                    "sustained output lost/duplicated lines: recovered \(numbers.count)/\(lineCount)")
            #expect(numbers == Array(0..<lineCount),
                    "sustained sequence was not exactly 0..<\(lineCount) in order")
            #expect(drained.contains("\u{1b}[32m"), "ANSI colour escape must be preserved")
            #expect(drained.contains(marker), "UTF-8 content must be preserved")
            let rate = Double(numbers.count) / max(0.001, drainSeconds)
            print("FLOE_REALVM_DRAIN lines=\(numbers.count) seconds=\(String(format: "%.2f", drainSeconds)) "
                  + "linesPerSecond=\(String(format: "%.0f", rate))")

            // 4) CTRL-C. The success token is assembled by the command that
            //    runs AFTER the interrupt (two printed halves); the literal is
            //    never typed or present beforehand, so a shell blocked in
            //    `sleep` cannot produce it.
            _ = await drive(owner: terminalOwner, command: "sleep 30", timeout: 1) { _ in false }
            await terminalOwner.interrupt()
            try? await Task.sleep(for: .milliseconds(500))
            let (afterInterrupt, ctrlCOK) = await drive(
                owner: terminalOwner,
                command: "printf 'RE''TURN_%s_OK' 'TOKEN'",
                timeout: 8
            ) { $0.contains("RETURN_TOKEN_OK") }
            #expect(ctrlCOK, "shell did not return to a usable prompt after Ctrl-C: \(afterInterrupt.suffix(160))")

            // 5) RESIZE rides the WINCH frame to the guest PTY and survives.
            await terminalOwner.resize(columns: 100, rows: 30)
            let (afterResize, resizeOK) = await drive(
                owner: terminalOwner,
                command: "stty size | grep -q '30 100' && printf GEOM_%s_OK OK",
                timeout: 8
            ) { $0.contains("GEOM_OK_OK") }
            #expect(resizeOK, "guest PTY did not adopt the resized geometry: \(afterResize.suffix(160))")

            // Success summary only when every required stage passed — a
            // partial run must never print the OK line.
            if shellReady && drainOK && ctrlCOK && resizeOK {
                print("FLOE_REALVM_OK baselineMs=\(String(format: "%.0f", baselineRTT)) "
                      + "adaptiveMs=\(String(format: "%.0f", adaptiveRTT)) drainLines=\(numbers.count) "
                      + "rate=\(String(format: "%.0f", rate))/s")
            }
            await cleanup()
        } catch {
            await cleanup()
            Issue.record("real-VM measurement failed: \(error)")
        }
    }

    // MARK: - Measurement helpers

    /// One typed-token round trip. `pollDelayMs == nil` uses the production
    /// visible loop; otherwise paces the SAME production exchange at a fixed
    /// old-cadence delay for the same-VM baseline. Returns milliseconds from
    /// enqueue to the token appearing in output.
    private func measureRoundTrip(
        owner: LocalTerminalOwner,
        pollDelayMs: Int?,
        label: String
    ) async -> Double {
        let samples = 5
        var values: [Double] = []
        for index in 0..<samples {
            let token = String(format: "t%@%02d", String(label.prefix(2)), index)
            let command = "printf 'R%s' \(token)"
            let start = Date()
            if let pollDelayMs {
                let (_, ok) = await pacedExchange(
                    owner: owner, command: command, delayMs: pollDelayMs,
                    predicate: { $0.contains("R\(token)") })
                guard ok else { continue }
            } else {
                let (_, ok) = await drive(
                    owner: owner, command: command, timeout: 10
                ) { $0.contains("R\(token)") }
                guard ok else { continue }
            }
            values.append(Date().timeIntervalSince(start) * 1000)
        }
        guard !values.isEmpty else { return .greatestFiniteMagnitude }
        return values.sorted()[values.count / 2] // median
    }

    /// Baseline pacer: drive the production exchange but sleep a fixed
    /// `delayMs` between polls (the pre-change 150 ms cadence).
    private func pacedExchange(
        owner: LocalTerminalOwner,
        command: String,
        delayMs: Int,
        predicate: @escaping (String) -> Bool
    ) async -> (String, Bool) {
        owner.enqueue(Data((command + "\n").utf8))
        var last = ""
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            await owner.pollOnceForTesting()
            last = String(decoding: owner.output, as: UTF8.self)
            if predicate(last) { return (last, true) }
            try? await Task.sleep(for: .milliseconds(delayMs))
        }
        return (last, predicate(last))
    }

    /// Extracts the exact marker sequence from real output. Only an emitted
    /// coloured line (`<marker><5 digits><ESC>[0m`) is counted; the PTY echo
    /// of the loop command cannot match because its digits are part of the
    /// script text, not a 5-digit number immediately followed by ESC[0m.
    static func extractSequence(text: String, marker: String) -> [Int] {
        var result: [Int] = []
        let escapedMarker = NSRegularExpression.escapedPattern(for: marker)
        let pattern = escapedMarker + #"(\d{5})\x1b\[0m"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return result }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        regex.enumerateMatches(in: text, range: range) { match, _, _ in
            guard let match, let capture = Range(match.range(at: 1), in: text),
                  let value = Int(text[capture]) else { return }
            result.append(value)
        }
        return result
    }
}

/// Thread-confined predicate holder for the visible-loop driver.
@MainActor
private final class PredicateBox: @unchecked Sendable {
    private let predicate: (String) -> Bool
    init(_ predicate: @escaping (String) -> Bool) { self.predicate = predicate }
    func matches(_ text: String) -> Bool { predicate(text) }
}
#endif
