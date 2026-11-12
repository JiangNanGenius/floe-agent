import Foundation
import FloeCore
import FloeExecution
import FloeMacBridgeProtocol
import FloeTools
import FloeWorkspace

/// The read-only subset of the paired Mac transport. Production uses
/// `MacBridgeClient.shared`; focused tests inject a recording transport without
/// a live pairing.
protocol MacBridgeAbsoluteFileTransport: Sendable {
    func hasPairing() async -> Bool
    func readAbsoluteFileChunk(
        path: String,
        offset: Int,
        limit: Int,
        expectedIdentity: String?,
        verifySHA256: Bool,
        cancellation: CancellationToken?
    ) async throws -> MacBridgeClient.AbsoluteFileChunk
}

extension MacBridgeClient: MacBridgeAbsoluteFileTransport {}

/// App-owned bridge between the dependency-free workspace seam and the paired
/// same-Mac transport.
///
/// Backend selection is fail-closed and comes from trusted runtime facts only:
/// the run's frozen execution binding, the task context's frozen environment
/// (when present), and the live registry record. Model arguments, tool output
/// and a command's environment can never promote a task to Mac execution.
struct MacBridgeAbsoluteFileReader: MacAbsoluteFileReading {
    typealias EnvironmentCheck = @Sendable (String) async -> Bool
    typealias FrozenSelectionCheck = @Sendable (ToolContext) async -> Bool

    private let transport: any MacBridgeAbsoluteFileTransport
    private let isPlatformSupported: @Sendable () -> Bool
    private let isMacEnvironment: EnvironmentCheck
    private let frozenSelectionIsMac: FrozenSelectionCheck

    init(
        transport: any MacBridgeAbsoluteFileTransport = MacBridgeClient.shared,
        isPlatformSupported: @escaping @Sendable () -> Bool = {
            LocalBridgePlatform.current.supportsMacBridge
        },
        isMacEnvironment: @escaping EnvironmentCheck,
        frozenSelectionIsMac: @escaping FrozenSelectionCheck
    ) {
        self.transport = transport
        self.isPlatformSupported = isPlatformSupported
        self.isMacEnvironment = isMacEnvironment
        self.frozenSelectionIsMac = frozenSelectionIsMac
    }

    var maximumChunkBytes: Int { BridgeAbsoluteFileRead.maximumChunkBytes }

    func readMacAbsoluteFileChunk(
        path: String,
        offset: Int,
        limit: Int,
        expectedIdentity: String?,
        verifySHA256: Bool,
        context: ToolContext
    ) async throws -> MacAbsoluteFileChunk? {
        // The seam is a public native entry point: enforce the ordinary Mac
        // read authority here as well as in each tool's own entry guards.
        try MacAbsoluteReadAuthorization.authorize(path, context: context)
        guard isPlatformSupported(), let environmentID = context.environmentID else { return nil }
        // A frozen Linux/native/SSH ToolContext must never reach the Mac just
        // because a live registry lookup says otherwise.
        if let frozen = context.environment {
            guard frozen.id == environmentID,
                  frozen.variables["FLOE_EXECUTION_BACKEND"] == "macBridge" else { return nil }
        }
        guard await frozenSelectionIsMac(context),
              await isMacEnvironment(environmentID) else { return nil }
        guard await transport.hasPairing() else { throw BridgeFailure.disconnected }
        let chunk = try await transport.readAbsoluteFileChunk(
            path: path, offset: offset, limit: limit,
            expectedIdentity: expectedIdentity, verifySHA256: verifySHA256,
            cancellation: context.cancellation)
        return MacAbsoluteFileChunk(
            data: chunk.data,
            byteOffset: Int(clamping: chunk.offset),
            totalBytes: Int(clamping: chunk.totalBytes),
            identity: chunk.identity,
            sha256: chunk.sha256)
    }
}
