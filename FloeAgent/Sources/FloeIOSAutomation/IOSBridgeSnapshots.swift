// FloeIOSAutomation — observable connection and pairing state.

import Foundation

public enum IOSBridgeEngineState: Sendable, Equatable {
    case unknown
    case notRegistered
    case notReady(reason: String)
    case ready

    public var isReady: Bool {
        if case .ready = self { return true }
        return false
    }

    public var wireValue: String {
        switch self {
        case .unknown: return "unknown"
        case .notRegistered: return "not_registered"
        case .notReady: return "not_ready"
        case .ready: return "ready"
        }
    }

    static func parse(_ value: String?, reason: String? = nil) -> IOSBridgeEngineState {
        switch value {
        case "not_registered": return .notRegistered
        case "not_ready": return .notReady(reason: reason ?? "")
        case "ready": return .ready
        default: return .unknown
        }
    }
}

public struct IOSBridgeInfo: Sendable, Equatable {
    public let product: String
    public let serverVersion: String
    public let protocolVersion: Int
    public let engineState: IOSBridgeEngineState
    public let capabilities: Set<String>
    public let lanEnabled: Bool

    public init(product: String,
                serverVersion: String,
                protocolVersion: Int,
                engineState: IOSBridgeEngineState,
                capabilities: Set<String>,
                lanEnabled: Bool) {
        self.product = product
        self.serverVersion = serverVersion
        self.protocolVersion = protocolVersion
        self.engineState = engineState
        self.capabilities = capabilities
        self.lanEnabled = lanEnabled
    }

    static func parse(_ value: IOSBridgeJSONValue) -> IOSBridgeInfo? {
        guard let object = value.objectValue else { return nil }
        guard let product = object["product"]?.stringValue,
              let serverVersion = object["server_version"]?.stringValue,
              let protocolVersion = object["protocol_version"]?.intValue else {
            return nil
        }
        let capabilities = Set((object["capabilities"]?.arrayValue ?? []).compactMap(\.stringValue))
        return IOSBridgeInfo(
            product: product,
            serverVersion: serverVersion,
            protocolVersion: protocolVersion,
            engineState: .parse(object["engine"]?.stringValue),
            capabilities: capabilities,
            lanEnabled: object["lan_enabled"]?.boolValue ?? false
        )
    }
}

public struct IOSBridgeClientRecord: Sendable, Equatable {
    public let clientID: String
    public let clientName: String
    public let grantedAt: Date
    public let lastActiveAt: Date
    public let expiresAt: Date
    public let sensitiveInputGranted: Bool

    public init(clientID: String,
                clientName: String,
                grantedAt: Date,
                lastActiveAt: Date,
                expiresAt: Date,
                sensitiveInputGranted: Bool) {
        self.clientID = clientID
        self.clientName = clientName
        self.grantedAt = grantedAt
        self.lastActiveAt = lastActiveAt
        self.expiresAt = expiresAt
        self.sensitiveInputGranted = sensitiveInputGranted
    }

    static func parse(_ value: IOSBridgeJSONValue) -> IOSBridgeClientRecord? {
        guard let object = value.objectValue,
              let clientID = object["client_id"]?.stringValue,
              let clientName = object["client_name"]?.stringValue,
              let granted = object["granted_at"]?.intValue,
              let lastActive = object["last_active_at"]?.intValue,
              let expires = object["expires_at"]?.intValue else {
            return nil
        }
        return IOSBridgeClientRecord(
            clientID: clientID,
            clientName: clientName,
            grantedAt: Date(timeIntervalSince1970: TimeInterval(granted)),
            lastActiveAt: Date(timeIntervalSince1970: TimeInterval(lastActive)),
            expiresAt: Date(timeIntervalSince1970: TimeInterval(expires)),
            sensitiveInputGranted: object["sensitive_input_granted"]?.boolValue ?? false
        )
    }
}

public struct IOSBridgeConfigurationSnapshot: Sendable, Equatable {
    public let port: Int?
    public let engineState: IOSBridgeEngineState
    public let supportedMethods: Set<String>
    public let capabilities: Set<String>
    public let clients: [IOSBridgeClientRecord]

    public init(port: Int?,
                engineState: IOSBridgeEngineState,
                supportedMethods: Set<String>,
                capabilities: Set<String>,
                clients: [IOSBridgeClientRecord]) {
        self.port = port
        self.engineState = engineState
        self.supportedMethods = supportedMethods
        self.capabilities = capabilities
        self.clients = clients
    }

    static func parse(_ value: IOSBridgeJSONValue) -> IOSBridgeConfigurationSnapshot? {
        guard let object = value.objectValue else { return nil }
        let engineObject = object["engine"]?.objectValue
        let engineState = IOSBridgeEngineState.parse(
            engineObject?["state"]?.stringValue,
            reason: engineObject?["reason"]?.stringValue
        )
        let methods = Set((engineObject?["supported_methods"]?.arrayValue ?? [])
            .compactMap(\.stringValue))
        let capabilities = Set((object["capabilities"]?.arrayValue ?? []).compactMap(\.stringValue))
        let clients = (object["clients"]?.arrayValue ?? []).compactMap(IOSBridgeClientRecord.parse)
        return IOSBridgeConfigurationSnapshot(
            port: object["port"]?.intValue,
            engineState: engineState,
            supportedMethods: methods,
            capabilities: capabilities,
            clients: clients
        )
    }
}

public enum IOSBridgeConnectionStatus: Sendable, Equatable {
    case unknown
    case unsupportedPlatform
    case companionMissing
    case companionPresenceUnknown
    case serviceOff
    case serviceUnavailable
    case incompatibleBridge(protocolVersion: Int)
    case needsPairing
    case pairingInProgress
    case waitingForOwnerApproval
    case lockedCredentials
    case credentialsUnavailable
    case pairingRecordInvalid
    case expired
    case revoked
    case engineNotReady(reason: String)
    case ready

    public var isReady: Bool { self == .ready }

    public var isPaired: Bool {
        switch self {
        case .expired, .revoked, .engineNotReady, .ready:
            return true
        default:
            return false
        }
    }

    public var isBusy: Bool {
        switch self {
        case .pairingInProgress, .waitingForOwnerApproval: return true
        default: return false
        }
    }

    public var requiresPairing: Bool {
        switch self {
        case .needsPairing, .pairingRecordInvalid, .expired, .revoked: return true
        default: return false
        }
    }

    public var requiresCredentialUnlock: Bool { self == .lockedCredentials }

    public var requiresCompanionInstall: Bool { self == .companionMissing }
}

public struct IOSBridgeConnectionSnapshot: Sendable, Equatable {
    public let status: IOSBridgeConnectionStatus
    public let info: IOSBridgeInfo?
    public let configuration: IOSBridgeConfigurationSnapshot?
    public let sensitiveInputGranted: Bool
    public let clientExpiresAt: Date?
    public let checkedAt: Date
    public let detail: String?

    public init(status: IOSBridgeConnectionStatus,
                info: IOSBridgeInfo? = nil,
                configuration: IOSBridgeConfigurationSnapshot? = nil,
                sensitiveInputGranted: Bool = false,
                clientExpiresAt: Date? = nil,
                checkedAt: Date = Date(),
                detail: String? = nil) {
        self.status = status
        self.info = info
        self.configuration = configuration
        self.sensitiveInputGranted = sensitiveInputGranted
        self.clientExpiresAt = clientExpiresAt
        self.checkedAt = checkedAt
        self.detail = detail
    }
}

public enum IOSBridgePairingProgress: Sendable, Equatable {
    case contactingCompanion
    case waitingForOwnerApproval
    case savingCredential
    case verifyingCredential
    case paired(expiresAt: Date)
}

public struct IOSBridgePairingResult: Sendable, Equatable {
    public let clientName: String
    /// Non-secret lookup id derived from the pairing key. Safe to show in a
    /// diagnostic view, never in ordinary UI.
    public let tokenID: String
    public let expiresAt: Date
    public let replacedExisting: Bool

    public init(clientName: String, tokenID: String, expiresAt: Date, replacedExisting: Bool) {
        self.clientName = clientName
        self.tokenID = tokenID
        self.expiresAt = expiresAt
        self.replacedExisting = replacedExisting
    }
}

/// Local forget never means server-side revocation. Bridge owns its client
/// list; this client deliberately has no RPC path that can revoke a grant.
public struct IOSBridgeForgetResult: Sendable, Equatable {
    public let handleWasPresent: Bool
    public let serverGrantMayRemain: Bool

    public init(handleWasPresent: Bool) {
        self.handleWasPresent = handleWasPresent
        self.serverGrantMayRemain = true
    }
}

public extension IOSBridgeConnectionSnapshot {
    /// Method availability is separate from engine readiness. Tool discovery
    /// should advertise an action only when the connected Bridge actually
    /// supports that method; a call is still validated by the server.
    func supports(_ action: IOSAutomationAction) -> Bool {
        configuration?.supportedMethods.contains(action.wireMethod) ?? false
    }

    var availableModelActions: [IOSAutomationAction] {
        IOSAutomationAction.allCases.filter {
            $0.isModelExposed && supports($0)
        }
    }
}
