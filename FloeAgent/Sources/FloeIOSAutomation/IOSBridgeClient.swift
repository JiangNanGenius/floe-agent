// FloeIOSAutomation — native local iOS Bridge client.
//
// Owned by the App lifecycle (one client per installed local-automation
// connection profile). It never runs a shell, never accepts a model-supplied
// host, and never retries a mutation automatically.

import Foundation

public actor IOSBridgeClient {
    public struct Configuration: Sendable {
        public var endpoint: IOSBridgeEndpoint
        public var pairingHandle: IOSBridgePairingHandle
        public var transport: any IOSBridgeHTTPTransport
        public var store: any IOSBridgePairingStore
        public var authority: any IOSAutomationTaskAuthority
        public var companionProbe: (any IOSBridgeCompanionProbe)?
        public var policy: IOSAutomationProtectionPolicy
        /// The App must pass `LocalBridgePlatform.current.supportsIOSAutomation`
        /// here. The module deliberately does not fork device-size,
        /// architecture or Mac/Catalyst detection.
        public var platformAllowsLocalAutomation: Bool
        public var clock: any IOSBridgeClock
        public var randomness: any IOSBridgeRandomness
        public var pairingTimeout: TimeInterval
        public var rpcTimeout: TimeInterval
        public var statusTimeout: TimeInterval
        public var credentialTouchInterval: TimeInterval

        public init(
            store: any IOSBridgePairingStore,
            platformAllowsLocalAutomation: Bool,
            endpoint: IOSBridgeEndpoint = .localDefault,
            pairingHandle: IOSBridgePairingHandle = .localDefault,
            transport: any IOSBridgeHTTPTransport = IOSBridgeURLSessionTransport(),
            authority: any IOSAutomationTaskAuthority = ReadOnlyIOSAutomationAuthority(),
            companionProbe: (any IOSBridgeCompanionProbe)? = nil,
            policy: IOSAutomationProtectionPolicy = .default,
            clock: any IOSBridgeClock = SystemIOSBridgeClock(),
            randomness: any IOSBridgeRandomness = SystemIOSBridgeRandomness(),
            pairingTimeout: TimeInterval = IOSBridgeProtocol.pairingTimeout,
            rpcTimeout: TimeInterval = IOSBridgeProtocol.rpcTimeout,
            statusTimeout: TimeInterval = IOSBridgeProtocol.statusTimeout,
            credentialTouchInterval: TimeInterval = 6 * 60 * 60
        ) {
            self.store = store
            self.platformAllowsLocalAutomation = platformAllowsLocalAutomation
            self.endpoint = endpoint
            self.pairingHandle = pairingHandle
            self.transport = transport
            self.authority = authority
            self.companionProbe = companionProbe
            self.policy = policy
            self.clock = clock
            self.randomness = randomness
            self.pairingTimeout = max(1, pairingTimeout)
            self.rpcTimeout = max(1, rpcTimeout)
            self.statusTimeout = max(1, statusTimeout)
            self.credentialTouchInterval = max(0, credentialTouchInterval)
        }
    }

    enum PairingPhase: Sendable, Equatable {
        case contactingCompanion
        case waitingForOwnerApproval
        case savingCredential
        case verifyingCredential
    }

    struct InputLease: Sendable {
        let token: UUID
        let taskID: UUID
        let taskGeneration: UInt64
        let action: IOSAutomationAction
        let cancellation: IOSAutomationCancellationToken
    }

    struct DeviceInputOwnerState: Sendable {
        let taskID: UUID
        let taskGeneration: UInt64
        let acquiredAt: Date
        var expiresAt: Date?

        var summary: IOSAutomationDeviceInputOwner {
            IOSAutomationDeviceInputOwner(
                taskID: taskID,
                taskGeneration: taskGeneration,
                acquiredAt: acquiredAt,
                expiresAt: expiresAt
            )
        }
    }

    let configuration: Configuration
    var pairingPhase: PairingPhase?
    var activePairingCancellation: IOSAutomationCancellationToken?
    var lifecycleEpoch: UInt64 = 0
    var taskGenerations: [UUID: UInt64] = [:]
    /// Persistent device-input owner for one task generation. This survives
    /// individual perform calls and is cleared only by explicit release,
    /// a newer generation for the same task, bounded-window expiry, or
    /// lifecycle invalidation.
    var deviceInputOwner: DeviceInputOwnerState?
    let credentialWriter = IOSBridgeCredentialWriter()
    /// Per-call serialization of an in-flight mutation. This is separate from
    /// the persistent task owner above.
    var activeLease: InputLease?
    var lastCredentialTouch: Date?
    var lastInvalidationReason: String?

    public init(configuration: Configuration) {
        self.configuration = configuration
    }

    public var endpoint: IOSBridgeEndpoint { configuration.endpoint }

    public var pairingHandle: IOSBridgePairingHandle { configuration.pairingHandle }

    /// Registers the latest generation for one task. Calls carrying an older
    /// generation are refused before dispatch; an in-flight call is fenced
    /// after dispatch if a newer generation is registered while it runs.
    public func registerTaskGeneration(_ generation: UInt64, for taskID: UUID) {
        let current = taskGenerations[taskID] ?? 0
        guard generation > current else { return }
        taskGenerations[taskID] = generation
        // A native runtime generation change supersedes that task's older
        // device-input owner. A stale generation can never release the
        // successor because release matches both task id and generation.
        if let owner = deviceInputOwner,
           owner.taskID == taskID,
           owner.taskGeneration < generation {
            deviceInputOwner = nil
        }
    }

    /// Releases persistent device-input ownership for exactly this task and
    /// generation. Returns false for a stale generation, a different task, or
    /// no owner. The primary run lifecycle calls this on finish/cancel/release.
    @discardableResult
    public func releaseTaskOwnership(taskID: UUID, generation: UInt64) -> Bool {
        expireDeviceInputOwnerIfNeeded(at: configuration.clock.now())
        guard let owner = deviceInputOwner,
              owner.taskID == taskID,
              owner.taskGeneration == generation else {
            return false
        }
        deviceInputOwner = nil
        return true
    }

    /// Non-secret observation for lifecycle diagnostics/tests. Expired bounded
    /// ownership is cleared before returning.
    public func currentDeviceInputOwner() -> IOSAutomationDeviceInputOwner? {
        expireDeviceInputOwnerIfNeeded(at: configuration.clock.now())
        return deviceInputOwner?.summary
    }

    func expireDeviceInputOwnerIfNeeded(at date: Date) {
        guard let owner = deviceInputOwner, let expiresAt = owner.expiresAt else {
            return
        }
        if date >= expiresAt {
            deviceInputOwner = nil
        }
    }

    /// Fences every in-flight callback after a lifecycle change (app
    /// background/cancel, credential revoke, environment switch). A mutating
    /// call that was already dispatched is reported as outcome-unknown, never
    /// as success and never replayed.
    public func invalidate(reason: String) {
        lifecycleEpoch &+= 1
        lastInvalidationReason = reason
        deviceInputOwner = nil
        activeLease?.cancellation.cancel()
        activeLease = nil
        activePairingCancellation?.cancel()
    }

    public func shutdown() async {
        invalidate(reason: "shutdown")
    }
}

public enum IOSBridgeOperationID {
    public static let maximumBytes = IOSBridgeProtocol.operationIDMaximumBytes

    public static func isCanonical(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard (1...maximumBytes).contains(bytes.count), let first = bytes.first else {
            return false
        }
        func isAlphanumeric(_ byte: UInt8) -> Bool {
            (0x41...0x5A).contains(byte)
                || (0x61...0x7A).contains(byte)
                || (0x30...0x39).contains(byte)
        }
        guard isAlphanumeric(first) else { return false }
        for byte in bytes {
            switch byte {
            case 0x41...0x5A, 0x61...0x7A, 0x30...0x39, 0x2E, 0x5F, 0x2D:
                continue
            default:
                return false
            }
        }
        return value != "." && value != ".."
    }

    public static func make() -> String {
        "iosauto-\(UUID().uuidString.lowercased())"
    }
}
