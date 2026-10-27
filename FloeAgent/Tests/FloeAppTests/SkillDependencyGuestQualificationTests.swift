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
// SPLIT (2026-10-27, job-2e854a51185441e3): the file now carries TWO serial
// opt-in methods over the SAME production boot/cleanup helpers, so Main can
// run the apt case alone during the real-guest apt repair without paying the
// ~6-minute Python/pip wheel-download window again. The original Python
// method KEEPS its exact historical name (Main owns the run filters and
// markers):
//
//   `guestRealPipAptAndWheelStoreQualification()` — Python channel, stages 1–4b:
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
//       WRONG-but-canonical digest must be refused by the guest's own pip
//       with pip's OWN hash verdict visible in the failure (the leg cannot
//       pass on a generic or transport failure) AND must leave mpmath
//       uninstalled; the REAL verified wheel digest must then install
//       through pip's `--require-hashes` mode with every pin delivered as a
//       requirements-file line on the runner's standardInput to a pin-free
//       guest wrapper that materializes an owned temporary requirements
//       file and runs pip against that real path — `/dev/stdin` is NOT
//       assumed (the real guest has no such path; 2026-10-27 regression)
//       and a CLI `--hash` is a pip grammar error (exit 2 "no such option"),
//       so this stage is the transport contract the real regression needs.
//
//   `guestAptExactInstallQualification()` — Debian channel, stages 5–6:
//   5. small Debian package: run `apt-get update` IN THE QUALIFICATION and
//      ENFORCE its exit BEFORE any candidate parsing, then query the guest's
//      OWN `apt-cache policy hello` and enforce its exit BEFORE the candidate
//      parse, freeze that exact version string, run the production
//      `aptInstallExact` signed transaction with it, read the version back
//      through `aptReadback` (dpkg-query), and EXECUTE /usr/bin/hello.
//      A failure at either gate is a FAIL (never a pass, never a skip) and
//      captures the FULL exit/stdout/stderr tails plus a fixed bounded
//      guest-side diagnostics battery (identity, clock, resolv, sources,
//      keyrings, lists dirs, DNS probe, HTTP mirror probe, apt config) so the
//      first apt-only run already returns the true root-cause evidence. The
//      previous shape discarded the update output and recorded an empty
//      policy stdout, which is exactly what hid the real stderr in the
//      2026-10-27 survey run (both update and policy exited 100).
//   6. optional font stage, gated by the SECOND flag below.
//
// Optional heavy stage, gated by a SECOND explicit flag
// `FLOE_SKILL_DEPENDENCY_GUEST_FONT_QUALIFICATION=1` (apt method only):
// fontconfig + fonts-noto-cjk candidates frozen and installed exactly, then
// the fixed stdlib-ctypes FreeType probe must actually render a Chinese and a
// Japanese glyph at 32 px (and must honestly answer NOT-ready before the
// fonts are installed). Without that flag no font payload is ever downloaded
// here.
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
//   * FLOE_SKILL_DEPENDENCY_GUEST_QUALIFICATION=1 enables BOTH methods above
//     (suite `.serialized` keeps them serial; each boots its own fixture).
//   * FLOE_SKILL_DEPENDENCY_GUEST_FONT_QUALIFICATION=1 (plus the base flag)
//     adds the font render stage to the apt method (large download).
//   * Apt-only repair iteration (the whole point of the split):
//       -only-testing:FloeAppTests/SkillDependencyGuestQualificationTests/guestAptExactInstallQualification()
//     with FLOE_SKILL_DEPENDENCY_GUEST_QUALIFICATION=1 — boot ≈ 30 s, apt
//     verdict within ~1–2 minutes, no Python download window.
//   Python-only: -only-testing:…/guestRealPipAptAndWheelStoreQualification().
//   Final qualification may keep BOTH methods selected together.
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

@Suite("FloeApp.SkillDependencyGuestQualification", .serialized)
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
        let redacted = SecretRedactor.redact(text).replacingOccurrences(
            of: #"(?i)(https?://)[^/\s\"'@]+@"#,
            with: "$1[redacted]@", options: .regularExpression)
        return String(redacted.suffix(limit)).trimmingCharacters(in: .whitespacesAndNewlines)
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

    /// Shared production boot preamble for BOTH methods: prepare + boot the
    /// owned fixture through the actual app services and resolve the
    /// canonical management lease. Returns nil after recording the honest
    /// failure and cleaning exactly its own partial state.
    private struct BootedGuest {
        let root: URL
        let environmentID: String
        let runner: any LinuxCommandRunning
        let env: ToolEnvironment
        let services: FloePlatformServices
        let leaseFinish: (@Sendable () async -> Void)?

        /// ORDERED, AWAITED cleanup of exactly what THIS test owns:
        /// finish the lease → stop the guest → delete the fixture environment
        /// → remove the temp root. The pinned image, caches, other
        /// environments and all user data are untouched.
        func teardown() async {
            await leaseFinish?()
            if !environmentID.isEmpty {
                do { try await services.stopEnvironment(id: environmentID) }
                catch { print("FLOE_DEPGUEST_CLEANUP_STOP_FAILED environment=\(environmentID.prefix(8)) error=\(String(error.localizedDescription.suffix(200)).trimmingCharacters(in: .whitespacesAndNewlines))") }
                do { try await services.deleteEnvironment(id: environmentID) }
                catch { print("FLOE_DEPGUEST_CLEANUP_DELETE_FAILED environment=\(environmentID.prefix(8)) error=\(String(error.localizedDescription.suffix(200)).trimmingCharacters(in: .whitespacesAndNewlines)) — a stopped fixture record remains for Main; it is not deleted elsewhere") }
            }
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func bootOwnedGuest(
        environment: AppEnvironment,
        services: FloePlatformServices,
        phase: @escaping (String) -> Void
    ) async -> BootedGuest? {
        let root: URL
        do { root = try makeWorkspaceRoot() }
        catch {
            Issue.record("could not create this test's private workspace root: \(error)")
            return nil
        }
        var ownedEnvironmentID = ""
        var leaseFinish: (@Sendable () async -> Void)?
        func partialCleanup() async {
            await leaseFinish?()
            leaseFinish = nil
            if !ownedEnvironmentID.isEmpty {
                try? await services.stopEnvironment(id: ownedEnvironmentID)
                try? await services.deleteEnvironment(id: ownedEnvironmentID)
            }
            try? FileManager.default.removeItem(at: root)
        }
        do {
            try await services.prepareWorkspaceEnvironment(root: root)
            guard let environmentID = await environmentID(
                forRoot: root, registry: environment.environmentRegistry) else {
                Issue.record("No Linux project environment exists for this test's workspace root")
                await partialCleanup()
                return nil
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
                await partialCleanup()
                return nil
            }
            phase("guest.booted")
            guard let runner = services.linuxCommandRunner() else {
                Issue.record("The production Linux command runner is not registered (host has no local Linux service)")
                await partialCleanup()
                return nil
            }
            let executions = EnvironmentExecutionCoordinator(
                roots: EnvironmentRoots(), registry: environment.environmentRegistry)
            let lease = try await executions.acquireManagement(
                environmentID: environmentID, cancellation: CancellationToken())
            guard let env = lease.context.environment else {
                Issue.record("The canonical lease resolved no ToolEnvironment")
                await lease.finish()
                await partialCleanup()
                return nil
            }
            leaseFinish = lease.finish
            return BootedGuest(
                root: root,
                environmentID: environmentID,
                runner: runner,
                env: env,
                services: services,
                leaseFinish: lease.finish
            )
        } catch {
            await partialCleanup()
            Issue.record("real-guest dependency boot failed: \(error)")
            return nil
        }
    }

    @Test(
        "Real RISC-V guest: uname truth, cache mount truth, mpmath exact pip install + venv import/version/calculation, offline wheel-store consumption, production hash-mode install (wrong digest refused by pip's own hash verdict, verified wheel digest installed through the owned temp-file transport)",
        .enabled(if: ProcessInfo.processInfo.environment["FLOE_SKILL_DEPENDENCY_GUEST_QUALIFICATION"] == "1")
    )
    func guestRealPipAptAndWheelStoreQualification() async throws {
        let environment = AppEnvironment.live()
        await environment.bootstrap()
        let services = FloePlatformServices.shared
        let started = Date()
        func phase(_ name: String) {
            print("FLOE_DEPGUEST_PHASE \(name) t=\(String(format: "%.1f", Date().timeIntervalSince(started)))s")
        }
        guard let guest = await bootOwnedGuest(
            environment: environment, services: services, phase: phase) else { return }
        var finished = false
        func cleanup() async {
            if finished { return }
            finished = true
            await guest.teardown()
        }
        do {
            func runGuest(_ argv: [String], timeout: TimeInterval, maxBytes: Int = 256 * 1024) async throws -> LinuxCommandResult {
                try await guest.runner.run(
                    environmentID: guest.environmentID,
                    argv: argv,
                    workingDirectory: nil,
                    standardInput: nil,
                    timeout: timeout,
                    maxOutputBytes: maxBytes,
                    cancellation: nil
                )
            }

            // Architecture truth from the guest itself.
            let uname = try await runGuest(["uname", "-m"], timeout: 60)
            let arch = uname.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            print("FLOE_DEPGUEST_UNAME_ARCH=\(arch) exit=\(uname.exitCode)")
            #expect(arch == "riscv64", "the pinned TinyEMU guest must answer uname -m riscv64 (got \(arch))")

            // 2) Shared-cache mount truth (exact field-2 check, same robust
            //    verb the managed installs use; honest fail if the pinned
            //    image + share do not actually mount /floe/cache).
            let mount = try await runGuest(["/bin/sh", "-c",
                #"awk '$2=="/floe/cache"{found=1} END{exit found?0:1}' /proc/mounts"#], timeout: 30, maxBytes: 4 * 1024)
            print("FLOE_DEPGUEST_CACHE_MOUNT_EXIT=\(mount.exitCode)")
            #expect(mount.exitCode == 0, "/floe/cache is not mounted in this real guest — the shared wheel store could never be consumed; failing honestly")

            let installer = try #require(environment.managedPythonInstaller)
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
                environment: guest.env
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
            let proof = try await runGuest([venvPython, "-c",
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
            print("FLOE_DEPGUEST_PIP_PROOF version=\(proofLines[0]) location=\(bounded(proofLines[1], limit: 120)) sqrt2=\(proofLines[2])")

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
            let uninstall = await installer.uninstall(distribution: "mpmath", environment: guest.env, cancellation: nil)
            guard case .ok = uninstall else {
                Issue.record("pre-offline-test uninstall failed: \(bounded(uninstall.describeForQualification()))")
                await cleanup()
                return
            }
            let offline = try await runGuest(
                [venvPython, "-m", "pip", "install", "--disable-pip-version-check", "--no-input",
                 "--no-index", "--find-links", "/floe/cache/pip/official-wheels", "mpmath==1.3.0"],
                timeout: 600)
            #expect(offline.exitCode == 0,
                    "pip --no-index --find-links install failed (wheel not discoverable through the mount?): \(bounded(offline.stdout + offline.stderr))")
            let offlineProof = try await runGuest([venvPython, "-c",
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
            //     standardInput to a pin-free guest wrapper that writes an
            //     owned temporary requirements file and invokes pip with
            //     that REAL path. `/dev/stdin` is never assumed — this is
            //     the exact path the 2026-10-27 real guest broke on (pip
            //     exit 1 "Could not open requirements file: '/dev/stdin'").
            //     A CLI `--hash` never reaches pip at all (its parser exits
            //     2), so only a real digest-verified guest install proves
            //     the contract. Order: uninstall → WRONG-but-canonical
            //     digest must be refused BY PIP'S OWN HASH VERDICT (the
            //     failure text must show the mismatch, not a generic or
            //     transport error) and leave NOTHING installed → the
            //     verified wheel digest must install and compute at exact
            //     precision.
            phase("hashmode.uninstall.before")
            let preHashUninstall = await installer.uninstall(distribution: "mpmath", environment: guest.env, cancellation: nil)
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
                environment: guest.env
            )
            guard case .failed(let wrongHashMessage) = wrongHashOutcome else {
                Issue.record("guest pip ACCEPTED a wrong sha256 pin in hash mode — digest verification is not real: \(bounded(wrongHashOutcome.describeForQualification()))")
                await cleanup()
                return
            }
            // The refusal must be PIP'S OWN hash verdict, not merely "some
            // failure": the 2026-10-27 run reached this leg while the whole
            // transport was already broken (/dev/stdin), and a bare
            // `.failed` still passed. Require pip's mismatch wording and
            // explicitly reject transport-shaped failures instead.
            let wrongNormalized = wrongHashMessage.lowercased()
            let hashVerdictMarkers = [
                "the packages do not match the hashes",
                "expected sha256",
                "has the wrong hash",
            ]
            let transportFailureMarkers = [
                "could not open requirements file",
                "/dev/stdin",
                "floe-pip-hash-transport:",
                "no such option",
                "no module named",
                "traceback (most recent call last)",
            ]
            let matchedVerdict = hashVerdictMarkers.first { wrongNormalized.contains($0) }
            #expect(matchedVerdict != nil,
                    "the wrong-digest install failed, but NOT with pip's own hash-mismatch verdict — the leg cannot pass on a generic or transport failure: \(bounded(wrongHashMessage))")
            #expect(transportFailureMarkers.first { wrongNormalized.contains($0) } == nil,
                    "the wrong-digest refusal carries a transport-failure marker; the hash verdict must stand on its own: \(bounded(wrongHashMessage))")
            print("FLOE_DEPGUEST_HASHMODE_WRONGREFUSED marker=\(matchedVerdict ?? "none") tail=\(bounded(wrongHashMessage, limit: 220))")
            let wrongImport = try await runGuest([venvPython, "-c", "import mpmath"], timeout: 120, maxBytes: 4 * 1024)
            #expect(wrongImport.exitCode != 0,
                    "the refused wrong-hash install must leave mpmath NOT installed, import exit was \(wrongImport.exitCode)")
            phase("hashmode.verifieddigest.install")
            let verifiedHashOutcome = await installer.install(
                specs: ["mpmath==1.3.0"],
                timeout: 600,
                findLinksGuestPath: "/floe/cache/pip/official-wheels",
                hashesBySpec: ["mpmath==1.3.0": [verified.sha256]],
                cancellation: nil,
                environment: guest.env
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
            let hashProof = try await runGuest([venvPython, "-c",
                "import mpmath; mpmath.mp.dps=30; print(mpmath.__version__); print(mpmath.sqrt(2))"],
                timeout: 300, maxBytes: 8 * 1024)
            #expect(hashProof.exitCode == 0
                    && hashProof.stdout.contains("1.3.0")
                    && hashProof.stdout.contains("1.414213562373095048"),
                    "the hash-mode-installed mpmath did not import/compute at exact precision: \(bounded(hashProof.stdout)) \(bounded(hashProof.stderr))")
            print("FLOE_DEPGUEST_HASHMODE_OK verifiedDigest=\(String(verified.sha256.prefix(12))) wrongDigestRefused=yes installTail=\(bounded(verifiedHashOutput, limit: 160))")

            await cleanup()
            print("FLOE_DEPGUEST_OK bootSeconds=\(String(format: "%.1f", Date().timeIntervalSince(started))) arch=riscv64 mpmath=1.3.0 wheelOffline=\(storeBundle.filename)")
            print("NOTE: this is the actual-guest component proof (pip/wheel-store/mount). The apt pin/readback/execute and font render legs are proven by guestAptExactInstallQualification() in this suite. Signed-package authorization and Hub live-install end-to-end remain covered by the center unit fixtures and Root's install acceptance.")
        } catch {
            await cleanup()
            Issue.record("real-guest dependency qualification failed: \(error)")
        }
    }

    @Test(
        "Real RISC-V guest (apt-only isolation): apt-get update + apt-cache policy truth with full exit/stdout/stderr capture and fixed diagnostics before candidate parse, hello exact apt pin through production aptInstallExact + dpkg readback + execution (+ optional fontconfig/fonts-noto-cjk pins and CJK render)",
        .enabled(if: ProcessInfo.processInfo.environment["FLOE_SKILL_DEPENDENCY_GUEST_QUALIFICATION"] == "1")
    )
    func guestAptExactInstallQualification() async throws {
        let environment = AppEnvironment.live()
        await environment.bootstrap()
        let services = FloePlatformServices.shared
        let started = Date()
        func phase(_ name: String) {
            print("FLOE_DEPGUEST_PHASE \(name) t=\(String(format: "%.1f", Date().timeIntervalSince(started)))s")
        }
        guard let guest = await bootOwnedGuest(
            environment: environment, services: services, phase: phase) else { return }
        var finished = false
        func cleanup() async {
            if finished { return }
            finished = true
            await guest.teardown()
        }
        do {
            func runGuest(_ argv: [String], timeout: TimeInterval, maxBytes: Int = 256 * 1024) async throws -> LinuxCommandResult {
                try await guest.runner.run(
                    environmentID: guest.environmentID,
                    argv: argv,
                    workingDirectory: nil,
                    standardInput: nil,
                    timeout: timeout,
                    maxOutputBytes: maxBytes,
                    cancellation: nil
                )
            }

            // Architecture truth from the guest itself (same boot sanity the
            // full suite asserts; cheap, keeps this method independently
            // meaningful during the repair loop).
            let uname = try await runGuest(["uname", "-m"], timeout: 60)
            let arch = uname.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            print("FLOE_DEPGUEST_UNAME_ARCH=\(arch) exit=\(uname.exitCode)")
            #expect(arch == "riscv64", "the pinned TinyEMU guest must answer uname -m riscv64 (got \(arch))")

            let packages = LinuxGuestLanguagePackages(runner: guest.runner)

            /// Fixed, bounded, guest-side READ-ONLY diagnostics battery. Every
            /// probe is a hard-coded `/bin/sh -c` script (no interpolation of
            /// anything dynamic into argv), captured with exit/stdout/stderr.
            /// It exists so ONE apt-only run already returns the true
            /// root-cause evidence instead of an empty stdout.
            func aptDiagnostics() async -> String {
                let probes: [(label: String, script: String, maxBytes: Int)] = [
                    ("id", "id 2>&1", 8 * 1024),
                    ("clock-utc", "date -u +%Y-%m-%dT%H:%M:%SZ 2>&1", 8 * 1024),
                    ("resolv", "cat /etc/resolv.conf 2>&1", 8 * 1024),
                    ("sources", #"cat /etc/apt/sources.list 2>&1; echo ---; ls -la /etc/apt/sources.list.d 2>&1; for f in /etc/apt/sources.list.d/*; do [ -f "$f" ] && { echo "== $f"; cat "$f" 2>&1; }; done"#, 32 * 1024),
                    ("keyrings", "ls -la /etc/apt/trusted.gpg.d /etc/apt/keyrings /usr/share/keyrings 2>&1", 32 * 1024),
                    ("lists-dir", "ls -ld /var/lib/apt/lists /var/lib/apt/lists/partial 2>&1; ls -la /var/lib/apt/lists 2>&1", 32 * 1024),
                    ("dns-deb", "getent hosts deb.debian.org 2>&1; echo getent_exit=$?", 8 * 1024),
                    ("http-mirror-probe", #"python3 -c "import urllib.request as u; print(u.urlopen('http://deb.debian.org/debian/', timeout=30).status)" 2>&1"#, 8 * 1024),
                    ("apt-config", "apt-config dump 2>&1", 64 * 1024),
                ]
                var lines: [String] = []
                for probe in probes {
                    do {
                        let result = try await runGuest(["/bin/sh", "-c", probe.script], timeout: 90, maxBytes: probe.maxBytes)
                        let combined = result.stdout + (result.stderr.isEmpty ? "" : "\n[stderr] " + result.stderr)
                        lines.append("[apt-diag:\(probe.label)] exit=\(result.exitCode) output=\(bounded(combined, limit: 900))")
                    } catch {
                        lines.append("[apt-diag:\(probe.label)] runner-threw=\(bounded(error.localizedDescription))")
                    }
                }
                let block = lines.joined(separator: "\n")
                print("FLOE_DEPGUEST_APT_DIAGNOSTICS\n\(block)")
                return block
            }

            // 5) apt-get update FIRST, FULLY CAPTURED and ENFORCED before any
            //    candidate parsing. The discarded `_ =` output of the old
            //    combined shape hid the real stderr (exit 100 with no recorded
            //    detail); a network/mirror error must FAIL here, loudly, with
            //    exit/stdout/stderr and the diagnostics battery — never pass,
            //    never skip.
            phase("apt.update")
            let update = try await runGuest(["apt-get", "update"], timeout: 600, maxBytes: 128 * 1024)
            print("FLOE_DEPGUEST_APT_UPDATE exit=\(update.exitCode) stdout=\(bounded(update.stdout, limit: 1_800)) stderr=\(bounded(update.stderr, limit: 1_800))")
            guard update.exitCode == 0 else {
                let diagnostics = await aptDiagnostics()
                Issue.record("apt-get update failed in the real guest BEFORE any candidate parse — exit=\(update.exitCode); stderr tail: \(bounded(update.stderr, limit: 4_000)); stdout tail: \(bounded(update.stdout, limit: 2_000)); diagnostics:\n\(diagnostics)")
                await cleanup()
                return
            }

            // apt-cache policy hello: the previous shape recorded only an
            // empty stdout (apt answers exit 100 with its message on stderr
            // when the cache holds no such package — a direct consequence of
            // the update above having failed). Enforce the exit BEFORE the
            // candidate parse and capture BOTH streams either way.
            phase("apt.policy.hello")
            let policy = try await runGuest(["/bin/sh", "-c", "apt-cache policy hello"], timeout: 120, maxBytes: 32 * 1024)
            print("FLOE_DEPGUEST_APT_POLICY hello exit=\(policy.exitCode) stdout=\(bounded(policy.stdout, limit: 1_500)) stderr=\(bounded(policy.stderr, limit: 1_500))")
            guard policy.exitCode == 0 else {
                let diagnostics = await aptDiagnostics()
                Issue.record("apt-cache policy hello failed before the candidate parse — exit=\(policy.exitCode); stderr tail: \(bounded(policy.stderr, limit: 4_000)); stdout tail: \(bounded(policy.stdout, limit: 2_000)); diagnostics:\n\(diagnostics)")
                await cleanup()
                return
            }
            guard let candidate = aptCandidateLine(policy.stdout, identity: "hello") else {
                let diagnostics = await aptDiagnostics()
                Issue.record("could not freeze an exact apt candidate for hello from the guest — exit=\(policy.exitCode); stdout tail: \(bounded(policy.stdout, limit: 2_000)); stderr tail: \(bounded(policy.stderr, limit: 2_000)); diagnostics:\n\(diagnostics)")
                await cleanup()
                return
            }
            print("FLOE_DEPGUEST_APT_CANDIDATE hello=\(candidate)")
            phase("apt.installExact.hello")
            _ = try await packages.aptInstallExact(
                identity: "hello", version: candidate, environment: guest.env, cancellation: nil)
            let readback = try await packages.aptReadback(identity: "hello", environment: guest.env, cancellation: nil)
            #expect(readback == candidate, "dpkg readback \(String(describing: readback)) != frozen candidate \(candidate)")
            phase("apt.execute.hello")
            let helloRun = try await runGuest(["/usr/bin/hello"], timeout: 60, maxBytes: 4 * 1024)
            #expect(helloRun.exitCode == 0 && helloRun.stdout.contains("Hello"),
                    "/usr/bin/hello did not execute cleanly: exit=\(helloRun.exitCode) out=\(bounded(helloRun.stdout))")
            print("FLOE_DEPGUEST_APT_OK hello=\(candidate) stdout=\(bounded(helloRun.stdout, limit: 120))")

            // Optional declared-font render stage (never without its own
            // explicit flag: no unconditional heavy font download). Same
            // enforcement discipline: update/policy capture before parse.
            if Self.fontEnabled {
                phase("font.probe.before")
                let before = try await packages.cjkFontProbe(environment: guest.env, cancellation: nil)
                print("FLOE_DEPGUEST_FONT_PROBE_BEFORE=\(before)")
                #expect(!before, "the FreeType probe must honestly answer not-ready before the declared fonts are installed (an always-true probe is a broken probe)")
                phase("font.apt.update")
                let fontUpdate = try await runGuest(["apt-get", "update"], timeout: 600, maxBytes: 128 * 1024)
                print("FLOE_DEPGUEST_APT_UPDATE_FONT exit=\(fontUpdate.exitCode) stdout=\(bounded(fontUpdate.stdout, limit: 1_800)) stderr=\(bounded(fontUpdate.stderr, limit: 1_800))")
                guard fontUpdate.exitCode == 0 else {
                    let diagnostics = await aptDiagnostics()
                    Issue.record("the pre-font apt-get update failed before any font candidate parse — exit=\(fontUpdate.exitCode); stderr tail: \(bounded(fontUpdate.stderr, limit: 4_000)); diagnostics:\n\(diagnostics)")
                    await cleanup()
                    return
                }
                for identity in ["fontconfig", "fonts-noto-cjk"] {
                    let fontPolicy = try await runGuest(["/bin/sh", "-c", "apt-cache policy \(identity)"], timeout: 120, maxBytes: 32 * 1024)
                    print("FLOE_DEPGUEST_APT_POLICY \(identity) exit=\(fontPolicy.exitCode) stdout=\(bounded(fontPolicy.stdout, limit: 1_500)) stderr=\(bounded(fontPolicy.stderr, limit: 1_500))")
                    guard fontPolicy.exitCode == 0 else {
                        Issue.record("apt-cache policy \(identity) failed before the candidate parse — exit=\(fontPolicy.exitCode); stderr tail: \(bounded(fontPolicy.stderr, limit: 4_000))")
                        await cleanup()
                        return
                    }
                    guard let pin = aptCandidateLine(fontPolicy.stdout, identity: identity) else {
                        Issue.record("could not freeze an exact apt candidate for \(identity): \(bounded(fontPolicy.stdout)) / \(bounded(fontPolicy.stderr))")
                        await cleanup()
                        return
                    }
                    phase("font.installExact.\(identity)")
                    _ = try await packages.aptInstallExact(
                        identity: identity, version: pin, environment: guest.env, cancellation: nil)
                    let fontReadback = try await packages.aptReadback(identity: identity, environment: guest.env, cancellation: nil)
                    #expect(fontReadback == pin, "\(identity) readback \(String(describing: fontReadback)) != frozen pin \(pin)")
                    print("FLOE_DEPGUEST_FONT_PINNED \(identity)=\(pin)")
                }
                phase("font.probe.after")
                let after = try await packages.cjkFontProbe(environment: guest.env, cancellation: nil)
                print("FLOE_DEPGUEST_FONT_PROBE_AFTER=\(after)")
                #expect(after, "the fixed FreeType glyph-render probe did not pass after the declared fontconfig+fonts-noto-cjk pins installed — renderer or faces are genuinely not ready")
            }

            await cleanup()
            print("FLOE_DEPGUEST_APT_STAGE_OK bootSeconds=\(String(format: "%.1f", Date().timeIntervalSince(started))) arch=riscv64 hello=\(candidate) fontStage=\(Self.fontEnabled ? "rendered" : "not-enabled")")
            print("NOTE: apt component proof only; pip/hash/wheel-store legs live in guestRealPipAptAndWheelStoreQualification(). Signed-package authorization and Hub live-install end-to-end remain covered by the center unit fixtures and Root's install acceptance.")
        } catch {
            await cleanup()
            Issue.record("real-guest apt qualification failed: \(error)")
        }
    }
    @Test("Diagnostic only: opened descriptor metadata across rename/unlink on guest and shared filesystems",
          .enabled(if: ProcessInfo.processInfo.environment["FLOE_GUEST_FD_DIAGNOSTIC"] == "1"))
    func guestOpenDescriptorMetadataDiagnostic() async throws {
        let environment = AppEnvironment.live()
        await environment.bootstrap()
        guard let guest = await bootOwnedGuest(
            environment: environment, services: FloePlatformServices.shared,
            phase: { print("FLOE_FD_PROBE_PHASE \($0)") }) else { return }
        do {
            // Fixed synthetic files in this disposable guest only. Never
            // operate on the shared model/package cache or user workspaces.
            let script = #"""
            import json, os, stat, subprocess, tempfile
            def metadata(fd):
                try:
                    s = os.fstat(fd)
                    return dict(ok=True, size=s.st_size, inode=s.st_ino, device=s.st_dev,
                                mode=oct(stat.S_IFMT(s.st_mode)))
                except OSError as e:
                    return dict(ok=False, errno=e.errno, message=str(e))
            rows = []
            for base in ('/tmp', '/run', '/var/lib/apt/lists/partial',
                         '/var/cache/apt/archives/partial', '/floe/env'):
                row = dict(base=base)
                fd = duplicate = None
                original = renamed = None
                try:
                    os.makedirs(base, exist_ok=True)
                    fs = subprocess.run(['stat', '-f', '-c', '%T', base], capture_output=True,
                                        text=True, timeout=10)
                    row['filesystem'] = fs.stdout.strip()
                    row['filesystemExit'] = fs.returncode
                    fd, original = tempfile.mkstemp(prefix='floe-fd-probe-', dir=base)
                    os.write(fd, b'probe')
                    duplicate = os.dup(fd)
                    row['before'] = metadata(fd)
                    row['duplicateBefore'] = metadata(duplicate)
                    renamed = original + '.renamed'
                    os.rename(original, renamed)
                    row['afterRename'] = metadata(fd)
                    row['duplicateAfterRename'] = metadata(duplicate)
                    os.unlink(renamed)
                    row['afterUnlink'] = metadata(fd)
                    row['duplicateAfterUnlink'] = metadata(duplicate)
                    try:
                        os.lseek(fd, 0, os.SEEK_SET)
                        row['readAfterUnlink'] = os.read(fd, 5).decode('ascii')
                    except OSError as e:
                        row['readAfterUnlink'] = dict(errno=e.errno, message=str(e))
                    try:
                        row['procLink'] = os.readlink('/proc/self/fd/' + str(fd))
                    except OSError as e:
                        row['procLink'] = dict(errno=e.errno, message=str(e))
                except Exception as e:
                    row['probeError'] = repr(e)
                finally:
                    for descriptor in (fd, duplicate):
                        if descriptor is not None:
                            os.close(descriptor)
                    for path in (original, renamed):
                        if path is not None:
                            try: os.unlink(path)
                            except FileNotFoundError: pass
                rows.append(row)
            print('FLOE_FD_PROBE_REPORT ' + json.dumps(dict(
                libc=os.confstr('CS_GNU_LIBC_VERSION'), procFD=os.path.isdir('/proc/self/fd'),
                rows=rows), sort_keys=True))
            """#
            let result = try await guest.runner.run(
                environmentID: guest.environmentID, argv: ["python3", "-c", script],
                workingDirectory: nil, standardInput: nil, timeout: 180,
                maxOutputBytes: 64 * 1024, cancellation: nil)
            print(SecretRedactor.redact(result.stdout))
            #expect(result.exitCode == 0, "Descriptor diagnostic process failed: \(bounded(result.stderr))")
            #expect(result.stdout.contains("FLOE_FD_PROBE_REPORT "))
            // This test records anomalies; it never asserts POSIX or apt
            // readiness. Only the real apt install/readback test qualifies it.
            print("FLOE_FD_PROBE_DIAGNOSTIC_ONLY exit=\(result.exitCode)")
        } catch {
            Issue.record("Guest descriptor diagnostic failed: \(error)")
        }
        await guest.teardown()
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
