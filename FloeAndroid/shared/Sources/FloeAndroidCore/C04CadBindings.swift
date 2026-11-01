// SPDX-License-Identifier: MPL-2.0
//
// C04A host-only bridge `floe.cad/8`.
//
// The App's Kotlin viewer host is the only caller. It sends structured
// session/resource/capture metadata (never file bytes), and receives opaque
// resource ids and a rendered-frame/capture receipt. Main patches the frozen
// `AndroidBridge.exchange` version switch to route version 8 here; voice/7
// remains owned by the C03 lane.
//
// The channel is NOT a model tool and does not widen BridgeV3's command
// matrix. An installed core without v8 returns the ordinary
// `unsupportedVersion`; the App maps that to a typed needs-core-update state.
import Foundation

public enum BridgeV8 {
    public static let version = C04CadWire.version
}

public enum C04CadBridge {
    public static func handle(requestData: Data,
                              fallbackRequestID: String?) -> [String: Any] {
        var requestID = fallbackRequestID
        func failure(_ error: C04CadError, operation: String?) -> [String: Any] {
            var value: [String: Any] = [
                "ok": false,
                "code": error.code,
                "reason": error.reason,
                "schema": C04CadWire.schema,
            ]
            if let operation { value["operation"] = operation }
            if let requestID { value["requestID"] = requestID }
            return value
        }
        func success(_ fields: [String: Any], operation: String) -> [String: Any] {
            var value = fields
            value["ok"] = true
            value["schema"] = C04CadWire.schema
            value["operation"] = operation
            if let requestID { value["requestID"] = requestID }
            return value
        }
        guard requestData.count <= C04CadWire.maximumRequestBytes else {
            return failure(.requestTooLarge, operation: nil)
        }
        guard let object = (try? JSONSerialization.jsonObject(with: requestData))
                as? [String: Any],
              let version = c04Int(object["version"]),
              version == C04CadWire.version,
              let operation = c04String(object["operation"], maxBytes: 64) else {
            return failure(.invalidRequest, operation: nil)
        }
        requestID = c04String(object["requestID"], maxBytes: 256) ?? requestID
        do {
            switch operation {
            case "handshake":
                return success(handshake(), operation: operation)
            case "c04.session.begin":
                return success(try begin(object), operation: operation)
            case "c04.session.readiness":
                return success(try readiness(object), operation: operation)
            case "c04.session.capture":
                return success(try capture(object), operation: operation)
            case "c04.session.end":
                return success(try end(object), operation: operation)
            case "c04.extension.validate":
                return success(try validateExtension(object), operation: operation)
            case "c04.cancelAll":
                return success(["cancelled": C04CadSessionRegistry.shared.cancelAll()],
                               operation: operation)
            default:
                return failure(.unsupportedOperation, operation: operation)
            }
        } catch let error as C04CadError {
            return failure(error, operation: operation)
        } catch {
            return failure(.invalidRequest, operation: operation)
        }
    }

    // MARK: - Operations

    private static func handshake() -> [String: Any] {
        var readers: [String: Any] = [:]
        for format in C04CadFormat.allCases {
            readers[format.rawValue] = [
                "family": format.family.rawValue,
                "reader": format.reader,
                "sourceByteLimit": format.sourceByteLimit,
                "resourceExtensions": format.resourceExtensions.sorted(),
            ]
        }
        return [
            "version": C04CadWire.version,
            "schema": C04CadWire.schema,
            "operations": C04CadWire.operations,
            "readers": readers,
            "packageLimits": [
                "maxResources": C04FloecadPackageLimits.maximumSessionResources,
                "maxResourceBytes": C04FloecadPackageLimits.maximumBlobBytes,
                "maxTotalResourceBytes": C04FloecadPackageLimits.maximumSessionTotalBytes,
                "maxBodies": C04FloecadPackageLimits.maximumBodies,
                "maxImages": C04FloecadPackageLimits.maximumImages,
                "maxBrepConversionBytes": C04FloecadPackageLimits.maximumBrepConversionBytes,
            ],
            "limits": [
                "maxResources": C04CadLimits.maximumResources,
                "maxResourceBytes": C04CadLimits.maximumResourceBytes,
                "maxTotalResourceBytes": C04CadLimits.maximumTotalResourceBytes,
                "maxCaptureBytes": C04CadLimits.maximumCaptureBytes,
                "maxCaptureEdge": C04CadLimits.maximumCaptureEdge,
                "maxSessions": C04CadLimits.maximumSessions,
                "sessionTTLSeconds": Int(C04CadLimits.sessionTTL),
            ],
        ]
    }

    private static func begin(_ object: [String: Any]) throws -> [String: Any] {
        let owner = try C04CadOwner.parse(object["owner"])
        guard let path = c04String(object["relativePath"],
                                   maxBytes: C04CadLimits.maximumPathBytes),
              let formatValue = c04String(object["format"], maxBytes: 16),
              let format = C04CadFormat(rawValue: formatValue),
              let sourceBytes = c04Int(object["sourceBytes"]) else {
            throw C04CadError.invalidRequest
        }
        let rawResources: [Any]
        if let value = object["resources"] {
            guard let array = value as? [Any] else { throw C04CadError.invalidRequest }
            rawResources = array
        } else {
            rawResources = []
        }
        let maximumResourceBytes = format == .floecad
            ? C04FloecadPackageLimits.maximumBlobBytes
            : C04CadLimits.maximumResourceBytes
        let resources = try rawResources.map {
            try C04CadResourceDescriptor.parse($0, maximumBytes: maximumResourceBytes)
        }
        let started = try C04CadSessionRegistry.shared.begin(
            owner: owner, relativePath: path, format: format,
            sourceBytes: sourceBytes, resources: resources)
        return [
            "sessionID": started.sessionID.uuidString,
            "grants": started.grants.map(\.wire),
            "routing": [
                "format": format.rawValue,
                "family": format.family.rawValue,
                "reader": format.reader,
            ],
            "sourceBytes": sourceBytes,
            "resourceCount": started.grants.count,
        ]
    }

    private static func readiness(_ object: [String: Any]) throws -> [String: Any] {
        guard let sessionValue = c04String(object["sessionID"], maxBytes: 64),
              let sessionID = UUID(uuidString: sessionValue),
              let factsObject = object["facts"] as? [String: Any],
              let formatValue = c04String(factsObject["format"], maxBytes: 16),
              let format = C04CadFormat(rawValue: formatValue) else {
            throw C04CadError.invalidRequest
        }
        let facts = try C04CadSceneFacts.parse(factsObject, expected: format)
        let accepted = try C04CadSessionRegistry.shared.readiness(
            sessionID: sessionID, facts: facts)
        return [
            "sessionID": sessionID.uuidString,
            "readiness": "rendered",
            "frameSequence": accepted.frameSequence,
            "facts": accepted.wire,
        ]
    }

    private static func capture(_ object: [String: Any]) throws -> [String: Any] {
        guard let sessionValue = c04String(object["sessionID"], maxBytes: 64),
              let sessionID = UUID(uuidString: sessionValue),
              let header = c04String(object["pngHeaderHex"], maxBytes: 128),
              let digest = c04String(object["pngSHA256"], maxBytes: 64),
              let byteCount = c04Int(object["byteCount"]),
              let width = c04Int(object["pixelWidth"]),
              let height = c04Int(object["pixelHeight"]),
              let frame = c04Int(object["frameSequence"]) else {
            throw C04CadError.invalidRequest
        }
        let receipt = try C04CadSessionRegistry.shared.capture(
            sessionID: sessionID, pngHeaderHex: header, pngSHA256: digest,
            byteCount: byteCount, pixelWidth: width, pixelHeight: height,
            frameSequence: frame)
        return [
            "sessionID": sessionID.uuidString,
            "receipt": receipt.wire,
        ]
    }

    private static func end(_ object: [String: Any]) throws -> [String: Any] {
        guard let sessionValue = c04String(object["sessionID"], maxBytes: 64),
              let sessionID = UUID(uuidString: sessionValue) else {
            throw C04CadError.invalidRequest
        }
        return [
            "sessionID": sessionID.uuidString,
            "released": C04CadSessionRegistry.shared.end(sessionID: sessionID),
        ]
    }

    private static func validateExtension(_ object: [String: Any]) throws -> [String: Any] {
        guard let manifest = object["manifest"] as? [String: Any] else {
            throw C04CadError.invalidRequest
        }
        let summary = try C04CadPackageValidator.validate(manifest)
        return ["summary": summary.wire]
    }
}
