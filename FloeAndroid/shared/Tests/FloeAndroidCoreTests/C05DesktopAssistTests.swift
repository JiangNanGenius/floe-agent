// SPDX-License-Identifier: MPL-2.0
//
// C05 desktop-assist tests (authored, NOT executed in this source-only lane).
//
// They exercise the REAL parser, the REAL ownership/freshness/revocation
// logic and the REAL tool structs over deterministic doubles for the Linux
// command seam, the credential metadata/secret seam and an already-live
// screen adapter. No protocol handshake, model call, network call, Tesseract
// binary, App DB or device is used.

import Foundation
import Testing
@testable import FloeAndroidCore
@testable import FloeRDP
import FloeCore
import FloeModels
import FloePersistence
import FloeSecurity
import FloeTools

// MARK: - Shared doubles

private final class AssistScreen: C05RemoteScreenDriving, @unchecked Sendable {
    let protocolName: String
    let width: Int
    let height: Int
    private let lock = NSLock()
    private var _revision: UInt64 = 1
    private var _data: Data
    private var _pointer: [String] = []
    private var _text: [String] = []

    init(protocolName: String = "rdp", width: Int = 4, height: Int = 4) {
        self.protocolName = protocolName
        self.width = width
        self.height = height
        var data = Data(count: width * height * 4)
        for index in stride(from: 0, to: data.count, by: 4) {
            data[index] = 30
            data[index + 1] = 60
            data[index + 2] = 90
            data[index + 3] = 255
        }
        _data = data
    }

    var isConnected: Bool { true }
    var frameRevision: UInt64 {
        lock.lock(); defer { lock.unlock() }; return _revision
    }
    var pointerEvents: [String] {
        lock.lock(); defer { lock.unlock() }; return _pointer
    }
    var typedText: [String] {
        lock.lock(); defer { lock.unlock() }; return _text
    }

    func captureFrame() throws -> C05RemoteScreenFrame {
        lock.lock(); defer { lock.unlock() }
        return C05RemoteScreenFrame(width: width, height: height, revision: _revision, data: _data)
    }

    func pointerMove(x: Int, y: Int) throws {
        lock.lock(); _pointer.append("move:\(x),\(y)"); _revision &+= 1; lock.unlock()
    }

    func pointerButton(button: String, down: Bool, x: Int, y: Int) throws {
        lock.lock()
        _pointer.append("\(button):\(down ? "down" : "up"):\(x),\(y)")
        _revision &+= 1
        lock.unlock()
    }

    func wheel(steps: Int, x: Int, y: Int) throws {
        lock.lock(); _pointer.append("wheel:\(steps):\(x),\(y)"); _revision &+= 1; lock.unlock()
    }

    func key(named: String) throws {
        lock.lock(); _revision &+= 1; lock.unlock()
    }

    func typeText(_ text: String, submit: Bool) throws {
        lock.lock(); _text.append(submit ? text + "\n" : text); _revision &+= 1; lock.unlock()
    }

    func releaseAllInput() {}
}

private final class FakeContextRecognizer: C05RemoteDesktopContextualTextRecognizing,
    @unchecked Sendable {
    private let lock = NSLock()
    private let elements: [C05RemoteToolTextElement]
    private let failure: C05DesktopAssistError?
    private(set) var lastOwnership: C05DesktopFrameOwnership?
    private(set) var calls = 0

    init(elements: [C05RemoteToolTextElement], failure: C05DesktopAssistError? = nil) {
        self.elements = elements
        self.failure = failure
    }

    func recognize(
        _ request: C05DesktopTextRecognitionRequest
    ) async throws -> [C05RemoteToolTextElement] {
        lock.lock()
        calls += 1
        lastOwnership = request.ownership
        lock.unlock()
        if let failure { throw failure }
        return elements
    }
}

private final class CountingCurrent: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0

    /// The pre-OCR fence is current; the post-OCR fence is stale.
    func read() -> Bool {
        lock.lock(); defer { lock.unlock() }
        calls += 1
        return calls == 1
    }
}

private actor FakeCardStore: C05DesktopCredentialCardStoring {
    private var records: [UUID: CredentialRecord] = [:]
    private var secrets: [UUID: Data] = [:]
    private var revokeOnResolve = false
    private(set) var resolveCount = 0
    private(set) var capturedOrigins: [String] = []

    func seed(_ record: CredentialRecord, secret: Data) {
        records[record.id] = record
        secrets[record.id] = secret
    }

    func setRevokeOnResolve(_ value: Bool) {
        revokeOnResolve = value
    }

    func credentialRecord(id: UUID) async throws -> CredentialRecord? {
        records[id]
    }

    func listCredentialRecords() async throws -> [CredentialRecord] {
        Array(records.values)
    }

    func captureCredential(
        _ secret: Data,
        kind: CredentialKind,
        owner: CredentialOwner,
        label: String,
        hostID: UUID?,
        origin: String
    ) async throws -> CredentialHandle {
        let record = CredentialRecord(
            kind: kind,
            owner: owner,
            hostID: hostID,
            origin: origin,
            label: label
        )
        records[record.id] = record
        secrets[record.id] = secret
        capturedOrigins.append(origin)
        return CredentialHandle(id: record.id)
    }

    func resolveCredentialSecret(_ handle: CredentialHandle) async throws -> Data {
        resolveCount += 1
        guard let secret = secrets[handle.id] else {
            throw C05DesktopAssistError.credentialUnavailable("missing")
        }
        if revokeOnResolve {
            records.removeValue(forKey: handle.id)
            secrets.removeValue(forKey: handle.id)
        }
        return secret
    }

    func replaceCredentialSecret(_ handle: CredentialHandle, secret: Data) async throws {
        guard var record = records[handle.id] else {
            throw C05DesktopAssistError.cardNotFound
        }
        secrets[handle.id] = secret
        record.updatedAt = Date()
        records[handle.id] = record
    }

    func updateCredentialLabel(_ handle: CredentialHandle, label: String) async throws {
        guard var record = records[handle.id] else {
            throw C05DesktopAssistError.cardNotFound
        }
        record.label = label
        record.updatedAt = Date()
        records[handle.id] = record
    }

    func deleteCredential(_ handle: CredentialHandle) async throws {
        records.removeValue(forKey: handle.id)
        secrets.removeValue(forKey: handle.id)
    }
}

private final class FakeOCRRunner: C05LinuxOCRCommandRunning, @unchecked Sendable {
    enum Mode {
        case ready(languages: [String])
        case missingThenInstall
        case alwaysMissing
    }

    private let lock = NSLock()
    private let root: URL
    private let mode: Mode
    private var probeCount = 0
    private(set) var commands: [String] = []
    private(set) var stagedFileExisted = false
    private(set) var stagedFileRemovedAfter = false

    init(root: URL, mode: Mode) {
        self.root = root
        self.mode = mode
    }

    func run(_ command: C05LinuxOCRCommand) async -> C05LinuxOCRCommandOutcome {
        lock.lock()
        commands.append(command.command)
        lock.unlock()
        if command.command.contains("command -v tesseract") {
            lock.lock(); probeCount += 1; let probe = probeCount; lock.unlock()
            switch mode {
            case .ready(let languages):
                let body = (["tesseract 5.3.0", "---FLOE-TESSERACT-LANGS---"] + languages)
                    .joined(separator: "\n")
                return .exited(code: 0, output: body, truncated: false)
            case .missingThenInstall:
                if probe == 1 {
                    return .exited(code: 0, output: "---FLOE-TESSERACT-MISSING---", truncated: false)
                }
                return .exited(
                    code: 0,
                    output: "tesseract 5.3.0\n---FLOE-TESSERACT-LANGS---\neng\n",
                    truncated: false
                )
            case .alwaysMissing:
                return .exited(code: 0, output: "---FLOE-TESSERACT-MISSING---", truncated: false)
            }
        }
        if command.command.contains("apt-get install") {
            return .exited(code: 0, output: "installed", truncated: false)
        }
        if command.command.contains("--psm 11") {
            guard let start = command.command.firstIndex(of: "'"),
                  let end = command.command[start...].dropFirst().firstIndex(of: "'") else {
                return .failed("missing staged path")
            }
            let relative = String(command.command[command.command.index(after: start)..<end])
            let file = root.appendingPathComponent(relative)
            lock.lock()
            stagedFileExisted = FileManager.default.fileExists(atPath: file.path)
            lock.unlock()
            guard stagedFileExisted else { return .failed("staged image absent") }
            let output = """
            level\tpage_num\tblock_num\tpar_num\tline_num\tword_num\tleft\ttop\twidth\theight\tconf\ttext
            5\t1\t1\t1\t1\t1\t1\t1\t2\t2\t97.0\tOK
            """
            return .exited(code: 0, output: output, truncated: false)
        }
        return .failed("unexpected command")
    }

    func noteRemoved(_ removed: Bool) {
        lock.lock(); stagedFileRemovedAfter = removed; lock.unlock()
    }
}

// MARK: - Tests

@Suite("C05 desktop assist", .serialized)
struct C05DesktopAssistTests {
    private let taskID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    private let otherTaskID = UUID(uuidString: "99999999-9999-4999-8999-999999999999")!
    private let profileID = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
    private let endpointID = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
    private let sessionID = UUID(uuidString: "44444444-4444-4444-8444-444444444444")!
    private let owner = C05RemoteOwner(
        token: "tool.11111111-1111-4111-8111-111111111111",
        nativeEpoch: 5,
        taskID: UUID(uuidString: "11111111-1111-4111-8111-111111111111")
    )

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-assist-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private func minimalPNG(width: Int = 4, height: Int = 4) -> Data {
        var data = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        data.append(contentsOf: [0, 0, 0, 13])
        data.append(contentsOf: Array("IHDR".utf8))
        for value in [width, height] {
            data.append(UInt8((value >> 24) & 0xFF))
            data.append(UInt8((value >> 16) & 0xFF))
            data.append(UInt8((value >> 8) & 0xFF))
            data.append(UInt8(value & 0xFF))
        }
        data.append(contentsOf: [8, 6, 0, 0, 0])
        data.append(Data(repeating: 0xAB, count: 32))
        return data
    }

    private func makeContext(
        workspace: URL?,
        runID: UUID = UUID(),
        approvalGrantID: UUID? = UUID(),
        runtimeAuthority: RuntimeTaskAuthority? = nil
    ) -> ToolContext {
        ToolContext(
            runID: runID,
            toolCallID: "call-1",
            toolIdempotencyKey: "idem-1",
            approvalGrantID: approvalGrantID,
            workspaceRootURL: workspace,
            cancellation: CancellationToken(),
            conversationID: taskID,
            runtimeAuthority: runtimeAuthority
        )
    }

    private func makeHandle(screen: AssistScreen) -> C05RemoteDesktopHandle {
        C05RemoteDesktopHandle(
            protocolName: screen.protocolName,
            profileID: profileID,
            endpointID: endpointID,
            sessionID: sessionID,
            owner: owner,
            displayName: "Desk",
            host: "10.0.0.4",
            port: screen.protocolName == "rdp" ? 3389 : 5900,
            screen: screen
        )
    }

    private func makeCoordinator() -> C05RemoteDesktopToolCoordinator {
        C05RemoteDesktopToolCoordinator(
            vncDomain: C05VNCDomain.shared,
            rdpDomain: C05RDPDomain.shared,
            profiles: C05RemoteDomain.shared
        )
    }

    private func makeRuntimeAuthority(
        toolName: String,
        runID: UUID,
        grantID: UUID
    ) -> RuntimeTaskAuthority {
        RuntimeTaskAuthority(
            id: UUID(),
            runID: runID,
            taskID: taskID,
            environmentBinding: "task:\(taskID.uuidString)|ws:*",
            canonicalTarget: "workspace:*",
            toolName: toolName,
            operation: "apply",
            operationID: "call-1",
            idempotencyKey: "idem-1",
            baseRevision: nil,
            payloadDigest: String(repeating: "a", count: 64),
            approvalGrantID: grantID,
            issuedAt: Date().addingTimeInterval(-1),
            expiresAt: Date().addingTimeInterval(600)
        )
    }

    private func json(_ output: ToolExecutionOutput) throws -> [String: Any] {
        try #require(
            JSONSerialization.jsonObject(with: Data(output.summary.utf8)) as? [String: Any]
        )
    }

    // MARK: Parser

    @Test("Tesseract TSV becomes line-grouped pixel anchors")
    func parserGroupsWords() throws {
        let tsv = """
        level\tpage_num\tblock_num\tpar_num\tline_num\tword_num\tleft\ttop\twidth\theight\tconf\ttext
        5\t1\t1\t1\t1\t1\t10\t20\t40\t12\t96.0\tOpen
        5\t1\t1\t1\t1\t2\t55\t20\t30\t12\t88.0\tFile
        5\t1\t1\t1\t2\t1\t10\t40\t50\t12\t91.5\tCancel
        """
        let elements = try C05TesseractTSVParser.parse(tsv, width: 100, height: 60)
        #expect(elements.count == 2)
        #expect(elements[0].reference == "text-1")
        #expect(elements[0].text == "Open File")
        #expect(elements[0].x == 10)
        #expect(elements[0].y == 20)
        #expect(elements[0].width == 75)
        #expect(elements[0].height == 12)
        #expect(abs(elements[0].confidence - 0.92) < 0.001)
        #expect(elements[1].reference == "text-2")
        #expect(elements[1].text == "Cancel")
        #expect(elements[1].y == 40)
    }

    @Test("Out-of-frame TSV words are discarded rather than clamped")
    func parserRejectsOutOfFrameWords() throws {
        let tsv = """
        level\tpage_num\tblock_num\tpar_num\tline_num\tword_num\tleft\ttop\twidth\theight\tconf\ttext
        5\t1\t1\t1\t1\t1\t90\t20\t40\t12\t96.0\tOutside
        """
        let elements = try C05TesseractTSVParser.parse(tsv, width: 100, height: 60)
        #expect(elements.isEmpty)
    }

    @Test("A missing TSV contract is a failure, not an empty success")
    func parserRejectsNonTSV() {
        #expect(throws: C05DesktopAssistError.self) {
            _ = try C05TesseractTSVParser.parse("Tesseract Error\n", width: 100, height: 60)
        }
    }

    // MARK: Linux recognizer

    @Test("Recognizer stages the exact PNG, runs Tesseract and removes the stage")
    func recognizerStagesAndParses() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = FakeOCRRunner(root: root, mode: .ready(languages: ["eng", "chi_sim"]))
        let recognizer = C05LinuxTesseractRecognizer(runner: runner)
        let context = makeContext(workspace: root)
        let png = minimalPNG()
        let ownership = C05DesktopFrameOwnership(
            taskID: taskID,
            sessionID: sessionID,
            protocolName: "rdp",
            profileID: profileID,
            endpointID: endpointID,
            target: "10.0.0.4:3389",
            frameRevision: 1,
            capturedAt: Date(),
            screenshotSHA256: FloeDigest.sha256Hex(png),
            isCurrent: { true }
        )
        let elements = try await recognizer.recognize(C05DesktopTextRecognitionRequest(
            png: png,
            width: 4,
            height: 4,
            ownership: ownership,
            context: context
        ))
        #expect(elements.count == 1)
        #expect(elements[0].text == "OK")
        #expect(runner.stagedFileExisted)
        let directory = root.appendingPathComponent(".floe/desktopassist/ocr")
        let remaining = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        #expect(remaining.filter { $0.hasSuffix(".png") }.isEmpty)
        #expect(runner.commands.contains { $0.contains("--psm 11") && $0.contains("-l 'eng+chi_sim'") })
    }

    @Test("Recognizer discards anchors when the frame changes after OCR")
    func recognizerRejectsStaleFrameAfterOCR() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = FakeOCRRunner(root: root, mode: .ready(languages: ["eng"]))
        let recognizer = C05LinuxTesseractRecognizer(runner: runner)
        let context = makeContext(workspace: root)
        let png = minimalPNG()
        let current = CountingCurrent()
        let ownership = C05DesktopFrameOwnership(
            taskID: taskID,
            sessionID: sessionID,
            protocolName: "rdp",
            profileID: profileID,
            endpointID: endpointID,
            target: "10.0.0.4:3389",
            frameRevision: 1,
            capturedAt: Date(),
            screenshotSHA256: FloeDigest.sha256Hex(png),
            isCurrent: { current.read() }
        )
        await #expect(throws: C05DesktopAssistError.self) {
            _ = try await recognizer.recognize(C05DesktopTextRecognitionRequest(
                png: png,
                width: 4,
                height: 4,
                ownership: ownership,
                context: context
            ))
        }
    }

    @Test("A missing engine fails without running OCR or faking empty anchors")
    func recognizerDoesNotFakeEmpty() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = FakeOCRRunner(root: root, mode: .alwaysMissing)
        let recognizer = C05LinuxTesseractRecognizer(runner: runner)
        let context = makeContext(workspace: root)
        let png = minimalPNG()
        let ownership = C05DesktopFrameOwnership(
            taskID: taskID,
            sessionID: sessionID,
            protocolName: "vnc",
            profileID: profileID,
            endpointID: endpointID,
            target: "10.0.0.4:5900",
            frameRevision: 1,
            capturedAt: Date(),
            screenshotSHA256: FloeDigest.sha256Hex(png),
            isCurrent: { true }
        )
        await #expect(throws: C05DesktopAssistError.self) {
            _ = try await recognizer.recognize(C05DesktopTextRecognitionRequest(
                png: png,
                width: 4,
                height: 4,
                ownership: ownership,
                context: context
            ))
        }
        #expect(!runner.commands.contains { $0.contains("--psm 11") })
    }

    @Test("Preparation installs Tesseract through the same shell seam")
    func preparationInstalls() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = FakeOCRRunner(root: root, mode: .missingThenInstall)
        let recognizer = C05LinuxTesseractRecognizer(runner: runner)
        let readiness = await recognizer.prepare(context: makeContext(workspace: root))
        #expect(readiness.state == .ready)
        #expect(runner.commands.contains { $0.contains("apt-get install") })
    }

    @Test("Workspace scope denial refuses staging before any command")
    func workspaceScopeDenied() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = FakeOCRRunner(root: root, mode: .ready(languages: ["eng"]))
        let recognizer = C05LinuxTesseractRecognizer(runner: runner)
        var context = makeContext(workspace: root)
        context.allowedWorkspacePaths = ["notes/only.md"]
        let png = minimalPNG()
        let ownership = C05DesktopFrameOwnership(
            taskID: taskID,
            sessionID: sessionID,
            protocolName: "rdp",
            profileID: profileID,
            endpointID: endpointID,
            target: "10.0.0.4:3389",
            frameRevision: 1,
            capturedAt: Date(),
            screenshotSHA256: FloeDigest.sha256Hex(png),
            isCurrent: { true }
        )
        await #expect(throws: C05DesktopAssistError.self) {
            _ = try await recognizer.recognize(C05DesktopTextRecognitionRequest(
                png: png,
                width: 4,
                height: 4,
                ownership: ownership,
                context: context
            ))
        }
        #expect(!runner.commands.contains { $0.contains("--psm 11") })
    }

    // MARK: Credential resolver

    private func makeRecord(
        kind: CredentialKind = .websitePassword,
        owner: CredentialOwner = .vault,
        hostID: UUID? = nil
    ) -> CredentialRecord {
        CredentialRecord(
            kind: kind,
            owner: owner,
            hostID: hostID,
            origin: "test",
            label: "Desk login"
        )
    }

    private func makeCardRequest(
        credentialID: UUID,
        current: @escaping @Sendable () -> Bool = { true }
    ) -> C05DesktopCredentialCardRequest {
        C05DesktopCredentialCardRequest(
            credentialID: credentialID,
            taskID: taskID,
            runID: UUID(),
            protocolName: "rdp",
            profileID: profileID,
            endpointID: endpointID,
            sessionID: sessionID,
            target: "10.0.0.4:3389",
            owner: owner,
            approvalGrantID: UUID(),
            runtimeAuthorityID: UUID(),
            isCurrent: current
        )
    }

    @Test("A scoped card resolves its secret only for the allowed task and host")
    func cardResolves() async throws {
        let store = FakeCardStore()
        let record = makeRecord()
        await store.seed(record, secret: Data("s3cret".utf8))
        let resolver = C05SecureCredentialCardResolver(store: store)
        let resolution = try await resolver.resolveCredentialCard(
            makeCardRequest(credentialID: record.id)
        )
        #expect(resolution.credentialID == record.id)
        #expect(resolution.kind == .websitePassword)
        #expect(resolution.secret == Data("s3cret".utf8))
        #expect(resolution.label == "Desk login")
    }

    @Test("SSH/provider/key cards and foreign hosts are refused before secret read")
    func cardRefusals() async throws {
        let store = FakeCardStore()
        let ssh = makeRecord(kind: .sshPrivateKey)
        let api = makeRecord(kind: .providerAPIKey)
        let foreign = makeRecord(hostID: UUID())
        await store.seed(ssh, secret: Data("key".utf8))
        await store.seed(api, secret: Data("api".utf8))
        await store.seed(foreign, secret: Data("pw".utf8))
        let resolver = C05SecureCredentialCardResolver(store: store)
        for record in [ssh, api] {
            await #expect(throws: C05DesktopAssistError.self) {
                _ = try await resolver.resolveCredentialCard(
                    makeCardRequest(credentialID: record.id)
                )
            }
        }
        await #expect(throws: C05DesktopAssistError.self) {
            _ = try await resolver.resolveCredentialCard(
                makeCardRequest(credentialID: foreign.id)
            )
        }
        let resolveCount = await store.resolveCount
        #expect(resolveCount == 0)
    }

    @Test("A card revoked while its secret is being read is never returned")
    func cardRevocationAfterRead() async throws {
        let store = FakeCardStore()
        let record = makeRecord()
        await store.seed(record, secret: Data("pw".utf8))
        await store.setRevokeOnResolve(true)
        let resolver = C05SecureCredentialCardResolver(store: store)
        await #expect(throws: C05DesktopAssistError.self) {
            _ = try await resolver.resolveCredentialCard(
                makeCardRequest(credentialID: record.id)
            )
        }
    }

    @Test("A conversation card from another task is refused; the same task is allowed")
    func cardOwnerScope() async throws {
        let store = FakeCardStore()
        let foreign = makeRecord(owner: .conversation(otherTaskID))
        let local = makeRecord(owner: .conversation(taskID))
        await store.seed(foreign, secret: Data("a".utf8))
        await store.seed(local, secret: Data("b".utf8))
        let resolver = C05SecureCredentialCardResolver(store: store)
        await #expect(throws: C05DesktopAssistError.self) {
            _ = try await resolver.resolveCredentialCard(
                makeCardRequest(credentialID: foreign.id)
            )
        }
        let resolution = try await resolver.resolveCredentialCard(
            makeCardRequest(credentialID: local.id)
        )
        #expect(resolution.secret == Data("b".utf8))
    }

    @Test("Settings create/list/update/delete never expose secret metadata")
    func cardManagement() async throws {
        let store = FakeCardStore()
        let resolver = C05SecureCredentialCardResolver(store: store)
        let created = try await resolver.createCard(
            label: "NAS",
            kind: .websitePassword,
            secret: Data("pw".utf8),
            hostID: profileID
        )
        #expect(created.reference == "⟨credential:\(created.id.uuidString)⟩")
        #expect(created.typingAllowed)
        let list = try await resolver.listCards()
        #expect(list.count == 1)
        #expect(list[0].reference == created.reference)
        _ = try await resolver.updateCard(id: created.id, label: "NAS 2", secret: nil)
        let updated = try await resolver.listCards()
        #expect(updated.first?.label == "NAS 2")
        try await resolver.deleteCard(id: created.id)
        let afterDelete = try await resolver.listCards()
        #expect(afterDelete.isEmpty)
    }

    // MARK: Tool integration

    @Test("observe -> clickElement uses the real anchor and stamps ownership")
    func toolClickElement() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let screen = AssistScreen(protocolName: "rdp")
        let coordinator = makeCoordinator()
        await coordinator.adopt(handle: makeHandle(screen: screen))
        let recognizer = FakeContextRecognizer(elements: [
            C05RemoteToolTextElement(
                reference: "text-1", text: "Open File", confidence: 0.9,
                x: 0, y: 0, width: 2, height: 2
            ),
        ])
        let environment = C05RemoteDesktopToolEnvironment(
            currentEpoch: { 5 },
            artifactRoot: { root },
            contextualTextRecognizer: recognizer,
            coordinator: coordinator
        )
        let context = makeContext(workspace: root)
        let observe = try await C05DesktopObserveTool<C05RDPProtocolKind>(environment: environment)
            .execute(.init(), context: context)
        let observeFields = try json(observe)
        #expect(observeFields["recognizerStatus"] as? String == "current")
        #expect(observeFields["structuredElementCount"] as? Int == 1)
        let digest = try #require(observeFields["screenshotSHA256"] as? String)
        let click = try await C05DesktopClickElementTool<C05RDPProtocolKind>(environment: environment)
            .execute(.init(reference: "text-1", screenshotSHA256: digest, clickCount: 1), context: context)
        let clickFields = try json(click)
        #expect(clickFields["inputDispatched"] as? Bool == true)
        #expect(clickFields["anchorKind"] as? String == "recognizedText")
        #expect(screen.pointerEvents.contains("left:down:1,1"))
        let ownership = try #require(recognizer.lastOwnership)
        #expect(ownership.taskID == taskID)
        #expect(ownership.sessionID == sessionID)
    }

    @Test("A recognizer failure is reported honestly and blocks clickElement")
    func toolRecognizerFailureIsHonest() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let screen = AssistScreen(protocolName: "vnc")
        let coordinator = makeCoordinator()
        await coordinator.adopt(handle: makeHandle(screen: screen))
        let recognizer = FakeContextRecognizer(
            elements: [],
            failure: .recognitionFailed("tesseract failed")
        )
        let environment = C05RemoteDesktopToolEnvironment(
            currentEpoch: { 5 },
            artifactRoot: { root },
            contextualTextRecognizer: recognizer,
            coordinator: coordinator
        )
        let context = makeContext(workspace: root)
        let output = try await C05DesktopObserveTool<C05VNCProtocolKind>(environment: environment)
            .execute(.init(), context: context)
        let fields = try json(output)
        #expect(fields["recognizerStatus"] as? String == "failed")
        #expect(fields["structuredElementCount"] as? Int == 0)
        #expect(fields["recognizerEvidenceValid"] as? Bool == false)
        let digest = try #require(fields["screenshotSHA256"] as? String)
        await #expect(throws: (any Error).self) {
            _ = try await C05DesktopClickElementTool<C05VNCProtocolKind>(environment: environment)
                .execute(.init(reference: "text-1", screenshotSHA256: digest), context: context)
        }
        #expect(screen.pointerEvents.isEmpty)
    }

    @Test("Foreign evidence is refused even when its digest is supplied")
    func toolRejectsForeignEvidence() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let screen = AssistScreen(protocolName: "rdp")
        let handle = makeHandle(screen: screen)
        let coordinator = makeCoordinator()
        await coordinator.adopt(handle: handle)
        let foreign = C05RemoteToolEvidence(
            screenshotSHA256: String(repeating: "a", count: 64),
            revision: 1,
            capturedAt: Date(),
            width: 4,
            height: 4,
            taskID: otherTaskID,
            sessionID: UUID(),
            protocolName: "rdp",
            profileID: profileID,
            endpointID: endpointID,
            target: "10.0.0.4:3389"
        )
        await coordinator.remember(
            foreign,
            elements: [
                C05RemoteToolTextElement(
                    reference: "text-1", text: "Open", confidence: 0.9,
                    x: 0, y: 0, width: 2, height: 2
                ),
            ],
            recognition: .current(elementCount: 1),
            handle: handle
        )
        let environment = C05RemoteDesktopToolEnvironment(
            currentEpoch: { 5 },
            artifactRoot: { root },
            contextualTextRecognizer: FakeContextRecognizer(elements: []),
            coordinator: coordinator
        )
        await #expect(throws: (any Error).self) {
            _ = try await C05DesktopClickElementTool<C05RDPProtocolKind>(environment: environment)
                .execute(
                    .init(reference: "text-1", screenshotSHA256: foreign.screenshotSHA256),
                    context: makeContext(workspace: root)
                )
        }
        #expect(screen.pointerEvents.isEmpty)
    }

    @Test("typeCredential requires the approved task authority and types the card secret")
    func toolTypeCredential() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let screen = AssistScreen(protocolName: "rdp")
        let coordinator = makeCoordinator()
        await coordinator.adopt(handle: makeHandle(screen: screen))
        let store = FakeCardStore()
        let record = makeRecord()
        await store.seed(record, secret: Data("pw-from-card".utf8))
        let resolver = C05SecureCredentialCardResolver(store: store)
        let environment = C05RemoteDesktopToolEnvironment(
            currentEpoch: { 5 },
            artifactRoot: { root },
            cardResolver: resolver,
            coordinator: coordinator
        )
        let runID = UUID()
        let grantID = UUID()
        let authority = makeRuntimeAuthority(
            toolName: "rdp.typeCredential",
            runID: runID,
            grantID: grantID
        )
        let context = makeContext(
            workspace: root,
            runID: runID,
            approvalGrantID: grantID,
            runtimeAuthority: authority
        )
        let output = try await C05DesktopTypeCredentialTool<C05RDPProtocolKind>(
            environment: environment
        ).execute(
            .init(
                credentialRef: "⟨credential:\(record.id.uuidString)⟩",
                submit: false
            ),
            context: context
        )
        let fields = try json(output)
        #expect(fields["credentialScopeVerified"] as? Bool == true)
        #expect(fields["sessionRevalidated"] as? Bool == true)
        #expect(fields["credentialKind"] as? String == "websitePassword")
        #expect(!output.summary.contains("pw-from-card"))
        #expect(screen.typedText == ["pw-from-card"])

        // Without the runtime-issued authority the same call is refused
        // before the resolver/secret read.
        let unapproved = makeContext(workspace: root, runID: runID, approvalGrantID: grantID)
        await #expect(throws: (any Error).self) {
            _ = try await C05DesktopTypeCredentialTool<C05RDPProtocolKind>(
                environment: environment
            ).execute(
                .init(
                    credentialRef: "⟨credential:\(record.id.uuidString)⟩",
                    submit: false
                ),
                context: unapproved
            )
        }
        #expect(screen.typedText == ["pw-from-card"])
    }

    @Test("Registration advertises clickElement/typeCredential only with real seams")
    func registration() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = makeCoordinator()
        let store = FakeCardStore()
        let record = makeRecord()
        await store.seed(record, secret: Data("pw".utf8))
        let environment = C05RemoteDesktopToolEnvironment(
            currentEpoch: { 5 },
            artifactRoot: { root },
            contextualTextRecognizer: FakeContextRecognizer(elements: []),
            cardResolver: C05SecureCredentialCardResolver(store: store),
            coordinator: coordinator
        )
        let registry = ToolRunnerRegistry()
        registerC05RemoteDesktopTools(environment: environment, registry: registry)
        defer { unregisterC05RemoteDesktopTools(registry: registry) }
        for name in [
            "vnc.clickElement", "rdp.clickElement",
            "vnc.typeCredential", "rdp.typeCredential",
        ] {
            #expect(registry.descriptor(named: name) != nil)
        }
    }
}
