import Foundation

public enum BridgeRPCVersion {
    /// Wire protocol version. v1 is the HMAC-SHA256 encrypted-envelope pairing
    /// and /rpc contract pinned to OpenMinis/iCTRL `c1e4268`.
    public static let protocolVersion = 1
    public static let serverVersion = "1.0.0"
    public static let skillVersion = "1.0.0"
    public static let productName = "Floe iOS Bridge"
}

/// Bounded budgets for the localhost-first service. Every limit is a hard
/// refusal, not a truncation target.
public struct BridgeRPCLimits: Sendable, Equatable {
    public var maxRequestHeadBytes: Int
    public var maxRequestBodyBytes: Int
    /// Maximum bytes of the sealed JSON response body. Screenshot replies
    /// legitimately approach this; media streams are outside JSON.
    public var maxJSONResponseBytes: Int
    public var maxConnections: Int
    public var maxQueuedAutomationCalls: Int
    public var maxCompletedOperations: Int
    public var maxOperationLedgerBytes: Int
    public var maxSingleOperationResultBytes: Int
    public var streamConsumerBufferBytes: Int
    public var maxStreamConsumers: Int
    public var timestampWindow: TimeInterval
    public var nonceCapacityPerClient: Int
    public var approvalTimeout: TimeInterval
    public var pairCooldown: TimeInterval
    public var inactivityWindow: TimeInterval
    public var maxClients: Int
    public var streamTicketTTL: TimeInterval
    public var maxStreamTickets: Int
    public var requestReadTimeout: TimeInterval
    public var responseWriteTimeout: TimeInterval
    public var executionTimeout: TimeInterval

    public init(
        maxRequestHeadBytes: Int = 16_384,
        maxRequestBodyBytes: Int = 262_144,
        maxJSONResponseBytes: Int = 16 * 1_024 * 1_024,
        maxConnections: Int = 8,
        maxQueuedAutomationCalls: Int = 16,
        maxCompletedOperations: Int = 256,
        maxOperationLedgerBytes: Int = 8 * 1_024 * 1_024,
        maxSingleOperationResultBytes: Int = 1 * 1_024 * 1_024,
        streamConsumerBufferBytes: Int = 262_144,
        maxStreamConsumers: Int = 8,
        timestampWindow: TimeInterval = 120,
        nonceCapacityPerClient: Int = 4_096,
        approvalTimeout: TimeInterval = 60,
        pairCooldown: TimeInterval = 15,
        inactivityWindow: TimeInterval = 30 * 24 * 60 * 60,
        maxClients: Int = 100,
        streamTicketTTL: TimeInterval = 60,
        maxStreamTickets: Int = 128,
        requestReadTimeout: TimeInterval = 10,
        responseWriteTimeout: TimeInterval = 10,
        executionTimeout: TimeInterval = 30
    ) {
        self.maxRequestHeadBytes = maxRequestHeadBytes
        self.maxRequestBodyBytes = maxRequestBodyBytes
        self.maxJSONResponseBytes = maxJSONResponseBytes
        self.maxConnections = maxConnections
        self.maxQueuedAutomationCalls = maxQueuedAutomationCalls
        self.maxCompletedOperations = maxCompletedOperations
        self.maxOperationLedgerBytes = maxOperationLedgerBytes
        self.maxSingleOperationResultBytes = maxSingleOperationResultBytes
        self.streamConsumerBufferBytes = streamConsumerBufferBytes
        self.maxStreamConsumers = maxStreamConsumers
        self.timestampWindow = timestampWindow
        self.nonceCapacityPerClient = nonceCapacityPerClient
        self.approvalTimeout = approvalTimeout
        self.pairCooldown = pairCooldown
        self.inactivityWindow = inactivityWindow
        self.maxClients = maxClients
        self.streamTicketTTL = streamTicketTTL
        self.maxStreamTickets = maxStreamTickets
        self.requestReadTimeout = requestReadTimeout
        self.responseWriteTimeout = responseWriteTimeout
        self.executionTimeout = executionTimeout
    }

    public static let `default` = BridgeRPCLimits()
}

/// How a request reached the service. Only `.local` and `.lan` are accepted;
/// `.nearby` (AWDL/low-latency WLAN), `.cellular`, `.vpn` and `.other` are
/// closed before routing. This is derived from the accepted socket address and
/// local interface table, never from request headers.
public enum BridgeRPCPeerVia: String, Sendable, Equatable, Codable {
    case local
    case lan
    case nearby
    case vpn
    case cellular
    case other
}

public struct BridgeRPCPeerInfo: Sendable, Equatable {
    public var address: String
    public var via: BridgeRPCPeerVia
    public var isLoopback: Bool

    public init(address: String, via: BridgeRPCPeerVia, isLoopback: Bool) {
        self.address = address
        self.via = via
        self.isLoopback = isLoopback
    }

    public static let unknown = BridgeRPCPeerInfo(address: "unknown", via: .other, isLoopback: false)

    /// A plaintext key grant is acceptable only when the kernel peer address is
    /// genuinely loopback. `via == .local` also covers a machine reaching the
    /// device over USB forwarding, which terminates on loopback.
    public var allowsPlainPairing: Bool {
        isLoopback && via == .local
    }

    public var isAcceptedTransport: Bool {
        via == .local || via == .lan
    }
}

/// Public metadata for one paired client. Deliberately contains no key
/// material; the Keychain-backed store keeps that separate.
public struct BridgeRPCClientRecord: Sendable, Equatable {
    public var clientID: String
    public var clientName: String
    public var grantedAt: Date
    public var lastActiveAt: Date
    public var lastAddress: String?
    public var lastVia: BridgeRPCPeerVia?
    public var sensitiveInputGranted: Bool

    public init(clientID: String,
                clientName: String,
                grantedAt: Date,
                lastActiveAt: Date,
                lastAddress: String? = nil,
                lastVia: BridgeRPCPeerVia? = nil,
                sensitiveInputGranted: Bool = false) {
        self.clientID = clientID
        self.clientName = clientName
        self.grantedAt = grantedAt
        self.lastActiveAt = lastActiveAt
        self.lastAddress = lastAddress
        self.lastVia = lastVia
        self.sensitiveInputGranted = sensitiveInputGranted
    }

    public var expiresAt: Date {
        lastActiveAt.addingTimeInterval(30 * 24 * 60 * 60)
    }
}

/// The complete record handed to the host Keychain adapter. This type is not
/// returned by any public snapshot or log.
public struct BridgeRPCStoredClient: Sendable, Equatable, Codable {
    public var clientID: String
    public var keyHex: String
    public var clientName: String
    public var grantedAt: Date
    public var lastActiveAt: Date
    public var lastAddress: String?
    public var lastVia: String?
    public var sensitiveInputGranted: Bool

    public init(clientID: String,
                key: Data,
                clientName: String,
                grantedAt: Date,
                lastActiveAt: Date,
                lastAddress: String? = nil,
                lastVia: BridgeRPCPeerVia? = nil,
                sensitiveInputGranted: Bool = false) {
        self.clientID = clientID
        self.keyHex = BridgeRPCEnvelope.hexLowercase(key)
        self.clientName = clientName
        self.grantedAt = grantedAt
        self.lastActiveAt = lastActiveAt
        self.lastAddress = lastAddress
        self.lastVia = lastVia?.rawValue
        self.sensitiveInputGranted = sensitiveInputGranted
    }

    public var key: Data? {
        BridgeRPCEnvelope.strictHex(keyHex, byteCount: BridgeRPCEnvelope.keyByteCount)
    }

    public var record: BridgeRPCClientRecord {
        BridgeRPCClientRecord(
            clientID: clientID,
            clientName: clientName,
            grantedAt: grantedAt,
            lastActiveAt: lastActiveAt,
            lastAddress: lastAddress,
            lastVia: lastVia.flatMap(BridgeRPCPeerVia.init(rawValue:)),
            sensitiveInputGranted: sensitiveInputGranted
        )
    }
}

/// Host-provided persistent secret storage. Production uses one Keychain item
/// per client; tests use an in-memory implementation. Flat plaintext files are
/// not an acceptable implementation.
public protocol BridgeRPCClientStore: Sendable {
    /// Client records including their keys. Implementations must keep these in
    /// approved credential storage, never a plaintext file.
    func loadClients() throws -> [BridgeRPCStoredClient]
    /// Consumed nonces within the timestamp window: token id -> nonce hex ->
    /// request timestamp. This contains no plaintext and no key material.
    func loadNonces() throws -> [String: [String: Int]]
    func upsertClient(_ client: BridgeRPCStoredClient) throws
    func removeClient(clientID: String) throws
    func removeAllClients() throws
    /// Atomically replaces the whole nonce map. If this throws, the caller
    /// rejects the request before executing anything.
    func saveNonces(_ nonces: [String: [String: Int]]) throws
}

public enum BridgeRPCStoreError: Error, Equatable, Sendable {
    case unavailable(String)
    case corrupt
}

public struct BridgeRPCPairGrant: Sendable, Equatable {
    public let clientID: String
    public let key: Data
    public let clientName: String
    public let expiresAt: Date
    public let revision: UInt64

    public init(clientID: String, key: Data, clientName: String, expiresAt: Date,
                revision: UInt64 = 1) {
        self.clientID = clientID
        self.key = key
        self.clientName = clientName
        self.expiresAt = expiresAt
        self.revision = revision
    }
}

public enum BridgeRPCPairOutcome: Sendable, Equatable {
    case approved(BridgeRPCPairGrant)
    case denied
    case busy(retryAfter: Int)
    case coolingDown(retryAfter: Int)
    case unavailable(code: String, message: String)
}

/// Information shown to the device owner before a fresh pairing decision.
public struct BridgeRPCApprovalRequest: Sendable, Equatable {
    public let requestID: String
    public let clientName: String
    public let isLoopback: Bool
    public let via: BridgeRPCPeerVia
    /// SHA-256 of the client X25519 public key, first 4 bytes, lowercase hex.
    /// Nil for a plain loopback grant.
    public let fingerprint: String?
    /// Always true: every pairing is a fresh owner decision. This field exists
    /// so a UI cannot accidentally reuse an earlier approval.
    public let requiresOwnerApproval: Bool
    /// The UI should withdraw the prompt at this deadline. The authority also
    /// enforces it internally and ignores any late callback.
    public let timeout: TimeInterval

    public init(requestID: String,
                clientName: String,
                isLoopback: Bool,
                via: BridgeRPCPeerVia,
                fingerprint: String?,
                timeout: TimeInterval = 60) {
        self.requestID = requestID
        self.clientName = clientName
        self.isLoopback = isLoopback
        self.via = via
        self.fingerprint = fingerprint
        self.requiresOwnerApproval = true
        self.timeout = timeout
    }
}

public enum BridgeRPCApprovalDecision: Sendable, Equatable {
    case approve
    case deny
}

public typealias BridgeRPCApprovalHandler =
    @Sendable (BridgeRPCApprovalRequest) async -> BridgeRPCApprovalDecision

public enum BridgeRPCEngineReadiness: Sendable, Equatable {
    case notRegistered
    case notReady(reason: String)
    case ready(generation: UInt64)

    public var isReady: Bool {
        if case .ready = self { return true }
        return false
    }

    public var generation: UInt64? {
        if case .ready(let generation) = self { return generation }
        return nil
    }
}

public struct BridgeRPCEngineSnapshot: Sendable, Equatable {
    public var owner: String?
    public var generation: UInt64?
    public var readiness: BridgeRPCEngineReadiness
    public var supportedMethods: Set<String>

    public init(owner: String? = nil,
                generation: UInt64? = nil,
                readiness: BridgeRPCEngineReadiness = .notRegistered,
                supportedMethods: Set<String> = []) {
        self.owner = owner
        self.generation = generation
        self.readiness = readiness
        self.supportedMethods = supportedMethods
    }

    public static let unregistered = BridgeRPCEngineSnapshot()
}

public struct BridgeRPCServiceSnapshot: Sendable, Equatable {
    public var port: UInt16
    public var lanEnabled: Bool
    public var bonjourEnabled: Bool
    public var engine: BridgeRPCEngineSnapshot
    public var clientCount: Int
    public var capabilities: [String]
    public var stopping: Bool
    public var skillAvailable: Bool
    public var remoteUIAvailable: Bool
    public var streamAvailable: Bool
    public var logsAvailable: Bool

    public init(port: UInt16,
                lanEnabled: Bool,
                bonjourEnabled: Bool,
                engine: BridgeRPCEngineSnapshot,
                clientCount: Int,
                capabilities: [String],
                stopping: Bool,
                skillAvailable: Bool,
                remoteUIAvailable: Bool,
                streamAvailable: Bool,
                logsAvailable: Bool) {
        self.port = port
        self.lanEnabled = lanEnabled
        self.bonjourEnabled = bonjourEnabled
        self.engine = engine
        self.clientCount = clientCount
        self.capabilities = capabilities
        self.stopping = stopping
        self.skillAvailable = skillAvailable
        self.remoteUIAvailable = remoteUIAvailable
        self.streamAvailable = streamAvailable
        self.logsAvailable = logsAvailable
    }
}

public struct BridgeRPCHostSnapshot: Sendable, Equatable {
    public var running: Bool
    public var loopbackIPv4Ready: Bool
    public var loopbackIPv6Ready: Bool
    public var lanIPv4Ready: Bool
    public var lanIPv6Ready: Bool
    public var lanEnabled: Bool
    public var bonjourState: String
    public var port: UInt16?
    public var engine: BridgeRPCEngineSnapshot
    public var clients: [BridgeRPCClientRecord]
    public var capabilities: [String]
    public var storageError: String?
    public var nonceStoreAvailable: Bool
    public var networkError: String?

    public init(running: Bool = false,
                loopbackIPv4Ready: Bool = false,
                loopbackIPv6Ready: Bool = false,
                lanIPv4Ready: Bool = false,
                lanIPv6Ready: Bool = false,
                lanEnabled: Bool = false,
                bonjourState: String = "off",
                port: UInt16? = nil,
                engine: BridgeRPCEngineSnapshot = .unregistered,
                clients: [BridgeRPCClientRecord] = [],
                capabilities: [String] = [],
                storageError: String? = nil,
                nonceStoreAvailable: Bool = true,
                networkError: String? = nil) {
        self.running = running
        self.loopbackIPv4Ready = loopbackIPv4Ready
        self.loopbackIPv6Ready = loopbackIPv6Ready
        self.lanIPv4Ready = lanIPv4Ready
        self.lanIPv6Ready = lanIPv6Ready
        self.lanEnabled = lanEnabled
        self.bonjourState = bonjourState
        self.port = port
        self.engine = engine
        self.clients = clients
        self.capabilities = capabilities
        self.storageError = storageError
        self.nonceStoreAvailable = nonceStoreAvailable
        self.networkError = networkError
    }

    /// Readiness is derived from actual listeners plus the engine. It is never
    /// inferred from "the service object exists".
    public var loopbackReady: Bool {
        running && loopbackIPv4Ready && loopbackIPv6Ready
    }

    public var engineReady: Bool {
        engine.readiness.isReady
    }

    public var isReady: Bool {
        loopbackReady && engineReady
    }

    public var lanReady: Bool {
        lanEnabled && (lanIPv4Ready || lanIPv6Ready)
    }
}

// MARK: - HTTP value types shared with the host transport

public struct BridgeRPCHTTPRequest: Sendable, Equatable {
    public var method: String
    public var path: String
    /// Path without the query string, exactly as routed.
    public var pathOnly: String
    public var query: String
    public var headers: [String: String]
    public var body: Data

    public init(method: String,
                path: String,
                pathOnly: String,
                query: String,
                headers: [String: String],
                body: Data) {
        self.method = method
        self.path = path
        self.pathOnly = pathOnly
        self.query = query
        self.headers = headers
        self.body = body
    }
}

/// Final response authorization binding. The transport must call
/// `BridgeRPCService.commitResponse` with this token immediately before the
/// first byte is sent. Stop/revoke then either wins before that byte or the
/// response was already committed while still authorized.
public struct BridgeRPCCommitToken: Sendable, Equatable {
    public let serviceEpoch: UInt64
    public let clientID: String?
    public let authEpoch: UInt64?
    public let clientRevision: UInt64?
    /// Only the acknowledged stop_server reply may commit while the service is
    /// already marked stopping; every other response is dropped.
    public let allowsStopping: Bool

    public init(serviceEpoch: UInt64,
                clientID: String? = nil,
                authEpoch: UInt64? = nil,
                clientRevision: UInt64? = nil,
                allowsStopping: Bool = false) {
        self.serviceEpoch = serviceEpoch
        self.clientID = clientID
        self.authEpoch = authEpoch
        self.clientRevision = clientRevision
        self.allowsStopping = allowsStopping
    }
}

public struct BridgeRPCHTTPResponse: Sendable, Equatable {
    public var status: Int
    public var headers: [String: String]
    public var body: Data
    public var commitToken: BridgeRPCCommitToken?

    public init(status: Int,
                headers: [String: String] = [:],
                body: Data,
                commitToken: BridgeRPCCommitToken? = nil) {
        self.status = status
        self.headers = headers
        self.body = body
        self.commitToken = commitToken
    }

    public static func text(_ status: Int,
                            _ value: String,
                            contentType: String = "text/plain; charset=utf-8") -> BridgeRPCHTTPResponse {
        BridgeRPCHTTPResponse(status: status,
                              headers: ["Content-Type": contentType],
                              body: Data(value.utf8))
    }

    public static func json(_ status: Int, _ value: BridgeRPCJSONValue) -> BridgeRPCHTTPResponse {
        BridgeRPCHTTPResponse(status: status,
                              headers: ["Content-Type": "application/json; charset=utf-8",
                                        "Cache-Control": "no-store"],
                              body: value.canonicalData())
    }

    public static func error(_ status: Int,
                             code: String,
                             message: String,
                             extra: [String: BridgeRPCJSONValue] = [:]) -> BridgeRPCHTTPResponse {
        var error: [String: BridgeRPCJSONValue] = [
            "code": .string(code),
            "message": .string(message),
        ]
        for (key, value) in extra { error[key] = value }
        return .json(status, .object(["error": .object(error)]))
    }
}

public enum BridgeRPCHTTPResult: Sendable {
    case response(BridgeRPCHTTPResponse)
    case stream(BridgeRPCStreamGrant)
}
