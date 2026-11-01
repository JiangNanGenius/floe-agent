// SPDX-License-Identifier: MPL-2.0
//
// C02 — Android official-Skill dependency preparation and verified readiness.
//
// This is the ANDROID client/service half of the reviewed
// `references/dependencies.json` channel. It deliberately does not create a
// second installer, registry or execution alias:
//
//   * package bytes and the declaration come from the SAME digest-verified
//     installed snapshot the existing SkillInstallStagingService committed;
//   * only a verified production curated receipt (schemaVersion-3 feed,
//     signed review, approve decision) authorizes automatic provisioning;
//   * requirements are installed with the environment's OWN apt / python3
//     -m pip / npm through the EXISTING `exec.shell` runner (ToolRunnerRegistry
//     + the caller's real ToolContext), never a host interpreter and never an
//     `exec.localService`/language-specific alias;
//   * the caller must supply the real selected task environment, conversation
//     and approval grant; missing binding refuses with guidance and no
//     fallback to the first project, a temp directory or the native host;
//   * long install commands use the ORIGINAL durable BackgroundJobService
//     (`submissionSource: .nativeService`) when composed, and fall back to the
//     bounded foreground shell only when jobs are unavailable. Readback always
//     comes from the guest's own dpkg/pip/npm output; a success string or a
//     cache hit is never accepted as readiness;
//   * receipts are bound to (skill version, content digest, declaration
//     digest, environmentID, target fingerprint, root generation) and are
//     only reused while those facts still match.
//
// Declaration is DATA: imported SKILL.md / dependencies.json never grants a
// tool permission. The existing approval grant and scoped environment write
// layer remain the only authority.
#if canImport(Darwin)
import Darwin
#elseif canImport(Android)
import Android
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import Crypto
import FloeCore
import FloePersistence
import FloeSkills
import FloeTools
import FloeModels
import FloeAndroidJobTools
import FloeAndroidShellTools

// MARK: - Fixed Android client compatibility identity

/// The Android CLIENT compatibility version used by schemaVersion-3 catalog
/// entries and compatibility gates. It is deliberately separate from the
/// native display/OTA prerelease (0.1.0-alpha.NN / code N). The trusted host
/// binds this value through `SkillsHostContextProviding.appVersion()`; this
/// constant is the documented value used by tests and the integration patch,
/// not a second source of truth.
public enum C02AndroidSkillCompatibility {
    public static let version = "0.1.0"
    public static let platform = SkillPlatform.android
}

// MARK: - Curated receipt sidecar (no DB migration)

/// Exact signed artifacts retained beside a committed curated install.
/// The receipt is DERIVED from these artifacts on every load; persisted
/// metadata is never authority.
public struct C02CuratedReceiptEnvelope: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1
    public let schemaVersion: Int
    public let catalogBytes: Data
    public let catalogSignature: Data
    public let reviewBytes: Data
    public let reviewSignature: Data
    /// Immutable publication commit Y. This is provenance only: it is not
    /// signed by the feed and cannot authorize anything by itself.
    public let publicationCommit: String

    public init(schemaVersion: Int = currentSchemaVersion,
                catalogBytes: Data, catalogSignature: Data,
                reviewBytes: Data, reviewSignature: Data,
                publicationCommit: String) {
        self.schemaVersion = schemaVersion
        self.catalogBytes = catalogBytes
        self.catalogSignature = catalogSignature
        self.reviewBytes = reviewBytes
        self.reviewSignature = reviewSignature
        self.publicationCommit = publicationCommit
    }
}

/// App-private sidecar for the ORIGINAL curated receipt. It stores the exact
/// signed catalog/review envelopes and re-verifies them with the compiled
/// production trust on every load. The Codable receipt is derived, never
/// trusted from disk. Reads are no-follow regular-file reads bounded before
/// any bytes are loaded.
public struct C02CuratedReceiptStore: Sendable {
    public static let directoryName = ".curated-receipts"
    /// 4 MiB feed + 256 KiB review + base64/JSON overhead, with margin.
    public static let maximumEnvelopeBytes = 8_388_608
    public static let maximumPointerBytes = 4_096

    private struct Pointer: Codable, Sendable {
        let digest: String
    }

    private let root: URL

    public init(installationRoot: URL) {
        self.root = installationRoot.appendingPathComponent(Self.directoryName, isDirectory: true)
    }

    public static func isSafeSkillID(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 128, let first = value.first,
              first.isLetter || first.isNumber else { return false }
        return value.unicodeScalars.allSatisfy {
            ($0.value >= 97 && $0.value <= 122)
                || ($0.value >= 48 && $0.value <= 57)
                || $0 == "-" || $0 == "_" || $0 == "."
        } && !value.split(separator: "/").isEmpty
    }

    private func skillDirectory(_ skillID: String) -> URL? {
        guard Self.isSafeSkillID(skillID), !skillID.contains("..") else { return nil }
        return root.appendingPathComponent(skillID, isDirectory: true)
    }

    private func digestURL(_ skillID: String, digest: String) -> URL? {
        guard Self.isHexDigest(digest), let directory = skillDirectory(skillID) else { return nil }
        return directory.appendingPathComponent("\(digest.lowercased()).json")
    }

    private func currentURL(_ skillID: String) -> URL? {
        skillDirectory(skillID)?.appendingPathComponent("current.json")
    }

    private static func isHexDigest(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy(\.isHexDigit)
    }

    /// Cheap pointer check used to avoid loading/verifying package bytes for
    /// rows without a curated sidecar.
    public func hasCurrent(skillID: String) -> Bool {
        guard let directory = skillDirectory(skillID),
              Self.realDirectoryNoFollow(root),
              Self.realDirectoryNoFollow(directory),
              let url = currentURL(skillID),
              let data = Self.boundedNoFollowData(url, maximumBytes: Self.maximumPointerBytes),
              let pointer = try? JSONDecoder().decode(Pointer.self, from: data) else {
            return false
        }
        return Self.isHexDigest(pointer.digest)
    }

    public func envelope(skillID: String, contentDigest: String) -> C02CuratedReceiptEnvelope? {
        guard let directory = skillDirectory(skillID),
              Self.realDirectoryNoFollow(root),
              Self.realDirectoryNoFollow(directory),
              let url = digestURL(skillID, digest: contentDigest),
              let data = Self.boundedNoFollowData(url, maximumBytes: Self.maximumEnvelopeBytes),
              let envelope = try? JSONDecoder().decode(C02CuratedReceiptEnvelope.self, from: data),
              envelope.schemaVersion == C02CuratedReceiptEnvelope.currentSchemaVersion else {
            return nil
        }
        return envelope
    }

    public func currentEnvelope(skillID: String) -> C02CuratedReceiptEnvelope? {
        guard let directory = skillDirectory(skillID),
              Self.realDirectoryNoFollow(root),
              Self.realDirectoryNoFollow(directory),
              let url = currentURL(skillID),
              let data = Self.boundedNoFollowData(url, maximumBytes: Self.maximumPointerBytes),
              let pointer = try? JSONDecoder().decode(Pointer.self, from: data),
              Self.isHexDigest(pointer.digest) else {
            return nil
        }
        return envelope(skillID: skillID, contentDigest: pointer.digest)
    }

    @discardableResult
    public func persist(_ envelope: C02CuratedReceiptEnvelope,
                        skillID: String, contentDigest: String) throws -> Bool {
        guard envelope.schemaVersion == C02CuratedReceiptEnvelope.currentSchemaVersion,
              Self.isSafeSkillID(skillID),
              Self.isHexDigest(contentDigest),
              envelope.publicationCommit.count == 40,
              envelope.publicationCommit.allSatisfy(\.isHexDigit),
              !envelope.catalogBytes.isEmpty,
              envelope.catalogBytes.count <= CuratedSkillHub.maximumFeedBytes,
              !envelope.reviewBytes.isEmpty,
              envelope.reviewBytes.count <= SignedContentFeedVerifier.maximumFeedBytes,
              !envelope.catalogSignature.isEmpty,
              envelope.catalogSignature.count <= SignedContentFeedVerifier.maximumSignatureBytes,
              !envelope.reviewSignature.isEmpty,
              envelope.reviewSignature.count <= SignedContentFeedVerifier.maximumSignatureBytes,
              let digestURL = digestURL(skillID, digest: contentDigest),
              let current = currentURL(skillID) else { return false }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(envelope)
        guard data.count <= Self.maximumEnvelopeBytes else { return false }
        let pointerData = try JSONEncoder().encode(Pointer(digest: contentDigest.lowercased()))
        guard pointerData.count <= Self.maximumPointerBytes else { return false }
        let directory = digestURL.deletingLastPathComponent()
        if FileManager.default.fileExists(atPath: root.path),
           !Self.realDirectoryNoFollow(root) { return false }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard Self.realDirectoryNoFollow(root),
              Self.realDirectoryNoFollow(directory) else { return false }
        try data.write(to: digestURL, options: .atomic)
        try pointerData.write(to: current, options: .atomic)
        return true
    }

    /// Re-verifies the exact signed feed, signed review and the ACTUAL
    /// installed package bytes, then derives a receipt. No persisted receipt
    /// field authorizes this result; a changed/absent/unsigned sidecar is nil.
    public func verifiedCurrent(skillID: String, contentDigest: String,
                                packageRoot: URL,
                                manifestOverride: SkillManifest?) -> CuratedSkillHub.Receipt? {
        guard let snapshot = try? SkillContentSnapshot(
            root: packageRoot, expectedDigest: contentDigest,
            manifestOverride: manifestOverride) else { return nil }
        return verifiedCurrent(skillID: skillID, contentDigest: contentDigest,
                               snapshot: snapshot)
    }

    public func verifiedCurrent(skillID: String, contentDigest: String,
                                snapshot: SkillContentSnapshot) -> CuratedSkillHub.Receipt? {
        guard let envelope = currentEnvelope(skillID: skillID),
              envelope.publicationCommit.count == 40,
              envelope.publicationCommit.allSatisfy(\.isHexDigit),
              !envelope.catalogBytes.isEmpty,
              envelope.catalogBytes.count <= CuratedSkillHub.maximumFeedBytes,
              !envelope.reviewBytes.isEmpty,
              envelope.reviewBytes.count <= SignedContentFeedVerifier.maximumFeedBytes,
              !envelope.catalogSignature.isEmpty,
              envelope.catalogSignature.count <= SignedContentFeedVerifier.maximumSignatureBytes,
              !envelope.reviewSignature.isEmpty,
              envelope.reviewSignature.count <= SignedContentFeedVerifier.maximumSignatureBytes,
              let verified = try? CuratedSkillHub.verifiedFeed(
                bytes: envelope.catalogBytes,
                signature: envelope.catalogSignature,
                channel: .android,
                mode: .production),
              verified.feed.feedStatus == .production,
              verified.feed.channel == .android,
              verified.keyID == CuratedSkillHub.productionKeyID,
              let entry = verified.feed.entry(id: skillID),
              entry.package?.contentDigest == contentDigest,
              let binding = entry.package,
              let reviewBinding = entry.review,
              let reviewEnvelope = try? CuratedSkillEnvelope.decode(envelope.reviewSignature),
              reviewBinding.keyID == CuratedSkillHub.productionKeyID,
              reviewEnvelope.keyID == reviewBinding.keyID,
              let record = try? CuratedSkillReviewRecord.decode(bytes: envelope.reviewBytes),
              FloeDigest.sha256Hex(envelope.reviewBytes) == reviewBinding.sha256,
              (try? SignedContentFeedVerifier.verifyEnvelope(
                bytes: envelope.reviewBytes,
                signature: envelope.reviewSignature,
                trustedKeys: CuratedSkillHub.productionTrustedKeys)) != nil,
              snapshot.package.manifest.id == entry.id,
              snapshot.package.manifest.version == entry.version,
              snapshot.package.canonicalSHA256 == contentDigest else {
            return nil
        }
        do {
            try CuratedSkillReviewJoin.verify(
                record: record, against: entry, actual: snapshot.package,
                archiveSHA256: binding.sha256, feedChannel: verified.feed.channel)
        } catch {
            return nil
        }
        return CuratedSkillHub.Receipt(
            receiptSchemaVersion: 1,
            channel: verified.feed.channel,
            feedStatus: verified.feed.feedStatus,
            hubRepository: verified.feed.hubRepository,
            publisher: verified.feed.publisher,
            feedSignatureKeyID: verified.keyID,
            auditedSourceCommit: verified.feed.sourceCommit,
            publicationCommit: envelope.publicationCommit,
            catalogSHA256: verified.catalogSHA256,
            catalogByteCount: verified.byteCount,
            entryID: entry.id,
            entryVersion: entry.version,
            packagePath: binding.path,
            packageSize: binding.size,
            packageSHA256: binding.sha256,
            contentDigest: binding.contentDigest,
            containsScripts: binding.containsScripts,
            reviewPath: reviewBinding.path,
            reviewSHA256: reviewBinding.sha256,
            reviewKeyID: reviewBinding.keyID,
            reviewStage: record.reviewStage,
            reviewDecision: record.decision,
            reviewedAt: record.reviewedAt,
            reviewer: record.reviewer,
            permissionDelta: CuratedSkillPermissionDelta.from(
                actualManifest: snapshot.package.manifest,
                effectiveCapabilities: [],
                effectiveTools: [],
                effectivePythonPackageSpecs: []))
    }

    /// Rollback restores the pointer for the version the journal is putting
    /// back. A missing/unsigned old envelope removes `current` (the row then
    /// honestly has no automatic-provisioning authority until reinstall).
    public func restoreCurrent(skillID: String, contentDigest: String) {
        guard let directory = skillDirectory(skillID),
              Self.realDirectoryNoFollow(root),
              Self.realDirectoryNoFollow(directory),
              let current = currentURL(skillID),
              let digestURL = digestURL(skillID, digest: contentDigest) else { return }
        guard Self.regularFileExistsNoFollow(digestURL) else {
            try? FileManager.default.removeItem(at: current)
            return
        }
        guard let pointerData = try? JSONEncoder().encode(
            Pointer(digest: contentDigest.lowercased())),
              pointerData.count <= Self.maximumPointerBytes else { return }
        try? pointerData.write(to: current, options: .atomic)
    }

    public func remove(skillID: String) {
        guard let directory = skillDirectory(skillID) else { return }
        try? FileManager.default.removeItem(at: directory)
    }

    /// lstat-only directory identity: a symlinked root/skill directory is
    /// rejected before any file is opened through it.
    private static func realDirectoryNoFollow(_ url: URL) -> Bool {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return false }
        return (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR)
    }

    /// No-follow regular-file existence check used before pointer restore.
    private static func regularFileExistsNoFollow(_ url: URL) -> Bool {
        #if canImport(Darwin)
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        #elseif canImport(Android)
        let descriptor = Android.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        #elseif canImport(Glibc)
        let descriptor = Glibc.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        #else
        return false
        #endif
        guard descriptor >= 0 else { return false }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { return false }
        _ = handle
        return (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG)
    }

    /// Opens with O_NOFOLLOW, requires a regular file, checks the size BEFORE
    /// reading, and reads at most the announced bound. A symlink, special
    /// file, oversized file or post-stat growth is rejected.
    private static func boundedNoFollowData(_ url: URL, maximumBytes: Int) -> Data? {
        guard maximumBytes > 0 else { return nil }
        #if canImport(Darwin)
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        #elseif canImport(Android)
        let descriptor = Android.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        #elseif canImport(Glibc)
        let descriptor = Glibc.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        #else
        return nil
        #endif
        guard descriptor >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              info.st_size >= 0,
              Int(info.st_size) <= maximumBytes else { return nil }
        let readData: Data
        do {
            readData = try handle.read(upToCount: maximumBytes) ?? Data()
        } catch {
            return nil
        }
        guard readData.count <= maximumBytes else { return nil }
        let extra: Data
        do {
            extra = try handle.read(upToCount: 1) ?? Data()
        } catch {
            return nil
        }
        guard extra.isEmpty else { return nil }
        return readData
    }
}

// MARK: - Model-safe outcomes

public struct C02DependencyRequirementReceipt: Codable, Sendable, Equatable {
    public let kind: String
    public let name: String
    public let version: String?
    public let required: Bool
    public let verified: Bool
    /// Model-safe readback text (e.g. `dpkg 1:2.2.4+ds-1`,
    /// `pip 2.2.3`, `npm 5.9.3`, `cjk-probe ok`). Never a host path.
    public let evidence: String
    public let deferredReason: String?

    public init(kind: String, name: String, version: String?, required: Bool,
                verified: Bool, evidence: String, deferredReason: String? = nil) {
        self.kind = kind
        self.name = name
        self.version = version
        self.required = required
        self.verified = verified
        self.evidence = evidence
        self.deferredReason = deferredReason
    }
}

public enum C02DependencyPreparationOutcome: Sendable, Equatable {
    /// The installed package carries no reviewed declaration. Ordinary shell
    /// behavior is unchanged and no readiness is claimed.
    case notRequired
    /// Every required resource was verified in the ACTUAL selected task
    /// environment. `annotation` lists optional gaps.
    case ready(annotation: String, requirements: [C02DependencyRequirementReceipt])
    /// A required resource could not be verified/installed. Only this
    /// skill-scoped invocation is refused; ordinary commands are untouched.
    case refused(reason: String, requirements: [C02DependencyRequirementReceipt])
    /// An install job was accepted and is still owned. No foreground replay
    /// and no lease release occur until that exact job settles.
    case pending(reason: String, jobID: UUID, requirements: [C02DependencyRequirementReceipt])
    /// The package is not a verified production curated install. Automatic
    /// provisioning is deliberately unavailable for imports.
    case notOfficial(reason: String)
    /// A declaration schema/newer kind this build does not understand.
    case unsupported(reason: String)
    /// The run/approval/environment binding is missing; no fallback exists.
    case bindingRequired(reason: String)
    /// The selected task Linux engine or its shell runner is unavailable.
    case engineUnavailable(reason: String)
}

// MARK: - Preparation center

/// Parses the shell tool's own structured exit line. A missing/malformed
/// line is `.unknown`; callers must never substitute exit 0.
enum C02JobCompletionProof: Equatable, Sendable {
    case exit(Int)
    case unknown

    static func parse(_ text: String?) -> C02JobCompletionProof {
        guard let text, let range = text.range(of: "exit=") else { return .unknown }
        let digits = text[range.upperBound...].prefix { $0.isNumber }
        guard !digits.isEmpty, let value = Int(digits) else { return .unknown }
        return .exit(value)
    }
}

/// The foreground path must never dispatch after cancellation.
enum C02ForegroundDispatchPolicy {
    static func shouldDispatch(cancelled: Bool) -> Bool { !cancelled }
}

// MARK: - Runtime-component target/supply classification

/// One verified runtime-component plan. It is derived from the strict
/// descriptor inside the already digest-verified installed snapshot and the
/// signed curated receipt's immutable publication commit; nothing here comes
/// from a model payload or a mutable marker.
struct C02RuntimeComponentPlan: Equatable, Sendable {
    let componentID: String
    let componentVersion: String
    let artifactSize: Int
    let artifactSHA256: String
    let artifactURL: String
    /// Guest-owned cache path. The file never lives on the native host: the
    /// selected task Linux downloads, verifies, stores and probes it.
    let guestPath: String
    let contractSHA256: String
    let contractVersion: Int
    let fileName: String
}

/// Precise reason the signed component cannot be prepared in the ACTUAL
/// selected task Linux. These are supply/target/version facts, never a
/// generic "device unsupported" claim and never a fake ready state.
enum C02RuntimeComponentAvailability: Equatable, Sendable {
    case portable(C02RuntimeComponentPlan)
    case targetMismatch(declared: String, actual: String)
    case clientVersionFloor(minimum: String, actual: String)
    case supplyRejected(reason: String)
}

enum C02RuntimeComponentPlanBuilder {
    static func quote(_ value: String) -> String? {
        guard !value.contains("'"), !value.contains("\n"), !value.contains("\r"),
              !value.contains("\0") else { return nil }
        return "'" + value + "'"
    }

    /// Compare the descriptor with the guest-probed target and the Android
    /// client identity. Ordering is deliberate: a different architecture is
    /// reported as a target/supply fact before the app-version floor, so the
    /// current app-local RISC-V engine is never mislabeled as a missing
    /// device capability or a broken cache.
    static func availability(
        descriptor: SkillRuntimeDependencyDescriptor,
        actualOS: String,
        actualArch: String,
        appVersion: String,
        publicationCommit: String
    ) -> C02RuntimeComponentAvailability {
        let declared = "\(descriptor.target.os)/\(descriptor.target.arch)"
        let actual = "\(actualOS)/\(actualArch)"
        guard publicationCommit.count == 40,
              publicationCommit.allSatisfy(\.isHexDigit) else {
            return .supplyRejected(reason: "the verified curated receipt has no immutable publication commit")
        }
        guard descriptor.target.os == actualOS,
              descriptor.target.arch == actualArch else {
            return .targetMismatch(declared: declared, actual: actual)
        }
        guard SkillRuntimeDependency.isCompatible(
            minimumAppVersion: descriptor.minimumAppVersion, appVersion: appVersion) else {
            return .clientVersionFloor(minimum: descriptor.minimumAppVersion,
                                       actual: appVersion)
        }
        guard SkillRuntimeDependency.isCaptureContractVersionSupported(
            descriptor.captureContract.version) else {
            return .supplyRejected(
                reason: "the signed component capture-contract version is not supported by this build")
        }
        let expectedPath = SkillRuntimeDependency.expectedArtifactPath(
            componentVersion: descriptor.componentVersion,
            triple: descriptor.target.triple)
        guard descriptor.artifact.path == expectedPath,
              (descriptor.artifact.path.split(separator: "/").last.map(String.init) ?? "")
                == SkillRuntimeDependency.frozenEngineFileName,
              !descriptor.artifact.path.split(separator: "/").contains("..") else {
            return .supplyRejected(reason: "the signed descriptor artifact path is outside the frozen component layout")
        }
        guard let encodedPath = descriptor.artifact.path.addingPercentEncoding(
                withAllowedCharacters: .urlPathAllowed) else {
            return .supplyRejected(reason: "the signed descriptor artifact path is not URL-safe")
        }
        let url = "https://raw.githubusercontent.com/\(CuratedSkillHub.owner)/"
            + "\(CuratedSkillHub.repository)/\(publicationCommit.lowercased())/"
            + "\(encodedPath)"
        // The guest path is assembled only from the allowlisted component id,
        // its strict numeric version and the exact lowercase digest. The
        // shell-quoted form below is never derived from JSON path segments.
        let guestPath = "~/.floe/runtime-components/"
            + "\(descriptor.componentID)/\(descriptor.componentVersion)/"
            + "\(descriptor.artifact.sha256)/\(SkillRuntimeDependency.frozenEngineFileName)"
        return .portable(C02RuntimeComponentPlan(
            componentID: descriptor.componentID,
            componentVersion: descriptor.componentVersion,
            artifactSize: descriptor.artifact.size,
            artifactSHA256: descriptor.artifact.sha256,
            artifactURL: url,
            guestPath: guestPath,
            contractSHA256: descriptor.captureContract.sha256,
            contractVersion: descriptor.captureContract.version,
            fileName: SkillRuntimeDependency.frozenEngineFileName))
    }
}

enum C02RuntimeComponentCommands {
    /// Read-only cache verification. A missing/mismatched file exits non-zero
    /// without touching it. On success it chmods the exact verified cache file
    /// and runs the two fixed component verbs.
    static func verify(_ plan: C02RuntimeComponentPlan) -> String? {
        guard let path = C02RuntimeComponentPlanBuilder.quote(plan.guestPath),
              let sha = C02RuntimeComponentPlanBuilder.quote(plan.artifactSHA256),
              let version = C02RuntimeComponentPlanBuilder.quote(plan.componentVersion),
              let contractSHA = C02RuntimeComponentPlanBuilder.quote(plan.contractSHA256) else {
            return nil
        }
        return """
        python3 - \(path) \(sha) \(plan.artifactSize) \(version) \(contractSHA) \(plan.contractVersion) <<'PY'
        import hashlib, os, stat, subprocess, sys
        path, sha, size, version, contract_sha, contract_version = sys.argv[1:7]
        path = os.path.expanduser(path)
        try:
            flags = os.O_RDONLY | getattr(os, 'O_NOFOLLOW', 0)
            with os.fdopen(os.open(path, flags), 'rb') as handle:
                info = os.fstat(handle.fileno())
                if not stat.S_ISREG(info.st_mode) or info.st_size != int(size):
                    raise SystemExit(3)
                digest = hashlib.sha256()
                for chunk in iter(lambda: handle.read(262144), b''):
                    digest.update(chunk)
            if digest.hexdigest() != sha:
                raise SystemExit(4)
            os.chmod(path, 0o755)
            probe = subprocess.run([path, 'engine-probe'], capture_output=True, timeout=30)
            expected = 'impeccable-engine ' + version + '\\n'
            if probe.returncode != 0 or probe.stdout.decode('utf-8', 'strict') != expected:
                raise SystemExit(5)
            contract = subprocess.run([path, 'contract'], capture_output=True, timeout=30)
            if contract.returncode != 0:
                raise SystemExit(6)
            if hashlib.sha256(contract.stdout).hexdigest() != contract_sha:
                raise SystemExit(7)
            if int(contract_version) not in (1,):
                raise SystemExit(8)
            print('component=verified version=' + version + ' sha256=' + sha)
        except subprocess.TimeoutExpired:
            raise SystemExit(9)
        except OSError:
            raise SystemExit(10)
        PY
        """
    }

    /// Provisioning is a single guest-owned fixed command. The URL is built
    /// from the compiled Hub repository + the receipt's immutable commit +
    /// the descriptor's exact allowlisted path; the bytes must match the
    /// descriptor size and SHA-256 BEFORE an atomic hard-link publish. A
    /// concurrent or foreign file at the destination is preserved and fails
    /// closed.
    static func provision(_ plan: C02RuntimeComponentPlan) -> String? {
        guard let url = C02RuntimeComponentPlanBuilder.quote(plan.artifactURL),
              let path = C02RuntimeComponentPlanBuilder.quote(plan.guestPath),
              let sha = C02RuntimeComponentPlanBuilder.quote(plan.artifactSHA256) else {
            return nil
        }
        return """
        python3 - \(url) \(path) \(sha) \(plan.artifactSize) <<'PY'
        import hashlib, os, sys, urllib.request, uuid
        url, dest, sha, size = sys.argv[1:5]
        dest = os.path.expanduser(dest)
        size = int(size)
        temporary = None
        try:
            # A foreign/damaged cache entry is preserved as found: fail
            # closed before any network use. The hard-link publish below still
            # closes the race against a concurrent writer.
            if os.path.lexists(dest):
                raise SystemExit(4)
            request = urllib.request.Request(
                url, headers={'User-Agent': 'FloeAgent-runtime-component'})
            with urllib.request.urlopen(request, timeout=120) as response:
                data = response.read(size + 1)
            if len(data) != size or hashlib.sha256(data).hexdigest() != sha:
                raise SystemExit(3)
            directory = os.path.dirname(dest)
            os.makedirs(directory, exist_ok=True)
            temporary = os.path.join(
                directory, '.partial-' + uuid.uuid4().hex)
            with open(temporary, 'wb') as handle:
                handle.write(data)
                handle.flush()
                os.fsync(handle.fileno())
            os.chmod(temporary, 0o755)
            try:
                # Atomic publish that NEVER overwrites a foreign/concurrent
                # cache entry: hard-link creation fails with EEXIST instead of
                # replacing the destination like rename(2) would.
                os.link(temporary, dest)
            except FileExistsError:
                raise SystemExit(4)
            os.unlink(temporary)
            temporary = None
            print('component=provisioned')
        finally:
            if temporary is not None:
                try:
                    os.unlink(temporary)
                except OSError:
                    pass
        PY
        """
    }
}

public actor C02SkillDependencyPreparation {
    public struct Configuration: Sendable {
        public var maximumDeclarationBytes: Int
        public var maximumPipLockBytes: Int
        public var probeTimeout: TimeInterval
        public var foregroundInstallTimeout: TimeInterval
        public var runtimeComponentInstallTimeout: TimeInterval
        public var jobPollIntervalNanos: UInt64
        public var jobWaitCeiling: TimeInterval

        public init(maximumDeclarationBytes: Int = SkillDependency.maximumDeclarationBytes,
                    maximumPipLockBytes: Int = 131_072,
                    probeTimeout: TimeInterval = 15,
                    foregroundInstallTimeout: TimeInterval = 120,
                    runtimeComponentInstallTimeout: TimeInterval = 300,
                    jobPollIntervalNanos: UInt64 = 500_000_000,
                    jobWaitCeiling: TimeInterval = 900) {
            self.maximumDeclarationBytes = maximumDeclarationBytes
            self.maximumPipLockBytes = maximumPipLockBytes
            self.probeTimeout = probeTimeout
            self.foregroundInstallTimeout = foregroundInstallTimeout
            self.runtimeComponentInstallTimeout = runtimeComponentInstallTimeout
            self.jobPollIntervalNanos = jobPollIntervalNanos
            self.jobWaitCeiling = jobWaitCeiling
        }
    }

    private struct ReceiptKey: Hashable, Sendable {
        let skillID: String
        let packageVersion: String
        let contentDigest: String
        let declarationSHA256: String
        let environmentID: String
        let targetFingerprint: String
        let generationToken: String
    }

    private struct TargetFacts: Sendable {
        let os: String
        let arch: String
        let dpkgArch: String
        let distro: String
        let fingerprint: String
        let generationToken: String
    }

    private struct MergedRequirement: Sendable {
        let profileIDs: [String]
        let requirement: SkillDependencyRequirement
    }

    struct ShellResult: Sendable {
        let exit: Int?
        let text: String
        let timedOut: Bool
        let failure: String?
        /// Set only when a durable job was ACCEPTED and remains owned. The
        /// caller must not fall back to a foreground replay or release its
        /// lease until this exact job reaches a terminal state.
        let pendingJobID: UUID?

        init(exit: Int?, text: String, timedOut: Bool, failure: String?,
             pendingJobID: UUID? = nil) {
            self.exit = exit
            self.text = text
            self.timedOut = timedOut
            self.failure = failure
            self.pendingJobID = pendingJobID
        }

        var succeeded: Bool { failure == nil && exit == 0 && !timedOut }
    }

    enum JobRunResult: Sendable {
        /// Proven pre-submission failure: no durable record was created.
        case notSubmitted(String)
        case finished(ShellResult)
        /// The job was accepted and is still live. Never replay.
        case pending(jobID: UUID, reason: String)
        case cancelled

        /// True ONLY for a proven pre-submission failure. Accepted/uncertain
        /// submissions and cancelled jobs must never trigger a foreground
        /// replay.
        var mayFallbackToForeground: Bool {
            if case .notSubmitted(_) = self { return true }
            return false
        }
    }

    private let store: SQLiteSkillStore
    private let installationRoot: URL
    private let receiptsStore: C02CuratedReceiptStore
    private let ownedWork: ConfigOwnedWorkLifecycle
    private let configuration: Configuration
    private var verified: [ReceiptKey: [C02DependencyRequirementReceipt]] = [:]
    /// One preparation per skill at a time; actor reentrancy must not allow a
    /// second install to start while the first is awaiting a job.
    private var inflightSkills: Set<String> = []
    /// Accepted install jobs that still own a work lease.
    private var pendingJobsBySkill: [String: UUID] = [:]
    private var retainedLeases: [UUID: ConfigOwnedWorkLease] = [:]

    public init(store: SQLiteSkillStore,
                installationRoot: URL,
                ownedWork: ConfigOwnedWorkLifecycle,
                configuration: Configuration = Configuration()) {
        self.store = store
        self.installationRoot = installationRoot
        self.receiptsStore = C02CuratedReceiptStore(installationRoot: installationRoot)
        self.ownedWork = ownedWork
        self.configuration = configuration
    }

    // MARK: Public entry points

    /// Runs only inside an ALREADY approved skill-scoped exec.shell call. The
    /// context is the real runtime-issued one; this method never mints a
    /// grant, picks an environment or switches execution targets.
    public func prepare(skillID: String,
                        context: ToolContext) async -> C02DependencyPreparationOutcome {
        guard (try? SkillIdentifier.validate(skillID)) != nil else {
            return .refused(reason: "invalidSkillID", requirements: [])
        }
        if let pending = pendingJobsBySkill[skillID] {
            return .pending(reason: "dependencyInstallOwnedPending",
                            jobID: pending, requirements: [])
        }
        guard context.approvalGrantID != nil else {
            return .bindingRequired(reason: "dependency-aware invocation requires the run's existing approval grant")
        }
        guard context.conversationID != nil else {
            return .bindingRequired(reason: "dependency-aware invocation requires the run's conversation identity")
        }
        guard let environmentID = context.environmentID, !environmentID.isEmpty else {
            return .bindingRequired(reason: "select and start the task Linux environment first; no default project, temporary directory or host fallback is used")
        }
        if Task.isCancelled || context.cancellation.isCancelled {
            return .refused(reason: "dependencyPreparationCancelled", requirements: [])
        }
        guard inflightSkills.insert(skillID).inserted else {
            return .refused(reason: "dependencyPreparationInFlight", requirements: [])
        }
        defer { inflightSkills.remove(skillID) }

        let rows: [PersistedSkill]
        do {
            rows = try await store.all()
        } catch {
            return .refused(reason: "installedSkillReadbackUnavailable", requirements: [])
        }
        guard let row = rows.first(where: { $0.id == skillID }) else {
            return .refused(reason: "skillNotInstalled", requirements: [])
        }
        guard row.status == "enabled" else {
            return .refused(reason: "skillDisabled", requirements: [])
        }
        let packageRoot = installationRoot.appendingPathComponent(skillID, isDirectory: true)
        let snapshot: SkillContentSnapshot
        do {
            snapshot = try SkillContentSnapshot(
                root: packageRoot,
                expectedDigest: row.rewrittenDigest,
                manifestOverride: SkillsDomain.sidecarManifest(for: row))
        } catch {
            return .refused(reason: "installedPackageDigestMismatch", requirements: [])
        }
        guard let receipt = receiptsStore.verifiedCurrent(
            skillID: skillID, contentDigest: row.rewrittenDigest,
            snapshot: snapshot) else {
            return .notOfficial(reason: "only a cryptographically re-verified production curated install carries automatic dependency authority; imported, unsigned or changed sidecars use ordinary exec.shell install/readback")
        }
        guard receipt.entryID == row.id, receipt.entryVersion == row.version else {
            return .notOfficial(reason: "verified curated receipt identity does not match the installed row")
        }
        guard let declarationBytes = snapshot.files[SkillDependency.packagePath] else {
            return .notRequired
        }
        guard declarationBytes.count <= configuration.maximumDeclarationBytes else {
            return .refused(reason: "dependencyDeclarationTooLarge", requirements: [])
        }
        let declaration: SkillDependencyDeclaration
        do {
            declaration = try SkillDependency.decode(declarationBytes)
            try SkillDependency.validate(declaration, packageFiles: snapshot.files)
        } catch {
            return .unsupported(reason: "dependencyDeclarationRejected")
        }

        guard let facts = await probeTarget(context: context, environmentID: environmentID) else {
            return .engineUnavailable(reason: "the selected task Linux engine did not return a usable uname/dpkg response; nothing was installed")
        }

        let merged: [MergedRequirement]
        do {
            merged = try mergeRequirements(declaration, arch: facts.arch)
        } catch let failure as PreparationFailure {
            return .refused(reason: failure.reason, requirements: [])
        } catch {
            return .refused(reason: "dependencyProfileSelectionFailed", requirements: [])
        }
        guard !merged.isEmpty else {
            return .refused(reason: "noMatchingProfileForActualArchitecture(\(facts.arch))", requirements: [])
        }

        let declarationSHA256 = FloeDigest.sha256Hex(declarationBytes)
        let key = ReceiptKey(skillID: skillID, packageVersion: row.version,
                             contentDigest: row.rewrittenDigest,
                             declarationSHA256: declarationSHA256,
                             environmentID: environmentID,
                             targetFingerprint: facts.fingerprint,
                             generationToken: facts.generationToken)
        if let cached = verified[key] {
            return readiness(from: cached)
        }

        let lease: ConfigOwnedWorkLease
        switch ownedWork.begin(kind: .tool, ownerID: "skill-deps:\(skillID)") {
        case .success(let started):
            lease = started
        case .failure(let rejection):
            return .engineUnavailable(reason: ownedWorkReason(rejection))
        }
        var leaseRetained = false
        defer {
            if !leaseRetained { ownedWork.settle(lease) }
        }

        var outcomes: [C02DependencyRequirementReceipt] = []
        for mergedRequirement in merged.sorted(by: Self.requirementOrder) {
            let requirement = mergedRequirement.requirement
            if Task.isCancelled || context.cancellation.isCancelled {
                return .refused(reason: "dependencyPreparationCancelled", requirements: outcomes)
            }
            if requirement.kind == .runtimeComponent {
                let component = await prepareRuntimeComponent(
                    requirement, snapshot: snapshot, receipt: receipt,
                    facts: facts, context: context)
                if let jobID = component.pendingJobID {
                    retainedLeases[jobID] = lease
                    pendingJobsBySkill[skillID] = jobID
                    leaseRetained = true
                    outcomes.append(component.receipt)
                    Task { await self.waitForRetainedJob(jobID: jobID, skillID: skillID) }
                    return .pending(reason: "runtimeComponentInstallOwnedPending",
                                    jobID: jobID, requirements: outcomes)
                }
                outcomes.append(component.receipt)
                if !component.verified && requirement.required {
                    return .refused(reason: "requiredRuntimeComponentNotAvailable",
                                    requirements: outcomes)
                }
                continue
            }
            if requirement.required == false {
                // Optional resources are best-effort. A missing optional gap
                // never blocks the invocation and never claims readiness.
                if let existing = await verify(requirement, snapshot: snapshot,
                                               facts: facts, context: context) {
                    outcomes.append(existing)
                } else {
                    let installResult = await install(requirement, snapshot: snapshot, context: context)
                    if let jobID = installResult.pendingJobID {
                        retainedLeases[jobID] = lease
                        pendingJobsBySkill[skillID] = jobID
                        leaseRetained = true
                        outcomes.append(C02DependencyRequirementReceipt(
                            kind: requirement.kind.rawValue, name: requirement.name,
                            version: requirement.version, required: false,
                            verified: false,
                            evidence: "optional install job accepted; exact job settlement pending",
                            deferredReason: "install job is still owned; no foreground replay and no lease release while it may be live"))
                        Task { await self.waitForRetainedJob(jobID: jobID, skillID: skillID) }
                        return .pending(reason: "dependencyInstallOwnedPending",
                                        jobID: jobID, requirements: outcomes)
                    }
                    if let after = await verify(requirement, snapshot: snapshot,
                                                facts: facts, context: context) {
                        outcomes.append(after)
                    } else {
                        outcomes.append(C02DependencyRequirementReceipt(
                            kind: requirement.kind.rawValue, name: requirement.name,
                            version: requirement.version, required: false,
                            verified: false, evidence: "optional resource not available",
                            deferredReason: "optional dependency is not installed; the skill continues with this visible gap"))
                    }
                }
                continue
            }
            if let existing = await verify(requirement, snapshot: snapshot,
                                           facts: facts, context: context) {
                outcomes.append(existing)
                continue
            }
            let installResult = await install(requirement, snapshot: snapshot, context: context)
            if let jobID = installResult.pendingJobID {
                retainedLeases[jobID] = lease
                pendingJobsBySkill[skillID] = jobID
                leaseRetained = true
                outcomes.append(C02DependencyRequirementReceipt(
                    kind: requirement.kind.rawValue, name: requirement.name,
                    version: requirement.version, required: requirement.required,
                    verified: false,
                    evidence: "install job accepted; exact job settlement pending",
                    deferredReason: "install job is still owned; no foreground replay and no lease release while it may be live"))
                Task { await self.waitForRetainedJob(jobID: jobID, skillID: skillID) }
                return .pending(reason: "dependencyInstallOwnedPending",
                                jobID: jobID, requirements: outcomes)
            }
            if !installResult.succeeded {
                outcomes.append(C02DependencyRequirementReceipt(
                    kind: requirement.kind.rawValue, name: requirement.name,
                    version: requirement.version, required: true,
                    verified: false,
                    evidence: String(installResult.text.prefix(240)),
                    deferredReason: installResult.failure ?? "install or readback failed"))
                return .refused(reason: "requiredDependencyNotReady(\(requirement.identityKey))", requirements: outcomes)
            }
            guard let after = await verify(requirement, snapshot: snapshot,
                                           facts: facts, context: context) else {
                outcomes.append(C02DependencyRequirementReceipt(
                    kind: requirement.kind.rawValue, name: requirement.name,
                    version: requirement.version, required: true,
                    verified: false, evidence: "install returned but readback did not prove the exact pin",
                    deferredReason: "guest readback did not match the reviewed exact version"))
                return .refused(reason: "requiredDependencyReadbackFailed(\(requirement.identityKey))", requirements: outcomes)
            }
            outcomes.append(after)
        }

        verified[key] = outcomes
        return readiness(from: outcomes)
    }

    /// Read-only cached readiness for the exact current package/environment
    /// pair. It never installs and never returns a fabricated ready state.
    public func cachedReadiness(skillID: String,
                                context: ToolContext) async -> C02DependencyPreparationOutcome? {
        guard pendingJobsBySkill[skillID] == nil else { return nil }
        guard let environmentID = context.environmentID, !environmentID.isEmpty else { return nil }
        guard let row = (try? await store.all())?.first(where: { $0.id == skillID }),
              row.status == "enabled" else { return nil }
        let packageRoot = installationRoot.appendingPathComponent(skillID, isDirectory: true)
        guard let snapshot = try? SkillContentSnapshot(
                root: packageRoot,
                expectedDigest: row.rewrittenDigest,
                manifestOverride: SkillsDomain.sidecarManifest(for: row)),
              receiptsStore.verifiedCurrent(
                skillID: skillID, contentDigest: row.rewrittenDigest,
                snapshot: snapshot) != nil,
              let declarationBytes = snapshot.files[SkillDependency.packagePath],
              declarationBytes.count <= configuration.maximumDeclarationBytes else {
            return nil
        }
        let declarationSHA256 = FloeDigest.sha256Hex(declarationBytes)
        guard let facts = await probeTarget(context: context, environmentID: environmentID) else {
            return nil
        }
        let key = ReceiptKey(skillID: skillID, packageVersion: row.version,
                             contentDigest: row.rewrittenDigest,
                             declarationSHA256: declarationSHA256,
                             environmentID: environmentID,
                             targetFingerprint: facts.fingerprint,
                             generationToken: facts.generationToken)
        guard let cached = verified[key] else { return nil }
        return readiness(from: cached)
    }

    /// Keeps the accepted job's work lease until the ORIGINAL job service
    /// proves a terminal state. It never replays the install and never
    /// releases while the process may still be live; Main's root/census owns
    /// any leftover after the bounded observation window.
    private func waitForRetainedJob(jobID: UUID, skillID: String) async {
        guard let service = RuntimeFacadeJobBindings.shared.service else { return }
        // The ORIGINAL job runner's own reconciliation ceiling is one hour;
        // observe past it plus margin before leaving the lease to Main's
        // census. Never release while the job could still be live.
        let deadline = Date().addingTimeInterval(max(4_200, configuration.jobWaitCeiling))
        while Date() < deadline {
            if let row = try? await service.job(id: jobID), row.state.isTerminal {
                if let lease = retainedLeases.removeValue(forKey: jobID) {
                    ownedWork.settle(lease)
                }
                if pendingJobsBySkill[skillID] == jobID {
                    pendingJobsBySkill.removeValue(forKey: skillID)
                }
                return
            }
            try? await Task.sleep(nanoseconds: configuration.jobPollIntervalNanos)
        }
    }

    private struct RuntimeComponentResult: Sendable {
        let receipt: C02DependencyRequirementReceipt
        let verified: Bool
        let pendingJobID: UUID?
    }

    /// Prepares exactly one packaged runtime component. The descriptor comes
    /// from the digest-verified installed snapshot; the retrieval pin is the
    /// immutable publication commit recorded by the verified curated receipt.
    /// The target is compared with the ACTUAL guest probe BEFORE any network
    /// or mutation. The guest owns the download/cache/probe; the native host
    /// never downloads or executes the artifact.
    private func prepareRuntimeComponent(
        _ requirement: SkillDependencyRequirement,
        snapshot: SkillContentSnapshot,
        receipt: CuratedSkillHub.Receipt,
        facts: TargetFacts,
        context: ToolContext
    ) async -> RuntimeComponentResult {
        func failed(_ reason: String, descriptor: SkillRuntimeDependencyDescriptor?) -> RuntimeComponentResult {
            RuntimeComponentResult(
                receipt: C02DependencyRequirementReceipt(
                    kind: requirement.kind.rawValue,
                    name: descriptor?.componentID
                        ?? (requirement.name.isEmpty ? "runtimeComponent" : requirement.name),
                    version: descriptor?.componentVersion ?? requirement.version,
                    required: requirement.required,
                    verified: false,
                    evidence: String(reason.prefix(240)),
                    deferredReason: String(reason.prefix(240))),
                verified: false,
                pendingJobID: nil)
        }

        guard let path = requirement.componentDescriptorPath,
              let bytes = snapshot.files[path],
              bytes.count <= SkillRuntimeDependency.maximumDescriptorBytes,
              let descriptor = try? SkillRuntimeDependency.decode(bytes) else {
            return failed("the packaged runtime-component descriptor is missing or failed strict validation", descriptor: nil)
        }
        let availability = C02RuntimeComponentPlanBuilder.availability(
            descriptor: descriptor,
            actualOS: facts.os,
            actualArch: facts.arch,
            appVersion: C02AndroidSkillCompatibility.version,
            publicationCommit: receipt.publicationCommit)
        switch availability {
        case .targetMismatch(let declared, let actual):
            return failed(
                "the signed component targets \(declared); the selected task Linux is \(actual); no signed artifact for the selected architecture is supplied",
                descriptor: descriptor)
        case .clientVersionFloor(let minimum, let actual):
            return failed(
                "the signed component requires app version \(minimum); the Android client compatibility version is \(actual); this is a supply/version fact, not a missing device capability",
                descriptor: descriptor)
        case .supplyRejected(let reason):
            return failed(reason, descriptor: descriptor)
        case .portable(let plan):
            if Task.isCancelled || context.cancellation.isCancelled {
                return failed("dependencyPreparationCancelled", descriptor: descriptor)
            }
            guard let verifyCommand = C02RuntimeComponentCommands.verify(plan),
                  let provisionCommand = C02RuntimeComponentCommands.provision(plan) else {
                return failed("the verified component plan could not be encoded safely", descriptor: descriptor)
            }
            let existing = await runShell(
                command: verifyCommand, context: context,
                timeout: configuration.probeTimeout, stdin: nil, preferJob: false)
            if existing.succeeded, existing.text.contains("component=verified") {
                return RuntimeComponentResult(
                    receipt: C02DependencyRequirementReceipt(
                        kind: requirement.kind.rawValue, name: plan.componentID,
                        version: plan.componentVersion, required: requirement.required,
                        verified: true,
                        evidence: "component \(plan.componentID) \(plan.componentVersion) sha256 \(plan.artifactSHA256) probe+contract verified"),
                    verified: true, pendingJobID: nil)
            }
            if Task.isCancelled || context.cancellation.isCancelled {
                return failed("dependencyPreparationCancelled", descriptor: descriptor)
            }
            let provision = await runShell(
                command: provisionCommand, context: context,
                timeout: configuration.runtimeComponentInstallTimeout,
                stdin: nil, preferJob: true)
            if let jobID = provision.pendingJobID {
                return RuntimeComponentResult(
                    receipt: C02DependencyRequirementReceipt(
                        kind: requirement.kind.rawValue, name: plan.componentID,
                        version: plan.componentVersion, required: requirement.required,
                        verified: false,
                        evidence: "component install job accepted; exact job settlement pending",
                        deferredReason: "the download/cache/probe job is still owned; no foreground replay and no lease release while it may be live"),
                    verified: false,
                    pendingJobID: jobID)
            }
            if !provision.succeeded {
                if Task.isCancelled || context.cancellation.isCancelled
                    || provision.exit == 130 {
                    return failed("dependencyPreparationCancelled", descriptor: descriptor)
                }
                let exitText = provision.exit.map { String($0) } ?? "unknown"
                return failed(
                    "component download/verification did not complete: "
                        + (provision.failure ?? "exit=\(exitText)"),
                    descriptor: descriptor)
            }
            let readback = await runShell(
                command: verifyCommand, context: context,
                timeout: configuration.probeTimeout, stdin: nil, preferJob: false)
            guard readback.succeeded, readback.text.contains("component=verified") else {
                return failed(
                    "component readback did not prove the exact artifact digest, probe handshake and contract digest",
                    descriptor: descriptor)
            }
            return RuntimeComponentResult(
                receipt: C02DependencyRequirementReceipt(
                    kind: requirement.kind.rawValue, name: plan.componentID,
                    version: plan.componentVersion, required: requirement.required,
                    verified: true,
                    evidence: "component \(plan.componentID) \(plan.componentVersion) sha256 \(plan.artifactSHA256) probe+contract verified"),
                verified: true, pendingJobID: nil)
        }
    }

    // MARK: Declaration/profile selection

    private struct PreparationFailure: Error, Sendable {
        let reason: String
    }

    private func mergeRequirements(_ declaration: SkillDependencyDeclaration,
                                   arch: String) throws -> [MergedRequirement] {
        var selected: [String: MergedRequirement] = [:]
        var matchedProfiles = 0
        for profile in declaration.profiles where profile.os == SkillDependency.frozenTargetOS {
            guard profile.architectures.contains("any") || profile.architectures.contains(arch) else {
                continue
            }
            matchedProfiles += 1
            for requirement in profile.requirements {
                if let existing = selected[requirement.identityKey] {
                    if existing.requirement.version != requirement.version {
                        throw PreparationFailure(reason: "conflictingMatchingProfiles(\(requirement.identityKey))")
                    }
                    selected[requirement.identityKey] = MergedRequirement(
                        profileIDs: existing.profileIDs + [profile.id],
                        requirement: existing.requirement)
                } else {
                    selected[requirement.identityKey] = MergedRequirement(
                        profileIDs: [profile.id], requirement: requirement)
                }
            }
        }
        guard matchedProfiles > 0 else { return [] }
        return selected.values.sorted(by: Self.requirementOrder)
    }

    private static func requirementOrder(_ lhs: MergedRequirement,
                                         _ rhs: MergedRequirement) -> Bool {
        let left = (kindOrder(lhs.requirement.kind), lhs.requirement.name)
        let right = (kindOrder(rhs.requirement.kind), rhs.requirement.name)
        return left < right
    }

    private static func kindOrder(_ kind: SkillDependencyRequirement.Kind) -> Int {
        switch kind {
        case .apt: 0
        case .font: 1
        case .pip: 2
        case .npm: 3
        case .runtimeComponent: 4
        }
    }

    private func readiness(from requirements: [C02DependencyRequirementReceipt])
        -> C02DependencyPreparationOutcome {
        let gaps = requirements.filter { !$0.verified }
        guard gaps.isEmpty else {
            if requirements.contains(where: { $0.required && !$0.verified }) {
                return .refused(reason: "requiredDependencyNotVerified", requirements: requirements)
            }
            return .ready(annotation: gaps.map { "\($0.kind):\($0.name)" }.joined(separator: ", "),
                          requirements: requirements)
        }
        return .ready(annotation: "", requirements: requirements)
    }

    // MARK: Target probe

    private func probeTarget(context: ToolContext,
                             environmentID: String) async -> TargetFacts? {
        let command = """
        printf 'os=%s\\n' "$(uname -s 2>/dev/null || true)"
        printf 'arch=%s\\n' "$(uname -m 2>/dev/null || true)"
        printf 'dpkg=%s\\n' "$(dpkg --print-architecture 2>/dev/null || true)"
        if [ -r /etc/os-release ]; then . /etc/os-release; printf 'distro=%s\\n' "${ID:-unknown}"; fi
        """
        let result = await runShell(command: command, context: context,
                                    timeout: configuration.probeTimeout,
                                    stdin: nil, preferJob: false)
        guard result.succeeded else { return nil }
        var values: [String: String] = [:]
        for line in result.text.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            values[String(parts[0])] = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard values["os"]?.lowercased() == "linux" else { return nil }
        let rawArch = (values["arch"] ?? "").lowercased()
        let arch: String
        switch rawArch {
        case "riscv64": arch = "riscv64"
        case "aarch64", "arm64": arch = "arm64"
        case "x86_64", "amd64": arch = "x86_64"
        default: return nil
        }
        let dpkgArch = (values["dpkg"] ?? "").lowercased()
        let distro = values["distro"] ?? "unknown"
        let generation = RuntimeFacadeLinuxBindings.shared.boundNativeEpoch
        let generationToken = generation == 0 ? "unbound" : String(generation)
        let fingerprint = "linux/\(arch)/\(dpkgArch.isEmpty ? "unknown" : dpkgArch)/\(distro)"
        return TargetFacts(os: "linux", arch: arch, dpkgArch: dpkgArch, distro: distro,
                           fingerprint: fingerprint, generationToken: generationToken)
    }

    // MARK: Verification

    private func verify(_ requirement: SkillDependencyRequirement,
                        snapshot: SkillContentSnapshot,
                        facts: TargetFacts,
                        context: ToolContext) async -> C02DependencyRequirementReceipt? {
        switch requirement.kind {
        case .apt:
            return await verifyApt(requirement, context: context)
        case .font:
            guard let apt = await verifyApt(requirement, context: context) else { return nil }
            guard await cjkProbe(context: context) else { return nil }
            return C02DependencyRequirementReceipt(
                kind: requirement.kind.rawValue, name: requirement.name,
                version: requirement.version, required: requirement.required,
                verified: true, evidence: "\(apt.evidence), cjk-probe ok")
        case .pip:
            return await verifyPip(requirement, context: context)
        case .npm:
            return await verifyNpm(requirement, context: context)
        case .runtimeComponent:
            return nil
        }
    }

    private func verifyApt(_ requirement: SkillDependencyRequirement,
                           context: ToolContext) async -> C02DependencyRequirementReceipt? {
        guard let version = requirement.version,
              let quotedName = Self.shellQuote(requirement.name) else { return nil }
        let command = "dpkg-query -W -f='${Version}\\n' \(quotedName) 2>/dev/null"
        let result = await runShell(command: command, context: context,
                                    timeout: configuration.probeTimeout,
                                    stdin: nil, preferJob: false)
        guard result.succeeded else { return nil }
        let installed = result.text.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? ""
        guard installed == version else { return nil }
        return C02DependencyRequirementReceipt(
            kind: requirement.kind.rawValue, name: requirement.name,
            version: version, required: requirement.required,
            verified: true, evidence: "dpkg \(installed)")
    }

    private func verifyPip(_ requirement: SkillDependencyRequirement,
                           context: ToolContext) async -> C02DependencyRequirementReceipt? {
        guard let version = requirement.version else { return nil }
        let command = """
        python3 - <<'PY' 2>/dev/null
        import sys
        name = \(Self.pythonStringLiteral(requirement.name))
        try:
            import importlib.metadata as m
            print(m.version(name))
        except Exception:
            try:
                import pkg_resources
                print(pkg_resources.get_distribution(name).version)
            except Exception:
                sys.exit(1)
        PY
        """
        let result = await runShell(command: command, context: context,
                                    timeout: configuration.probeTimeout,
                                    stdin: nil, preferJob: false)
        guard result.succeeded else { return nil }
        let installed = result.text.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? ""
        guard Self.normalizedPythonVersion(installed) == Self.normalizedPythonVersion(version) else {
            return nil
        }
        return C02DependencyRequirementReceipt(
            kind: requirement.kind.rawValue, name: requirement.name,
            version: version, required: requirement.required,
            verified: true, evidence: "pip \(installed)")
    }

    private func verifyNpm(_ requirement: SkillDependencyRequirement,
                           context: ToolContext) async -> C02DependencyRequirementReceipt? {
        guard let version = requirement.version else { return nil }
        let command = """
        root="$(npm root -g --silent 2>/dev/null)" || exit 1
        python3 -c 'import json,sys; print(json.load(open(sys.argv[1], encoding="utf-8"))["version"])' "$root/\(requirement.name)/package.json" 2>/dev/null
        """
        let result = await runShell(command: command, context: context,
                                    timeout: configuration.probeTimeout,
                                    stdin: nil, preferJob: false)
        guard result.succeeded else { return nil }
        let installed = result.text.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? ""
        guard installed == version else { return nil }
        return C02DependencyRequirementReceipt(
            kind: requirement.kind.rawValue, name: requirement.name,
            version: version, required: requirement.required,
            verified: true, evidence: "npm \(installed)")
    }

    // MARK: Installation

    private func install(_ requirement: SkillDependencyRequirement,
                         snapshot: SkillContentSnapshot,
                         context: ToolContext) async -> ShellResult {
        switch requirement.kind {
        case .apt, .font:
            guard let version = requirement.version,
                  let pin = Self.shellQuote("\(requirement.name)=\(version)") else {
                return ShellResult(exit: nil, text: "", timedOut: false,
                                   failure: "invalid apt pin")
            }
            let command = "DEBIAN_FRONTEND=noninteractive LC_ALL=C apt-get install -y --no-install-recommends \(pin)"
            return await runShell(command: command, context: context,
                                  timeout: configuration.foregroundInstallTimeout,
                                  stdin: nil, preferJob: true)
        case .pip:
            return await installPip(requirement, snapshot: snapshot, context: context)
        case .npm:
            guard let version = requirement.version,
                  let spec = Self.shellQuote("\(requirement.name)@\(version)") else {
                return ShellResult(exit: nil, text: "", timedOut: false,
                                   failure: "invalid npm pin")
            }
            let command = "npm install --global --no-audit --no-fund \(spec)"
            return await runShell(command: command, context: context,
                                  timeout: configuration.foregroundInstallTimeout,
                                  stdin: nil, preferJob: true)
        case .runtimeComponent:
            // Defensive: the requirement loop routes components through
            // prepareRuntimeComponent before this generic installer.
            return ShellResult(exit: nil, text: "", timedOut: false,
                               failure: "runtime-component provisioning requires the dedicated verified component path")
        }
    }

    private func installPip(_ requirement: SkillDependencyRequirement,
                            snapshot: SkillContentSnapshot,
                            context: ToolContext) async -> ShellResult {
        guard let version = requirement.version else {
            return ShellResult(exit: nil, text: "", timedOut: false,
                               failure: "missing exact pip version")
        }
        if let lockfile = requirement.lockfile {
            guard let lockBytes = snapshot.files[lockfile],
                  lockBytes.count <= configuration.maximumPipLockBytes,
                  let lock = Self.parsePipLock(lockBytes,
                                               declaredName: requirement.name,
                                               declaredVersion: version) else {
                return ShellResult(exit: nil, text: "", timedOut: false,
                                   failure: "pip lock is not a strict pinned hash closure")
            }
            let command = "python3 -m pip install --disable-pip-version-check --no-input --require-hashes -r /dev/stdin"
            return await runShell(command: command, context: context,
                                  timeout: configuration.foregroundInstallTimeout,
                                  stdin: lock, preferJob: true)
        }
        guard let spec = Self.shellQuote("\(requirement.name)==\(version)") else {
            return ShellResult(exit: nil, text: "", timedOut: false,
                               failure: "invalid pip pin")
        }
        let command = "python3 -m pip install --disable-pip-version-check --no-input \(spec)"
        return await runShell(command: command, context: context,
                              timeout: configuration.foregroundInstallTimeout,
                              stdin: nil, preferJob: true)
    }

    // MARK: CJK glyph probe (real FreeType render, not a file-presence claim)

    private func cjkProbe(context: ToolContext) async -> Bool {
        let command = #"""
        python3 - <<'PY'
        import ctypes, os, sys
        candidates = [
            "/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc",
            "/usr/share/fonts/opentype/noto/NotoSerifCJK-Regular.ttc",
            "/usr/share/fonts/truetype/noto/NotoSansCJK-Regular.ttc",
        ]
        path = next((p for p in candidates if os.path.isfile(p)), None)
        if path is None:
            sys.exit(1)
        try:
            ft = ctypes.CDLL("libfreetype.so.6")
        except Exception:
            sys.exit(1)
        ft.FT_Init_FreeType.argtypes = [ctypes.POINTER(ctypes.c_void_p)]
        ft.FT_New_Face.argtypes = [ctypes.c_void_p, ctypes.c_char_p,
                                   ctypes.c_long, ctypes.POINTER(ctypes.c_void_p)]
        ft.FT_Set_Pixel_Sizes.argtypes = [ctypes.c_void_p, ctypes.c_uint, ctypes.c_uint]
        ft.FT_Load_Char.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.c_int32]
        ft.FT_Done_Face.argtypes = [ctypes.c_void_p]
        ft.FT_Done_FreeType.argtypes = [ctypes.c_void_p]
        lib = ctypes.c_void_p()
        if ft.FT_Init_FreeType(ctypes.byref(lib)) != 0:
            sys.exit(1)
        face = ctypes.c_void_p()
        try:
            if ft.FT_New_Face(lib, path.encode(), 0, ctypes.byref(face)) != 0:
                sys.exit(1)
            ft.FT_Get_Char_Index.restype = ctypes.c_uint
            ft.FT_Get_Char_Index.argtypes = [ctypes.c_void_p, ctypes.c_ulong]
            if ft.FT_Get_Char_Index(face, ord("中")) == 0:
                sys.exit(1)
            if ft.FT_Get_Char_Index(face, ord("あ")) == 0:
                sys.exit(1)
            if ft.FT_Set_Pixel_Sizes(face, 0, 32) != 0:
                sys.exit(1)
            if ft.FT_Load_Char(face, ord("中"), 4) != 0:
                sys.exit(1)
        finally:
            if face:
                ft.FT_Done_Face(face)
            ft.FT_Done_FreeType(lib)
        print("cjk-probe ok")
        PY
        """#
        let result = await runShell(command: command, context: context,
                                    timeout: configuration.probeTimeout,
                                    stdin: nil, preferJob: false)
        return result.succeeded && result.text.contains("cjk-probe ok")
    }

    // MARK: Shell execution (existing exec.shell + durable jobs)

    private func runShell(command: String,
                          context: ToolContext,
                          timeout: TimeInterval,
                          stdin: String?,
                          preferJob: Bool) async -> ShellResult {
        if preferJob, let service = RuntimeFacadeJobBindings.shared.service {
            let jobResult = await runJob(command: command, context: context,
                                         timeout: timeout, stdin: stdin,
                                         service: service)
            if jobResult.mayFallbackToForeground {
                // Proven pre-submission: no durable record exists, so the
                // foreground path is safe. Any accepted/uncertain submission
                // returns a result and is never replayed here.
                return await runForeground(command: command, context: context,
                                           timeout: timeout, stdin: stdin)
            }
            switch jobResult {
            case .finished(let result):
                return result
            case .pending(let jobID, let reason):
                return ShellResult(exit: nil, text: reason, timedOut: true,
                                   failure: "jobPending", pendingJobID: jobID)
            case .cancelled:
                return ShellResult(exit: 130, text: "cancelled",
                                   timedOut: false, failure: nil)
            case .notSubmitted:
                // Unreachable: mayFallbackToForeground handled it.
                return ShellResult(exit: nil, text: "", timedOut: false,
                                   failure: "jobSubmissionUnavailable")
            }
        }
        return await runForeground(command: command, context: context,
                                   timeout: timeout, stdin: stdin)
    }

    private func runForeground(command: String, context: ToolContext,
                               timeout: TimeInterval,
                               stdin: String?) async -> ShellResult {
        // Use the EXISTING LocalShellService behind exec.shell directly: the
        // caller's ToolContext already carries the resolved environment lease
        // from its approved exec.shell dispatch, so nested tool-environment
        // routing is unnecessary. Policy, input validation, owned-work
        // tracking, output bounds and cancellation are the same service
        // authority the tool path uses.
        guard C02ForegroundDispatchPolicy.shouldDispatch(
            cancelled: Task.isCancelled || context.cancellation.isCancelled) else {
            return ShellResult(exit: 130, text: "cancelled",
                               timedOut: false, failure: nil)
        }
        guard let service = RuntimeFacadeLinuxBindings.shared.components?.service else {
            return ShellResult(exit: nil, text: "", timedOut: false,
                               failure: "exec.shell service is not composed")
        }
        let result = await service.run(
            command: command,
            cwd: ".",
            environment: [:],
            stdin: stdin,
            timeout: max(0.05, min(timeout, 120)),
            maxOutputBytes: 65_536,
            isBackground: false,
            context: context)
        switch result {
        case .blocked(let verdict):
            return ShellResult(exit: 126,
                               text: "blocked:\(verdict.matchedPatternID ?? "policy")",
                               timedOut: false, failure: nil)
        case .outcome(let outcome):
            return Self.render(outcome)
        }
    }

    private static func render(_ outcome: ShellRunOutcome) -> ShellResult {
        switch outcome {
        case .exited(let code, let stdout, let stderr, _, _, _):
            let text = stdout + (stderr.isEmpty ? "" : "\n" + stderr)
            return ShellResult(exit: Int(code), text: text,
                               timedOut: false, failure: nil)
        case .timedOut(let stdout, let stderr, _):
            return ShellResult(exit: 124,
                               text: stdout + (stderr.isEmpty ? "" : "\n" + stderr),
                               timedOut: true, failure: nil)
        case .cancelled:
            return ShellResult(exit: 130, text: "cancelled", timedOut: false, failure: nil)
        case .notStarted(let reason):
            return ShellResult(exit: 75, text: reason, timedOut: false, failure: nil)
        case .failed(let message):
            return ShellResult(exit: nil, text: message, timedOut: false,
                               failure: "engineUnavailable")
        }
    }

    private func runJob(command: String, context: ToolContext,
                        timeout: TimeInterval, stdin: String?,
                        service: BackgroundJobService) async -> JobRunResult {
        if Task.isCancelled || context.cancellation.isCancelled {
            return .cancelled
        }
        var payload: [String: Any] = [
            "command": command,
            "cwd": ".",
            "timeout": max(0.05, min(timeout, 600)),
            "maxOutputBytes": 65_536,
        ]
        if let stdin { payload["stdin"] = stdin }
        guard let data = try? JSONSerialization.data(withJSONObject: payload,
                                                     options: [.sortedKeys]) else {
            // No durable record was created: this is the only fallback-safe
            // pre-submission failure.
            return .notSubmitted("payloadEncode")
        }
        let callID = "skill-deps-\(UUID().uuidString)"
        let job: BackgroundJob
        do {
            job = try await service.submit(
                runID: context.runID,
                toolCallID: callID,
                targetTool: "exec.shell",
                payloadJSON: data,
                scope: context.scope,
                workspaceRootURL: context.workspaceRootURL,
                allowedWorkspacePaths: context.allowedWorkspacePaths,
                environmentID: context.environmentID,
                allowedToolNames: context.allowedToolNames,
                approvalGrantID: context.approvalGrantID,
                submissionSource: .nativeService,
                waitForCompletion: false)
        } catch is CancellationError {
            return .cancelled
        } catch {
            // Submission may have persisted before throwing. Do not fall
            // back to a foreground replay; report the uncertain ownership.
            return .finished(ShellResult(
                exit: nil, text: String(describing: error),
                timedOut: false, failure: "jobSubmissionUncertain"))
        }

        let deadline = Date().addingTimeInterval(configuration.jobWaitCeiling)
        while Date() < deadline {
            if Task.isCancelled || context.cancellation.isCancelled {
                return await cancelAndDrain(jobID: job.id, service: service,
                                            reason: "cancelled")
            }
            if let row = try? await service.job(id: job.id) {
                switch row.state {
                case .completed:
                    let text = row.resultSummary ?? ""
                    switch C02JobCompletionProof.parse(text) {
                    case .unknown:
                        // Never fabricate exit 0 when the structured proof is
                        // absent. The caller may still get a real readiness
                        // only from guest readback, but this install is not a
                        // success.
                        return .finished(ShellResult(
                            exit: nil, text: text, timedOut: false,
                            failure: "jobCompletedWithoutExitEvidence"))
                    case .exit(let exit):
                        return .finished(ShellResult(
                            exit: exit, text: text, timedOut: false,
                            failure: exit == 0 ? nil : "jobExit\(exit)"))
                    }
                case .failed:
                    let text = [row.lastError, row.resultSummary]
                        .compactMap { $0 }.joined(separator: "\n")
                    return .finished(ShellResult(
                        exit: nil, text: text, timedOut: false,
                        failure: text.isEmpty ? "jobFailed" : nil))
                case .cancelled:
                    return .finished(ShellResult(
                        exit: 130, text: row.resultSummary ?? "cancelled",
                        timedOut: false, failure: nil))
                case .interrupted:
                    return .finished(ShellResult(
                        exit: nil, text: row.lastError ?? "interrupted",
                        timedOut: false, failure: "jobInterrupted"))
                case .queued, .running:
                    break
                }
            }
            try? await Task.sleep(nanoseconds: configuration.jobPollIntervalNanos)
        }
        return await cancelAndDrain(jobID: job.id, service: service,
                                    reason: "waitCeiling")
    }

    /// Requests the EXACT accepted job to stop, then observes its terminal
    /// state. A job that completed after the deadline/cancel is not reported
    /// as a success in this invocation; the next approved invocation must
    /// re-verify the guest. A still-live job returns `.pending` so the caller
    /// retains its work lease instead of replaying the install.
    private func cancelAndDrain(jobID: UUID, service: BackgroundJobService,
                                reason: String) async -> JobRunResult {
        _ = try? await service.cancel(id: jobID)
        let drainDeadline = Date().addingTimeInterval(
            min(max(30, configuration.jobWaitCeiling), 120))
        while Date() < drainDeadline {
            if let row = try? await service.job(id: jobID), row.state.isTerminal {
                switch row.state {
                case .completed:
                    let text = row.resultSummary ?? ""
                    return .finished(ShellResult(
                        exit: 124,
                        text: "job settled after \(reason); inspect existing outputs before retrying\n" + text,
                        timedOut: true, failure: nil))
                case .failed:
                    let text = [row.lastError, row.resultSummary]
                        .compactMap { $0 }.joined(separator: "\n")
                    return .finished(ShellResult(
                        exit: nil, text: text, timedOut: false,
                        failure: text.isEmpty ? "jobFailed" : nil))
                case .cancelled:
                    return .finished(ShellResult(
                        exit: 130, text: row.resultSummary ?? "cancelled",
                        timedOut: false, failure: nil))
                case .interrupted:
                    return .finished(ShellResult(
                        exit: nil, text: row.lastError ?? "interrupted",
                        timedOut: false, failure: "jobInterrupted"))
                case .queued, .running:
                    break
                }
            }
            try? await Task.sleep(nanoseconds: configuration.jobPollIntervalNanos)
        }
        return .pending(jobID: jobID, reason: "jobStillLiveAfter\(reason)")
    }

    // MARK: Small pure helpers

    private func ownedWorkReason(_ rejection: ConfigOwnedWorkLifecycle.BeginRejection) -> String {
        switch rejection {
        case .noAdmittedEpoch: "noAdmittedRuntimeEpoch"
        case .invalidOwnerIdentity: "invalidOwnerIdentity"
        case .rejected(code: let code): "ownedWorkRejected.\(code)"
        }
    }

    private static func shellQuote(_ value: String) -> String? {
        guard !value.contains("'"), !value.contains("\n"), !value.contains("\r"),
              !value.contains("\0") else { return nil }
        return "'" + value + "'"
    }

    private static func pythonStringLiteral(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
        return "\"\(escaped)\""
    }

    private static func normalizedPythonVersion(_ value: String) -> String {
        value.lowercased().replacingOccurrences(of: "_", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Strict package-local pip lock parser: every non-comment line is an
    /// exact `name==version` with at least one `--hash=sha256:<64 hex>` and no
    /// other token. The declared pin must be present. Returns a normalized
    /// lock body for `pip --require-hashes -r /dev/stdin`.
    static func parsePipLock(_ bytes: Data, declaredName: String,
                             declaredVersion: String) -> String? {
        guard let raw = String(data: bytes, encoding: .utf8) else { return nil }
        var output: [String] = []
        var declaredFound = false
        var seen: [String: String] = [:]
        for rawLine in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let tokens = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard tokens.count >= 2 else { return nil }
            let head = tokens[0]
            let pieces = head.split(separator: "=", omittingEmptySubsequences: false)
            guard pieces.count == 3, pieces[1].isEmpty else { return nil }
            let name = String(pieces[0])
            let version = String(pieces[2])
            guard isValidLockName(name), isValidLockVersion(version) else { return nil }
            var hashes: [String] = []
            for token in tokens.dropFirst() {
                guard token.hasPrefix("--hash=sha256:"),
                      token.count == "--hash=sha256:".count + 64 else { return nil }
                let digest = String(token.dropFirst("--hash=sha256:".count))
                guard digest.allSatisfy(\.isHexDigit), digest == digest.lowercased() else { return nil }
                hashes.append(digest)
            }
            guard !hashes.isEmpty else { return nil }
            let key = name.lowercased()
            if let prior = seen[key], prior != version { return nil }
            seen[key] = version
            if key == declaredName.lowercased(), version == declaredVersion {
                declaredFound = true
            }
            output.append("\(name)==\(version) " + hashes.map { "--hash=sha256:\($0)" }.joined(separator: " "))
        }
        guard declaredFound, !output.isEmpty else { return nil }
        return output.joined(separator: "\n") + "\n"
    }

    private static func isValidLockName(_ value: String) -> Bool {
        guard let first = value.first, first.isLetter || first.isNumber,
              value.count <= 128 else { return false }
        return value.unicodeScalars.allSatisfy {
            ($0.value >= 65 && $0.value <= 90) || ($0.value >= 97 && $0.value <= 122)
                || ($0.value >= 48 && $0.value <= 57) || $0 == "." || $0 == "_" || $0 == "-"
        }
    }

    private static func isValidLockVersion(_ value: String) -> Bool {
        guard let first = value.first, first.isLetter || first.isNumber,
              value.count <= 128, value.contains(where: { $0.isNumber }) else { return false }
        return value.unicodeScalars.allSatisfy {
            ($0.value >= 65 && $0.value <= 90) || ($0.value >= 97 && $0.value <= 122)
                || ($0.value >= 48 && $0.value <= 57) || $0 == "." || $0 == "*"
                || $0 == "+" || $0 == "!" || $0 == "_" || $0 == "-"
        }
    }
}
