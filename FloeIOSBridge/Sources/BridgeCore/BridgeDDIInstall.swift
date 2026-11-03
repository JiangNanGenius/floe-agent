import Foundation

/// Which on-device DDI install path this OS needs.
///
/// iOS 26.4 and later install the DDI as a cryptex through cryptexd; earlier
/// releases use the personalized image mounter. The two paths need different
/// files, so keeping the choice in one place prevents mixing a cryptex set with
/// an image-mounter call.
public enum BridgeDDIInstallMethod: String, Codable, Sendable, CaseIterable {
    case personalized
    case cryptex

    public static func forOperatingSystem(_ version: OperatingSystemVersion) -> BridgeDDIInstallMethod {
        if version.majorVersion > 26 { return .cryptex }
        if version.majorVersion == 26 && version.minorVersion >= 4 { return .cryptex }
        return .personalized
    }

    public static var current: BridgeDDIInstallMethod {
        forOperatingSystem(ProcessInfo.processInfo.operatingSystemVersion)
    }

    public var mirrorFolder: String {
        switch self {
        case .personalized: return "Xcode_iOS_DDI_Personalized"
        case .cryptex: return "Xcode_iOS_DDI_Cryptex"
        }
    }

    public var components: [BridgeDDIComponent] {
        switch self {
        case .personalized:
            return [.buildManifest, .image, .trustCache]
        case .cryptex:
            return [.buildManifest, .image, .trustCache, .cryptexInfo, .rootHash]
        }
    }
}

public enum BridgeDDIComponent: String, Codable, Sendable, CaseIterable {
    case buildManifest = "BuildManifest.plist"
    case image = "Image.dmg"
    case trustCache = "Image.dmg.trustcache"
    case cryptexInfo = "Image.dmg.cryptex_info"
    case rootHash = "Image.dmg.root_hash"

    public var maximumBytes: Int64 {
        switch self {
        case .buildManifest: return 4 * 1024 * 1024
        case .image: return 768 * 1024 * 1024
        case .trustCache: return 16 * 1024 * 1024
        case .cryptexInfo: return 4 * 1024 * 1024
        case .rootHash: return 64 * 1024
        }
    }

    public var minimumBytes: Int64 {
        switch self {
        case .buildManifest: return 64
        case .image: return 1 * 1024 * 1024
        case .trustCache: return 16
        case .cryptexInfo: return 16
        case .rootHash: return 16
        }
    }

    /// Only BuildManifest has a meaningful minimum before its plist is parsed.
    public var isPlist: Bool { self == .buildManifest }
}

public enum BridgeDDISource {
    /// Apple does not publish the personalized image for direct download. This
    /// is the same runtime-only mirror used by the pinned upstream, recorded in
    /// provenance with a per-file SHA-256 at download time. The files are never
    /// bundled in the IPA.
    public static let mirrorBase = "https://github.com/doronz88/DeveloperDiskImage/raw/refs/heads/main/PersonalizedImages"

    public static func remoteURL(for component: BridgeDDIComponent,
                                 method: BridgeDDIInstallMethod) -> URL {
        URL(string: "\(mirrorBase)/\(method.mirrorFolder)/\(component.rawValue)")!
    }
}

/// ABI v1 native phase codes contain no device identifiers or payload values.
public enum BridgeDDINativeStage: UInt32, Codable, Sendable, CaseIterable {
    case connecting = 1, queryingServices = 2, loadingAssets = 3
    case personalization = 10, nonce = 11, signing = 12
    case openingInstaller = 13, sendingRequest = 14
    case sendingImage = 20, sendingTrustCache = 21, sendingTicket = 22
    case sendingInfo = 23, sendingRootHash = 24
    case awaitingInstallReply = 30, verifyingRemoteInstall = 31
    case personalizedInstall = 40
}

public enum BridgeDDINativePolicy {
    public static let abiVersion: UInt32 = 1
    public static let defaultTimeoutMilliseconds: UInt64 = 180_000
    /// Persisted before a mutation. A crash or uncertain native result requires
    /// read-only reconciliation before any further install is considered.
    public static let reconciliationMarker = ".floe-ddi-reconciliation-required"
}

/// Service-owned remote mutation state. It deliberately lives outside DDI
/// assets, whose ordinary import/refresh/removal may replace whole directories.
public struct BridgeDDIRecoveryState: Sendable {
    public let directory: URL
    public var markerURL: URL { directory.appendingPathComponent("pending-install") }

    public init(supportDirectory: URL = BridgePaths.supportDirectory) {
        directory = supportDirectory.appendingPathComponent("DDIRecovery", isDirectory: true)
    }

    public func requiresReconciliation() throws -> Bool {
        try exists(markerURL)
    }

    public func markUnresolved() throws {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try BridgeAtomicFile.write(Data("native-ddi-v1\n".utf8), to: markerURL, protection: .complete)
    }

    /// Copy forward before any install decision. Keep the legacy marker too:
    /// only a confirmed resolution may remove either record.
    public func migrateLegacyMarkers(in assetDirectories: [URL]) throws {
        for assets in assetDirectories {
            let legacy = assets.appendingPathComponent(BridgeDDINativePolicy.reconciliationMarker)
            if try exists(legacy) { try markUnresolved() }
        }
    }

    /// Call only after verified remote/local recovery, or when no mutation
    /// entered. Remove legacy markers first; any failure preserves the durable
    /// marker so an I/O failure cannot silently authorize another install.
    public func clearResolvedMarker(legacyDirectories: [URL]) throws {
        for assets in legacyDirectories {
            let legacy = assets.appendingPathComponent(BridgeDDINativePolicy.reconciliationMarker)
            if try exists(legacy) { try FileManager.default.removeItem(at: legacy) }
        }
        if try exists(markerURL) { try FileManager.default.removeItem(at: markerURL) }
    }

    private func exists(_ url: URL) throws -> Bool {
        do {
            _ = try FileManager.default.attributesOfItem(atPath: url.path)
            return true
        } catch let error as NSError {
            if error.domain == NSCocoaErrorDomain &&
                (error.code == NSFileNoSuchFileError || error.code == NSFileReadNoSuchFileError) {
                return false
            }
            // Protected/inaccessible state is unknown, never absence.
            throw error
        }
    }
}
