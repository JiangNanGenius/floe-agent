import Foundation
import CoreFoundation
import FloeSync

/// Local saved-grant inspection only. This proves neither online token
/// validity nor a provider-verified identity/email address.
enum NativeExternalOAuthLocalGrant {
    enum Status: Sendable, Equatable { case available, needsRefresh }

    static func inspect(_ payload: Data, skillID: String, installationID: String,
                        profile: String, target: String, now: Date) throws -> Status {
        guard target == "local-linux", let grant = try ExternalOAuthSavedGrant.decode(payload),
              skillID == (grant.clientProfile.provider == .google ? "floe-google-auth" : "floe-microsoft-auth"),
              case .linuxEnvironment = grant.location,
              grant.registrationClientID == grant.clientProfile.clientID,
              grant.registrationIssuer == grant.clientProfile.authorizationEndpoint.absoluteString else {
            throw ExternalOAuthFailure.storageUnavailable
        }
        let context = try ExternalOAuthCredentialContext(connectorID: skillID, installationID: installationID,
            profile: profile, accountID: grant.accountID, location: grant.location, client: grant.clientProfile)
        guard context.vaultPartition == grant.partition,
              let token = try? JSONSerialization.jsonObject(with: grant.token) as? [String: Any],
              let access = token["access_token"] as? String, !access.isEmpty, access.utf8.count <= 16_384,
              access.unicodeScalars.allSatisfy({ $0.value > 32 && $0.value < 127 }),
              (token["token_type"] as? String)?.lowercased() == "bearer" else {
            throw ExternalOAuthFailure.storageUnavailable
        }
        func number(_ key: String) -> Double? {
            guard let value = token[key] as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
                  value.doubleValue.isFinite, value.doubleValue >= 0 else { return nil }
            return value.doubleValue
        }
        guard let issued = number("issued_at"), let lifetime = number("expires_in"),
              issued <= now.timeIntervalSince1970 + 60, (issued + lifetime).isFinite,
              issued + lifetime > now.timeIntervalSince1970 + 60 else { return .needsRefresh }
        return .available
    }
}

struct NativeExternalOAuthConnectionValidator: SkillConfigurationValidating {
    let supportedConnectionKind = "oauth.external"
    let identifier = "oauth.external.local-token.v1"
    /// Required live installed/source/capabilities and exact current payload
    /// validation. No task/run/permission is fabricated by this callback.
    let authorize: @Sendable (SkillConfigurationValidationRequest, Data?) async throws -> Void
    var now: @Sendable () -> Date = { Date() }

    func validate(_ request: SkillConfigurationValidationRequest) async throws -> SkillConfigurationValidationResult {
        guard request.connectionKind == supportedConnectionKind, request.fieldKey == "connection",
              ["floe-google-auth", "floe-microsoft-auth"].contains(request.skillID), request.target == "local-linux" else {
            return .unsupported(reason: NativeExternalOAuthCopy.text("This account connection is unavailable.", "此账号连接不可用。"))
        }
        do {
            try await authorize(request, nil)
            let payload = try await request.readSecret()
            let result = try NativeExternalOAuthLocalGrant.inspect(payload, skillID: request.skillID,
                installationID: request.installationID, profile: request.profile, target: request.target, now: now())
            try await authorize(request, payload)
            switch result {
            case .available:
                return .valid(message: NativeExternalOAuthCopy.text("Saved authorization is available.", "已保存的授权可用。"))
            case .needsRefresh:
                return .invalid(message: NativeExternalOAuthCopy.text("Refresh this connection before using it.", "请先刷新此连接。"))
            }
        } catch is CancellationError { throw CancellationError() }
        catch {
            // No provider/vault error text or payload enters validation receipts.
            return .invalid(message: NativeExternalOAuthCopy.text(
                "The saved authorization is unavailable. Unlock this device and try again; it was retained.",
                "暂时无法使用已保存的授权。请解锁设备后重试；连接已保留。"))
        }
    }
}
