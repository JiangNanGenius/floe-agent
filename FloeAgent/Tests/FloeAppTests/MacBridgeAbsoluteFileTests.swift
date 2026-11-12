import Foundation
import Testing
import FloeCore
import FloeExecution
import FloeMacBridgeProtocol
import FloeModels
import FloeTools
import FloeWorkspace
@testable import FloeApp

private actor RecordingMacAbsoluteTransport: MacBridgeAbsoluteFileTransport {
    struct Call: Sendable {
        let path: String
        let offset: Int
        let limit: Int
        let expectedIdentity: String?
        let verifySHA256: Bool
    }

    private let pairing: Bool
    private let result: MacBridgeClient.AbsoluteFileChunk
    private let failure: BridgeFailure?
    private(set) var calls: [Call] = []

    init(pairing: Bool = true,
         result: MacBridgeClient.AbsoluteFileChunk = .init(
            data: Data("absolute mac bytes".utf8), offset: 18, totalBytes: 18,
            identity: String(repeating: "a", count: 64)),
         failure: BridgeFailure? = nil) {
        self.pairing = pairing
        self.result = result
        self.failure = failure
    }

    func hasPairing() async -> Bool { pairing }

    func readAbsoluteFileChunk(
        path: String, offset: Int, limit: Int, expectedIdentity: String?,
        verifySHA256: Bool, cancellation: CancellationToken?
    ) async throws -> MacBridgeClient.AbsoluteFileChunk {
        calls.append(Call(path: path, offset: offset, limit: limit,
                          expectedIdentity: expectedIdentity, verifySHA256: verifySHA256))
        if let failure { throw failure }
        return result
    }
}

@Suite("Mac absolute read resolver uses only frozen trusted selection")
struct MacBridgeAbsoluteFileTests {
    private func reader(
        transport: RecordingMacAbsoluteTransport,
        platform: Bool = true,
        registryMac: Bool = true,
        frozenMac: Bool = true
    ) -> MacBridgeAbsoluteFileReader {
        MacBridgeAbsoluteFileReader(
            transport: transport,
            isPlatformSupported: { platform },
            isMacEnvironment: { _ in registryMac },
            frozenSelectionIsMac: { _ in frozenMac })
    }

    private func context(
        environmentID: String = "mac-env",
        environment: ToolEnvironment? = nil,
        allowed: [String] = [],
        temporary: Bool = false,
        scope: ToolScope = .local,
        token: CancellationToken = CancellationToken()
    ) -> ToolContext {
        ToolContext(runID: UUID(), scope: scope,
            allowedWorkspacePaths: allowed, cancellation: token,
            environmentID: environmentID, environment: environment,
            temporaryReadOnly: temporary)
    }

    @Test("Native-apple nil-environment context resolves through the frozen pin")
    func nilEnvironmentContextStillResolves() async throws {
        let transport = RecordingMacAbsoluteTransport()
        let macReader = reader(transport: transport)
        let ctx = context()
        #expect(ctx.environment?.id == nil)

        let chunk = try await macReader.readMacAbsoluteFileChunk(
            path: "/Users/fixture/跨 工作区.txt", offset: 0, limit: 64,
            expectedIdentity: nil, verifySHA256: false, context: ctx)
        let value = try #require(chunk)
        #expect(value.data == Data("absolute mac bytes".utf8))
        let calls = await transport.calls
        #expect(calls.count == 1)
        #expect(calls.first?.path == "/Users/fixture/跨 工作区.txt")
    }

    @Test("Frozen Linux context never reaches the Mac transport")
    func frozenLinuxContextIsDenied() async throws {
        let transport = RecordingMacAbsoluteTransport()
        let macReader = reader(transport: transport)
        let root = FileManager.default.temporaryDirectory
        let environment = ToolEnvironment(id: "mac-env", writableLayerURL: root,
            layerURLs: [root], variables: ["FLOE_EXECUTION_BACKEND": "linuxVM"])
        let chunk = try await macReader.readMacAbsoluteFileChunk(
            path: "/Users/fixture/outside.txt", offset: 0, limit: 64,
            expectedIdentity: nil, verifySHA256: false,
            context: context(environment: environment))
        #expect(chunk == nil)
        let calls = await transport.calls
        #expect(calls.isEmpty)
    }

    @Test("A stale or conflicting frozen run binding cannot promote a task")
    func frozenBindingAndRegistryMustAgree() async throws {
        for (frozen, registry) in [(false, true), (true, false), (false, false)] {
            let transport = RecordingMacAbsoluteTransport()
            let macReader = reader(transport: transport, registryMac: registry, frozenMac: frozen)
            let chunk = try await macReader.readMacAbsoluteFileChunk(
                path: "/Users/fixture/outside.txt", offset: 0, limit: 64,
                expectedIdentity: nil, verifySHA256: false, context: context())
            #expect(chunk == nil)
            let calls = await transport.calls
            #expect(calls.isEmpty)
        }
    }

    @Test("Scope, temporary, file ceiling and cancellation fail before transport")
    func readAuthorityIsEnforcedAtTheSeam() async throws {
        let transport = RecordingMacAbsoluteTransport()
        let macReader = reader(transport: transport)

        await #expect(throws: FloeError.self) {
            _ = try await macReader.readMacAbsoluteFileChunk(
                path: "/Users/fixture/outside.txt", offset: 0, limit: 64,
                expectedIdentity: nil, verifySHA256: false,
                context: context(scope: .host(UUID())))
        }
        await #expect(throws: FloeError.self) {
            _ = try await macReader.readMacAbsoluteFileChunk(
                path: "/Users/fixture/outside.txt", offset: 0, limit: 64,
                expectedIdentity: nil, verifySHA256: false,
                context: context(temporary: true))
        }
        await #expect(throws: FloeError.self) {
            _ = try await macReader.readMacAbsoluteFileChunk(
                path: "/Users/fixture/outside.txt", offset: 0, limit: 64,
                expectedIdentity: nil, verifySHA256: false,
                context: context(allowed: ["output"]))
        }
        let token = CancellationToken(); token.cancel()
        await #expect(throws: FloeError.self) {
            _ = try await macReader.readMacAbsoluteFileChunk(
                path: "/Users/fixture/outside.txt", offset: 0, limit: 64,
                expectedIdentity: nil, verifySHA256: false,
                context: context(token: token))
        }
        let calls = await transport.calls
        #expect(calls.isEmpty)
    }

    @Test("Unsupported platform and missing pairing fail honestly")
    func platformAndPairingErrors() async throws {
        let transport = RecordingMacAbsoluteTransport()
        let unsupported = reader(transport: transport, platform: false)
        let nilChunk = try await unsupported.readMacAbsoluteFileChunk(
            path: "/Users/fixture/outside.txt", offset: 0, limit: 64,
            expectedIdentity: nil, verifySHA256: false, context: context())
        #expect(nilChunk == nil)

        let unpairedTransport = RecordingMacAbsoluteTransport(pairing: false)
        let unpaired = reader(transport: unpairedTransport)
        await #expect(throws: BridgeFailure.self) {
            _ = try await unpaired.readMacAbsoluteFileChunk(
                path: "/Users/fixture/outside.txt", offset: 0, limit: 64,
                expectedIdentity: nil, verifySHA256: false, context: context())
        }
        let unpairedCalls = await unpairedTransport.calls
        #expect(unpairedCalls.isEmpty)
    }

    @Test("An old companion surfaces the explicit update error")
    func legacyCompanionErrorSurfaces() async throws {
        let transport = RecordingMacAbsoluteTransport(failure: .unsupportedAbsoluteRead)
        let macReader = reader(transport: transport)
        do {
            _ = try await macReader.readMacAbsoluteFileChunk(
                path: "/Users/fixture/outside.txt", offset: 0, limit: 64,
                expectedIdentity: nil, verifySHA256: false, context: context())
            Issue.record("A legacy companion was treated as supporting absolute reads")
        } catch {
            guard case BridgeFailure.unsupportedAbsoluteRead = error else {
                Issue.record("The explicit companion update failure was replaced: \(error)")
                return
            }
            #expect(error.localizedDescription == BridgeFailure.unsupportedAbsoluteRead.localizedDescription)
            #expect(error.localizedDescription.contains("Floe Bridge"))
            let calls = await transport.calls
            #expect(calls.count == 1, "An unsupported read must not be replayed")
        }
    }
}
