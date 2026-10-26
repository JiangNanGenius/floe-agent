// FloeAppTests — REAL-guest qualification for the official Skill dependency
// channel (opt-in; component proof, not the entire Hub live-install claim).
//
// What this drives is the production path end to end, exactly as the app
// assembles it: the live `AppEnvironment` services, the pinned hash-verified
// Debian/RISC-V TinyEMU image via the same install/boot lifecycle the proven
// `LocalLinuxTerminalRealVMTests` uses (its self-owned workspace pattern is
// the reference; this file does not modify it), the app's ONE shared
// `ManagedPythonInstallService`, a `LinuxGuestLanguagePackages` over the SAME
// production `linuxCommandRunner` instance, and the environment lease through
// the canonical `EnvironmentExecutionCoordinator.acquireManagement` resolver
// (the same resolution `AppEnvironment.resolveSkillDependencyEnvironment`
// uses). There is no mock, no host interpreter and no native fallback: every
// command below executes inside THIS test's own guest.
//
// Required stages (a failure in any one FAILS the test; nothing is skipped
// or cached-faked):
//   1. boot + architecture truth: the owned project container (never the
//      ambient first project) becomes available and the guest itself answers
//      `uname -m` = riscv64;
//   2. shared-cache mount truth: the floe-cache 9p share Main wired is
//      actually mounted at /floe/cache inside this pinned guest (the exact
//      field-2 check `LinuxGuestLanguagePackages` uses to choose the shared
//      cache — the "cache is actually consumed" precondition);
//   3. pip exact pin: managed `install(["mpmath==1.3.0"])` through the real
//      service, then proof INSIDE the shared venv (`/floe/env/python/venv/bin/
//      python3`) of actual import, version string, module location under the
//      venv, and a real mpmath computation;
//   4. wheel-store consumption: the exact same pin installed through the guest
//      pip DIRECTLY with `--no-index --find-links /floe/cache/pip/official-
//      wheels` after uninstalling — possible only if the persisted bytes live
//      under their REAL canonical PEP 427 basename inside the mounted share
//      (the pre-fix invented name could never satisfy this; no redownload
//      masking because the index is disabled);
//   4b. PRODUCTION hash-mode install through the same managed service: a
//       WRONG-but-canonical digest must be refused by the guest's own pip AND
//       leave mpmath uninstalled; the REAL verified wheel digest must then
//       install through pip's `--require-hashes` mode with every pin delivered
//       as a requirements-file line on the runner's standardInput
//       (`--requirement /dev/stdin`) — a CLI `--hash` is a pip grammar error
//       (exit 2 "no such option"), so this stage is the transport contract
//       the real regression needs;
//   5. small Debian package: query the guest's OWN apt candidate for `hello`
//      after `apt-get update`, freeze that exact version string, run the NEW
//      `aptInstallExact` signed transaction with it, read the version back
//      through `aptReadback` (dpkg-query), and EXECUTE /usr/bin/hello.
//
// Optional heavy stage, gated by a SECOND explicit flag
// `FLOE_SKILL_DEPENDENCY_GUEST_FONT_QUALIFICATION=1`: fontconfig +
// fonts-noto-cjk candidates frozen and installed exactly, then the fixed
// stdlib-ctypes FreeType probe must actually render a Chinese and a Japanese
// glyph at 32 px (and must honestly answer NOT-ready before the fonts are
// installed). Without that flag no font payload is ever downloaded here.
//
// Ownership boundary and cleanup (bounded, ordered, awaited): only THIS
// test's temp workspace root and the environment derived from it are touched.
// The lease is finished, the owned guest is stopped and its fixture
// environment deleted; the verified installed image, every other environment,
// all app/user data, other tasks' Simulator state and the shared caches stay
// exactly as they were. No Simulator reset, no user-data erase, no device
// commands from this lane.
//
// SELECTORS (for Main's unified run — disabled opt-in is reported as
// disabled, NEVER as a pass):
//   * FLOE_SKILL_DEPENDENCY_GUEST_QUALIFICATION=1 enables the required
//     stages above (real boot + installs; budget up to the 20-minute first
//     image/install/boot window plus several minutes of emulated apt/pip).
//   * FLOE_SKILL_DEPENDENCY_GUEST_FONT_QUALIFICATION=1 (plus the base flag)
//     adds the font render stage (large download).
//   Test id: FloeApp.SkillDependencyGuestQualification /
//   guestRealPipAptAndWheelStoreQualification().
// Run under the canonical reused Simulator with the repo's
// `select_test_simulator.py --with-lock` serialization; first-use services
// (LinuxGuestPythonProvisioner etc.) are reused, not recreated.
//
// This lane authored and grammar-checked the file only: it was NOT executed
// here (no VM/Simulator run from the lane). The signed-package/authorization
// half is covered by the source lane's unit fixtures; what passes here is the
// actual guest component proof.

#if canImport(SwiftUI) && canImport(UIKit) && DEBUG
import Foundation
import Testing
@testable import FloeApp
import FloeCore
import FloeExecution
import FloeTools
import FloeEnvironments

@Suite("FloeApp.SkillDependencyGuestQualification")
@MainActor
struct SkillDependencyGuestQualificationTests {

    /// Pinned-image verified download + expand and a cold TinyEMU boot can
    /// take several minutes on a first run (same window as the proven
    /// terminal real-VM qualification).
    private let bootTimeout: TimeInterval = 1200

    private static var fontEnabled: Bool {
        ProcessInfo.processInfo.environment["FLOE_SKILL_DEPENDENCY_GUEST_FONT_QUALIFICATION"] == "1"
    }

    private func makeWorkspaceRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("depguest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// The environment THIS test owns, derived from its own workspace root —
    /// never the ambient first project (reference lifecycle, unchanged).
    private func environmentID(forRoot root: URL, registry: EnvironmentRegistry) async -> String? {
        let canonical = root.resolvingSymlinksInPath().standardizedFileURL
        let workspaceID = FloeDigest.sha256Hex(Data(canonical.path.utf8))
        let owned = await registry.containersOwned(by: workspaceID)
        return owned.first { $0.kind == .project && $0.state != .deleting }?.id
    }

    private func waitForAsync(timeout: TimeInterval, _ condition: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return await condition()
    }

    private func bounded(_ text: String, limit: Int = 500) -> String {
        String(text.suffix(limit)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func aptCandidateLine(_ policyOutput: String, identity: String) -> String? {
        var foundIdentity = false
        for rawLine in policyOutput.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("\(identity):") { foundIdentity = true; continue }
            if foundIdentity, line.hasPrefix("Candidate:") {
                let value = String(line.dropFirst("Candidate:".count)).trimmingCharacters(in: .whitespaces)
                guard value != "(none)", !value.isEmpty,
                      LinuxGuestLanguagePackages.isValidAptVersion(value) else { return nil }
                return value
            }
        }
        return nil
    }

    @Test(
        "Real RISC-V guest: uname truth, cache mount truth, mpmath exact pip install + venv import/version/calculation, offline wheel-store consumption, production hash-mode install (wrong digest refused, verified wheel digest accepted through requirements stdin), hello exact apt pin + dpkg readback + execution (+ optional CJK render)",
        .enabled(if: ProcessInfo.processInfo.environment["FLOE_SKILL_DEPENDENCY_GUEST_QUALIFICATION"] == "1")
    )
    func guestRealPipAptAndWheelStoreQualification() async throws {
        let environment = AppEnvironment.live()
        await environment.bootstrap()
        let services = FloePlatformServices.shared
        let root = try makeWorkspaceRoot()
        let started = Date()
        func phase(_ name: String) {
            print("FLOE_DEPGUEST_PHASE \(name) t=\(String(format: "%.1f", Date().timeIntervalSince(started)))s")
        }
        var ownedEnvironmentID = ""
        var leaseFinish: (@Sendable () async -> Void)?
        // ORDERED, AWAITED cleanup of exactly what THIS test owns:
        // finish the lease → stop the guest → delete the fixture environment
        // → remove the temp root. The pinned image, caches, other
        // environments and all user data are untouched.
        func cleanup() async {
            await leaseFinish?()
            leaseFinish = nil
            if !ownedEnvironmentID.isEmpty {
                do { try await services.stopEnvironment(id: ownedEnvironmentID) }
                catch { print("FLOE_DEPGUEST_CLEANUP_STOP_FAILED environment=\(ownedEnvironmentID.prefix(8)) error=\(bounded(error.localizedDescription))") }
                do { try await services.deleteEnvironment(id: ownedEnvironmentID) }
                catch { print("FLOE_DEPGUEST_CLEANUP_DELETE_FAILED environment=\(ownedEnvironmentID.prefix(8)) error=\(bounded(error.localizedDescription)) — a stopped fixture record remains for Main; it is not deleted elsewhere") }
            }
            try? FileManager.default.removeItem(at: root)
        }
        do {
            // 1) Prepare + boot through the actual production services.
            try await services.prepareWorkspaceEnvironment(root: root)
            guard let environmentID = await environmentID(
                forRoot: root, registry: environment.environmentRegistry) else {
                Issue.record("No Linux project environment exists for this test's workspace root")
                await cleanup()
                return
            }
            ownedEnvironmentID = environmentID
            phase("activateWithPreparation.begin")
            try await services.activateLinuxGuestWithPreparation(
                id: environmentID, cancellation: CancellationToken())
            let ready = await waitForAsync(timeout: bootTimeout) {
                await services.linuxEnvironmentAvailable(id: environmentID)
            }
            guard ready else {
                let postStatus = await services.linuxEnvironmentStatus(id: environmentID)
                Issue.record("Linux guest never became available after preparation/boot status=\(String(describing: postStatus))")
                await cleanup()
                return
            }
            phase("guest.booted")
            guard let runner = services.linuxCommandRunner() else {
                Issue.record("The production Linux command runner is not registered (host has no local Linux service)")
                await cleanup()
                return
            }
            func guest(_ argv: [String], timeout: TimeInterval, maxBytes: Int = 256 * 1024) async throws -> LinuxCommandResult {
                try await runner.run(
                    environmentID: environmentID,
                    argv: argv,
                    workingDirectory: nil,
                    standardInput: nil,
                    timeout: timeout,
                    maxOutputBytes: maxBytes,
                    cancellation: nil
                )
            }

            // Architecture truth from the guest itself.
            let uname = try await guest(["uname", "-m"], timeout: 60)
            let arch = uname.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            print("FLOE_DEPGUEST_UNAME_ARCH=\(arch) exit=\(uname.exitCode)")
            #expect(arch == "riscv64", "the pinned TinyEMU guest must answer uname -m riscv64 (got \(arch))")

            // 2) Shared-cache mount truth (exact field-2 check, same robust
            //    verb the managed installs use; honest fail if the pinned
            //    image + share do not actually mount /floe/cache).
            let mount = try await guest(["/bin/sh", "-c",
                #"awk '$2=="/floe/cache"{found=1} END{exit found?0:1}' /proc/mounts"#], timeout: 30, maxBytes: 4 * 1024)
            print("FLOE_DEPGUEST_CACHE_MOUNT_EXIT=\(mount.exitCode)")
            #expect(mount.exitCode == 0, "/floe/cache is not mounted in this real guest — the shared wheel store could never be consumed; failing honestly")

            // The canonical managed-environment lease (same resolution the
            // production dependency center uses for THIS environment id).
            let executions = EnvironmentExecutionCoordinator(
                roots: EnvironmentRoots(), registry: environment.environmentRegistry)
            let lease = try await executions.acquireManagement(
                environmentID: environmentID, cancellation: CancellationToken())
            guard let env = lease.context.environment else {
                Issue.record("The canonical lease resolved no ToolEnvironment")
                await lease.finish()
                await cleanup()
                return
            }
            leaseFinish = lease.finish
            let installer = try #require(environment.managedPythonInstaller)
            let packages = LinuxGuestLanguagePackages(runner: runner)
            let venvPython = LinuxGuestPythonEnvironment.guestVenvPath + "/bin/python3"

            // 3) pip exact pin through the REAL managed service (first use
            //    provisions the shared venv through the existing service).
            //    Proof runs AT dps=30: mpmath's default 15 dps prints
            //    1.4142135623731 (the value rounded to display precision),
            //    which is NOT the binary-double prefix some expected — the
            //    high-precision RISC-V digit string starts
            //    1.414213562373095048, so the assertion pins that exact 20
            //    significant digits (a float32/float64 computation cannot
            //    produce them).
            phase("pip.install.mpmath")
            let pipOutcome = await installer.install(
                specs: ["mpmath==1.3.0"],
                timeout: 600,
                cancellation: nil,
                environment: env
            )
            guard case .ok(let pipOutput) = pipOutcome else {
                let detail: String
                switch pipOutcome {
                case .failed(let message): detail = message
                case .timedOut(let partial): detail = "timeout: " + bounded(partial)
                case .cancelled: detail = "cancelled"
                case .ok: detail = ""
                }
                Issue.record("managed pip install of mpmath==1.3.0 failed in the real guest: \(bounded(detail))")
                await cleanup()
                return
            }
            print("FLOE_DEPGUEST_PIP_INSTALL tail=\(bounded(pipOutput))")
            phase("pip.proof.venv")
            let proof = try await guest([venvPython, "-c",
                "import mpmath; mpmath.mp.dps=30; print(mpmath.__version__); print(mpmath.__file__); print(mpmath.sqrt(2))"],
                timeout: 300, maxBytes: 8 * 1024)
            #expect(proof.exitCode == 0, "venv python proof run failed: \(bounded(proof.stderr))")
            let proofLines = proof.stdout
                .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            guard proofLines.count >= 3 else {
                Issue.record("unexpected proof output: \(bounded(proof.stdout))")
                await cleanup()
                return
            }
            #expect(proofLines[0] == "1.3.0", "imported mpmath version is not the pinned 1.3.0: \(proofLines[0])")
            #expect(proofLines[1].contains(LinuxGuestPythonEnvironment.guestVenvPath),
                    "mpmath must import from THIS environment's shared guest venv, saw \(proofLines[1])")
            #expect(proofLines[2].hasPrefix("1.414213562373095048"),
                    "mpmath.sqrt(2) at dps=30 must start 1.414213562373095048, saw \(proofLines[2])")
            print("FLOE_DEPGUEST_PIP_PROOF version=\(proofLines[0]) location=\(bounded(proofLines[1], 120)) sqrt2=\(proofLines[2])")

            // 4) Wheel-store consumption proof: persist the exact verified
            //    bytes host-side through the production store path, uninstall
            //    the venv copy, then install INSIDE the guest with the index
            //    DISABLED. Success means pip discovered the canonical wheel
            //    basename through the real 9p mount — not a redownload.
            phase("wheelstore.persist")
            let hostStoreRoot: URL
            do {
                hostStoreRoot = try RuntimeV2Layout.production().cacheDirectory(kind: "pip")
                try FileManager.default.createDirectory(at: hostStoreRoot, withIntermediateDirectories: true)
            } catch {
                Issue.record("The production pip cache root is unavailable, so wheel-store consumption cannot be proven: \(error)")
                await cleanup()
                return
            }
            let wheels = try await ManagedPythonPackageInspector.fetchVerifiedWheels(specs: ["mpmath==1.3.0"])
            guard let verified = wheels.first, verified.spec == "mpmath==1.3.0" else {
                Issue.record("the managed inspector returned no verified bundle for the pinned spec")
                await cleanup()
                return
            }
            let storeBundle = SkillDependencyWheelBundle(
                spec: verified.spec, filename: verified.filename,
                sha256: verified.sha256, size: verified.size, bytes: verified.bytes)
            guard storeBundle.isCanonical else {
                Issue.record("the fetched bundle failed the canonical gate")
                await cleanup()
                return
            }
            let binding = SkillDependencyPreparationCenter.WheelStoreBinding(
                spec: "mpmath==1.3.0", filename: storeBundle.filename,
                sha256: storeBundle.sha256, size: storeBundle.size)
            try SkillDependencyPreparationCenter.persistWheelBinding(
                storeURL: hostStoreRoot, bundle: storeBundle, binding: binding)
            phase("wheelstore.offline.reinstall")
            let uninstall = await installer.uninstall(distribution: "mpmath", environment: env, cancellation: nil)
            guard case .ok = uninstall else {
                Issue.record("pre-offline-test uninstall failed: \(bounded(uninstall.describeForQualification()))")
                await cleanup()
                return
            }
            let offline = try await guest(
                [venvPython, "-m", "pip", "install", "--disable-pip-version-check", "--no-input",
                 "--no-index", "--find-links", "/floe/cache/pip/official-wheels", "mpmath==1.3.0"],
                timeout: 600)
            #expect(offline.exitCode == 0,
                    "pip --no-index --find-links install failed (wheel not discoverable through the mount?): \(bounded(offline.stdout + offline.stderr))")
            let offlineProof = try await guest([venvPython, "-c",
                "import mpmath; mpmath.mp.dps=30; print(mpmath.__version__, mpmath.sqrt(2))"], timeout: 300, maxBytes: 4 * 1024)
            #expect(offlineProof.exitCode == 0
                    && offlineProof.stdout.contains("1.3.0")
                    && offlineProof.stdout.contains("1.414213562373095048"),
                    "the offline-installed mpmath did not import/compute at exact precision: \(bounded(offlineProof.stdout)) \(bounded(offlineProof.stderr))")
            print("FLOE_DEPGUEST_WHEELSTORE_OFFLINE_OK wheel=\(storeBundle.filename) sha=\(String(storeBundle.sha256.prefix(12)))")

            // 4b) PRODUCTION hash-mode install through the same managed
            //     service — the transport under real-guest qualification:
            //     pip's `--require-hashes` mode with every pin as a
            //     requirements-file line fed through the runner's
            //     standardInput (`--requirement /dev/stdin`). A CLI `--hash`
            //     never reaches pip at all (its parser exits 2), so only a
            //     real digest-verified guest install proves the contract.
            //     Order: uninstall → WRONG-but-canonical digest must be
            //     refused and leave NOTHING installed → the verified wheel
            //     digest must install and compute at exact precision.
            phase("hashmode.uninstall.before")
            let preHashUninstall = await installer.uninstall(distribution: "mpmath", environment: env, cancellation: nil)
            guard case .ok = preHashUninstall else {
                Issue.record("pre-hash-mode uninstall failed: \(bounded(preHashUninstall.describeForQualification()))")
                await cleanup()
                return
            }
            phase("hashmode.wrongdigest.refused")
            let wrongDigest = String(repeating: "a", count: 64)
            let wrongHashOutcome = await installer.install(
                specs: ["mpmath==1.3.0"],
                timeout: 600,
                findLinksGuestPath: "/floe/cache/pip/official-wheels",
                hashesBySpec: ["mpmath==1.3.0": [wrongDigest]],
                cancellation: nil,
                environment: env
            )
            guard case .failed = wrongHashOutcome else {
                Issue.record("guest pip ACCEPTED a wrong sha256 pin in hash mode — digest verification is not real: \(bounded(wrongHashOutcome.describeForQualification()))")
                await cleanup()
                return
            }
            let wrongImport = try await guest([venvPython, "-c", "import mpmath"], timeout: 120, maxBytes: 4 * 1024)
            #expect(wrongImport.exitCode != 0,
                    "the refused wrong-hash install must leave mpmath NOT installed, import exit was \(wrongImport.exitCode)")
            phase("hashmode.verifieddigest.install")
            let verifiedHashOutcome = await installer.install(
                specs: ["mpmath==1.3.0"],
                timeout: 600,
                findLinksGuestPath: "/floe/cache/pip/official-wheels",
                hashesBySpec: ["mpmath==1.3.0": [verified.sha256]],
                cancellation: nil,
                environment: env
            )
            guard case .ok(let verifiedHashOutput) = verifiedHashOutcome else {
                let detail: String
                switch verifiedHashOutcome {
                case .failed(let message): detail = message
                case .timedOut(let partial): detail = "timeout: " + bounded(partial)
                case .cancelled: detail = "cancelled"
                case .ok: detail = ""
                }
                Issue.record("production hash-mode install with the verified wheel digest failed in the real guest (pip's own grammar rejects the transport or the digest does not match the served artifact): \(bounded(detail))")
                await cleanup()
                return
            }
            let hashProof = try await guest([venvPython, "-c",
                "import mpmath; mpmath.mp.dps=30; print(mpmath.__version__); print(mpmath.sqrt(2))"],
                timeout: 300, maxBytes: 8 * 1024)
            #expect(hashProof.exitCode == 0
                    && hashProof.stdout.contains("1.3.0")
                    && hashProof.stdout.contains("1.414213562373095048"),
                    "the hash-mode-installed mpmath did not import/compute at exact precision: \(bounded(hashProof.stdout)) \(bounded(hashProof.stderr))")
            print("FLOE_DEPGUEST_HASHMODE_OK verifiedDigest=\(String(verified.sha256.prefix(12))) wrongDigestRefused=yes installTail=\(bounded(verifiedHashOutput, 160))")

            // 5) Small Debian package through the NEW exact-pin transaction.
            phase("apt.update.candidate.hello")
            _ = try await guest(["apt-get", "update"], timeout: 600, maxBytes: 128 * 1024)
            let policy = try await guest(["/bin/sh", "-c", "apt-cache policy hello"], timeout: 120, maxBytes: 32 * 1024)
            guard let candidate = aptCandidateLine(policy.stdout, identity: "hello") else {
                Issue.record("could not freeze an exact apt candidate for hello from the guest: \(bounded(policy.stdout))")
                await cleanup()
                return
            }
            print("FLOE_DEPGUEST_APT_CANDIDATE hello=\(candidate)")
            phase("apt.installExact.hello")
            _ = try await packages.aptInstallExact(
                identity: "hello", version: candidate, environment: env, cancellation: nil)
            let readback = try await packages.aptReadback(identity: "hello", environment: env, cancellation: nil)
            #expect(readback == candidate, "dpkg readback \(String(describing: readback)) != frozen candidate \(candidate)")
            phase("apt.execute.hello")
            let helloRun = try await guest(["/usr/bin/hello"], timeout: 60, maxBytes: 4 * 1024)
            #expect(helloRun.exitCode == 0 && helloRun.stdout.contains("Hello"),
                    "/usr/bin/hello did not execute cleanly: exit=\(helloRun.exitCode) out=\(bounded(helloRun.stdout))")
            print("FLOE_DEPGUEST_APT_OK hello=\(candidate) stdout=\(bounded(helloRun.stdout, 120))")

            // Optional declared-font render stage (never without its own
            // explicit flag: no unconditional heavy font download).
            if Self.fontEnabled {
                phase("font.probe.before")
                let before = try await packages.cjkFontProbe(environment: env, cancellation: nil)
                print("FLOE_DEPGUEST_FONT_PROBE_BEFORE=\(before)")
                #expect(!before, "the FreeType probe must honestly answer not-ready before the declared fonts are installed (an always-true probe is a broken probe)")
                _ = try await guest(["apt-get", "update"], timeout: 600, maxBytes: 128 * 1024)
                for identity in ["fontconfig", "fonts-noto-cjk"] {
                    let fontPolicy = try await guest(["/bin/sh", "-c", "apt-cache policy \(identity)"], timeout: 120, maxBytes: 32 * 1024)
                    guard let pin = aptCandidateLine(fontPolicy.stdout, identity: identity) else {
                        Issue.record("could not freeze an exact apt candidate for \(identity): \(bounded(fontPolicy.stdout))")
                        await cleanup()
                        return
                    }
                    phase("font.installExact.\(identity)")
                    _ = try await packages.aptInstallExact(
                        identity: identity, version: pin, environment: env, cancellation: nil)
                    let fontReadback = try await packages.aptReadback(identity: identity, environment: env, cancellation: nil)
                    #expect(fontReadback == pin, "\(identity) readback \(String(describing: fontReadback)) != frozen pin \(pin)")
                    print("FLOE_DEPGUEST_FONT_PINNED \(identity)=\(pin)")
                }
                phase("font.probe.after")
                let after = try await packages.cjkFontProbe(environment: env, cancellation: nil)
                print("FLOE_DEPGUEST_FONT_PROBE_AFTER=\(after)")
                #expect(after, "the fixed FreeType glyph-render probe did not pass after the declared fontconfig+fonts-noto-cjk pins installed — renderer or faces are genuinely not ready")
            }

            await leaseFinish.map { await $0() }
            leaseFinish = nil
            await cleanup()
            print("FLOE_DEPGUEST_OK bootSeconds=\(String(format: "%.1f", Date().timeIntervalSince(started))) arch=riscv64 mpmath=1.3.0 wheelOffline=\(storeBundle.filename) hello=\(candidate) fontStage=\(Self.fontEnabled ? "rendered" : "not-enabled")")
            print("NOTE: this is the actual-guest component proof (pip/apt/wheel-store/mount/render). Signed-package authorization and Hub live-install end-to-end remain covered by the center unit fixtures and Root's install acceptance.")
        } catch {
            await cleanup()
            Issue.record("real-guest dependency qualification failed: \(error)")
        }
    }
}

private extension ManagedPythonInstallService.Outcome {
    /// Compact honest description for qualification logging only.
    func describeForQualification() -> String {
        switch self {
        case .ok(let output): return output
        case .failed(let message): return message
        case .timedOut(let partial): return "timedOut " + partial
        case .cancelled: return "cancelled"
        }
    }
}
#endif
