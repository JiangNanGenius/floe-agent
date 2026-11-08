import Foundation

public enum GitHubTransportMirrorID: String, Codable, Sendable, CaseIterable {
    case ghfast = "ghfast.top"
    case ghProxy = "gh-proxy.com"

    var prefix: String { "https://\(rawValue)/" }
}

public struct GitHubTransportMirrorRoles: Codable, Sendable, Equatable {
    public let rawFiles: [GitHubTransportMirrorID]
    public let atom: [GitHubTransportMirrorID]
    public let releaseAssets: [GitHubTransportMirrorID]

    public init(rawFiles: [GitHubTransportMirrorID], atom: [GitHubTransportMirrorID],
                releaseAssets: [GitHubTransportMirrorID]) {
        self.rawFiles = rawFiles; self.atom = atom; self.releaseAssets = releaseAssets
    }

    public static let bundled = Self(rawFiles: [.ghfast, .ghProxy], atom: [.ghProxy], releaseAssets: [])
}

public enum GitHubTransportManifestFailure: Error, Equatable, Sendable {
    case bounds, signature, shape, canonical, time, expired, rollback, generationReused
    case storage, unavailable, cancelled
}

/// A signed list can only order or disable already compiled transport IDs.
/// It cannot supply endpoints, keys, content identities or permissions.
public struct GitHubTransportMirrorManifest: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let purpose: String
    public let generation: Int64
    public let issuedAt: String
    public let expiresAt: String
    public let roles: GitHubTransportMirrorRoles

    public static let payloadPath = "transport/mirrors.v1.json"
    public static let signaturePath = "transport/mirrors.v1.json.sig"
    public static let maximumPayloadBytes = 16_384
    public static let maximumSignatureBytes = 8_192
    public static let maximumGeneration: Int64 = 9_007_199_254_740_991
    public static let domain = Data("FLOE-GITHUB-TRANSPORT-MIRRORS-V1\n".utf8)

    public struct Verified: Sendable {
        public let manifest: GitHubTransportMirrorManifest
        public let payload: Data
        public let signature: Data
        public let keyID: String
        public let expiry: Date
        public let issued: Date
    }

    /// Crypto runs on the exact domain-prefixed payload before interpreting
    /// configuration values. Cache history may be expired, never activated.
    public static func verify(
        payload: Data, signature: Data, now: Date,
        mode: CuratedSkillTrustMode = .production,
        allowExpiredHistory: Bool = false
    ) throws -> Verified {
        guard !payload.isEmpty, payload.count <= maximumPayloadBytes,
              !signature.isEmpty, signature.count <= maximumSignatureBytes else {
            throw GitHubTransportManifestFailure.bounds
        }
        let keyID: String
        do {
            let envelope = try CuratedSkillEnvelope.decode(signature)
            let keys = try CuratedSkillHub.trustedKeys(for: mode)
            _ = try SignedContentFeedVerifier.verifyEnvelope(
                bytes: domain + payload, signature: signature, trustedKeys: keys,
                maximumBytes: maximumPayloadBytes + domain.count)
            keyID = envelope.keyID
        } catch { throw GitHubTransportManifestFailure.signature }
        let value: Self
        do { value = try JSONDecoder().decode(Self.self, from: payload) }
        catch { throw GitHubTransportManifestFailure.shape }
        guard value.schemaVersion == 1, value.purpose == "floe-github-transport-mirrors",
              (1...maximumGeneration).contains(value.generation),
              [value.roles.rawFiles, value.roles.atom, value.roles.releaseAssets].allSatisfy({
                  $0.count <= 2 && Set($0).count == $0.count
              }) else { throw GitHubTransportManifestFailure.shape }
        // Re-encoding the typed six-key model also rejects unknown/duplicate
        // keys, bool/float integers, BOM, whitespace and escaped aliases.
        guard payload.allSatisfy({ $0 < 128 }),
              let canonical = try? value.canonicalBytes(), canonical == payload else {
            throw GitHubTransportManifestFailure.canonical
        }
        guard let issued = timestamp(value.issuedAt), let expiry = timestamp(value.expiresAt),
              expiry > issued, expiry.timeIntervalSince(issued) <= 30 * 86_400,
              issued.timeIntervalSince(now) <= 300 else {
            throw GitHubTransportManifestFailure.time
        }
        guard allowExpiredHistory || expiry > now else { throw GitHubTransportManifestFailure.expired }
        return Verified(manifest: value, payload: payload, signature: signature, keyID: keyID, expiry: expiry, issued: issued)
    }

    public func canonicalBytes() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self) + Data([10])
    }

    private static func timestamp(_ text: String) -> Date? {
        guard text.utf8.count == 20 else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.isLenient = false
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        guard let date = formatter.date(from: text), formatter.string(from: date) == text else { return nil }
        return date
    }
}

/// App-owned policy cache. It outlives individual downloads/views; rejected
/// refreshes never modify the last verified record or the generation floor.
public actor GitHubTransportMirrorPolicyStore {
    public struct Downloaded: Sendable {
        public let payload: Data
        public let signature: Data
        public init(payload: Data, signature: Data) { self.payload = payload; self.signature = signature }
    }
    public struct Snapshot: Sendable {
        public let roles: GitHubTransportMirrorRoles
        public let generation: Int64?
        public let highestGeneration: Int64
        public let usesBundledDefaults: Bool
        public let diagnostic: GitHubTransportManifestFailure?
    }
    private struct Record: Codable {
        let schemaVersion: Int
        let highestGeneration: Int64
        let payload: Data
        let signature: Data
    }
    private struct Flight: Sendable {
        let id: UUID
        let task: Task<Void, Never>
    }
    private let persistenceURL: URL?
    private let trustMode: CuratedSkillTrustMode
    private let clock: @Sendable () -> Date
    private var loaded = false
    private var persistenceBlocked = false
    private var highestGeneration: Int64 = 0
    private var verified: GitHubTransportMirrorManifest.Verified?
    private var lastAttempt: Date?
    private var diagnostic: GitHubTransportManifestFailure?
    private var flight: Flight?

    public init(persistenceURL: URL?, mode: CuratedSkillTrustMode = .production,
                clock: @escaping @Sendable () -> Date = { Date() }) {
        self.persistenceURL = persistenceURL; self.trustMode = mode; self.clock = clock
    }

    public func snapshot() -> Snapshot {
        loadOnce()
        let now = clock()
        if let verified, verified.expiry > now, verified.issued.timeIntervalSince(now) <= 300 {
            return Snapshot(roles: verified.manifest.roles, generation: verified.manifest.generation,
                            highestGeneration: highestGeneration, usesBundledDefaults: false,
                            diagnostic: diagnostic)
        }
        return Snapshot(roles: .bundled, generation: nil, highestGeneration: highestGeneration,
                        usesBundledDefaults: true, diagnostic: diagnostic)
    }

    /// Nonblocking normal-use refresh; discovery must use compiled routes,
    /// never this store, so a downloaded policy cannot recursively bootstrap.
    public func policyRefreshingIfNeeded(
        download: @escaping @Sendable () async throws -> Downloaded
    ) -> Snapshot {
        let current = snapshot()
        let now = clock()
        if flight == nil, lastAttempt == nil || now.timeIntervalSince(lastAttempt!) >= 6 * 3_600
            || lastAttempt!.timeIntervalSince(now) > 300 {
            lastAttempt = now
            let id = UUID()
            let task = Task { [weak self] in
                do {
                    let bytes = try await download()
                    try Task.checkCancellation()
                    await self?.finish(id: id, bytes: bytes)
                } catch {
                    await self?.fail(id: id, failure: error is CancellationError ? .cancelled : .unavailable)
                }
            }
            flight = Flight(id: id, task: task)
        }
        return current
    }

    public func cancelRefresh() async {
        guard let current = flight else { return }
        current.task.cancel()
        await current.task.value
        if flight?.id == current.id { flight = nil }
    }

    deinit { flight?.task.cancel() }

    // Internal qualification hook; production reads do not wait on refresh.
    func waitForRefresh() async { await flight?.task.value }

    private func loadOnce() {
        guard !loaded else { return }; loaded = true
        guard let persistenceURL else { persistenceBlocked = true; diagnostic = .storage; return }
        guard FileManager.default.fileExists(atPath: persistenceURL.path) else { return }
        do {
            guard (try persistenceURL.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink != true else {
                throw GitHubTransportManifestFailure.storage
            }
            let handle = try FileHandle(forReadingFrom: persistenceURL)
            defer { try? handle.close() }
            let data = try handle.read(upToCount: 65_537) ?? Data()
            guard data.count <= 65_536 else { throw GitHubTransportManifestFailure.storage }
            let record = try JSONDecoder().decode(Record.self, from: data)
            guard record.schemaVersion == 1 else { throw GitHubTransportManifestFailure.storage }
            let item = try GitHubTransportMirrorManifest.verify(payload: record.payload,
                signature: record.signature, now: clock(), mode: trustMode, allowExpiredHistory: true)
            guard record.highestGeneration == item.manifest.generation else {
                throw GitHubTransportManifestFailure.storage
            }
            highestGeneration = record.highestGeneration; verified = item
        } catch {
            // Preserve a corrupt/unreadable record rather than silently
            // resetting a potentially higher persisted floor.
            persistenceBlocked = true; diagnostic = .storage
        }
    }

    private func finish(id: UUID, bytes: Downloaded) {
        guard flight?.id == id else { return }
        defer { flight = nil }
        guard !Task.isCancelled else { diagnostic = .cancelled; return }
        do {
            let item = try GitHubTransportMirrorManifest.verify(payload: bytes.payload,
                signature: bytes.signature, now: clock(), mode: trustMode)
            guard item.manifest.generation >= highestGeneration else { throw GitHubTransportManifestFailure.rollback }
            if item.manifest.generation == highestGeneration {
                guard let verified, verified.payload == bytes.payload else {
                    throw GitHubTransportManifestFailure.generationReused
                }
                diagnostic = nil; return // byte-identical refresh is a no-op
            }
            guard !persistenceBlocked, let persistenceURL else { throw GitHubTransportManifestFailure.storage }
            let record = Record(schemaVersion: 1, highestGeneration: item.manifest.generation,
                                payload: bytes.payload, signature: bytes.signature)
            do {
                try FileManager.default.createDirectory(at: persistenceURL.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                try JSONEncoder().encode(record).write(to: persistenceURL, options: .atomic)
            } catch {
                persistenceBlocked = true
                throw GitHubTransportManifestFailure.storage
            }
            // No suspension between durable commit and publishing the new
            // floor/LKG. Cancellation cannot interleave a half-adoption.
            highestGeneration = item.manifest.generation; verified = item; diagnostic = nil
        } catch {
            diagnostic = (error as? GitHubTransportManifestFailure) ?? .storage
        }
    }

    private func fail(id: UUID, failure: GitHubTransportManifestFailure) {
        guard flight?.id == id else { return }
        flight = nil; diagnostic = failure
    }
}
