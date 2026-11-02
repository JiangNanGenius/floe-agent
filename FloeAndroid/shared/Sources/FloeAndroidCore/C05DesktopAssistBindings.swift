// SPDX-License-Identifier: MPL-2.0
//
// C05 desktop-assist trusted host bridge `floe.desktopassist/22` (reserved
// optional channel) and the settings-side card manager surface.
//
// This channel is App-host only. It carries secret-free card metadata in both
// directions and accepts ONE bounded one-time secret on create/update; that
// secret is handed directly to the original AndroidCredentialVault and is
// never returned, logged or placed in a projection. It is not a BridgeV3
// command, not a model tool and not a permission bypass. Model typing stays
// on the ordinary `vnc.typeCredential` / `rdp.typeCredential` tool path.

import Foundation
import CoreFoundation
import FloeCore
import FloeModels
import FloePersistence
import FloeSecurity

public enum BridgeV22 {
    public static let version = 22
    public static let schema = C05DesktopAssistWire.schema
    public static let maximumRequestBytes = C05DesktopAssistWire.maximumRequestBytes
    public static let maximumResponseBytes = C05DesktopAssistWire.maximumResponseBytes
    public static let modelTools: [String] = []
}

public enum C05DesktopAssistWire {
    public static let version = 22
    public static let schema = "floe.desktopassist/22"
    public static let maximumRequestBytes = 65_536
    public static let maximumResponseBytes = 128 * 1_024
    public static let maximumSecretBytes = 4_096
    public static let maximumLabelBytes = 600
    public static let operations: Set<String> = [
        "handshake",
        "c05.desktopassist.capabilities",
        "c05.desktopassist.cards.list",
        "c05.desktopassist.cards.create",
        "c05.desktopassist.cards.update",
        "c05.desktopassist.cards.delete",
        "c05.desktopassist.hosts.list",
        "c05.desktopassist.ocr.status",
    ]
}

public enum C05DesktopAssistBridgeError: Error, Sendable, Equatable {
    case invalidRequest(String)
    case invalidOwner
    case staleEpoch
    case runtimeUnavailable
    case invalidSecret
    case operationFailed(String)

    var code: String {
        switch self {
        case .invalidRequest: return "invalidRequest"
        case .invalidOwner: return "invalidOwner"
        case .staleEpoch: return "staleEpoch"
        case .runtimeUnavailable: return "runtimeUnavailable"
        case .invalidSecret: return "invalidSecret"
        case .operationFailed: return "desktopAssistOperationFailed"
        }
    }

    var reason: String {
        switch self {
        case .invalidRequest(let reason): return reason
        case .invalidOwner: return "invalidOwner"
        case .staleEpoch: return "staleNativeEpoch"
        case .runtimeUnavailable: return "runtimeNotInstalled"
        case .invalidSecret: return "invalidSecret"
        case .operationFailed(let reason): return reason
        }
    }
}

public enum C05DesktopAssistBridge {
    private final class ResultBox<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Result<T, C05DesktopAssistBridgeError>?

        func set(_ result: Result<T, C05DesktopAssistBridgeError>) {
            lock.lock(); value = result; lock.unlock()
        }

        func get() -> Result<T, C05DesktopAssistBridgeError>? {
            lock.lock(); defer { lock.unlock() }; return value
        }
    }

    private struct BlockResult<T> {
        let operation: String
        let result: Result<T, C05DesktopAssistBridgeError>

        func map(_ transform: (T) -> [String: Any]) -> [String: Any] {
            switch result {
            case .success(let value):
                return transform(value)
            case .failure(let error):
                return C05DesktopAssistBridge.failure(
                    error, operation: operation
                )
            }
        }
    }

    // MARK: - Entry

    public static func handle(requestData: Data, fallbackRequestID: String?) -> [String: Any] {
        var requestID = fallbackRequestID

        func failure(_ error: C05DesktopAssistBridgeError, operation: String?) -> [String: Any] {
            C05DesktopAssistBridge.failure(
                error,
                operation: operation,
                requestID: requestID ?? ""
            )
        }

        guard requestData.count <= C05DesktopAssistWire.maximumRequestBytes else {
            return failure(.invalidRequest("requestTooLarge"), operation: nil)
        }
        guard let object = (try? JSONSerialization.jsonObject(with: requestData)) as? [String: Any],
              let version = exactInt(object["version"]),
              version == C05DesktopAssistWire.version,
              let operation = boundedString(object["operation"], 64),
              C05DesktopAssistWire.operations.contains(operation) else {
            return failure(.invalidRequest("invalidRequest"), operation: nil)
        }
        requestID = boundedString(object["requestID"], 256) ?? requestID

        switch operation {
        case "handshake", "c05.desktopassist.capabilities":
            return run(seconds: 5, operation: operation) {
                await capabilities()
            }.map { (value: [String: Any]) in value }

        case "c05.desktopassist.cards.list":
            let owner = try? parseOwner(object["owner"])
            guard let owner else {
                return failure(.invalidOwner, operation: operation)
            }
            do { try requireLiveEpoch(owner) }
            catch let error as C05DesktopAssistBridgeError {
                return failure(error, operation: operation)
            } catch {
                return failure(.invalidOwner, operation: operation)
            }
            return run(seconds: 20, operation: operation) {
                let manager = try manager()
                return try await manager.listCards()
            }.map { (cards: [C05DesktopAssistCardMetadata]) in
                [
                    "ok": true,
                    "schema": C05DesktopAssistWire.schema,
                    "operation": operation,
                    "cards": cards.map(cardJSON),
                ]
            }

        case "c05.desktopassist.cards.create":
            let owner = try? parseOwner(object["owner"])
            guard let owner else {
                return failure(.invalidOwner, operation: operation)
            }
            do { try requireLiveEpoch(owner) }
            catch let error as C05DesktopAssistBridgeError {
                return failure(error, operation: operation)
            } catch {
                return failure(.invalidOwner, operation: operation)
            }
            let label: String
            let kind: CredentialKind
            let secret: Data
            let hostID: UUID?
            do {
                label = try requireLabel(object["label"])
                kind = try requireKind(object["kind"])
                secret = try requireSecret(object["secret"])
                hostID = try optionalUUID(object["hostID"])
            } catch let error as C05DesktopAssistBridgeError {
                return failure(error, operation: operation)
            } catch {
                return failure(.invalidRequest("invalidBody"), operation: operation)
            }
            return run(seconds: 30, operation: operation) {
                let manager = try manager()
                return try await manager.createCard(
                    label: label,
                    kind: kind,
                    secret: secret,
                    hostID: hostID
                )
            }.map { (card: C05DesktopAssistCardMetadata) in
                [
                    "ok": true,
                    "schema": C05DesktopAssistWire.schema,
                    "operation": operation,
                    "card": cardJSON(card),
                ]
            }

        case "c05.desktopassist.cards.update":
            let owner = try? parseOwner(object["owner"])
            guard let owner else {
                return failure(.invalidOwner, operation: operation)
            }
            do { try requireLiveEpoch(owner) }
            catch let error as C05DesktopAssistBridgeError {
                return failure(error, operation: operation)
            } catch {
                return failure(.invalidOwner, operation: operation)
            }
            let id: UUID
            let label: String?
            let secret: Data?
            do {
                guard let parsed = try optionalUUID(object["id"]) else {
                    throw C05DesktopAssistBridgeError.invalidRequest("invalidCardID")
                }
                id = parsed
                label = try optionalLabel(object["label"])
                secret = try optionalSecret(object["secret"])
            } catch let error as C05DesktopAssistBridgeError {
                return failure(error, operation: operation)
            } catch {
                return failure(.invalidRequest("invalidBody"), operation: operation)
            }
            guard label != nil || secret != nil else {
                return failure(.invalidRequest("emptyUpdate"), operation: operation)
            }
            return run(seconds: 30, operation: operation) {
                let manager = try manager()
                return try await manager.updateCard(
                    id: id,
                    label: label,
                    secret: secret
                )
            }.map { (card: C05DesktopAssistCardMetadata) in
                [
                    "ok": true,
                    "schema": C05DesktopAssistWire.schema,
                    "operation": operation,
                    "card": cardJSON(card),
                ]
            }

        case "c05.desktopassist.cards.delete":
            let owner = try? parseOwner(object["owner"])
            guard let owner else {
                return failure(.invalidOwner, operation: operation)
            }
            do { try requireLiveEpoch(owner) }
            catch let error as C05DesktopAssistBridgeError {
                return failure(error, operation: operation)
            } catch {
                return failure(.invalidOwner, operation: operation)
            }
            let id: UUID
            do {
                guard let parsed = try optionalUUID(object["id"]) else {
                    throw C05DesktopAssistBridgeError.invalidRequest("invalidCardID")
                }
                id = parsed
            } catch let error as C05DesktopAssistBridgeError {
                return failure(error, operation: operation)
            } catch {
                return failure(.invalidRequest("invalidCardID"), operation: operation)
            }
            return run(seconds: 20, operation: operation) {
                let manager = try manager()
                try await manager.deleteCard(id: id)
                return id
            }.map { (deleted: UUID) in
                [
                    "ok": true,
                    "schema": C05DesktopAssistWire.schema,
                    "operation": operation,
                    "deletedID": deleted.uuidString,
                ]
            }

        case "c05.desktopassist.hosts.list":
            let owner = try? parseOwner(object["owner"])
            guard let owner else {
                return failure(.invalidOwner, operation: operation)
            }
            do { try requireLiveEpoch(owner) }
            catch let error as C05DesktopAssistBridgeError {
                return failure(error, operation: operation)
            } catch {
                return failure(.invalidOwner, operation: operation)
            }
            return run(seconds: 20, operation: operation) {
                guard let composition = C05RuntimeWiring.composition() else {
                    throw C05DesktopAssistBridgeError.runtimeUnavailable
                }
                let store = RemoteHostStore(database: composition.cluster.database)
                return try await store.hosts()
            }.map { (hosts: [RemoteHostStore.StoredHost]) in
                [
                    "ok": true,
                    "schema": C05DesktopAssistWire.schema,
                    "operation": operation,
                    "hosts": hosts.map { host in
                        [
                            "id": host.id.uuidString,
                            "displayName": host.displayName,
                            "address": host.address,
                        ] as [String: Any]
                    },
                ]
            }

        case "c05.desktopassist.ocr.status":
            let owner = try? parseOwner(object["owner"])
            guard let owner else {
                return failure(.invalidOwner, operation: operation)
            }
            do { try requireLiveEpoch(owner) }
            catch let error as C05DesktopAssistBridgeError {
                return failure(error, operation: operation)
            } catch {
                return failure(.invalidOwner, operation: operation)
            }
            return run(seconds: 5, operation: operation) {
                RuntimeFacadeLinuxBindings.shared.isCapabilityQualified
            }.map { (qualified: Bool) in
                [
                    "ok": true,
                    "schema": C05DesktopAssistWire.schema,
                    "operation": operation,
                    "engine": "linuxTesseract",
                    "taskScoped": true,
                    "linuxShellQualified": qualified,
                    "preparation": C05LinuxTesseractConfiguration.preparationCommand,
                    "note": "Text recognition runs inside the task's Linux environment and is prepared on the first VNC/RDP connect.",
                ]
            }

        default:
            return failure(.invalidRequest("unsupportedOperation"), operation: operation)
        }
    }

    // MARK: - Capabilities

    private static func capabilities() async -> [String: Any] {
        let composition = C05RuntimeWiring.composition()
        let epoch = composition.map { NSNumber(value: $0.epoch) } ?? NSNull()
        return [
            "ok": true,
            "schema": C05DesktopAssistWire.schema,
            "operation": "c05.desktopassist.capabilities",
            "coreReady": composition != nil,
            "epoch": epoch,
            "cardManagementReady": composition != nil,
            "typingKinds": C05SecureCredentialCardResolver.typingKinds
                .map(\.rawValue)
                .sorted(),
            "maximumSecretBytes": C05SecureCredentialCardResolver.maximumSecretBytes,
            "linuxShellQualified": RuntimeFacadeLinuxBindings.shared.isCapabilityQualified,
            "ocrEngine": "linuxTesseract",
            "ocrPreparedOnConnect": true,
            "modelTools": C05RemoteDesktopToolNames.all,
        ]
    }

    // MARK: - Runtime

    private static func manager() throws -> any C05DesktopCredentialCardManaging {
        guard let composition = C05RuntimeWiring.composition() else {
            throw C05DesktopAssistBridgeError.runtimeUnavailable
        }
        let store = C05AndroidCredentialCardStore(vault: composition.vault)
        return C05SecureCredentialCardResolver(store: store)
    }

    private static func requireLiveEpoch(_ owner: C05RemoteOwner) throws {
        guard let composition = C05RuntimeWiring.composition(),
              composition.epoch == owner.nativeEpoch,
              composition.vaultEpoch == owner.nativeEpoch else {
            throw C05DesktopAssistBridgeError.staleEpoch
        }
        guard !owner.temporary else {
            throw C05DesktopAssistBridgeError.invalidOwner
        }
    }

    // MARK: - Blocking async

    private static func run<T>(
        seconds: Double,
        operation: String,
        _ body: @escaping @Sendable () async throws -> T
    ) -> BlockResult<T> {
        let semaphore = DispatchSemaphore(value: 0)
        let box = ResultBox<T>()
        let task = Task {
            do {
                box.set(.success(try await body()))
            } catch let error as C05DesktopAssistBridgeError {
                box.set(.failure(error))
            } catch let error as C05DesktopAssistError {
                box.set(.failure(.operationFailed(error.code)))
            } catch is CancellationError {
                box.set(.failure(.operationFailed("cancelled")))
            } catch {
                box.set(.failure(.operationFailed("operationFailed")))
            }
            semaphore.signal()
        }
        let timeout = DispatchTime.now()
            + .milliseconds(Int(max(0.05, seconds) * 1_000))
        if semaphore.wait(timeout: timeout) == .timedOut {
            task.cancel()
            return BlockResult(
                operation: operation,
                result: .failure(.operationFailed("timeout"))
            )
        }
        guard let result = box.get() else {
            return BlockResult(
                operation: operation,
                result: .failure(.operationFailed("missingResult"))
            )
        }
        return BlockResult(operation: operation, result: result)
    }

    // MARK: - Parsing

    private static func parseOwner(_ value: Any?) throws -> C05RemoteOwner {
        guard let object = value as? [String: Any],
              let token = boundedString(object["token"], 128),
              let epoch = uint64(object["nativeEpoch"]),
              epoch > 0 else {
            throw C05DesktopAssistBridgeError.invalidOwner
        }
        let owner = C05RemoteOwner(
            token: token,
            nativeEpoch: epoch,
            taskID: try optionalUUID(object["taskID"]),
            temporary: bool(object["temporary"]) ?? false
        )
        do {
            try owner.validate()
        } catch {
            throw C05DesktopAssistBridgeError.invalidOwner
        }
        return owner
    }

    private static func requireLabel(_ value: Any?) throws -> String {
        guard let label = boundedString(value, C05DesktopAssistWire.maximumLabelBytes) else {
            throw C05DesktopAssistBridgeError.invalidRequest("invalidLabel")
        }
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= C05SecureCredentialCardResolver.maximumLabelCharacters else {
            throw C05DesktopAssistBridgeError.invalidRequest("invalidLabel")
        }
        return trimmed
    }

    private static func optionalLabel(_ value: Any?) throws -> String? {
        guard let value, !(value is NSNull) else { return nil }
        return try requireLabel(value)
    }

    private static func requireKind(_ value: Any?) throws -> CredentialKind {
        guard let raw = boundedString(value, 32),
              let kind = CredentialKind(rawValue: raw),
              C05SecureCredentialCardResolver.typingKinds.contains(kind) else {
            throw C05DesktopAssistBridgeError.invalidRequest("invalidKind")
        }
        return kind
    }

    private static func requireSecret(_ value: Any?) throws -> Data {
        guard let text = value as? String, !text.isEmpty else {
            throw C05DesktopAssistBridgeError.invalidSecret
        }
        let data = Data(text.utf8)
        guard data.count <= C05SecureCredentialCardResolver.maximumSecretBytes else {
            throw C05DesktopAssistBridgeError.invalidSecret
        }
        return data
    }

    private static func optionalSecret(_ value: Any?) throws -> Data? {
        guard let value, !(value is NSNull) else { return nil }
        return try requireSecret(value)
    }

    private static func cardJSON(_ card: C05DesktopAssistCardMetadata) -> [String: Any] {
        var value: [String: Any] = [
            "id": card.id.uuidString,
            "reference": card.reference,
            "label": card.label,
            "kind": card.kind.rawValue,
            "ownerKind": card.ownerKind,
            "hostID": card.hostID?.uuidString ?? NSNull(),
            "updatedAt": ISO8601DateFormatter().string(from: card.updatedAt),
            "typingAllowed": card.typingAllowed,
        ]
        value["secretReturned"] = false
        return value
    }

    private static func failure(
        _ error: C05DesktopAssistBridgeError,
        operation: String?,
        requestID: String
    ) -> [String: Any] {
        var value: [String: Any] = [
            "ok": false,
            "code": error.code,
            "reason": error.reason,
            "retryable": false,
            "schema": C05DesktopAssistWire.schema,
            "requestID": requestID,
        ]
        if let operation { value["operation"] = operation }
        return value
    }

    private static func failure(
        _ error: C05DesktopAssistBridgeError,
        operation: String?
    ) -> [String: Any] {
        failure(error, operation: operation, requestID: "")
    }

    // MARK: - JSON helpers

    private static func boundedString(_ value: Any?, _ maximum: Int) -> String? {
        guard let text = value as? String, !text.isEmpty,
              text.utf8.count <= maximum,
              !text.contains("\u{0}") else { return nil }
        return text
    }

    private static func exactInt(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite else { return nil }
        let integer = number.int64Value
        guard number.compare(NSNumber(value: integer)) == .orderedSame,
              integer >= Int64(Int.min), integer <= Int64(Int.max) else { return nil }
        return Int(integer)
    }

    private static func uint64(_ value: Any?) -> UInt64? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite else { return nil }
        let integer = number.int64Value
        guard integer >= 0,
              number.compare(NSNumber(value: integer)) == .orderedSame else { return nil }
        return UInt64(integer)
    }

    private static func bool(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    private static func optionalUUID(_ value: Any?) throws -> UUID? {
        guard let value, !(value is NSNull) else { return nil }
        guard let text = value as? String, let id = UUID(uuidString: text),
              text.count == 36 else {
            throw C05DesktopAssistBridgeError.invalidRequest("invalidUUID")
        }
        return id
    }
}


/// Narrow internal access to the ONE installed runtime composition. It is a
/// lookup, not a second registry: card metadata still comes from the original
/// `CredentialStore` and secret bytes from the original vault.
enum C05RuntimeWiring {
    static func composition() -> G02InstalledComposition? {
        G02RuntimeComposition.shared.installedComposition
    }
}
