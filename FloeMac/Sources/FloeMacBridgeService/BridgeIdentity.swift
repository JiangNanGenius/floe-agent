// Floe Mac M00 — Bridge server identity resolution.
//
// SPDX-License-Identifier: MPL-2.0
//
// Production uses the existing standalone Bridge Keychain item read-only. It
// never overwrites paired-clients.json, never generates a replacement identity
// while pairings exist, and never accepts a synthetic key. An ad-hoc build
// that cannot read the old item must report the limit instead of resetting it.
//
// Test mode uses a fixture-persisted Curve25519 key so restart/recovery can be
// exercised without touching the user's Keychain or real Bridge data.

import ApplicationServices
import CoreGraphics
import CryptoKit
import Darwin
import Foundation
import FloeMacBridgeProtocol
import LocalAuthentication
import Security

struct SigningInformation: Sendable {
    var identifier: String
    var teamIdentifier: String
    var flags: UInt32
    var adHoc: Bool

    var summary: String {
        "identifier=\(identifier) team=\(teamIdentifier.isEmpty ? "none" : teamIdentifier) adhoc=\(adHoc)"
    }
}

enum KeychainIdentityRead: Sendable {
    case found(Data)
    case absent
    case denied(OSStatus)
    case failed(OSStatus)
}

enum ResolvedBridgeIdentity: Sendable {
    case keychain(Curve25519.Signing.PrivateKey, SigningInformation)
    case isolatedKeychain(Curve25519.Signing.PrivateKey, SigningInformation)
    case testFixture(Curve25519.Signing.PrivateKey)

    var signingKey: Curve25519.Signing.PrivateKey {
        switch self {
        case .keychain(let key, _): key
        case .isolatedKeychain(let key, _): key
        case .testFixture(let key): key
        }
    }

    var publicKey: Data { signingKey.publicKey.rawRepresentation }
    var fingerprintSHA256: String { BridgeControlCodec.fingerprint(publicKey) }

    var source: String {
        switch self {
        case .keychain: "keychain:org.floeagent.bridge.server"
        case .isolatedKeychain: "keychain:\(BridgeIsolatedProfile.identityService)"
        case .testFixture: "test-fixture-persistent"
        }
    }
}

enum BridgeIdentityError: Error, LocalizedError, Sendable {
    case keychainDenied(OSStatus, pairedClients: Int)
    case missingWithPairings(pairedClients: Int)
    case absentNeedsSignedBuild
    case invalidKeyLength(Int)
    case invalidFixtureIdentity(String)
    case signingReadFailed(String)
    case invalidIsolatedProfile
    case untrustedIsolatedService
    case isolatedKeychainDenied(OSStatus)

    var errorDescription: String? {
        switch self {
        case .keychainDenied(let status, let pairs):
            "The existing Floe Bridge identity is in the login Keychain but this build cannot read it (OSStatus \(status)). "
                + "\(pairs) pairing(s) were left untouched. Sign the embedded service with the existing Floe Bridge code identity, "
                + "or allow this app in Keychain access; M00 does not create or reset the identity."
        case .missingWithPairings(let pairs):
            "Floe Bridge has \(pairs) existing pairing(s) but no readable server identity. "
                + "Refusing to create a new identity and leave those clients paired to a different key. Restore the original Keychain item or sign with the original identity."
        case .absentNeedsSignedBuild:
            "No existing Floe Bridge server identity was found. M00 does not create a new identity from an ad-hoc build; "
                + "the signed product must create it once, or the existing standalone Bridge identity must be made accessible."
        case .invalidKeyLength(let length):
            "The stored Bridge identity is \(length) bytes, not a Curve25519 signing key. It was not replaced."
        case .invalidFixtureIdentity(let reason):
            "The test fixture identity is invalid: \(reason). It was not replaced."
        case .signingReadFailed(let reason):
            "The helper code signature could not be inspected: \(reason)"
        case .invalidIsolatedProfile:
            "The separate Bridge identity requires the separate Bridge data location."
        case .untrustedIsolatedService:
            "The separate Bridge identity requires the Floe Developer ID signed Bridge service."
        case .isolatedKeychainDenied(let status):
            "The separate Bridge identity could not be accessed (OSStatus \(status)). It was not replaced."
        }
    }
}

enum BridgeIdentity {
    static let service = "org.floeagent.bridge.server"
    static let account = "identity-v1"

    /// This namespace has no fallback to the old service or identity.
    private static func readIsolatedIdentity() -> KeychainIdentityRead {
        var result: CFTypeRef?
        let context = LAContext()
        context.interactionNotAllowed = true
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: BridgeIsolatedProfile.identityService,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
            kSecUseAuthenticationContext: context
        ]
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { return .failed(status) }
            return .found(data)
        case errSecItemNotFound: return .absent
        case errSecInteractionNotAllowed, errSecAuthFailed, errSecUserCanceled: return .denied(status)
        default: return .failed(status)
        }
    }

    /// Add-only: concurrent creators never update or replace a winner.
    private static func addIsolatedIdentityIfAbsent(_ data: Data) -> OSStatus {
        let context = LAContext()
        context.interactionNotAllowed = true
        let item: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: BridgeIsolatedProfile.identityService,
            kSecAttrAccount: account,
            kSecValueData: data,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecUseAuthenticationContext: context
        ]
        return SecItemAdd(item as CFDictionary, nil)
    }

    /// Resolves only the isolated store and isolated Keychain service. The
    /// future caller must retain its real store lock across this operation
    /// and the entire service lifetime. This function does not grant service
    /// startup, validate later path substitution, or migrate legacy data.
    static func resolveIsolatedProduction(paths: BridgePaths, createIfAbsent: Bool) throws -> ResolvedBridgeIdentity {
        guard paths.namespace == .isolated else { throw BridgeIdentityError.invalidIsolatedProfile }
        let signing = try verifiedIsolatedServiceSigning()
        return try resolveIsolatedIdentity(paths: paths, createIfAbsent: createIfAbsent, signing: signing,
                                          readIdentity: readIsolatedIdentity, addIdentity: addIsolatedIdentityIfAbsent)
    }

    /// These values match the signed helper in the inherited OTA bundle.
    /// Validate the live process against the requirement before opening the
    /// pair store or asking Security to return an existing secret.
    static func verifiedIsolatedServiceSigning() throws -> SigningInformation {
        let text = """
            anchor apple generic and identifier "org.floeagent.mac.bridgecomponent" and
            certificate 1[field.1.2.840.113635.100.6.2.6] and
            certificate leaf[field.1.2.840.113635.100.6.1.13] and certificate leaf[subject.OU] = "QYL72C43K6"
            """
        var requirement: SecRequirement?
        var runningCode: SecCode?
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess,
              let requirement,
              SecCodeCopySelf([], &runningCode) == errSecSuccess,
              let runningCode,
              SecCodeCheckValidity(runningCode, [], requirement) == errSecSuccess else {
            throw BridgeIdentityError.untrustedIsolatedService
        }
        let signing = signingInformation()
        guard !signing.adHoc else { throw BridgeIdentityError.untrustedIsolatedService }
        return signing
    }

    #if FLOE_IPC_TESTING
    static func resolveIsolatedProduction(
        paths: BridgePaths, createIfAbsent: Bool, signing: SigningInformation,
        readIdentity: @Sendable () -> KeychainIdentityRead,
        addIdentity: @Sendable (Data) -> OSStatus
    ) throws -> ResolvedBridgeIdentity {
        try resolveIsolatedIdentity(paths: paths, createIfAbsent: createIfAbsent, signing: signing,
                                    readIdentity: readIdentity, addIdentity: addIdentity)
    }
    #endif

    private static func resolveIsolatedIdentity(
        paths: BridgePaths, createIfAbsent: Bool, signing: SigningInformation,
        readIdentity: @Sendable () -> KeychainIdentityRead,
        addIdentity: @Sendable (Data) -> OSStatus
    ) throws -> ResolvedBridgeIdentity {
        guard paths.namespace == .isolated else { throw BridgeIdentityError.invalidIsolatedProfile }
        let pairs = try BridgeService.loadPairs(at: paths.root.appendingPathComponent("State/paired-clients.json")).count
        switch readIdentity() {
        case .found(let data):
            guard data.count == 32 else { throw BridgeIdentityError.invalidKeyLength(data.count) }
            return .isolatedKeychain(try Curve25519.Signing.PrivateKey(rawRepresentation: data), signing)
        case .denied(let status), .failed(let status):
            throw BridgeIdentityError.isolatedKeychainDenied(status)
        case .absent:
            guard pairs == 0 else { throw BridgeIdentityError.missingWithPairings(pairedClients: pairs) }
            guard createIfAbsent, !signing.adHoc, !signing.teamIdentifier.isEmpty else {
                throw BridgeIdentityError.absentNeedsSignedBuild
            }
            let proposed = Curve25519.Signing.PrivateKey()
            let status = addIdentity(proposed.rawRepresentation)
            guard status == errSecSuccess || status == errSecDuplicateItem else {
                throw BridgeIdentityError.isolatedKeychainDenied(status)
            }
            switch readIdentity() {
            case .found(let data):
                guard data.count == 32 else { throw BridgeIdentityError.invalidKeyLength(data.count) }
                guard status != errSecSuccess || data == proposed.rawRepresentation else {
                    throw BridgeIdentityError.signingReadFailed("the new separate identity changed before verification")
                }
                return .isolatedKeychain(try Curve25519.Signing.PrivateKey(rawRepresentation: data), signing)
            case .denied(let status), .failed(let status): throw BridgeIdentityError.isolatedKeychainDenied(status)
            case .absent: throw BridgeIdentityError.signingReadFailed("the separate identity was not readable after creation")
            }
        }
    }

    static func signingInformation() -> SigningInformation {
        var code: SecCode?
        var information: SigningInformation?
        if SecCodeCopySelf([], &code) == errSecSuccess, let code {
            var staticCode: SecStaticCode?
            if SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode {
                var details: CFDictionary?
                let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
                if SecCodeCopySigningInformation(staticCode, flags, &details) == errSecSuccess,
                   let dictionary = details as? [String: Any] {
                    let identifier = dictionary[kSecCodeInfoIdentifier as String] as? String ?? "unknown"
                    let team = dictionary[kSecCodeInfoTeamIdentifier as String] as? String ?? ""
                    let number = dictionary[kSecCodeInfoFlags as String] as? NSNumber
                    let rawFlags = number?.uint32Value ?? 0
                    // kSecCodeSignatureAdhoc is 0x0002. A missing team is also
                    // treated as ad-hoc for identity-creation decisions.
                    let adHoc = (rawFlags & 0x0002) != 0 || team.isEmpty
                    information = SigningInformation(
                        identifier: identifier,
                        teamIdentifier: team,
                        flags: rawFlags,
                        adHoc: adHoc
                    )
                }
            }
        }
        return information ?? SigningInformation(identifier: "unavailable", teamIdentifier: "", flags: 0, adHoc: true)
    }

    static func readExistingKeychainIdentity() -> KeychainIdentityRead {
        var result: CFTypeRef?
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
            kSecUseAuthenticationUI: kSecUseAuthenticationUIFail
        ]
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { return .failed(status) }
            return .found(data)
        case errSecItemNotFound:
            return .absent
        case errSecInteractionNotAllowed, errSecAuthFailed, errSecUserCanceled:
            return .denied(status)
        default:
            return .failed(status)
        }
    }

    /// Never update an existing identity, including when another process
    /// creates it between our initial lookup and this add.
    static func addKeychainIdentityIfAbsent(_ data: Data) -> OSStatus {
        let item: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecValueData: data,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecUseAuthenticationUI: kSecUseAuthenticationUIFail
        ]
        return SecItemAdd(item as CFDictionary, nil)
    }

    static func pairCount(storageRoot: URL) throws -> Int {
        let pairURL = storageRoot
            .appendingPathComponent("Library/Application Support/Floe Bridge/State/paired-clients.json", isDirectory: false)
        return try BridgeService.loadPairs(at: pairURL).count
    }

    static func resolveProduction(
        createIfAbsent: Bool,
        signing: SigningInformation = BridgeIdentity.signingInformation(),
        storageRoot: URL = ServicePaths.realUserHome,
        readIdentity: @Sendable () -> KeychainIdentityRead = BridgeIdentity.readExistingKeychainIdentity,
        addIdentity: @Sendable (Data) -> OSStatus = BridgeIdentity.addKeychainIdentityIfAbsent
    ) throws -> ResolvedBridgeIdentity {
        let pairs = try pairCount(storageRoot: storageRoot)
        switch readIdentity() {
        case .found(let data):
            guard data.count == 32 else { throw BridgeIdentityError.invalidKeyLength(data.count) }
            let key = try Curve25519.Signing.PrivateKey(rawRepresentation: data)
            return .keychain(key, signing)
        case .denied(let status):
            throw BridgeIdentityError.keychainDenied(status, pairedClients: pairs)
        case .failed(let status):
            throw BridgeIdentityError.keychainDenied(status, pairedClients: pairs)
        case .absent:
            if pairs > 0 { throw BridgeIdentityError.missingWithPairings(pairedClients: pairs) }
            guard createIfAbsent, !signing.adHoc, !signing.teamIdentifier.isEmpty else {
                throw BridgeIdentityError.absentNeedsSignedBuild
            }
            let key = Curve25519.Signing.PrivateKey()
            let status = addIdentity(key.rawRepresentation)
            guard status == errSecSuccess || status == errSecDuplicateItem else {
                throw BridgeIdentityError.keychainDenied(status, pairedClients: pairs)
            }
            switch readIdentity() {
            case .found(let data):
                guard data.count == 32 else { throw BridgeIdentityError.invalidKeyLength(data.count) }
                guard status != errSecSuccess || data == key.rawRepresentation else {
                    throw BridgeIdentityError.signingReadFailed("the newly created identity changed before it could be verified")
                }
                return .keychain(try Curve25519.Signing.PrivateKey(rawRepresentation: data), signing)
            case .denied(let status):
                throw BridgeIdentityError.keychainDenied(status, pairedClients: pairs)
            case .failed(let status):
                throw BridgeIdentityError.keychainDenied(status, pairedClients: pairs)
            case .absent:
                throw BridgeIdentityError.signingReadFailed("the new Keychain item was not readable after creation")
            }
        }
    }

    static func resolveTestFixture(_ fixture: URL) throws -> ResolvedBridgeIdentity {
        let identityURL = fixture.appendingPathComponent("service-identity.json", isDirectory: false)
        var status = stat()
        if lstat(identityURL.path, &status) == 0 {
            guard (status.st_mode & S_IFMT) != S_IFLNK else {
                throw BridgeIdentityError.invalidFixtureIdentity("the identity file is a symbolic link")
            }
            guard (status.st_mode & S_IFMT) == S_IFREG, status.st_uid == geteuid() else {
                throw BridgeIdentityError.invalidFixtureIdentity("the identity file is not a regular file owned by this user")
            }
            let descriptor = open(identityURL.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard descriptor >= 0 else {
                throw BridgeIdentityError.invalidFixtureIdentity("the identity file could not be opened without following links")
            }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            let data = try handle.readToEnd() ?? Data()
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let encoded = object["privateKey"] as? String,
                  let raw = Data(base64Encoded: encoded), raw.count == 32 else {
                throw BridgeIdentityError.invalidFixtureIdentity("privateKey is not a base64 32-byte key")
            }
            return .testFixture(try Curve25519.Signing.PrivateKey(rawRepresentation: raw))
        }
        guard errno == ENOENT else {
            throw BridgeIdentityError.invalidFixtureIdentity("the identity path could not be inspected")
        }
        let key = Curve25519.Signing.PrivateKey()
        let payload: [String: Any] = [
            "schema": "floe-mac-bridge-test-identity-v1",
            "privateKey": key.rawRepresentation.base64EncodedString(),
            "publicKey": key.publicKey.rawRepresentation.base64EncodedString(),
            "createdAt": ISO8601DateFormatter().string(from: Date())
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys, .prettyPrinted])
        // O_EXCL and O_NOFOLLOW make the first identity creation race-safe and
        // prevent a replaced path from writing through a symbolic link.
        let descriptor = open(identityURL.path,
                              O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else {
            throw BridgeIdentityError.invalidFixtureIdentity("the identity file could not be created exclusively")
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        try handle.write(contentsOf: data)
        try handle.synchronize()
        return .testFixture(key)
    }

    static func permissions() -> (screenCapture: Bool, accessibility: Bool) {
        (CGPreflightScreenCaptureAccess(), AXIsProcessTrusted())
    }
}

struct IdentityCheckReport: Codable, Sendable {
    var schema: String
    var bundleIdentifier: String
    var bundlePath: String
    var version: String
    var build: String
    var signingIdentifier: String
    var signingTeamIdentifier: String
    var signingFlags: UInt32
    var signingAdHoc: Bool
    var keychainService: String
    var keychainAccount: String
    var keychainItemStatus: String
    var keychainAccessible: Bool
    var keychainOSStatus: Int32
    var pairedClientCount: Int
    var dataRoot: String
    var dataRootExists: Bool
    var screenCaptureAllowed: Bool
    var accessibilityAllowed: Bool
    var helperRunsAsProduction: Bool
    var note: String
}

enum IdentityCheck {
    static func run() -> IdentityCheckReport {
        let signing = BridgeIdentity.signingInformation()
        let read = BridgeIdentity.readExistingKeychainIdentity()
        let status: Int32
        let label: String
        var accessible = false
        switch read {
        case .found(let data):
            status = errSecSuccess
            label = data.count == 32 ? "found" : "found-wrong-length"
            accessible = data.count == 32
        case .absent:
            status = errSecItemNotFound
            label = "absent"
        case .denied(let value):
            status = value
            label = "access-denied"
        case .failed(let value):
            status = value
            label = "read-failed"
        }
        let pairs = (try? BridgeIdentity.pairCount(storageRoot: ServicePaths.realUserHome)) ?? -1
        let dataRoot = ServicePaths.userBridgeRoot
        let permissions = BridgeIdentity.permissions()
        return IdentityCheckReport(
            schema: "floe-mac-bridge-identity-check-v1",
            bundleIdentifier: Bundle.main.bundleIdentifier ?? "unknown",
            bundlePath: Bundle.main.bundlePath,
            version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
            signingIdentifier: signing.identifier,
            signingTeamIdentifier: signing.teamIdentifier,
            signingFlags: signing.flags,
            signingAdHoc: signing.adHoc,
            keychainService: BridgeIdentity.service,
            keychainAccount: BridgeIdentity.account,
            keychainItemStatus: label,
            keychainAccessible: accessible,
            keychainOSStatus: status,
            pairedClientCount: pairs,
            dataRoot: dataRoot.path,
            dataRootExists: FileManager.default.fileExists(atPath: dataRoot.path),
            screenCaptureAllowed: permissions.screenCapture,
            accessibilityAllowed: permissions.accessibility,
            helperRunsAsProduction: true,
            note: "Read-only. No Keychain item, pairing store or Bridge data was created, reset or modified."
        )
    }
}
