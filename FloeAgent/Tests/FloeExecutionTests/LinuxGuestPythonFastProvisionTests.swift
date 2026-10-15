// FloeExecutionTests — first-use Python venv provisioning: the fast staging
// path, the historical in-place fallback, the existing-directory repair and
// the reuse of an already-valid venv.
//
// The real guest measurements and the end-to-end evidence live in the E-lane
// qualification (Local/Private/task-lifecycle-20261015/E); these focused
// cases pin the command sequence the provisioner emits so a future edit
// cannot silently reintroduce the 143-259 s ensurepip path for a fresh
// environment, discard an existing venv directory, or promote a venv that
// lacks a standard pip entrypoint.
//
// The scripted runner models the GUEST's real state (a venv interpreter that
// runs or does not, a pip entrypoint that exists or does not) instead of
// answering every command optimistically: the provisioner's reuse path and
// its post-promotion validation issue the same probe, so only a stateful
// answer reproduces the real sequence.

import Foundation
import XCTest
import FloeCore
import FloeTools
@testable import FloeExecution

/// Minimal scripted `LinuxCommandRunning` for the provisioner command
/// sequence. Records every argv exactly as the provisioner sends it.
private final class ProvisionerScriptedRunner: LinuxCommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [[String]] = []
    var calls: [[String]] { lock.withLock { recorded } }
    var joinedCalls: [String] { calls.map { $0.joined(separator: " ") } }

    func supports(environmentID: String) async -> Bool { true }

    func run(
        environmentID: String,
        argv: [String],
        workingDirectory: String?,
        standardInput: String?,
        timeout: TimeInterval,
        maxOutputBytes: Int,
        cancellation: CancellationToken?
    ) async throws -> LinuxCommandResult {
        if cancellation?.isCancelled == true { throw FloeError.cancelled }
        lock.withLock { recorded.append(argv) }
        return answer(argv)
    }

    // MARK: Guest state

    /// Whether `<venv>/bin/python3` currently runs (a valid, reusable venv).
    var venvUsable = false
    /// Whether a venv DIRECTORY exists while the interpreter does not run —
    /// the half-created/repair case.
    var venvDirectoryPresent = false
    /// Whether `<venv>/bin/pip` exists.
    var pipPresent = false
    var pipImportable = true
    var fastCreateExitCode: Int32 = 0
    /// Exit code for the standard `pip3` / versioned-alias (pip3.13) step.
    var aliasCreateExitCode: Int32 = 0
    /// Number of leading fast `--without-pip` creations to fail.
    var fastCreateFailuresRemaining = 0

    private static func result(_ stdout: String, _ code: Int32 = 0, stderr: String = "") -> LinuxCommandResult {
        LinuxCommandResult(stdout: stdout, stderr: stderr, exitCode: code)
    }

    private func answer(_ argv: [String]) -> LinuxCommandResult {
        let joined = argv.joined(separator: " ")
        // Directory probe
        if joined.contains("echo venv-dir-present") {
            return Self.result(venvDirectoryPresent ? "venv-dir-present\n" : "venv-dir-absent\n")
        }
        // Fast creation in the private staging directory.
        if joined.contains("venv --system-site-packages --without-pip") {
            if fastCreateFailuresRemaining > 0 {
                fastCreateFailuresRemaining -= 1
                return Self.result("", 1, stderr: "venv: staging create failed")
            }
            return Self.result("", fastCreateExitCode,
                               stderr: fastCreateExitCode == 0 ? "" : "venv: staging create failed")
        }
        // Standard pip3 / versioned-alias (pip3.13) step (answered BEFORE the
        // staging-interpreter branch: this command also runs the staging
        // python to read its version).
        if joined.contains("venv-pip-aliases") {
            return Self.result("venv-pip-aliases\n", aliasCreateExitCode,
                               stderr: aliasCreateExitCode == 0 ? "" : "cp: alias failed")
        }
        // Staging interpreter validation (`import sys, sysconfig, pip`).
        if joined.contains(".venv-staging/bin/python3") {
            if pipImportable {
                return Self.result("3.13.5\n/floe/env/python/.venv-staging/lib/python3.13/site-packages\n")
            }
            return Self.result("ModuleNotFoundError: No module named 'pip'\n", 1)
        }
        // Distro version probe.
        if argv.count >= 3, argv[0] == "python3", argv[1] == "-c", argv[2].contains("print(sys.version") {
            return Self.result("3.13.5\n")
        }
        // Wrapper write + chmod.
        if joined.contains("> /floe/env/python/.venv-staging/bin/pip && chmod 755") {
            return Self.result("")
        }
        // Activation/pyvenv.cfg rewrite (staging path -> final path).
        if joined.contains("venv-rewritten") {
            return Self.result("venv-rewritten\n")
        }
        // Atomic promotion: the venv becomes usable at the final path.
        if joined.contains("mv -T /floe/env/python/.venv-staging /floe/env/python/venv") {
            venvUsable = true
            pipPresent = true
            return Self.result("venv-promoted\n")
        }
        // In-place creation/repair (historical ensurepip form).
        if joined.contains("venv --system-site-packages /floe/env/python/venv") {
            venvUsable = true
            pipPresent = true
            return Self.result("")
        }
        // Site-packages probe / post-promotion validation on the FINAL venv
        // interpreter. Returns the real path only when the interpreter runs.
        if joined.contains("/floe/env/python/venv/bin/python3 -c"), joined.contains("sysconfig") {
            guard venvUsable else {
                return Self.result("", 1, stderr: "python3: not found")
            }
            return Self.result("/floe/env/python/venv/lib/python3.13/site-packages\n")
        }
        // ensurePip probe.
        if joined.contains("test -x /floe/env/python/venv/bin/pip && echo pip-ok") {
            return Self.result(pipPresent ? "pip-ok\n" : "pip-missing\n")
        }
        // ensurePip repair inside the venv.
        if joined.contains("/floe/env/python/venv/bin/python3 -m ensurepip --upgrade") {
            pipPresent = true
            return Self.result("")
        }
        // python version.
        if joined.contains("/floe/env/python/venv/bin/python3 --version") {
            return Self.result("Python 3.13.5\n")
        }
        // distro python presence probe
        if joined.contains("command -v python3") {
            return Self.result("python-ok\n")
        }
        // Staging cleanup
        if joined.contains("rm -rf /floe/env/python/.venv-staging") {
            return Self.result("")
        }
        // apt-get update / install and anything else: succeed quietly.
        return Self.result("")
    }
}

final class LinuxGuestPythonFastProvisionTests: XCTestCase {
    private func provision(
        _ runner: ProvisionerScriptedRunner,
        environmentID: String
    ) async throws -> LinuxGuestPythonEnvironment {
        try await LinuxGuestPythonProvisioner.shared.ensure(
            environmentID: environmentID,
            runner: runner
        )
    }

    func testFreshEnvironmentUsesStagingWithoutEnsurepipThenPromotes() async throws {
        let runner = ProvisionerScriptedRunner()
        let environmentID = "fast-\(UUID().uuidString)"
        defer { Task { await LinuxGuestPythonProvisioner.shared.forget(environmentID: environmentID) } }

        let environment = try await provision(runner, environmentID: environmentID)

        XCTAssertEqual(environment.venvPath, LinuxGuestPythonEnvironment.guestVenvPath)
        XCTAssertEqual(environment.sitePackages, "/floe/env/python/venv/lib/python3.13/site-packages")
        XCTAssertEqual(environment.version, "Python 3.13.5")
        // The old ensurepip form is never used for a fresh environment, and no
        // ensurepip runs anywhere in the fast path.
        XCTAssertFalse(runner.joinedCalls.contains { $0.contains("venv --system-site-packages /floe/env/python/venv") })
        XCTAssertFalse(runner.joinedCalls.contains { $0.contains("ensurepip") })
        // Order: --without-pip staging creation < staging validation < wrapper
        // < standard aliases < rewrite < atomic mv.
        let fastIndex = try XCTUnwrap(runner.joinedCalls.firstIndex { $0.contains("--without-pip") })
        let wrapperIndex = try XCTUnwrap(runner.joinedCalls.firstIndex {
            $0.contains("> /floe/env/python/.venv-staging/bin/pip && chmod 755")
        })
        let aliasIndex = try XCTUnwrap(runner.joinedCalls.firstIndex { $0.contains("venv-pip-aliases") })
        let rewriteIndex = try XCTUnwrap(runner.joinedCalls.firstIndex { $0.contains("venv-rewritten") })
        let mvIndex = try XCTUnwrap(runner.joinedCalls.firstIndex { $0.contains("mv -T") })
        XCTAssertLessThan(fastIndex, wrapperIndex)
        XCTAssertLessThan(wrapperIndex, aliasIndex)
        XCTAssertLessThan(aliasIndex, rewriteIndex)
        XCTAssertLessThan(rewriteIndex, mvIndex)
        XCTAssertTrue(runner.joinedCalls.contains { $0.contains("mv -T /floe/env/python/.venv-staging /floe/env/python/venv && echo venv-promoted") })
        // The activation rewrite points from staging at the final path.
        let rewrite = runner.joinedCalls[rewriteIndex]
        XCTAssertTrue(rewrite.contains("/floe/env/python/.venv-staging/bin/activate"))
        XCTAssertTrue(rewrite.contains("s|/floe/env/python/.venv-staging|/floe/env/python/venv|g"))
        XCTAssertTrue(rewrite.contains("venv-rewritten"))
    }

    func testFastPathFallsBackWhenDistroPipIsNotImportable() async throws {
        let runner = ProvisionerScriptedRunner()
        runner.pipImportable = false
        let environmentID = "fallback-\(UUID().uuidString)"
        defer { Task { await LinuxGuestPythonProvisioner.shared.forget(environmentID: environmentID) } }

        let environment = try await provision(runner, environmentID: environmentID)

        XCTAssertEqual(environment.venvPath, LinuxGuestPythonEnvironment.guestVenvPath)
        // The staging directory is discarded and the historical in-place
        // command runs exactly once instead.
        XCTAssertTrue(runner.joinedCalls.contains { $0.contains("rm -rf /floe/env/python/.venv-staging") })
        XCTAssertTrue(runner.joinedCalls.contains { $0.contains("venv --system-site-packages /floe/env/python/venv") })
        XCTAssertFalse(runner.joinedCalls.contains { $0.contains("mv -T") })
    }

    /// A venv DIRECTORY whose interpreter does not run (an interrupted
    /// creation) is repaired in place, never replaced by the fast path.
    func testExistingBrokenVenvDirectoryKeepsTheInPlaceRepair() async throws {
        let runner = ProvisionerScriptedRunner()
        runner.venvDirectoryPresent = true
        runner.venvUsable = false
        let environmentID = "existing-\(UUID().uuidString)"
        defer { Task { await LinuxGuestPythonProvisioner.shared.forget(environmentID: environmentID) } }

        _ = try await provision(runner, environmentID: environmentID)

        XCTAssertTrue(runner.joinedCalls.contains { $0.contains("venv --system-site-packages /floe/env/python/venv") })
        XCTAssertFalse(runner.joinedCalls.contains { $0.contains("--without-pip") })
    }

    /// An already-valid venv is reused as-is: neither the staging path nor the
    /// in-place repair runs, and its site-packages are read from the
    /// interpreter itself.
    func testExistingUsableVenvIsReusedWithoutRebuild() async throws {
        let runner = ProvisionerScriptedRunner()
        runner.venvDirectoryPresent = true
        runner.venvUsable = true
        runner.pipPresent = true
        let environmentID = "reuse-\(UUID().uuidString)"
        defer { Task { await LinuxGuestPythonProvisioner.shared.forget(environmentID: environmentID) } }

        let environment = try await provision(runner, environmentID: environmentID)

        XCTAssertEqual(environment.sitePackages, "/floe/env/python/venv/lib/python3.13/site-packages")
        XCTAssertFalse(runner.joinedCalls.contains { $0.contains("--without-pip") })
        XCTAssertFalse(runner.joinedCalls.contains { $0.contains("venv --system-site-packages /floe/env/python/venv") })
        XCTAssertFalse(runner.joinedCalls.contains { $0.contains("mv -T") })
        XCTAssertFalse(runner.joinedCalls.contains { $0.contains("ensurepip") })
    }

    /// A failed fast creation is cleaned up and retried once after the apt
    /// repair; the retry still takes the fast path (no in-place command).
    func testFastCreateFailureCleansStagingThenRetriesFast() async throws {
        let runner = ProvisionerScriptedRunner()
        runner.fastCreateFailuresRemaining = 1
        let environmentID = "createfail-\(UUID().uuidString)"
        defer { Task { await LinuxGuestPythonProvisioner.shared.forget(environmentID: environmentID) } }

        let environment = try await provision(runner, environmentID: environmentID)

        XCTAssertEqual(environment.sitePackages, "/floe/env/python/venv/lib/python3.13/site-packages")
        XCTAssertTrue(runner.joinedCalls.contains { $0.contains("rm -rf /floe/env/python/.venv-staging") })
        XCTAssertTrue(runner.joinedCalls.contains { $0.contains("apt-get install") })
        let fastAttempts = runner.joinedCalls.filter { $0.contains("--without-pip") }
        XCTAssertEqual(fastAttempts.count, 2)
        XCTAssertFalse(runner.joinedCalls.contains { $0.contains("venv --system-site-packages /floe/env/python/venv") })
        XCTAssertTrue(runner.joinedCalls.contains { $0.contains("mv -T") })
    }

    /// Standard venv entrypoints: `pip`, `pip3` and the versioned alias
    /// (`pip3.13` for the pinned image's Python 3.13: `pip<major>.<minor>`)
    /// must exist in the promoted venv, all wired to the venv interpreter
    /// (a missing `pip3` would fall through to `/usr/bin/pip3` and its
    /// PEP 668 refusal).
    func testFastPathCreatesAllStandardPipEntrypointsBeforePromotion() async throws {
        let runner = ProvisionerScriptedRunner()
        let environmentID = "entrypoints-\(UUID().uuidString)"
        defer { Task { await LinuxGuestPythonProvisioner.shared.forget(environmentID: environmentID) } }

        _ = try await provision(runner, environmentID: environmentID)

        let wrapperIndex = try XCTUnwrap(runner.joinedCalls.firstIndex {
            $0.contains("> /floe/env/python/.venv-staging/bin/pip && chmod 755")
        })
        let aliasIndex = try XCTUnwrap(runner.joinedCalls.firstIndex {
            $0.contains("venv-pip-aliases")
        })
        let mvIndex = try XCTUnwrap(runner.joinedCalls.firstIndex { $0.contains("mv -T") })
        XCTAssertLessThan(wrapperIndex, aliasIndex)
        XCTAssertLessThan(aliasIndex, mvIndex)

        let aliases = runner.joinedCalls[aliasIndex]
        XCTAssertTrue(aliases.contains("cp /floe/env/python/.venv-staging/bin/pip /floe/env/python/.venv-staging/bin/pip3"))
        // The versioned alias name is derived from the staging interpreter's
        // own version, so it can never drift from the venv python.
        XCTAssertTrue(aliases.contains("sys.version_info[:2]"))
        XCTAssertTrue(aliases.contains("cp /floe/env/python/.venv-staging/bin/pip \"/floe/env/python/.venv-staging/bin/$alias\""))
    }

    /// The wrapper must install into THIS venv: it execs the venv's own
    /// python with `-m pip` and never targets the system prefix, forces a
    /// system install or overwrites existing (distro) packages.
    func testWrapperTargetsTheVenvNeverTheSystemPrefix() async throws {
        let runner = ProvisionerScriptedRunner()
        let environmentID = "prefix-\(UUID().uuidString)"
        defer { Task { await LinuxGuestPythonProvisioner.shared.forget(environmentID: environmentID) } }

        _ = try await provision(runner, environmentID: environmentID)

        let creation = try XCTUnwrap(runner.joinedCalls.first { $0.contains("--without-pip") })
        // Existing distro packages stay visible (reused, never re-installed).
        XCTAssertTrue(creation.contains("--system-site-packages"))

        let wrapper = try XCTUnwrap(runner.joinedCalls.first {
            $0.contains("> /floe/env/python/.venv-staging/bin/pip && chmod 755")
        })
        XCTAssertTrue(wrapper.contains("exec \"$(dirname \"$0\")/python3\" -m pip"))
        XCTAssertFalse(wrapper.contains("/usr/bin"))
        XCTAssertFalse(wrapper.contains("/usr/local"))
        XCTAssertFalse(wrapper.contains("--break-system-packages"))
        XCTAssertFalse(wrapper.contains("--ignore-installed"))
        XCTAssertFalse(wrapper.contains("--prefix"))
        XCTAssertFalse(wrapper.contains("sudo"))
    }

    /// A miss while creating the standard aliases must not promote a venv
    /// that lacks `pip3`: the historical in-place command runs instead and
    /// every staging artifact is removed first.
    func testAliasFailureTakesTheInPlaceFallback() async throws {
        let runner = ProvisionerScriptedRunner()
        runner.aliasCreateExitCode = 1
        let environmentID = "aliasfail-\(UUID().uuidString)"
        defer { Task { await LinuxGuestPythonProvisioner.shared.forget(environmentID: environmentID) } }

        let environment = try await provision(runner, environmentID: environmentID)

        XCTAssertEqual(environment.venvPath, LinuxGuestPythonEnvironment.guestVenvPath)
        XCTAssertTrue(runner.joinedCalls.contains { $0.contains("rm -rf /floe/env/python/.venv-staging") })
        XCTAssertTrue(runner.joinedCalls.contains { $0.contains("venv --system-site-packages /floe/env/python/venv") })
        XCTAssertFalse(runner.joinedCalls.contains { $0.contains("mv -T") })
    }
}
