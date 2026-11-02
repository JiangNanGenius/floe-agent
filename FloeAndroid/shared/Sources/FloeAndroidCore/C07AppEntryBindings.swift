// SPDX-License-Identifier: MPL-2.0
//
// C07 additive host-only entries channel `floe.entry/24`.
//
// Same frozen `floe_bridge_exchange` C ABI and the same 65,536-byte request
// frame as the other host channels. This channel performs NO file, network,
// task, schedule, approval, credential or storage operation. It only parses an
// untrusted `floe://` navigation request and validates bounded share/open item
// descriptors against the shared policy. The platform host still owns Intent
// admission, grant leases, store re-reads and the actual destination.
import Foundation

public enum BridgeV24 {
    public static let version = 24
    public static let schema = "floe.entry/24"
    public static let maximumRequestBytes = 65_536
    public static let maximumResponseBytes = 49_152
    public static let modelTools = false
}

public enum C07AppEntryBridge {
    private static let baseKeys: Set<String> = [
        "version", "schema", "operation", "requestID",
    ]
    private static let operations: Set<String> = [
        "handshake", "entry.capabilities", "entry.parseLink", "entry.validateShare",
    ]
    private static let linkKeys = baseKeys.union(["url"])
    private static let shareKeys = baseKeys.union(["items"])
    private static let itemKeys: Set<String> = [
        "kind", "mimeType", "byteCount", "textBytes", "fileName",
    ]

    public static func handle(
        requestData: Data,
        fallbackRequestID: String?
    ) -> [String: Any] {
        var requestID = fallbackRequestID

        func failure(_ code: String, operation: String? = nil) -> [String: Any] {
            var value: [String: Any] = [
                "ok": false,
                "code": code,
                "version": BridgeV24.version,
                "schema": BridgeV24.schema,
            ]
            if let operation { value["operation"] = operation }
            if let requestID { value["requestID"] = requestID }
            return value
        }

        guard requestData.count <= BridgeV24.maximumRequestBytes else {
            return failure("requestTooLarge")
        }
        guard let object = (try? JSONSerialization.jsonObject(with: requestData))
                as? [String: Any] else {
            return failure("invalidJSON")
        }
        guard int(object["version"]) == BridgeV24.version else {
            return failure("unsupportedVersion")
        }
        guard string(object["schema"], maxBytes: 64) == BridgeV24.schema else {
            return failure("invalidSchema")
        }
        guard let operation = string(object["operation"], maxBytes: 64),
              operations.contains(operation) else {
            return failure("unsupportedOperation")
        }
        requestID = string(object["requestID"], maxBytes: 256) ?? requestID

        func reply(_ body: [String: Any]) -> [String: Any] {
            var value = body
            value["ok"] = value["ok"] ?? true
            value["version"] = BridgeV24.version
            value["schema"] = BridgeV24.schema
            value["operation"] = operation
            if let requestID { value["requestID"] = requestID }
            guard JSONSerialization.isValidJSONObject(value),
                  let encoded = try? JSONSerialization.data(
                    withJSONObject: value, options: [.sortedKeys]),
                  encoded.count <= BridgeV24.maximumResponseBytes else {
                return failure("responseTooLarge", operation: operation)
            }
            return value
        }

        switch operation {
        case "handshake", "entry.capabilities":
            guard Set(object.keys).isSubset(of: baseKeys) else {
                return reply(failure("unexpectedKeys", operation: operation))
            }
            return reply(capabilities())

        case "entry.parseLink":
            guard Set(object.keys).isSubset(of: linkKeys) else {
                return reply(failure("unexpectedKeys", operation: operation))
            }
            guard let raw = string(object["url"], maxBytes: C07AppEntryRoute.maximumURLBytes),
                  !raw.isEmpty else {
                return reply(failure("invalidRequest", operation: operation))
            }
            do {
                let route = try C07AppEntryRoute.parse(raw)
                return reply(["route": routeJSON(route)])
            } catch let error as C07AppEntryRouteError {
                return reply(failure(error.rawValue, operation: operation))
            } catch {
                return reply(failure("malformedURL", operation: operation))
            }

        case "entry.validateShare":
            guard Set(object.keys).isSubset(of: shareKeys) else {
                return reply(failure("unexpectedKeys", operation: operation))
            }
            guard let rawItems = object["items"] as? [Any], !rawItems.isEmpty else {
                return reply(failure("empty", operation: operation))
            }
            guard rawItems.count <= 16 else {
                return reply(failure("itemLimit", operation: operation))
            }
            var items: [C07ShareItemDescriptor] = []
            items.reserveCapacity(rawItems.count)
            for rawItem in rawItems {
                guard let item = rawItem as? [String: Any],
                      Set(item.keys).isSubset(of: itemKeys),
                      let kindRaw = string(item["kind"], maxBytes: 16),
                      let kind = C07ShareItemKind(rawValue: kindRaw),
                      let mimeType = string(item["mimeType"], maxBytes: 200),
                      let byteCount = int64(item["byteCount"]),
                      let textBytes = int64(item["textBytes"]) else {
                    return reply(failure("invalidDescriptor", operation: operation))
                }
                let fileName: String?
                if item["fileName"] != nil {
                    guard let value = string(item["fileName"], maxBytes: 512) else {
                        return reply(failure("invalidDescriptor", operation: operation))
                    }
                    fileName = value
                } else {
                    fileName = nil
                }
                items.append(C07ShareItemDescriptor(
                    kind: kind,
                    mimeType: mimeType,
                    byteCount: byteCount,
                    textBytes: textBytes,
                    fileName: fileName
                ))
            }
            switch C07SharePolicy.validate(items) {
            case .success(let admission):
                return reply([
                    "admission": [
                        "items": admission.items.map(itemJSON),
                        "totalKnownBytes": admission.totalKnownBytes,
                        "textBytes": admission.textBytes,
                        "taskAvailable": admission.taskAvailable,
                        "notesAvailable": admission.notesAvailable,
                        "packageKind": admission.packageKind.rawValue,
                    ],
                ])
            case .failure(let refusal):
                return reply(failure(refusal.rawValue, operation: operation))
            }

        default:
            return reply(failure("unsupportedOperation", operation: operation))
        }
    }

    private static func capabilities() -> [String: Any] {
        [
            "ok": true,
            "maximumURLBytes": C07AppEntryRoute.maximumURLBytes,
            "maxItems": C07ShareLimits.standard.maxItems,
            "maxTextBytes": C07ShareLimits.standard.maxTextBytes,
            "maxItemBytes": C07ShareLimits.standard.maxItemBytes,
            "maxTotalBytes": C07ShareLimits.standard.maxTotalBytes,
            "modelTools": false,
        ]
    }

    private static func routeJSON(_ route: C07AppEntryRoute) -> [String: Any] {
        switch route {
        case .newTask:
            return ["kind": "newTask"]
        case .task(let id):
            return ["kind": "task", "id": id.uuidString.lowercased()]
        case .schedule(let id):
            return ["kind": "schedule", "id": id.uuidString.lowercased()]
        case .share(let id):
            return [
                "kind": "share",
                "intakeID": id?.uuidString.lowercased() ?? NSNull(),
            ]
        }
    }

    private static func itemJSON(_ item: C07ShareItemDescriptor) -> [String: Any] {
        var value: [String: Any] = [
            "kind": item.kind.rawValue,
            "mimeType": item.mimeType,
            "byteCount": item.byteCount,
            "textBytes": item.textBytes,
        ]
        if let fileName = item.fileName { value["fileName"] = fileName }
        return value
    }

    private static func string(_ value: Any?, maxBytes: Int) -> String? {
        guard let value = value as? String, value.utf8.count <= maxBytes else {
            return nil
        }
        return value
    }

    private static func int(_ value: Any?) -> Int? {
        if value is Bool { return nil }
        if let number = value as? NSNumber { return number.intValue }
        if let value = value as? String { return Int(value) }
        return nil
    }

    private static func int64(_ value: Any?) -> Int64? {
        if value is Bool { return nil }
        if let number = value as? NSNumber { return number.int64Value }
        if let value = value as? String { return Int64(value) }
        return nil
    }
}
