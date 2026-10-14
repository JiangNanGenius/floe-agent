// FloeExecution — transactional, verified Linux boot-asset (firmware +
// kernel pair) updates for an installed guest image.
//
// The modern pair (OpenSBI fw_jump + the 6.18.56 Image) ships to the App
// as a generated, gitignored bundled resource pinned by a small public
// manifest (hashes/bytes/license/source URLs only). This service installs
// that verified pair onto an ALREADY installed image without touching the
// base disk, the rootfs, the shipped default (4.15) pair, or the trusted
// manifest itself:
//
//  1. CLOSED BY DEFAULT. An update is offered only when the image is
//     installed; the staged bundle bytes match the tracked manifest
//     (size + sha256); the bundle version strictly NEWER-orders above the
//     adopted pair (unparseable/equal/older is refused); every environment
//     of the image can be enumerated; and every environment is quietly
//     stopped per LinuxGuestStoppedReconciliation. Enumeration failure and
//     a missing reconciliation snapshot are NEVER treated as quiet.
//  2. MUTUAL EXCLUSION, NOT SNAPSHOTS. The quiet probe is re-taken inside a
//     LinuxGuestBootAssetGate exclusive pass that blocks guest starts for
//     this image from before boot-path resolution until the session is
//     registered, so no start can interleave with the commit and the
//     environment set is re-enumerated fresh inside the pass (an
//     environment created mid-update simply takes its lease after the
//     commit and boots the new pair consistently).
//  3. ONE ATOMIC COMMIT POINT. Adopted bytes live in an immutable,
//     content-addressed directory (`boot-assets.d/<version>-<hash>/`); the
//     `boot-assets.json` sidecar is the single switch that selects a pair
//     and is written atomically (temp + rename) after every file it
//     references is fully in place. There is no multi-file in-place update
//     to recover from. Staging directories are removed on every exit path.
//  4. INSTALLED-NEWER WINS. LinuxGuestRuntimeImagePreparer resolves boot
//     paths as: adopted sidecar whose files still verify -> its immutable
//     directory; anything else -> the manifest default pair.
//
// Rollback re-verifies the manifest default pair against the manifest's
// own SHA-512 artifact records and then flips the sidecar back — the
// adopted immutable directory stays on disk so re-adoption is instant.

import Foundation
import FloeCore

/// One verified boot pair: SBI firmware plus kernel image, with the public
/// identity of its bytes. `version` orders precedence (a bundle must
/// strictly outrank an adopted pair to be offered).
public struct LinuxGuestBootAssetPair: Sendable, Equatable, Codable {
    public var label: String
    public var version: String
    public var firmwareFileName: String
    public var kernelFileName: String
    public var firmwareSHA256: String
    public var kernelSHA256: String
    public var firmwareBytes: Int64
    public var kernelBytes: Int64

    public init(
        label: String,
        version: String,
        firmwareFileName: String,
        kernelFileName: String,
        firmwareSHA256: String,
        kernelSHA256: String,
        firmwareBytes: Int64,
        kernelBytes: Int64
    ) {
        self.label = label
        self.version = version
        self.firmwareFileName = firmwareFileName
        self.kernelFileName = kernelFileName
        self.firmwareSHA256 = firmwareSHA256
        self.kernelSHA256 = kernelSHA256
        self.firmwareBytes = firmwareBytes
        self.kernelBytes = kernelBytes
    }
}

/// The tracked public bundle manifest (no private paths, no credentials).
public struct LinuxGuestBootAssetBundle: Sendable, Equatable, Codable {
    /// Schema version; only 1 is understood.
    public var schema: Int
    public var pair: LinuxGuestBootAssetPair
    /// Public source references (kernel.org tarball URL, OpenSBI release)
    /// and license names for the provenance UI.
    public var sourceReferences: [String]
    public var licenses: [String]

    public static let currentSchema = 1

    public init(
        schema: Int = LinuxGuestBootAssetBundle.currentSchema,
        pair: LinuxGuestBootAssetPair,
        sourceReferences: [String] = [],
        licenses: [String] = []
    ) {
        self.schema = schema
        self.pair = pair
        self.sourceReferences = sourceReferences
        self.licenses = licenses
    }
}

/// Persisted per-image adoption record (sidecar `boot-assets.json`).
public struct LinuxGuestBootAssetSidecar: Sendable, Equatable, Codable {
    public enum State: String, Sendable, Codable {
        /// The pair is installed and selected for future boots.
        case adopted
        /// Explicitly rolled back; the manifest default pair governs.
        case rolledBack
        /// A previous selection failed verification; the default pair
        /// governs and the reason is recorded for the UI/derivation.
        case failed
    }

    public var state: State
    public var pair: LinuxGuestBootAssetPair
    /// Immutable, content-addressed directory (relative to the image
    /// directory) holding the adopted bytes. Never mutated in place.
    public var storageDirectory: String
    /// Manifest-declared default pair captured at install time; rollback
    /// restores resolution to these paths (the files are never moved).
    public var defaultBiosPath: String
    public var defaultKernelPath: String?
    public var installedAt: Date
    public var failureReason: String?

    public init(
        state: State,
        pair: LinuxGuestBootAssetPair,
        storageDirectory: String,
        defaultBiosPath: String,
        defaultKernelPath: String?,
        installedAt: Date,
        failureReason: String? = nil
    ) {
        self.state = state
        self.pair = pair
        self.storageDirectory = storageDirectory
        self.defaultBiosPath = defaultBiosPath
        self.defaultKernelPath = defaultKernelPath
        self.installedAt = installedAt
        self.failureReason = failureReason
    }
}

/// Derived, user-presentable state for one installed image.
public enum LinuxGuestBootAssetState: Sendable, Equatable {
    /// The image is not installed; nothing can be offered.
    case unavailable
    /// No adoption yet; `bundle` (when present) may be installed.
    case defaultPair(bundle: LinuxGuestBootAssetBundle?)
    /// The newer bundled pair is adopted and governs future boots.
    case updateInstalled(LinuxGuestBootAssetSidecar)
    /// Explicitly rolled back to the default pair.
    case rolledBack(LinuxGuestBootAssetSidecar)
    /// A previous selection failed closed; the default pair governs.
    case installFailed(LinuxGuestBootAssetSidecar)
}

public enum LinuxGuestBootAssetUpdateError: Error, LocalizedError, Sendable, Equatable {
    case imageNotInstalled(id: String)
    case imageBusy(id: String)
    case bundleUnavailable(detail: String)
    case bundleMismatch(detail: String)
    case notOffered(reason: String)
    case environmentsNotQuiet([String])
    case enumerationUnavailable(imageID: String)
    case artifactVerificationFailed(role: String)
    case ioFailure(path: String)

    public var errorDescription: String? {
        switch self {
        case .imageNotInstalled(let id):
            return "Linux image '\(id)' is not installed."
        case .imageBusy(let id):
            return "Another boot-asset operation is in progress for '\(id)'; try again shortly."
        case .bundleUnavailable(let detail):
            return "Boot-asset bundle is unavailable: \(detail)"
        case .bundleMismatch(let detail):
            return "Boot-asset bundle failed closed verification: \(detail)"
        case .notOffered(let reason):
            return "Boot-asset update is not offered: \(reason)"
        case .environmentsNotQuiet(let ids):
            return "Boot assets can only change while every guest using this image is stopped (active: \(ids.joined(separator: ", ")))."
        case .enumerationUnavailable(let imageID):
            return "The environments using Linux image '\(imageID)' could not be enumerated, so the update was refused."
        case .artifactVerificationFailed(let role):
            return "Boot \(role) failed size/hash verification; the previous boot pair is unchanged."
        case .ioFailure(let path):
            return "Boot-asset file operation failed at \(path)."
        }
    }
}

/// Why a boot-pair adoption is being attempted. AUTOMATIC adoption (the
/// App's pre-start hook) must never override an explicit rollback: the
/// user's choice of the manifest default pair sticks until an EXPLICIT
/// reapply. Both origins still refuse to overwrite a newer recorded pair
/// (installed-newer wins), and both remain bound by the same quiet gate and
/// the same exclusive pass as every other adoption/rollback.
public enum LinuxGuestBootAssetAdoptionOrigin: String, Sendable, Equatable, Codable {
    /// Best-effort adoption from the boot path ("adopt a pending verified
    /// update at the next quiet start"): never re-opens an explicit rollback.
    case automatic
    /// Explicit user/UI action: (re)applies the tracked bundle, including
    /// re-adopting the exact pair an earlier explicit rollback selected
    /// away from.
    case explicitReapply
}

/// Installs/rolls back verified boot-asset pairs. Actor-serialized with an
/// explicit per-image in-flight marker so two update operations can never
/// interleave; guest START serialization against the commit comes from the
/// injected LinuxGuestBootAssetGate (the registry holds start leases).
public actor LinuxGuestBootAssetUpdateService {
    /// Quiet-stop probe for one environment. Must reflect the serialized
    /// lifecycle truth. A nil snapshot means "cannot prove quiet" and
    /// refuses the update — never a pass.
    public typealias QuietProbe = @Sendable (_ environmentID: String) async -> LinuxGuestStoppedReconciliation?
    /// Environments bound to one image. nil means enumeration is not
    /// possible and refuses the update — never an implicit "no guests".
    public typealias EnvironmentIDs = @Sendable (_ imageID: String) async -> [String]?

    /// Resolves the image directory the ACTUAL boot of this image will use.
    /// The App wires Runtime v2's expanded (verified, rebuildable) directory
    /// here, because every real start resolves its boot pair against that
    /// directory; the updater must write the sidecar the boot consults, so
    /// it resolves through the same seam. nil answers fall back to the
    /// legacy `<imagesRoot>/<imageID>` directory — the only boot root for
    /// callers with no Runtime v2 substrate (and for module tests).
    public typealias ImageDirectoryResolver = @Sendable (_ imageID: String) async -> URL?

    private let imagesRoot: URL
    private let bundleProvider: @Sendable () -> URL?
    private let quietProbe: QuietProbe?
    private let gate: LinuxGuestBootAssetGate
    private let imageDirectoryResolver: ImageDirectoryResolver?
    private var inFlight: Set<String> = []

    /// Test-only fault seam at the transaction's commit boundary. Never set
    /// in production (internal, default nil): a throwing injector proves the
    /// failure-atomicity contract without weakening any real verification.
    internal enum CommitFaultPoint: String, Sendable {
        case beforeSidecarWrite
    }
    internal var commitFaultInjector: (@Sendable (CommitFaultPoint) throws -> Void)?

    /// Installs (or clears) the test-only commit fault injector.
    internal func setCommitFaultInjector(
        _ injector: (@Sendable (CommitFaultPoint) throws -> Void)?
    ) {
        commitFaultInjector = injector
    }

    public init(
        imagesRoot: URL,
        bundleProvider: @escaping @Sendable () -> URL? = { nil },
        quietProbe: QuietProbe? = nil,
        gate: LinuxGuestBootAssetGate = .default,
        imageDirectoryResolver: ImageDirectoryResolver? = nil
    ) {
        self.imagesRoot = imagesRoot
        self.bundleProvider = bundleProvider
        self.quietProbe = quietProbe
        self.gate = gate
        self.imageDirectoryResolver = imageDirectoryResolver
    }

    /// The image directory the boot resolves for this image: the injected
    /// resolver's answer when it yields one (Runtime v2's expanded image in
    /// the App), else the legacy `<imagesRoot>/<id>`. Reads and writes MUST
    /// use the same resolution, or an adopted pair lands somewhere the boot
    /// never looks — which is exactly the "adopted but still boots the
    /// manifest default" state this seam exists to prevent.
    private func imageDirectory(id: String) async -> URL {
        if let imageDirectoryResolver,
           let resolved = await imageDirectoryResolver(id) {
            return resolved
        }
        return imagesRoot.appendingPathComponent(id, isDirectory: true)
    }

    // MARK: - Read side

    public func state(imageID: String) async -> LinuxGuestBootAssetState {
        let dir = await imageDirectory(id: imageID)
        guard FileManager.default.fileExists(atPath: dir.appendingPathComponent("manifest.json").path) else {
            return .unavailable
        }
        guard let sidecar = try? Self.loadSidecar(imageDirectory: dir) else {
            return .defaultPair(bundle: try? loadBundle().bundle)
        }
        switch sidecar.state {
        case .adopted:
            // An adopted sidecar whose files no longer verify is failed
            // closed at read time: the default pair governs and the UI can
            // show the reason instead of silently booting stale bytes.
            if let failure = Self.verificationFailure(of: sidecar, imageDirectory: dir) {
                var failed = sidecar
                failed.state = .failed
                failed.failureReason = failure
                return .installFailed(failed)
            }
            return .updateInstalled(sidecar)
        case .rolledBack:
            return .rolledBack(sidecar)
        case .failed:
            return .installFailed(sidecar)
        }
    }

    // MARK: - Install

    /// Verify + install the bundled pair. Throws without touching any file
    /// when an offer precondition does not hold.
    ///
    /// `origin` selects the AUTOMATIC pre-start policy or an EXPLICIT user
    /// reapply (see `LinuxGuestBootAssetAdoptionOrigin`); both remain bound by
    /// the service's configured quiet probe and the shared exclusive gate.
    @discardableResult
    public func installUpdate(
        imageID: String,
        environmentIDs: @escaping EnvironmentIDs,
        origin: LinuxGuestBootAssetAdoptionOrigin = .explicitReapply
    ) async throws -> LinuxGuestBootAssetState {
        let dir = await imageDirectory(id: imageID)
        guard FileManager.default.fileExists(atPath: dir.appendingPathComponent("manifest.json").path) else {
            throw LinuxGuestBootAssetUpdateError.imageNotInstalled(id: imageID)
        }
        guard !inFlight.contains(imageID) else {
            throw LinuxGuestBootAssetUpdateError.imageBusy(id: imageID)
        }
        inFlight.insert(imageID)
        defer { inFlight.remove(imageID) }

        let loaded = try loadBundle()
        let bundle = loaded.bundle
        let manifest = try loadManifest(imageDirectory: dir)
        try Self.validate(pair: bundle.pair, manifest: manifest)
        let probe = quietProbe
        let faultInjector = commitFaultInjector

        // Fail-fast precedence check. The AUTHORITATIVE check runs inside the
        // exclusive pass against fresh state (a different service instance
        // may have committed while this call was queued), so this read is
        // only a guard that avoids waiting for a gate turn it would lose.
        if let satisfied = try Self.installDecision(
            bundle: bundle.pair,
            current: try Self.loadSidecar(imageDirectory: dir),
            origin: origin,
            imageDirectory: dir
        ) {
            return satisfied
        }

        // Pre-pass quiet check (fails fast); the authoritative check runs
        // inside the exclusive pass with fresh enumeration + snapshots.
        try await assertAllQuiet(imageID: imageID, environmentIDs: environmentIDs, probe: probe)

        let storageName = Self.storageDirectoryName(for: bundle.pair)
        let storageDir = dir.appendingPathComponent(storageName, isDirectory: true)

        return try await gate.performExclusive(imageID: imageID) {
            // Authoritative: re-enumerate (covers environments created
            // since the pre-check) and re-prove quiet inside the pass.
            try await self.assertAllQuiet(imageID: imageID, environmentIDs: environmentIDs, probe: probe)

            // Version/state preconditions are re-proved against FRESH state
            // inside the pass, immediately after the previous pass (if any)
            // committed: an older service instance that passed its pre-check
            // before this pass was queued must NOT overwrite the newer pair
            // the earlier pass installed.
            if let satisfied = try Self.installDecision(
                bundle: bundle.pair,
                current: try Self.loadSidecar(imageDirectory: dir),
                origin: origin,
                imageDirectory: dir
            ) {
                return satisfied
            }

            let staging = dir.appendingPathComponent(".boot-assets-staging-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: staging) }
            do {
                try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
                let bundleDir = loaded.url.deletingLastPathComponent()
                try Self.copyVerified(
                    from: bundleDir.appendingPathComponent(bundle.pair.firmwareFileName),
                    to: staging.appendingPathComponent(bundle.pair.firmwareFileName),
                    role: "firmware",
                    expectedBytes: bundle.pair.firmwareBytes,
                    expectedSHA256: bundle.pair.firmwareSHA256
                )
                try Self.copyVerified(
                    from: bundleDir.appendingPathComponent(bundle.pair.kernelFileName),
                    to: staging.appendingPathComponent(bundle.pair.kernelFileName),
                    role: "kernel",
                    expectedBytes: bundle.pair.kernelBytes,
                    expectedSHA256: bundle.pair.kernelSHA256
                )
            }

            // Promote the immutable storage directory (verifying any
            // preexisting bytes at the same content address) and land the
            // single atomic commit point (the sidecar). Failure atomicity:
            // only bytes THIS pass created may be removed on failure; a
            // preexisting payload is restored untouched and the old sidecar
            // record stays exactly as it was.
            var storageOwnedByThisPass = false
            var quarantined: URL?
            do {
                if FileManager.default.fileExists(atPath: storageDir.path) {
                    switch Self.storageIntegrity(storageDir, pair: bundle.pair) {
                    case true:
                        // Verified reuse: the immutable directory already
                        // holds exactly this pair (both files); the staged
                        // copy is dropped by the defer above.
                        break
                    case false:
                        // Proven different bytes at the same content
                        // address (an earlier interrupted promotion): move
                        // them aside — never delete — and install the
                        // freshly verified copy.
                        let quarantine = dir.appendingPathComponent(
                            ".boot-assets-quarantine-\(UUID().uuidString)", isDirectory: true
                        )
                        try FileManager.default.moveItem(at: storageDir, to: quarantine)
                        quarantined = quarantine
                        try FileManager.default.moveItem(at: staging, to: storageDir)
                        storageOwnedByThisPass = true
                    case nil:
                        // Missing/unreadable/unprovable bytes: refuse
                        // instead of guessing; nothing is touched.
                        throw LinuxGuestBootAssetUpdateError.artifactVerificationFailed(
                            role: "existing boot-asset storage"
                        )
                    }
                } else {
                    try FileManager.default.createDirectory(
                        at: storageDir.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    try FileManager.default.moveItem(at: staging, to: storageDir)
                    storageOwnedByThisPass = true
                }
                // Re-verify the promoted bytes BEFORE the commit: a corrupt
                // payload must never be advertised as adopted.
                if let failure = Self.storageVerificationFailure(storageDir, pair: bundle.pair) {
                    throw LinuxGuestBootAssetUpdateError.artifactVerificationFailed(role: failure)
                }
                // Final authoritative precondition recheck immediately
                // before the commit point.
                try Self.assertInstallAllowed(
                    bundle: bundle.pair,
                    current: try Self.loadSidecar(imageDirectory: dir),
                    origin: origin
                )
                if let faultInjector {
                    try faultInjector(.beforeSidecarWrite)
                }
                Self.syncDirectory(dir)
                let sidecar = LinuxGuestBootAssetSidecar(
                    state: .adopted,
                    pair: bundle.pair,
                    storageDirectory: storageName,
                    defaultBiosPath: manifest.biosPath,
                    defaultKernelPath: manifest.kernelPath,
                    installedAt: Date()
                )
                try Self.saveSidecar(sidecar, imageDirectory: dir)
                if let quarantined {
                    // Success: the canonical directory now holds freshly
                    // verified bytes for this exact pair; the quarantined
                    // copy is no longer needed.
                    try? FileManager.default.removeItem(at: quarantined)
                }
                FloeLogger(category: .tools).info(
                    "Linux boot assets adopted image=\(imageID) version=\(bundle.pair.version) label=\(bundle.pair.label) origin=\(origin.rawValue)"
                )
                return .updateInstalled(sidecar)
            } catch {
                if storageOwnedByThisPass {
                    try? FileManager.default.removeItem(at: storageDir)
                }
                if let quarantined {
                    try? FileManager.default.moveItem(at: quarantined, to: storageDir)
                }
                if let typed = error as? LinuxGuestBootAssetUpdateError { throw typed }
                throw LinuxGuestBootAssetUpdateError.ioFailure(path: storageDir.path)
            }
        }
    }

    // MARK: - Rollback

    /// Restore the manifest default pair for future boots. The adopted
    /// immutable directory stays on disk (recovery is instant); the
    /// sidecar is the only write, after the default pair re-verifies
    /// against the manifest's own SHA-512 artifact records.
    @discardableResult
    public func rollback(
        imageID: String,
        environmentIDs: @escaping EnvironmentIDs
    ) async throws -> LinuxGuestBootAssetState {
        let dir = await imageDirectory(id: imageID)
        guard FileManager.default.fileExists(atPath: dir.appendingPathComponent("manifest.json").path) else {
            throw LinuxGuestBootAssetUpdateError.imageNotInstalled(id: imageID)
        }
        guard !inFlight.contains(imageID) else {
            throw LinuxGuestBootAssetUpdateError.imageBusy(id: imageID)
        }
        inFlight.insert(imageID)
        defer { inFlight.remove(imageID) }

        guard try Self.loadSidecar(imageDirectory: dir) != nil else {
            throw LinuxGuestBootAssetUpdateError.notOffered(reason: "no boot-asset update is installed")
        }
        let probe = quietProbe

        try await assertAllQuiet(imageID: imageID, environmentIDs: environmentIDs, probe: probe)
        let manifest = try loadManifest(imageDirectory: dir)

        let updated = try await gate.performExclusive(imageID: imageID) {
            try await self.assertAllQuiet(imageID: imageID, environmentIDs: environmentIDs, probe: probe)
            // Fresh state inside the pass: an explicit reapply that committed
            // earlier in this image's queue is exactly what this rollback
            // marks rolled back (never a stale capture).
            guard var current = try Self.loadSidecar(imageDirectory: dir) else {
                throw LinuxGuestBootAssetUpdateError.notOffered(reason: "no boot-asset update is installed")
            }
            if current.state == .rolledBack {
                // Idempotent: already rolled back; nothing to write.
                return current
            }
            // The default pair must still match the manifest's artifact
            // records before we claim rollback (existence alone is not
            // verification).
            guard Self.manifestArtifactIntegrity(manifest.biosPath, manifest: manifest, imageDirectory: dir) else {
                throw LinuxGuestBootAssetUpdateError.artifactVerificationFailed(role: "default bios")
            }
            if let kernelPath = manifest.kernelPath,
               !Self.manifestArtifactIntegrity(kernelPath, manifest: manifest, imageDirectory: dir) {
                throw LinuxGuestBootAssetUpdateError.artifactVerificationFailed(role: "default kernel")
            }
            current.state = .rolledBack
            current.failureReason = nil
            try Self.saveSidecar(current, imageDirectory: dir)
            return current
        }
        FloeLogger(category: .tools).info("Linux boot assets rolled back image=\(imageID)")
        return .rolledBack(updated)
    }

    // MARK: - Boot-path resolution (used by LinuxGuestRuntimeImagePreparer)

    /// The boot pair a start should use: a verified adopted sidecar wins
    /// over the manifest default (installed-newer precedence); everything
    /// else resolves to the manifest pair.
    public static func resolvedBootPaths(
        manifest: LinuxGuestImage,
        imageDirectory: URL
    ) -> (biosPath: String, kernelPath: String?) {
        if let sidecar = try? loadSidecar(imageDirectory: imageDirectory),
           sidecar.state == .adopted,
           verificationFailure(of: sidecar, imageDirectory: imageDirectory) == nil {
            let storage = imageDirectory.appendingPathComponent(sidecar.storageDirectory, isDirectory: true)
            return (
                storage.appendingPathComponent(sidecar.pair.firmwareFileName).path,
                storage.appendingPathComponent(sidecar.pair.kernelFileName).path
            )
        }
        return (manifest.biosPath, manifest.kernelPath)
    }

    // MARK: - internals

    private struct LoadedBundle {
        var bundle: LinuxGuestBootAssetBundle
        var url: URL
    }

    private func loadBundle() throws -> LoadedBundle {
        guard let url = bundleProvider() else {
            throw LinuxGuestBootAssetUpdateError.bundleUnavailable(
                detail: "no bundle URL was provided by the app"
            )
        }
        let manifestURL = url.appendingPathComponent("boot-pair-v2.manifest.json")
        guard let data = try? Data(contentsOf: manifestURL) else {
            throw LinuxGuestBootAssetUpdateError.bundleUnavailable(
                detail: "manifest missing at \(manifestURL.lastPathComponent)"
            )
        }
        guard let bundle = try? JSONDecoder().decode(LinuxGuestBootAssetBundle.self, from: data),
              bundle.schema == LinuxGuestBootAssetBundle.currentSchema else {
            throw LinuxGuestBootAssetUpdateError.bundleUnavailable(detail: "manifest is undecodable or unsupported")
        }
        return LoadedBundle(bundle: bundle, url: manifestURL)
    }

    private func loadManifest(imageDirectory: URL) throws -> LinuxGuestImage {
        let url = imageDirectory.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: url),
              let image = try? JSONDecoder().decode(LinuxGuestImage.self, from: data) else {
            throw LinuxGuestBootAssetUpdateError.ioFailure(path: url.path)
        }
        return image
    }

    static func sidecarURL(imageDirectory: URL) -> URL {
        imageDirectory.appendingPathComponent("boot-assets.json")
    }

    /// Content-addressed storage identity: version + BOTH file hashes.
    /// Hashing only the kernel would alias two pairs that share a kernel but
    /// ship different firmware (or vice versa) onto one directory.
    static func storageDirectoryName(for pair: LinuxGuestBootAssetPair) -> String {
        let kernel = String(pair.kernelSHA256.prefix(12))
        let firmware = String(pair.firmwareSHA256.prefix(12))
        return "boot-assets.d/\(pair.version)-\(kernel)-\(firmware)"
    }

    static func loadSidecar(imageDirectory: URL) throws -> LinuxGuestBootAssetSidecar? {
        let url = sidecarURL(imageDirectory: imageDirectory)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let data = try? Data(contentsOf: url),
              let sidecar = try? JSONDecoder().decode(LinuxGuestBootAssetSidecar.self, from: data) else {
            throw LinuxGuestBootAssetUpdateError.ioFailure(path: url.path)
        }
        return sidecar
    }

    static func saveSidecar(_ sidecar: LinuxGuestBootAssetSidecar, imageDirectory: URL) throws {
        let url = sidecarURL(imageDirectory: imageDirectory)
        do {
            // Atomic write replaces any previous sidecar as one unit: the
            // sidecar is the single commit point of a transaction.
            try JSONEncoder().encode(sidecar).write(to: url, options: .atomic)
            syncDirectory(imageDirectory)
        } catch {
            throw LinuxGuestBootAssetUpdateError.ioFailure(path: url.path)
        }
    }

    /// Pair file names must be plain components that cannot collide with
    /// the manifest default pair or the manifest/sidecar themselves, and
    /// must not escape the image directory.
    static func validate(pair: LinuxGuestBootAssetPair, manifest: LinuxGuestImage) throws {
        func check(_ name: String, role: String) throws {
            guard !name.isEmpty,
                  name != ".", name != "..",
                  !name.contains("/"),
                  name != "manifest.json",
                  name != "boot-assets.json",
                  !name.hasPrefix("boot-assets.d")
            else {
                throw LinuxGuestBootAssetUpdateError.bundleMismatch(detail: "\(role) file name is unsafe: \(name)")
            }
        }
        try check(pair.firmwareFileName, role: "firmware")
        try check(pair.kernelFileName, role: "kernel")
        guard pair.firmwareFileName != manifest.biosPath,
              pair.kernelFileName != manifest.kernelPath else {
            throw LinuxGuestBootAssetUpdateError.bundleMismatch(
                detail: "bundle file names must not collide with the manifest default pair"
            )
        }
    }

    /// Strict dotted-numeric compare; ANY unparseable component refuses
    /// the update (never a speculative string fallback that could
    /// downgrade). nil means "cannot order at all".
    static func compareVersions(_ candidate: String, _ installed: String) -> Int? {
        func parts(_ v: String) -> [Int]? {
            let comps = v.split(separator: ".", omittingEmptySubsequences: false)
            guard !comps.isEmpty else { return nil }
            var out: [Int] = []
            for comp in comps {
                guard let n = Int(comp), n >= 0 else { return nil }
                out.append(n)
            }
            return out
        }
        guard let a = parts(candidate), let b = parts(installed) else { return nil }
        let n = max(a.count, b.count)
        let aa = a + repeatElement(0, count: n - a.count)
        let bb = b + repeatElement(0, count: n - b.count)
        for i in 0..<n where aa[i] != bb[i] {
            return aa[i] < bb[i] ? -1 : 1
        }
        return 0
    }

    static func isVersion(_ candidate: String, newerThan installed: String) -> Bool {
        (compareVersions(candidate, installed) ?? 0) > 0
    }

    /// Equality under the same strict parse: an unparseable pair is NEVER
    /// "the same version" (it must not unlock a refused install path).
    static func isVersion(_ candidate: String, sameAs installed: String) -> Bool {
        compareVersions(candidate, installed) == 0
    }

    /// The AUTOMATIC/EXPLICIT offer policy, evaluated against a specific
    /// (possibly fresh) sidecar record. Throws `notOffered` when the bundle
    /// must not be applied; returns a satisfied state when the requested
    /// origin is already met (an explicit reapply of a verified adopted pair
    /// is an idempotent success); nil means "proceed with the install".
    ///
    ///  - automatic: never overrides a `.rolledBack` record (an explicit
    ///    user choice stays until an explicit reapply) and requires strictly
    ///    newer than any recorded pair.
    ///  - explicit: an older bundle never overwrites a newer
    ///    installed/rolled-back marker; the same version is re-appliable
    ///    over a rollback/failure record, and an adopted record whose bytes
    ///    no longer verify is REPAIRED (assertInstallAllowed passes; the
    ///    promote step replaces the proven-corrupt storage).
    static func installDecision(
        bundle: LinuxGuestBootAssetPair,
        current: LinuxGuestBootAssetSidecar?,
        origin: LinuxGuestBootAssetAdoptionOrigin,
        imageDirectory: URL
    ) throws -> LinuxGuestBootAssetState? {
        try assertInstallAllowed(bundle: bundle, current: current, origin: origin)
        guard let current,
              current.state == .adopted,
              isVersion(bundle.version, sameAs: current.pair.version),
              verificationFailure(of: current, imageDirectory: imageDirectory) == nil else {
            return nil
        }
        return .updateInstalled(current)
    }

    /// The refusal half of `installDecision`; also the final authoritative
    /// recheck immediately before the commit point. `bundle` must be
    /// strictly newer than any recorded pair except for an explicit reapply
    /// of an equal version, which a rollback/failure record permits.
    static func assertInstallAllowed(
        bundle: LinuxGuestBootAssetPair,
        current: LinuxGuestBootAssetSidecar?,
        origin: LinuxGuestBootAssetAdoptionOrigin
    ) throws {
        guard let current else { return }
        switch origin {
        case .automatic where current.state == .rolledBack:
            throw LinuxGuestBootAssetUpdateError.notOffered(
                reason: "\(current.pair.version) was explicitly rolled back; it stays until an explicit reapply"
            )
        case .automatic:
            guard isVersion(bundle.version, newerThan: current.pair.version) else {
                throw LinuxGuestBootAssetUpdateError.notOffered(
                    reason: "recorded \(current.state.rawValue) \(current.pair.version) is not older than bundled \(bundle.version)"
                )
            }
        case .explicitReapply:
            guard isVersion(bundle.version, newerThan: current.pair.version)
                    || isVersion(bundle.version, sameAs: current.pair.version) else {
                throw LinuxGuestBootAssetUpdateError.notOffered(
                    reason: "recorded \(current.state.rawValue) \(current.pair.version) is newer than bundled \(bundle.version)"
                )
            }
        }
    }

    private func assertAllQuiet(
        imageID: String,
        environmentIDs: @escaping EnvironmentIDs,
        probe: QuietProbe?
    ) async throws {
        guard let probe else {
            // No probe supplied: we cannot prove quiet, so refuse.
            throw LinuxGuestBootAssetUpdateError.environmentsNotQuiet(["<no-probe>"])
        }
        guard let ids = await environmentIDs(imageID) else {
            throw LinuxGuestBootAssetUpdateError.enumerationUnavailable(imageID: imageID)
        }
        var active: [String] = []
        for id in ids {
            guard let reconciliation = await probe(id) else {
                // A missing snapshot proves nothing; fail closed.
                active.append(id)
                continue
            }
            if !reconciliation.isQuietlyStopped {
                active.append(id)
            }
        }
        if !active.isEmpty {
            throw LinuxGuestBootAssetUpdateError.environmentsNotQuiet(active)
        }
    }

    /// A failure reason when the sidecar's pair does NOT verify; nil when
    /// it does (or the sidecar carries no selection).
    static func verificationFailure(
        of sidecar: LinuxGuestBootAssetSidecar,
        imageDirectory: URL
    ) -> String? {
        guard sidecar.state == .adopted else { return nil }
        let storage = imageDirectory.appendingPathComponent(sidecar.storageDirectory, isDirectory: true)
        return storageVerificationFailure(storage, pair: sidecar.pair)
    }

    /// nil = missing/unreadable/not-a-regular-file; true = BOTH files match
    /// the pair's sizes+hashes; false = proven different bytes.
    static func storageIntegrity(
        _ storageDirectory: URL,
        pair: LinuxGuestBootAssetPair
    ) -> Bool? {
        let firmware = artifactIntegrity(
            storageDirectory.appendingPathComponent(pair.firmwareFileName),
            expectedBytes: pair.firmwareBytes,
            expectedSHA256: pair.firmwareSHA256
        )
        let kernel = artifactIntegrity(
            storageDirectory.appendingPathComponent(pair.kernelFileName),
            expectedBytes: pair.kernelBytes,
            expectedSHA256: pair.kernelSHA256
        )
        guard let firmware, let kernel else { return nil }
        return firmware && kernel
    }

    /// Human reason when the storage directory does not verify; nil when it
    /// verifies. A nil (unprovable) result keeps the reason explicit so no
    /// caller can read it as success.
    static func storageVerificationFailure(
        _ storageDirectory: URL,
        pair: LinuxGuestBootAssetPair
    ) -> String? {
        switch storageIntegrity(storageDirectory, pair: pair) {
        case true: return nil
        case false: return "stored boot pair failed size/hash verification"
        case nil: return "stored boot pair is missing or unreadable"
        }
    }

    /// nil = missing/unreadable/not-a-regular-file/outside-dir; true =
    /// size+hash match; false = mismatch.
    static func artifactIntegrity(
        _ url: URL,
        expectedBytes: Int64,
        expectedSHA256: String
    ) -> Bool? {
        let base = url.deletingLastPathComponent().standardizedFileURL
        let resolved = url.standardizedFileURL
        guard resolved.path.hasPrefix(base.path + "/") || resolved.path == base.path else { return nil }
        guard let values = try? resolved.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true, values.isSymbolicLink != true else { return nil }
        guard let data = try? Data(contentsOf: resolved, options: [.mappedIfSafe]) else { return nil }
        guard Int64(data.count) == expectedBytes else { return false }
        let actual = FloeDigest.sha256Hex(data)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return actual == expectedSHA256.lowercased()
    }

    /// Default-pair check against the manifest's own SHA-512 artifact
    /// record: existence alone is never verification.
    static func manifestArtifactIntegrity(
        _ path: String,
        manifest: LinuxGuestImage,
        imageDirectory: URL
    ) -> Bool {
        guard let artifact = manifest.artifacts?.first(where: { $0.path == path }) else {
            // A manifest without digest records for the default pair can
            // never be proven intact; refuse rather than guess.
            return false
        }
        let url = imageDirectory.appendingPathComponent(path).standardizedFileURL
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true, values.isSymbolicLink != true else { return false }
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else { return false }
        guard Int64(data.count) == artifact.bytes else { return false }
        let expected = artifact.sha512.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return FloeDigest.sha512Hex(data) == expected
    }

    static func copyVerified(
        from source: URL,
        to destination: URL,
        role: String,
        expectedBytes: Int64,
        expectedSHA256: String
    ) throws {
        guard let values = try? source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true, values.isSymbolicLink != true else {
            throw LinuxGuestBootAssetUpdateError.artifactVerificationFailed(role: role)
        }
        guard let data = try? Data(contentsOf: source, options: [.mappedIfSafe]) else {
            throw LinuxGuestBootAssetUpdateError.artifactVerificationFailed(role: role)
        }
        guard Int64(data.count) == expectedBytes else {
            throw LinuxGuestBootAssetUpdateError.artifactVerificationFailed(role: role)
        }
        let actual = FloeDigest.sha256Hex(data)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard actual == expectedSHA256.lowercased() else {
            throw LinuxGuestBootAssetUpdateError.artifactVerificationFailed(role: role)
        }
        do {
            try data.write(to: destination, options: .atomic)
        } catch {
            throw LinuxGuestBootAssetUpdateError.ioFailure(path: destination.path)
        }
    }

    static func syncDirectory(_ url: URL) {
        // Best-effort directory fsync; failures here do not change
        // correctness (rename and atomic writes are already atomic).
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        try? handle.synchronize()
        try? handle.close()
    }
}
