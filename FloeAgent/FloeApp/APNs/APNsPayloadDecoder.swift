// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import CoreFoundation

/// Decode synchronously at the UIApplication/UN delegate boundary. Raw
/// AnyHashable/Any dictionaries never cross a Swift concurrency boundary.
nonisolated enum APNsPayloadDecoder {
    static func decode(userInfo: [AnyHashable: Any]) throws -> APNsPayload {
        guard userInfo.keys.allSatisfy({ $0.base is String }),
              Set(userInfo.keys.compactMap { $0.base as? String }) == ["aps", "floe"],
              JSONSerialization.isValidJSONObject(userInfo),
              try JSONSerialization.data(withJSONObject: userInfo).count <= 4_096,
              let aps = userInfo["aps"] as? [String: Any],
              let body = userInfo["floe"] as? [String: Any] else { throw APNsServiceError.invalidPayload }
        let allowed: Set<String> = ["schemaVersion", "kind", "eventID", "installationID", "registrationRevision", "sentAt", "expiresAt", "releaseID", "channel"]
        guard Set(body.keys).isSubset(of: allowed),
              integer(body["schemaVersion"]) == 1,
              let kindText = body["kind"] as? String, let kind = APNsPayload.Kind(rawValue: kindText),
              let eventText = body["eventID"] as? String, let event = UUID(uuidString: eventText),
              let installationText = body["installationID"] as? String, let installation = UUID(uuidString: installationText),
              let revision = integer(body["registrationRevision"]), revision >= 0,
              let sent = date(body["sentAt"]), let expires = date(body["expiresAt"]), expires > sent else {
            throw APNsServiceError.invalidPayload
        }
        let releaseID = body["releaseID"] as? String
        let channel = (body["channel"] as? String).flatMap(APNsInstallChannel.init(rawValue:))
        if kind == .heartbeat {
            guard Set(aps.keys) == ["content-available"], integer(aps["content-available"]) == 1,
                  body["releaseID"] == nil, body["channel"] == nil,
                  expires.timeIntervalSince(sent) <= 15 * 60 else { throw APNsServiceError.invalidPayload }
        } else {
            let allowedAPS: Set<String> = ["alert", "sound", "badge", "thread-id", "category", "content-available"]
            guard Set(aps.keys).isSubset(of: allowedAPS),
                  let releaseID, releaseID.range(of: "^[A-Za-z0-9._-]{1,128}$", options: .regularExpression) != nil,
                  channel == .appStore || channel == .testFlight,
                  expires.timeIntervalSince(sent) <= 86_400 else { throw APNsServiceError.invalidPayload }
        }
        return .init(schemaVersion: 1, kind: kind, eventID: event, installationID: installation,
            registrationRevision: revision, sentAt: sent, expiresAt: expires, releaseID: releaseID, channel: channel)
    }
    private static func integer(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue.rounded() == number.doubleValue,
              number.doubleValue >= 0, number.doubleValue < Double(Int64.max) else { return nil }
        return number.int64Value
    }
    private static func date(_ value: Any?) -> Date? {
        guard let raw = value as? String, raw.utf8.count <= 40 else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: raw) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: raw)
    }
}
#endif
