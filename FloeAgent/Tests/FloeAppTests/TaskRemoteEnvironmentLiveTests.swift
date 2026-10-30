#if canImport(UIKit)
import Foundation
import XCTest
import FloeCore
import FloeModels
import FloePersistence
import FloeSecurity
import FloeSSH
import FloeTools
import FloeExecution
@testable import FloeApp

/// Opt-in live qualification. The coordinator provisions an isolated loopback
/// SSH VM and copies a one-use credential into this test-only cache location.
/// No fixture values, production host or user credential are committed.
@MainActor
final class TaskRemoteEnvironmentLiveTests: XCTestCase {
    private struct Fixture: Decodable {
        var address: String; var port: Int; var user: String; var home: String
        var fingerprint: String; var fingerprints: [String]?
        var keyFile: String; var pipSpec: String; var pipHash: String; var aptVersion: String
    }
    func testRealSSHFilesDependenciesLongScriptFullOutputAndBindingCommit() async throws {
        let input = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Floe306SSHQualification")
        guard FileManager.default.fileExists(atPath: input.appendingPathComponent("fixture.json").path) else {
            throw XCTSkip("Requires a coordinator-provisioned isolated loopback SSH target")
        }
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: input.appendingPathComponent("fixture.json")))
        guard fixture.address == "127.0.0.1", fixture.port > 1024, !fixture.keyFile.contains("/") else {
            throw FloeError.validationFailed("Only the isolated local qualification fixture is accepted")
        }
        let credential = KeychainStore(service: "org.floeagent.tests.ssh-qualification", synchronizable: false)
        let account = UUID().uuidString
        try credential.store(account: account, secret: Data(contentsOf: input.appendingPathComponent(fixture.keyFile)))
        try FileManager.default.removeItem(at: input.appendingPathComponent(fixture.keyFile))
        defer { try? credential.delete(account: account) }
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        let hostID = UUID()
        let profile = RemoteHostProfile(id: hostID, displayName: "Isolated qualification VM", address: fixture.address,
            port: fixture.port, user: fixture.user,
            auth: .importedKey(SecretReference(keychainAccount: account, synchronizable: false), keyType: .ed25519))
        let connection = SSHConnectionService(hostStore: RemoteHostStore(database: database))
        let fingerprints = Set((fixture.fingerprints ?? [fixture.fingerprint]).map(SSHHostKeyFingerprint.normalize))
        let sessionFactory: RemotePythonService.SessionFactory = { _ in
            try await connection.connect(profile: profile,
                credentialResolver: { _ in try credential.read(account: account) },
                hostKeyDecision: { fingerprints.contains(SSHHostKeyFingerprint.normalize($0.fingerprintSHA256)) })
        }
        let ssh = SSHCommandService(sessionFactory: sessionFactory,
            hostResolver: { _ in .init(id: hostID, displayName: "Isolated qualification VM") },
            defaultHostProvider: { throw FloeError.validationFailed("No default host is allowed in this test") })
        let conversationID = UUID(), environmentID = UUID().uuidString
        let remoteRoot = fixture.home + "/.floe/tasks/" + conversationID.uuidString + "/" + UUID().uuidString
        let target = try XCTUnwrap(SSHShellTarget(hostID: hostID, remoteTaskRoot: remoteRoot,
            environmentID: environmentID, generation: "qualification-boot"))
        let mirror = TaskWorkspaceMirror(ssh: ssh)
        let root = input.appendingPathComponent("workspace-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("资料"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("你好 · こんにちは · hello\n".utf8).write(to: root.appendingPathComponent("资料/input.txt"))
        do {
            let initial = try await mirror.synchronize(target: target, root: root, cancellation: nil)
            XCTAssertEqual(initial.map(\.path), ["资料/input.txt"])
            let shape = try await ssh.run(command: "uname -s; uname -m", hostID: hostID)
            XCTAssertEqual(shape.exitCode, 0)
            XCTAssertTrue(shape.stdout.contains("Linux"))
            XCTAssertTrue(shape.stdout.contains("aarch64"))
            let router = RemoteEnvironmentShellRouter(defaultBackend: NoFallbackBackend(),
                resolver: { id in id == environmentID ? .ssh(target) : .unavailable(environmentID: id, reason: "Unknown fixture target") },
                sessionFactory: { _ in try await ssh.openShellConnection(hostID: hostID) },
                sync: RemoteWorkspaceSyncCallbacks { target, _, cancellation in
                    _ = try await mirror.synchronize(target: target, root: root, cancellation: cancellation)
                }, outputRoot: root)
            let toolEnvironment = ToolEnvironment(id: environmentID, writableLayerURL: root, layerURLs: [root], variables: [:])
            // Larger than inline staging, with both streams and >30 s runtime.
            let script = "#" + String(repeating: "staging", count: 30_000) + "\n" + """
            python3 -c 'import pathlib,sys; pathlib.Path("result.txt").write_text("REMOTE-FILE-OK"); print("A"*200000+"STDOUT-TAIL",flush=True); print("B"*100000+"STDERR-TAIL",file=sys.stderr,flush=True)'
            sleep 31
            printf '\nUNLIMITED-FINISHED\n'
            """
            let request = ShellRunRequest(command: script, cwd: ".", rootURL: root, deadline: .unlimited,
                maxOutputBytes: 1024, sessionID: "qualification", runID: UUID(), toolEnvironment: toolEnvironment)
            let outcome = await router.run(request, cancellation: nil)
            guard case .exited(let code, _, _, let truncated, let stderrTruncated, _) = outcome else {
                XCTFail("Live SSH command did not exit normally: \(outcome)"); throw FloeError.validationFailed("Live SSH command failed")
            }
            XCTAssertEqual(code, 0)
            XCTAssertTrue(truncated || stderrTruncated)
            XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("result.txt"), encoding: .utf8), "REMOTE-FILE-OK")
            let logs = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent(".floe/terminal"), includingPropertiesForKeys: nil)
            let full = try logs.filter { $0.pathExtension == "log" }.map { try Data(contentsOf: $0) }.reduce(Data(), +)
            XCTAssertGreaterThan(full.count, 300_000)
            XCTAssertTrue(String(decoding: full, as: UTF8.self).contains("STDOUT-TAIL"))
            XCTAssertTrue(String(decoding: full, as: UTF8.self).contains("STDERR-TAIL"))
            XCTAssertTrue(String(decoding: full, as: UTF8.self).contains("UNLIMITED-FINISHED"))
            let quote: @Sendable (String) -> String = { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }
            let operations = TaskTargetDependencyOperations { command, _, cancellation in
                let result = try await ssh.run(command: "cd " + quote(remoteRoot) + " && " + command,
                    hostID: hostID, timeout: 180, maxOutputBytes: 128 * 1024, cancellation: cancellation)
                guard result.exitCode == 0, !result.truncated else { throw FloeError.validationFailed("The isolated dependency operation failed") }
                return result.stdout
            }
            _ = try await operations.pythonEnsure(spec: fixture.pipSpec, hashes: [fixture.pipHash], environment: toolEnvironment, cancellation: nil)
            let ownedPython = try await operations.pythonOwnedVenvVersions(environment: toolEnvironment, cancellation: nil)
            XCTAssertEqual(ownedPython?["mpmath"], "1.3.0")
            _ = try await operations.aptEnsure(identity: "python3-roman", version: fixture.aptVersion, environment: toolEnvironment, cancellation: nil)
            let aptVersion = try await operations.aptInstalledVersion(identity: "python3-roman", environment: toolEnvironment, cancellation: nil)
            XCTAssertEqual(aptVersion, fixture.aptVersion)
            let use = try await ssh.run(command: "cd " + quote(remoteRoot) + " && .floe-env/bin/python -c 'import mpmath,roman; print(mpmath.__version__); print(roman.toRoman(42))'", hostID: hostID)
            XCTAssertEqual(use.exitCode, 0); XCTAssertTrue(use.stdout.contains("1.3.0")); XCTAssertTrue(use.stdout.contains("XLII"))
            let conversations = SQLiteConversationStore(database: database)
            try await conversations.saveConversation(ConversationRecord(id: conversationID, title: "Isolated migration", createdAt: Date(), updatedAt: Date()))
            let store = TaskExecutionBindingStore(database: database)
            let source = try await store.bindInitial(TaskExecutionBinding(conversationID: conversationID,
                target: .init(environmentID: "source-fixture", backend: .linuxVM, operatingSystem: "linux", architecture: "riscv64")))
            let destination = TaskExecutionTarget(environmentID: environmentID, backend: .remoteSSH,
                remoteHostID: hostID, remoteRootPath: remoteRoot, operatingSystem: "linux", architecture: "aarch64")
            var migration = TaskEnvironmentMigration(source: source, target: destination)
            try await store.begin(migration)
            for phase: TaskEnvironmentMigration.Phase in [.waiting, .preparing, .verifying] {
                migration.phase = phase
                migration = try await store.update(migration, expectedRevision: migration.revision)
            }
            migration.phase = .verified
            let files = try await mirror.synchronize(target: target, root: root, cancellation: nil)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            migration.manifestDigest = FloeDigest.sha256Hex(try encoder.encode(files))
            migration.skillDigests = [:]
            migration.dependencyReceiptDigest = FloeDigest.sha256Hex(Data((fixture.pipSpec + fixture.pipHash + fixture.aptVersion).utf8))
            migration = try await store.update(migration, expectedRevision: migration.revision)
            migration = try await store.commit(migration)
            let committedBinding = try await store.binding(conversationID: conversationID)
            XCTAssertEqual(committedBinding?.target, destination)
            XCTAssertEqual(migration.phase, .committed)
            migration = try await store.finish(migration, notice: "Isolated task moved")
            XCTAssertEqual(migration.phase, .completed)
            try await mirror.removeOwnedTarget(target: target, cancellation: CancellationToken())
        } catch {
            try? await mirror.removeOwnedTarget(target: target, cancellation: CancellationToken())
            throw error
        }
    }
}

private struct NoFallbackBackend: LocalShellBackend {
    func normalizedRunDeadline(_ deadline: ShellExecutionDeadline) -> ShellExecutionDeadline { deadline }
    func run(_ request: ShellRunRequest, cancellation: CancellationToken?) async -> ShellRunOutcome {
        XCTFail("A pinned SSH command reached a fallback backend")
        return .failed(message: "No fallback is permitted")
    }
    func openSession(_ request: ShellOpenRequest, cancellation: CancellationToken?) async throws -> ShellOpenResult { throw FloeError.validationFailed("No fallback") }
    func exchangeSession(_ request: ShellExchangeRequest, cancellation: CancellationToken?) async throws -> ShellExchangeResult { throw FloeError.validationFailed("No fallback") }
    func closeSession(sessionID: String) async {}
    func signalSession(sessionID: String, signal: ShellSignal) async {}
    func resizeSession(sessionID: String, columns: Int, rows: Int) async {}
}
#endif
