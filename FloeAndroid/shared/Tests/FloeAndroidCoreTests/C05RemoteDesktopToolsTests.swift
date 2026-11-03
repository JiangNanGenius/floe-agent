// SPDX-License-Identifier: MPL-2.0
//
// C05 VNC/RDP model-tool tests (authored, NOT RUN in this lane).
// They use an already-live owner-fenced screen adapter, a real PNG encoder,
// a real artifact file and the real ToolContext/tool structs. No protocol
// handshake is simulated as success: the screen adapter is the test seam for
// the frame/input contract, and the production connect paths are covered by
// the domain tests and pending device qualification.

import Foundation
import Testing
@testable import FloeAndroidCore
@testable import FloeRDP
import FloeCore
import FloeModels
import FloeTools

private final class FakeRemoteScreen: C05RemoteScreenDriving, @unchecked Sendable {
    let protocolName: String
    let width: Int
    let height: Int
    private let lock = NSLock()
    private var _revision: UInt64 = 1
    private var _data: Data
    private var _pointer: [String] = []
    private var _text: [String] = []
    private var _keys: [String] = []

    init(protocolName: String, width: Int = 2, height: Int = 2) {
        self.protocolName = protocolName
        self.width = width
        self.height = height
        var data = Data(count: width * height * 4)
        for index in stride(from: 0, to: data.count, by: 4) {
            data[index] = 40
            data[index + 1] = 80
            data[index + 2] = 120
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
    var keys: [String] {
        lock.lock(); defer { lock.unlock() }; return _keys
    }

    func captureFrame() throws -> C05RemoteScreenFrame {
        lock.lock(); defer { lock.unlock() }
        return C05RemoteScreenFrame(
            width: width,
            height: height,
            revision: _revision,
            data: _data
        )
    }

    func pointerMove(x: Int, y: Int) throws {
        lock.lock(); _pointer.append("move:\(x),\(y)"); bumpLocked(); lock.unlock()
    }

    func pointerButton(button: String, down: Bool, x: Int, y: Int) throws {
        lock.lock(); _pointer.append("\(button):\(down ? "down" : "up"):\(x),\(y)"); bumpLocked(); lock.unlock()
    }

    func wheel(steps: Int, x: Int, y: Int) throws {
        lock.lock(); _pointer.append("wheel:\(steps):\(x),\(y)"); bumpLocked(); lock.unlock()
    }

    func key(named: String) throws {
        lock.lock(); _keys.append(named); bumpLocked(); lock.unlock()
    }

    func typeText(_ text: String, submit: Bool) throws {
        lock.lock(); _text.append(submit ? text + "\n" : text); bumpLocked(); lock.unlock()
    }

    func releaseAllInput() {
        lock.lock(); _pointer.append("releaseAll"); lock.unlock()
    }

    private func bumpLocked() {
        _revision &+= 1
    }
}

@Suite("C05 remote-desktop model tools", .serialized)
struct C05RemoteDesktopToolsTests {
    private let owner = C05RemoteOwner(
        token: "tool.11111111-1111-4111-8111-111111111111",
        nativeEpoch: 5,
        taskID: UUID(uuidString: "11111111-1111-4111-8111-111111111111")
    )

    private func makeHandle(
        protocolName: String = "rdp",
        screen: FakeRemoteScreen
    ) -> C05RemoteDesktopHandle {
        C05RemoteDesktopHandle(
            protocolName: protocolName,
            profileID: UUID(uuidString: "22222222-2222-4222-8222-222222222222")!,
            endpointID: UUID(uuidString: "33333333-3333-4333-8333-333333333333")!,
            sessionID: UUID(uuidString: "44444444-4444-4444-8444-444444444444")!,
            owner: owner,
            displayName: "Desk",
            host: "10.0.0.4",
            port: 3389,
            screen: screen
        )
    }

    private func makeEnvironment(
        root: URL,
        credentialResolver: (@Sendable (UUID) async throws -> Data)? = nil
    ) async -> (C05RemoteDesktopToolEnvironment, C05RemoteDesktopToolCoordinator) {
        let coordinator = C05RemoteDesktopToolCoordinator(
            vncDomain: C05VNCDomain.shared,
            rdpDomain: C05RDPDomain.shared,
            profiles: C05RemoteDomain.shared
        )
        let environment = C05RemoteDesktopToolEnvironment(
            currentEpoch: { 5 },
            artifactRoot: { root },
            credentialResolver: credentialResolver,
            coordinator: coordinator
        )
        return (environment, coordinator)
    }

    private func makeContext() -> ToolContext {
        ToolContext(
            runID: UUID(),
            approvalGrantID: UUID(),
            cancellation: CancellationToken(),
            conversationID: UUID(uuidString: "11111111-1111-4111-8111-111111111111")
        )
    }

    private func json(_ output: ToolExecutionOutput) throws -> [String: Any] {
        try #require(
            JSONSerialization.jsonObject(with: Data(output.summary.utf8)) as? [String: Any]
        )
    }

    @Test("Observe captures a real PNG artifact and current evidence")
    func observeWritesPNG() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-rdp-tools-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let screen = FakeRemoteScreen(protocolName: "rdp")
        let (environment, coordinator) = await makeEnvironment(root: root)
        await coordinator.adopt(handle: makeHandle(screen: screen))
        let tool = C05DesktopObserveTool<C05RDPProtocolKind>(environment: environment)
        let output = try await tool.execute(.init(), context: makeContext())
        let fields = try json(output)
        #expect(fields["status"] as? String == "ok")
        #expect(fields["pixelWidth"] as? Int == 2)
        #expect(fields["pixelHeight"] as? Int == 2)
        let artifact = try #require(output.artifacts.first)
        #expect(artifact.mimeType == "image/png")
        #expect(artifact.relativePath.hasPrefix("RDPArtifacts/"))
        let bytes = try Data(contentsOf: root.appendingPathComponent(artifact.relativePath))
        #expect(bytes.count == artifact.byteCount)
        #expect(Array(bytes.prefix(8)) == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        #expect(FloeDigest.sha256Hex(bytes) == artifact.sha256)
        #expect(fields["screenshotSHA256"] as? String == artifact.sha256)
    }

    @Test("A coordinate click requires fresh evidence and returns a post-action PNG")
    func clickUsesEvidence() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-rdp-tools-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let screen = FakeRemoteScreen(protocolName: "rdp")
        let (environment, coordinator) = await makeEnvironment(root: root)
        await coordinator.adopt(handle: makeHandle(screen: screen))
        let context = makeContext()
        let observe = try await C05DesktopObserveTool<C05RDPProtocolKind>(environment: environment)
            .execute(.init(), context: context)
        let evidence = try #require(try json(observe)["screenshotSHA256"] as? String)
        let click = C05DesktopClickTool<C05RDPProtocolKind>(environment: environment)
        let output = try await click.execute(
            .init(x: 1, y: 1, screenshotSHA256: evidence, clickCount: 1),
            context: context
        )
        let fields = try json(output)
        #expect(fields["inputDispatched"] as? Bool == true)
        #expect(fields["serverAcknowledged"] as? Bool == false)
        #expect(fields["taskSuccessVerified"] as? Bool == false)
        #expect(!output.artifacts.isEmpty)
        #expect(screen.pointerEvents.contains("left:down:1,1"))
        #expect(screen.pointerEvents.contains("left:up:1,1"))
    }

    @Test("A click with stale or foreign evidence is refused before input")
    func clickRejectsStaleEvidence() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-rdp-tools-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let screen = FakeRemoteScreen(protocolName: "rdp")
        let (environment, coordinator) = await makeEnvironment(root: root)
        await coordinator.adopt(handle: makeHandle(screen: screen))
        let click = C05DesktopClickTool<C05RDPProtocolKind>(environment: environment)
        do {
            _ = try await click.execute(
                .init(x: 1, y: 1, screenshotSHA256: String(repeating: "0", count: 64), clickCount: 1),
                context: makeContext()
            )
            Issue.record("stale evidence must not dispatch input")
        } catch {
            #expect(screen.pointerEvents.isEmpty)
        }
    }

    @Test("typeCredential resolves plaintext only inside the tool and suppresses the screenshot")
    func credentialTyping() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-rdp-tools-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let screen = FakeRemoteScreen(protocolName: "vnc")
        let credentialID = UUID()
        let (environment, coordinator) = await makeEnvironment(
            root: root,
            credentialResolver: { _ in Data("s3cret".utf8) }
        )
        await coordinator.adopt(handle: makeHandle(protocolName: "vnc", screen: screen))
        let tool = C05DesktopTypeCredentialTool<C05VNCProtocolKind>(environment: environment)
        let output = try await tool.execute(
            .init(credentialRef: "⟨credential:\(credentialID.uuidString)⟩", submit: false),
            context: makeContext()
        )
        let fields = try json(output)
        #expect(fields["observationStatus"] as? String == "suppressedForCredentialPrivacy")
        #expect(output.artifacts.isEmpty)
        #expect(screen.typedText == ["s3cret"])
    }

    @Test("clickElement is unavailable without a real on-device recognizer")
    func clickElementRequiresRecognizer() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-rdp-tools-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let screen = FakeRemoteScreen(protocolName: "rdp")
        let (environment, coordinator) = await makeEnvironment(root: root)
        await coordinator.adopt(handle: makeHandle(screen: screen))
        let tool = C05DesktopClickElementTool<C05RDPProtocolKind>(environment: environment)
        do {
            _ = try await tool.execute(
                .init(reference: "text-1", screenshotSHA256: String(repeating: "a", count: 64), clickCount: 1),
                context: makeContext()
            )
            Issue.record("clickElement must not invent a recognized element")
        } catch {
            #expect(screen.pointerEvents.isEmpty)
        }
    }

    @Test("Registration exposes the established names and hides unavailable capabilities")
    func registration() async {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-rdp-tools-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let (environment, _) = await makeEnvironment(root: root)
        let registry = ToolRunnerRegistry()
        registerC05RemoteDesktopTools(environment: environment, registry: registry)
        defer { unregisterC05RemoteDesktopTools(registry: registry) }
        for name in [
            "vnc.status", "vnc.connect", "vnc.reconnect", "vnc.disconnect", "vnc.observe",
            "vnc.click", "vnc.typeText", "vnc.scroll", "vnc.drag", "vnc.keyPress",
            "rdp.status", "rdp.connect", "rdp.reconnect", "rdp.disconnect", "rdp.observe",
            "rdp.click", "rdp.typeText", "rdp.scroll", "rdp.drag", "rdp.keyPress",
        ] {
            #expect(registry.descriptor(named: name) != nil)
        }
        // No on-device recognizer is configured in this lane, so the
        // text-anchor tool is not advertised as usable.
        #expect(registry.descriptor(named: "rdp.clickElement") == nil)
        #expect(registry.descriptor(named: "vnc.clickElement") == nil)
        #expect(registry.descriptor(named: "rdp.typeCredential") == nil)
    }
}
