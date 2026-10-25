// FloeSkills — curated Skill Hub native client (lane A1).
//
// Consumes the fixed H1 schemaVersion-3 signed channel feeds from
// `JiangNanGenius/floe-skill-hub`. End-to-end operation shape:
//
//   1. Resolve the pinned repository ref ONCE through the injected transport
//      to an immutable `publicationCommit` Y. Every artifact of the whole
//      operation (feed, signature, archives, review records and review
//      signatures) is fetched at that single Y — never at the feed's audited
//      `sourceCommit` X, and never with a fresh mutable-head resolution per
//      file. X and Y are recorded separately in the receipt; X != Y is the
//      normal shape and the client never demands X == Y.
//   2. Verify the Ed25519 envelope over the EXACT fetched bytes under the
//      compiled production trust (`OfficialSkillHub.trustedKeys`, keyID
//      "official-2026-09"). An explicit fixture identity
//      ("fixture-only-2026-10") is accepted only behind the dedicated
//      `fixtureTestOnly` policy and only for `feedStatus == "fixture"` feeds.
//      Nothing a feed, package or model declares can add a trust root.
//   3. Validate the feed structurally (strict models) and stage only valid
//      ready offers: recomputed counts, lifecycle implications, the actual
//      archive digest chain and the three-way review join against the real
//      unpacked manifest. Corrupt/missing signatures, digest mismatches,
//      unqualified offers and unavailable platforms fail closed; an absent
//      production catalog is never faked as a valid empty feed.
//   4. Return an immutable owned staged snapshot plus a typed reviewed
//      receipt. This module never installs, grants, enables or overwrites
//      user choices; the combined permission flow and the existing SkillStore
//      promotion stay with the caller.
//
// The legacy four-item official feed (`OfficialSkillHub`, JiangNanGenius/
// floe-agent/skill-hub) is untouched: this client reads the hub repository at
// its own root layout (`catalog.json`/`android/catalog.json`) and the legacy
// decoder rejects schemaVersion 3 by design.

import Foundation
import Crypto
import FloeCore

// MARK: - Failures

/// Machine-readable fail-closed outcomes. UI maps `offer`/`unavailable` to
/// "暂不可用 / Unavailable" — never to a "获取 / Get" action.
public enum CuratedSkillHubFailure: Error, Equatable, Sendable, LocalizedError {
    /// Transport identity or retrieval pin problem (bad source, non-40-hex Y).
    case source(String)
    /// Trust configuration problem (malformed test key, fixture identity in
    /// production, production feed under fixture trust).
    case trust(String)
    /// Envelope missing/malformed or signature invalid over the exact bytes.
    case signature(String)
    /// Structurally invalid feed (strict schema, counts, lifecycle, paths).
    case feed(String)
    /// No valid ready install offer (unqualified, missing review, drift).
    case offer(String)
    /// Entry requires a newer app than the running one.
    case compatibility(String)
    /// Archive size/sha mismatch or an unsafe-archive rejection.
    case archive(String)
    /// Canonical content digest or review-record digest mismatch.
    case digest(String)
    /// Review record decode or the three-way exact-bytes join failed.
    case review(String)
    /// Published same-version bytes differ from the installed/recorded copy.
    case immutableVersion(String)
    /// An artifact fetch failed at the pinned publication commit, or the
    /// publication is not available. Fail-closed: never a valid empty feed.
    case unavailable(String)

    public var errorDescription: String? {
        switch self {
        case .source(let reason): "Invalid curated Skill Hub source or publication pin: \(reason)"
        case .trust(let reason): "Curated Skill Hub trust policy rejected the request: \(reason)"
        case .signature(let reason): "Curated Skill Hub signature verification failed: \(reason)"
        case .feed(let reason): "Invalid curated Skill Hub feed: \(reason)"
        case .offer(let reason): "This curated skill is not available for installation: \(reason)"
        case .compatibility(let reason): "Update Floe before installing this curated skill: \(reason)"
        case .archive(let reason): "Unsafe, oversized or corrupt curated skill archive: \(reason)"
        case .digest(let reason): "Curated skill content does not match the signed digests: \(reason)"
        case .review(let reason): "Curated skill review binding failed: \(reason)"
        case .immutableVersion(let reason): "Published curated skill versions cannot change content: \(reason)"
        case .unavailable(let reason): "The curated Skill Hub publication is unavailable: \(reason)"
        }
    }
}

// MARK: - Trust configuration

/// The two and only two trust configurations. `production` uses exactly the
/// compiled app trust root; `fixtureTestOnly` is an explicit, locally
/// configured contract-test identity that can never carry production meaning.
/// There is no API path that adds a key from fetched data.
public enum CuratedSkillTrustMode: Sendable {
    case production
    case fixtureTestOnly(fixturePublicKey: Data)
}

// MARK: - Client

public enum CuratedSkillHub {
    /// Fixed repository identity (contract §1, FIELD-TABLE). Not the legacy
    /// `JiangNanGenius/floe-agent` source; the legacy protocol is unchanged.
    public static let owner = "JiangNanGenius"
    public static let repository = "floe-skill-hub"
    public static let hubRepository = "JiangNanGenius/floe-skill-hub"
    public static let publisher = "JiangNanGenius"
    public static let feedSchemaVersion = 3

    /// Production identity is the compiled `official-2026-09` trust already
    /// used by the legacy hub; no new or rotated key enters here silently.
    public static let productionKeyID = "official-2026-09"
    /// Fixture identity is rejected as trust material at load time and only
    /// reachable through `CuratedSkillTrustMode.fixtureTestOnly`.
    public static let fixtureKeyID = "fixture-only-2026-10"

    /// Bounded feed size for the 43-row channel feeds (generous, fail-closed).
    public static let maximumFeedBytes = 4_194_304
    public static let maximumEntries = 256
    public static let maximumDirectoryListingBytes = 2_097_152

    // MARK: Identity and paths

    /// Channel root within the hub repository at publication Y. iOS lives at
    /// the tree root; Android under `android/`. Reviews are shared.
    public static func catalogPath(for channel: CuratedSkillChannel) -> String {
        switch channel {
        case .ios: "catalog.json"
        case .android: "android/catalog.json"
        }
    }

    public static func signaturePath(for channel: CuratedSkillChannel) -> String {
        String(catalogPath(for: channel).dropLast(".json".count)) + ".sig"
    }

    /// The pinned repository source for one channel. `ref` is the branch or
    /// tag the caller has pinned; it is resolved to an immutable commit
    /// exactly once by `loadPublication`.
    public static func source(channel: CuratedSkillChannel, ref: String = "main") throws -> GitHubSkillSource {
        try GitHubSkillSource(owner: owner, repository: repository, ref: ref, path: catalogPath(for: channel))
    }

    /// A curated operation may only read the fixed hub repository at one of
    /// the two channel catalog paths. Model-supplied URLs are never accepted.
    public static func validateSource(_ source: GitHubSkillSource, for channel: CuratedSkillChannel) throws {
        guard source.owner == owner, source.repository == repository,
              source.path == catalogPath(for: channel) else {
            throw CuratedSkillHubFailure.source(
                "curated skills download only from \(hubRepository) at a channel catalog path")
        }
    }

    /// The compiled production trust. Never mutated, never extended.
    public static var productionTrustedKeys: [String: Data] { OfficialSkillHub.trustedKeys }

    public static func trustedKeys(for mode: CuratedSkillTrustMode) throws -> [String: Data] {
        switch mode {
        case .production:
            return OfficialSkillHub.trustedKeys
        case .fixtureTestOnly(let publicKey):
            guard publicKey.count == 32 else {
                throw CuratedSkillHubFailure.trust("fixture test key must be a 32-byte raw Ed25519 public key")
            }
            return [fixtureKeyID: publicKey]
        }
    }

    // MARK: Feed verification (pure, synchronous)

    public struct VerifiedFeed: Sendable, Equatable {
        public let feed: CuratedSkillFeed
        /// Envelope identity that verified the exact bytes.
        public let keyID: String
        /// SHA-256 of the exact fetched feed bytes (the catalog digest kept
        /// in receipts and displayed alongside the publication pin).
        public let catalogSHA256: String
        public let byteCount: Int
    }

    /// Verifies the exact-bytes signature and then strictly decodes and
    /// validates the feed, enforcing the trust-mode/feedStatus coupling:
    /// production trust verifies production feeds only; explicit fixture test
    /// trust verifies fixture feeds only (contract §6.2).
    public static func verifiedFeed(
        bytes: Data,
        signature: Data,
        channel: CuratedSkillChannel,
        mode: CuratedSkillTrustMode
    ) throws -> VerifiedFeed {
        guard bytes.count <= maximumFeedBytes else {
            throw CuratedSkillHubFailure.feed("feed exceeds the \(maximumFeedBytes)-byte bound")
        }
        let envelope = try CuratedSkillEnvelope.decode(signature)
        let keys = try trustedKeys(for: mode)
        switch mode {
        case .production:
            guard envelope.keyID != fixtureKeyID else {
                throw CuratedSkillHubFailure.trust("the fixture identity can never verify a production feed")
            }
        case .fixtureTestOnly:
            guard envelope.keyID == fixtureKeyID else {
                throw CuratedSkillHubFailure.trust("explicit fixture test trust only accepts the fixture identity")
            }
        }
        do {
            _ = try SignedContentFeedVerifier.verifyEnvelope(
                bytes: bytes, signature: signature, trustedKeys: keys,
                maximumBytes: maximumFeedBytes
            )
        } catch {
            throw CuratedSkillHubFailure.signature("signature is invalid over the exact fetched bytes")
        }
        let feed = try CuratedSkillFeed.decode(bytes: bytes, expectedChannel: channel)
        switch mode {
        case .production:
            guard feed.feedStatus == .production else {
                throw CuratedSkillHubFailure.trust("a fixture feed can never activate a production channel")
            }
        case .fixtureTestOnly:
            guard feed.feedStatus == .fixture else {
                throw CuratedSkillHubFailure.trust("explicit fixture test trust never verifies a production feed")
            }
        }
        return VerifiedFeed(
            feed: feed, keyID: envelope.keyID,
            catalogSHA256: FloeDigest.sha256Hex(bytes), byteCount: bytes.count
        )
    }

    // MARK: Offer state, cards and honest counts

    public enum OfferState: Sendable, Equatable {
        /// Valid ready production offer — the only state that may show a
        /// "获取 / Get" action under production trust.
        case installable
        /// Fixture-simulated offer, installable only inside the explicit
        /// contract-test trust. Never a production meaning.
        case simulatedFixture
        /// 暂不可用 / Unavailable — never a Get action.
        case unavailable(reason: String)
        /// The entry needs a newer app than the running one.
        case incompatibleApp(minimumAppVersion: String)
    }

    public static func offerState(
        for entry: CuratedSkillEntry,
        mode: CuratedSkillTrustMode,
        appVersion: String
    ) -> OfferState {
        let offerGate: OfferState
        switch entry.installOffer {
        case .qualified:
            if case .production = mode {
                offerGate = .installable
            } else {
                offerGate = .unavailable(reason: "qualified offers require production trust")
            }
        case .fixtureSimulated:
            if case .fixtureTestOnly = mode {
                offerGate = .simulatedFixture
            } else {
                offerGate = .unavailable(reason: "fixture-simulated offers are contract-test only")
            }
        case .none:
            offerGate = .unavailable(reason: "no install offer for this candidate")
        }
        switch offerGate {
        case .installable, .simulatedFixture:
            if let minimum = entry.minimumAppVersion {
                guard let app = try? SignedContentVersion(appVersion),
                      let floor = try? SignedContentVersion(minimum) else {
                    return .unavailable(reason: "version compatibility cannot be evaluated")
                }
                if app < floor { return .incompatibleApp(minimumAppVersion: minimum) }
            }
            return offerGate
        default:
            return offerGate
        }
    }

    /// One card row for the native Hub UI. All display facts come from the
    /// verified feed itself; counts and availability are per-entry, never a
    /// hardcoded candidate total.
    public struct Card: Sendable, Equatable {
        public let entry: CuratedSkillEntry
        public let offer: OfferState

        public var displayName: CuratedSkillLocalizedText { entry.name }
        public var displayDescription: CuratedSkillLocalizedText { entry.description }

        /// True only when a Get action may be shown under this trust mode.
        public var showsInstallAction: Bool {
            offer == .installable || offer == .simulatedFixture
        }
    }

    public static func cards(
        feed: CuratedSkillFeed, mode: CuratedSkillTrustMode, appVersion: String
    ) -> [Card] {
        feed.entries.map { entry in
            Card(entry: entry, offer: offerState(for: entry, mode: mode, appVersion: appVersion))
        }
    }

    /// Honest source count: entries with an actually qualifying offer right
    /// now — not the candidate total and not a hardcoded 43.
    public static func installableOfferCount(
        feed: CuratedSkillFeed, mode: CuratedSkillTrustMode, appVersion: String
    ) -> Int {
        cards(feed: feed, mode: mode, appVersion: appVersion)
            .filter { $0.offer == .installable || $0.offer == .simulatedFixture }
            .count
    }

    /// Localized substring search over id, tags, bilingual name/description
    /// and the category id. Empty queries return all cards.
    public static func searchCards(
        feed: CuratedSkillFeed, mode: CuratedSkillTrustMode, appVersion: String,
        query: String, preferredLanguages: [String] = Locale.preferredLanguages
    ) -> [Card] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let all = cards(feed: feed, mode: mode, appVersion: appVersion)
        guard !needle.isEmpty else { return all }
        return all.filter { card in
            let haystacks = [
                card.entry.id,
                card.entry.category.rawValue,
                card.entry.name.value(preferredLanguages: preferredLanguages),
                card.entry.description.value(preferredLanguages: preferredLanguages),
                card.entry.tags.joined(separator: " "),
            ]
            return haystacks.contains { $0.lowercased().contains(needle) }
        }
    }

    // MARK: Publication (resolve Y once, fetch everything at Y)

    /// One immutable publication of one channel: the ref resolution result Y
    /// plus the exact-bytes-verified feed. The audited source X stays visible
    /// as provenance only (`feed.sourceCommit`) and is never a fetch pin.
    public struct Publication: Sendable {
        public let source: GitHubSkillSource
        /// Y — the resolved immutable commit whose tree carries every artifact.
        public let publicationCommit: String
        public let verifiedFeed: VerifiedFeed
        public let mode: CuratedSkillTrustMode
        /// X — signed provenance (nil only in fixture feeds). Never used to
        /// locate artifacts and never required to equal Y.
        public var auditedSourceCommit: String? { verifiedFeed.feed.sourceCommit }
        public var feed: CuratedSkillFeed { verifiedFeed.feed }
    }

    /// Resolves the pinned ref exactly once to Y, fetches the channel feed
    /// and its signature at Y, and verifies them under the given trust mode.
    /// A failed fetch or missing signature is an `.unavailable`/`.signature`
    /// error — never a fabricated valid empty feed and never a silent trust
    /// of the unsigned registry.
    public static func loadPublication(
        channel: CuratedSkillChannel,
        mode: CuratedSkillTrustMode,
        ref: String = "main",
        resolve: GitHubSkillDownload.ResolveCommit,
        fetch: GitHubSkillDownload.FetchFile
    ) async throws -> Publication {
        let source = try source(channel: channel, ref: ref)
        try validateSource(source, for: channel)
        let commit: String
        do {
            commit = try await resolve(source)
        } catch {
            throw CuratedSkillHubFailure.unavailable(
                "publication ref could not be resolved: \(error.localizedDescription)")
        }
        guard commit.count == 40, commit.allSatisfy(\.isHexDigit) else {
            throw CuratedSkillHubFailure.source("resolve did not return an immutable 40-hex commit")
        }
        let catalogBytes: Data
        do {
            catalogBytes = try await fetch(source, commit, catalogPath(for: channel))
        } catch {
            throw CuratedSkillHubFailure.unavailable(
                "channel feed is not present at the pinned publication: \(error.localizedDescription)")
        }
        let signatureBytes: Data
        do {
            signatureBytes = try await fetchSignatureBytes(
                source: source, commit: commit, signaturePath: signaturePath(for: channel), fetch: fetch)
        } catch let failure as CuratedSkillHubFailure {
            throw failure
        } catch {
            throw CuratedSkillHubFailure.unavailable(
                "channel signature is not present at the pinned publication: \(error.localizedDescription)")
        }
        let verified = try verifiedFeed(
            bytes: catalogBytes, signature: signatureBytes, channel: channel, mode: mode)
        return Publication(source: source, publicationCommit: commit, verifiedFeed: verified, mode: mode)
    }

    // MARK: Staged result types

    /// Immutable, caller-owned staging result. Files live under a fresh
    /// staging root created by this call; nothing was installed, enabled or
    /// granted. Same-run reads of the staged snapshot see immutable bytes
    /// (the digest-verified `SkillContentSnapshot` keeps its own copies).
    public struct StagedSkill: Sendable {
        public let content: SkillContentSnapshot
        public let archiveSHA256: String
        public let reviewRecordSHA256: String
        public let permissionDelta: CuratedSkillPermissionDelta
        public let receipt: Receipt
    }

    /// The reviewed receipt: every identity a later store write needs, with
    /// X and Y kept separate and the full digest binding chain recorded.
    public struct Receipt: Codable, Sendable, Equatable {
        public let receiptSchemaVersion: Int
        public let channel: CuratedSkillChannel
        public let feedStatus: CuratedSkillFeedStatus
        public let hubRepository: String
        public let publisher: String
        public let feedSignatureKeyID: String
        /// Audited source revision X (signed provenance; nil only in fixture feeds).
        public let auditedSourceCommit: String?
        /// Immutable publication revision Y every artifact was fetched at.
        public let publicationCommit: String
        public let catalogSHA256: String
        public let catalogByteCount: Int
        public let entryID: String
        public let entryVersion: String
        public let packagePath: String
        public let packageSize: Int
        public let packageSHA256: String
        public let contentDigest: String
        public let containsScripts: Bool
        public let reviewPath: String
        public let reviewSHA256: String
        public let reviewKeyID: String
        public let reviewStage: CuratedSkillReviewStage
        public let reviewDecision: CuratedSkillReviewDecision
        public let reviewedAt: String
        public let reviewer: String
        public let permissionDelta: CuratedSkillPermissionDelta

        /// Retrieval evidence for the caller's own persistence. This is
        /// deliberately NOT a generic GitHub folder-update binding: curated
        /// installs are the signed ZIP plus review chain fetched at the
        /// immutable `publicationCommit` Y through `CuratedSkillHub.stage`
        /// only. If the caller records a `SkillGitHubBinding`, it must carry
        /// the curated channel catalog source and Y as provenance — never as
        /// an instruction for the recursive directory updater, which reads a
        /// loose SKILL.md source tree and has no signature/digest/review
        /// chain meaning here.
        public var curatedRetrievalEvidence: CuratedSkillRetrievalEvidence {
            CuratedSkillRetrievalEvidence(
                publicationCommit: publicationCommit,
                catalogSHA256: catalogSHA256,
                contentDigest: contentDigest)
        }
    }

    /// Typed immutable retrieval facts of one curated operation (Y, catalog
    /// digest, canonical package digest). Provenance only — not an update
    /// route.
    public struct CuratedSkillRetrievalEvidence: Sendable, Equatable {
        public let publicationCommit: String
        public let catalogSHA256: String
        public let contentDigest: String

        public init(publicationCommit: String, catalogSHA256: String, contentDigest: String) {
            self.publicationCommit = publicationCommit
            self.catalogSHA256 = catalogSHA256
            self.contentDigest = contentDigest
        }
    }

    /// Verifies the full §6 chain for one entry and stages the immutable
    /// snapshot plus typed receipt. Requires a `loadPublication` result from
    /// the SAME run — every fetch here uses `publication.publicationCommit`,
    /// so one operation is pinned to one Y even if the branch moves.
    ///
    /// The caller supplies the existing effective grants (from the current
    /// native permission storage) purely to compute the verified delta; no
    /// grant is written here, and no blanket approval is implied.
    public static func stage(
        _ publication: Publication,
        entryID: String,
        appVersion: String,
        at root: URL,
        effectiveCapabilities: Set<String> = [],
        effectiveTools: Set<String> = [],
        effectivePythonPackageSpecs: Set<String> = [],
        fetch: GitHubSkillDownload.FetchFile
    ) async throws -> StagedSkill {
        let verified = publication.verifiedFeed
        let feed = verified.feed
        guard let entry = feed.entry(id: entryID) else {
            throw CuratedSkillHubFailure.offer("entry '\(entryID)' is not part of the pinned publication")
        }
        switch offerState(for: entry, mode: publication.mode, appVersion: appVersion) {
        case .installable, .simulatedFixture:
            break
        case .unavailable(let reason):
            throw CuratedSkillHubFailure.offer(reason)
        case .incompatibleApp(let minimum):
            throw CuratedSkillHubFailure.compatibility("minimum app version \(minimum)")
        }
        guard let binding = entry.package else {
            throw CuratedSkillHubFailure.offer("entry has no signed package binding")
        }
        guard let reviewBinding = entry.review else {
            throw CuratedSkillHubFailure.offer("entry has no signed review binding; unqualified content cannot install")
        }
        let commit = publication.publicationCommit
        let archive: Data
        do {
            archive = try await fetch(publication.source, commit, binding.path)
        } catch {
            throw CuratedSkillHubFailure.unavailable(
                "package archive is not present at the pinned publication: \(error.localizedDescription)")
        }
        guard archive.count == binding.size else {
            throw CuratedSkillHubFailure.archive(
                "archive size \(archive.count) does not match the signed size \(binding.size)")
        }
        let archiveSHA256 = FloeDigest.sha256Hex(archive)
        guard archiveSHA256 == binding.sha256.lowercased() else {
            throw CuratedSkillHubFailure.archive("archive bytes do not match the signed sha256")
        }
        // Bounded safe unpack through the EXISTING shared gates
        // (SignedContentArchive extraction bounds + SkillPackageValidator).
        let snapshot: SkillContentSnapshot
        do {
            snapshot = try OfficialSkillHub.unpack(archive, at: root)
        } catch {
            throw mapExtractionFailure(error)
        }
        guard snapshot.package.canonicalSHA256 == binding.contentDigest.lowercased() else {
            try? FileManager.default.removeItem(at: root)
            throw CuratedSkillHubFailure.digest(
                "unpacked canonical digest does not match the signed contentDigest")
        }
        do {
            let reviewBytes: Data
            do {
                reviewBytes = try await fetch(publication.source, commit, reviewBinding.path)
            } catch {
                throw CuratedSkillHubFailure.unavailable(
                    "review record is not present at the pinned publication: \(error.localizedDescription)")
            }
            let reviewSignature: Data
            do {
                reviewSignature = try await fetchSignatureBytes(
                    source: publication.source, commit: commit,
                    signaturePath: reviewBinding.path + ".sig", fetch: fetch)
            } catch let failure as CuratedSkillHubFailure {
                throw failure
            } catch {
                throw CuratedSkillHubFailure.unavailable(
                    "review signature is not present at the pinned publication: \(error.localizedDescription)")
            }
            let envelope = try CuratedSkillEnvelope.decode(reviewSignature)
            guard envelope.keyID == reviewBinding.keyID else {
                throw CuratedSkillHubFailure.signature(
                    "review envelope keyID '\(envelope.keyID)' does not match the bound identity '\(reviewBinding.keyID)'")
            }
            let reviewKeys = try trustedKeys(for: publication.mode)
            do {
                _ = try SignedContentFeedVerifier.verifyEnvelope(
                    bytes: reviewBytes, signature: reviewSignature, trustedKeys: reviewKeys,
                    maximumBytes: SignedContentFeedVerifier.maximumFeedBytes)
            } catch {
                throw CuratedSkillHubFailure.signature("review record signature is invalid over the exact bytes")
            }
            let reviewSHA256 = FloeDigest.sha256Hex(reviewBytes)
            guard reviewSHA256 == reviewBinding.sha256.lowercased() else {
                throw CuratedSkillHubFailure.digest(
                    "review record bytes do not match the binding sha256; a changed review needs a new publication")
            }
            let record = try CuratedSkillReviewRecord.decode(bytes: reviewBytes)
            try CuratedSkillReviewJoin.verify(
                record: record, against: entry, actual: snapshot.package,
                archiveSHA256: archiveSHA256, feedChannel: feed.channel)
            let delta = CuratedSkillPermissionDelta.from(
                actualManifest: snapshot.package.manifest,
                effectiveCapabilities: effectiveCapabilities,
                effectiveTools: effectiveTools,
                effectivePythonPackageSpecs: effectivePythonPackageSpecs)
            let receipt = Receipt(
                receiptSchemaVersion: 1,
                channel: feed.channel,
                feedStatus: feed.feedStatus,
                hubRepository: feed.hubRepository,
                publisher: feed.publisher,
                feedSignatureKeyID: verified.keyID,
                auditedSourceCommit: feed.sourceCommit,
                publicationCommit: commit,
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
                reviewSHA256: reviewSHA256,
                reviewKeyID: reviewBinding.keyID,
                reviewStage: record.reviewStage,
                reviewDecision: record.decision,
                reviewedAt: record.reviewedAt,
                reviewer: record.reviewer,
                permissionDelta: delta
            )
            return StagedSkill(
                content: snapshot, archiveSHA256: archiveSHA256,
                reviewRecordSHA256: reviewSHA256, permissionDelta: delta, receipt: receipt)
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    // MARK: - Internals

    static func mapExtractionFailure(_ error: Error) -> CuratedSkillHubFailure {
        if let failure = error as? OfficialSkillHub.Failure {
            switch failure {
            case .archive: return .archive("the shared archive gate rejected the package")
            case .catalog: return .digest("the package failed its signed identity contract")
            case .signature: return .signature("the shared envelope verifier rejected the package")
            case .immutableVersion: return .immutableVersion("same-version content changed")
            case .incompatible: return .compatibility("the package declares an unsupported runtime")
            case .source: return .source("the package source identity drifted")
            }
        }
        if let validation = error as? SkillValidationError {
            return .archive(validation.errorDescription ?? "package gate rejected the content")
        }
        if let signed = error as? SignedContentFailure {
            return .archive(signed.errorDescription ?? "archive staging rejected the content")
        }
        return .archive(error.localizedDescription)
    }

    /// Fetches the exact sidecar path declared by the catalog/review contract. When the transport returns content that is
    /// not a signature envelope for that guess (some proxies answer missing
    /// raw files with a JSON 404 body), the client discovers the real entry
    /// through the pinned GitHub directory listing at the SAME commit Y and
    /// verifies the blob integrity, mirroring the existing read-pin flow.
    private static func fetchSignatureBytes(
        source: GitHubSkillSource,
        commit: String,
        signaturePath: String,
        fetch: GitHubSkillDownload.FetchFile
    ) async throws -> Data {
        if let direct = try? await fetch(source, commit, signaturePath),
           (try? CuratedSkillEnvelope.decode(direct)) != nil {
            return direct
        }
        let directory = signaturePath.split(separator: "/", omittingEmptySubsequences: false)
            .dropLast().map(String.init).joined(separator: "/")
        guard !directory.isEmpty else {
            if let direct = try? await fetch(source, commit, signaturePath) { return direct }
            throw CuratedSkillHubFailure.unavailable("signature is not present at the pinned publication: \(signaturePath)")
        }
        let listingBytes: Data
        do {
            listingBytes = try await fetch(source, commit, directory)
        } catch {
            if let direct = try? await fetch(source, commit, signaturePath) { return direct }
            throw CuratedSkillHubFailure.unavailable(
                "signature directory is unavailable: \(error.localizedDescription)")
        }
        struct ListingEntry: Decodable {
            let name: String
            let path: String
            let type: String
            let sha: String?
            let target: String?
        }
        guard listingBytes.count <= maximumDirectoryListingBytes,
              let entries = try? JSONDecoder().decode([ListingEntry].self, from: listingBytes) else {
            if let direct = try? await fetch(source, commit, signaturePath) { return direct }
            throw CuratedSkillHubFailure.unavailable("signature directory listing is invalid")
        }
        let expectedName = signaturePath.split(separator: "/").last.map(String.init) ?? signaturePath
        guard let entry = entries.first(where: { $0.name == expectedName && $0.type == "file" }),
              entry.target == nil,
              entry.path == directory + "/" + entry.name else {
            if let direct = try? await fetch(source, commit, signaturePath) { return direct }
            throw CuratedSkillHubFailure.unavailable("signature entry is absent from the pinned listing: \(signaturePath)")
        }
        let bytes: Data
        do {
            bytes = try await fetch(source, commit, entry.path)
        } catch {
            throw CuratedSkillHubFailure.unavailable(
                "signature fetch failed at the pinned publication: \(error.localizedDescription)")
        }
        if let blobSHA = entry.sha, blobSHA.count == 40, blobSHA.allSatisfy(\.isHexDigit) {
            var blob = Insecure.SHA1()
            blob.update(data: Data("blob \(bytes.count)\u{00}".utf8))
            blob.update(data: bytes)
            guard blob.finalize().map({ String(format: "%02x", $0) }).joined() == blobSHA.lowercased() else {
                throw CuratedSkillHubFailure.digest("signature blob failed the pinned Git integrity check")
            }
        }
        return bytes
    }
}

// MARK: - Signature envelope

/// `{"keyID": <string>, "signature": <base64 Ed25519 over the exact payload
/// bytes>}` with an EXACT key set (mirrors `hubcore.verify_envelope`). The
/// crypto check itself reuses `SignedContentFeedVerifier`.
public struct CuratedSkillEnvelope: Sendable, Equatable {
    public let keyID: String
    public let signature: String

    public static func decode(_ bytes: Data) throws -> CuratedSkillEnvelope {
        guard bytes.count <= SignedContentFeedVerifier.maximumSignatureBytes else {
            throw CuratedSkillHubFailure.signature("signature envelope exceeds its bound")
        }
        let object: [String: Any]
        do {
            object = try CuratedSkillStrictJSON.object(bytes)
        } catch {
            throw CuratedSkillHubFailure.signature("signature envelope is not a JSON object")
        }
        do {
            try CuratedSkillStrictJSON.exactKeys(object, required: ["keyID", "signature"], path: "envelope")
        } catch {
            throw CuratedSkillHubFailure.signature("signature envelope keys must be exactly keyID + signature")
        }
        let keyID: String
        let signature: String
        do {
            keyID = try CuratedSkillStrictJSON.string(object["keyID"], path: "envelope.keyID")
            signature = try CuratedSkillStrictJSON.string(object["signature"], path: "envelope.signature")
        } catch {
            throw CuratedSkillHubFailure.signature("signature envelope fields must be strings")
        }
        guard !keyID.isEmpty, Data(base64Encoded: signature) != nil else {
            throw CuratedSkillHubFailure.signature("signature envelope is malformed")
        }
        return CuratedSkillEnvelope(keyID: keyID, signature: signature)
    }
}
