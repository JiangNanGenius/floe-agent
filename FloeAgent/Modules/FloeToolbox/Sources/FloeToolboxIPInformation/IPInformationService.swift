// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeToolboxDiagnostics

public actor IPInformationService {
    /// Off-main restoration verifies saved bytes once before exposing a version.
    /// The App owns this factory task; no view owns the service's update jobs.
    public static func open(storageRoot: URL) async throws -> IPInformationService {
        try await Task.detached(priority: .utility) { try IPInformationService(storageRoot: storageRoot) }.value
    }
    private struct Cached { let value: IPInformationRecord?; var used: UInt64 }
    private struct Lookup { let id: UUID; let snapshotID: UUID; let task: Task<IPInformationRecord?, Error> }
    private let root: URL
    private let download: IPDatabaseDownload
    private let language: String
    private var snapshot: IPDatabaseSnapshot?
    private var cache: [String: Cached] = [:]
    private var lookups: [String: Lookup] = [:]
    private var clock: UInt64 = 0
    private var observers: [UUID: AsyncStream<IPInformationState>.Continuation] = [:]
    private var jobs: [UUID: Task<IPDatabaseMetadata, Error>] = [:]
    private var history: [UUID] = []
    private var activeUpdate: UUID?
    private var lastState: IPInformationState
    // Internal test seams suspend actual file/reader work without replacing it.
    var beforeLookup: (@Sendable () async -> Void)?
    var beforeCommit: (@Sendable () async -> Void)?
    private(set) var readerLookups = 0
    func testHooks(beforeLookup: (@Sendable () async -> Void)? = nil, beforeCommit: (@Sendable () async -> Void)? = nil) {
        self.beforeLookup = beforeLookup; self.beforeCommit = beforeCommit
    }

    public init(storageRoot: URL) throws {
        root = try IPDatabaseStorage.prepareRoot(storageRoot)
        snapshot = try IPDatabaseStorage.load(root)
        download = IPDatabaseNetwork.download
        language = Locale.current.language.languageCode?.identifier == "zh" ? "zh-CN" : "en"
        lastState = IPInformationState(phase: snapshot == nil ? .empty : .ready, operationID: nil,
            downloadedBytes: 0, totalBytes: nil, metadata: snapshot?.metadata, message: nil)
    }
    init(storageRoot: URL, download: @escaping IPDatabaseDownload) throws {
        root = try IPDatabaseStorage.prepareRoot(storageRoot)
        snapshot = try IPDatabaseStorage.load(root); self.download = download; language = "en"
        lastState = IPInformationState(phase: snapshot == nil ? .empty : .ready, operationID: nil,
            downloadedBytes: 0, totalBytes: nil, metadata: snapshot?.metadata, message: nil)
    }
    public func currentVersion() -> String? { snapshot?.metadata.datasetVersion }
    public func state() -> IPInformationState { lastState }
    public func updates() -> AsyncStream<IPInformationState> {
        let id = UUID(), pair = AsyncStream<IPInformationState>.makeStream(bufferingPolicy: .bufferingNewest(1))
        observers[id] = pair.continuation; pair.continuation.yield(lastState)
        pair.continuation.onTermination = { [weak self] _ in Task { await self?.removeObserver(id) } }
        return pair.stream
    }
    private func removeObserver(_ id: UUID) { observers.removeValue(forKey: id) }
    private func publish(_ phase: IPInformationState.Phase, operation: UUID?, bytes: Int64 = 0, message: String? = nil) {
        lastState = IPInformationState(phase: phase, operationID: operation, downloadedBytes: bytes,
            totalBytes: nil, metadata: snapshot?.metadata, message: message)
        for observer in observers.values { observer.yield(lastState) }
    }
    public nonisolated func tracerouteProvider() -> TracerouteIPInformationProvider {
        TracerouteIPInformationProvider(currentVersion: { await self.currentVersion() },
            isPublicInternetAddress: { try IPAddressClassification.classify($0) == .publicInternet },
            lookup: { address, version in
            guard let value = try await self.lookup(address, expectedVersion: version) else { return nil }
            return TracerouteIPInformation(address: address, region: value.regionSummary,
                autonomousSystemNumber: value.autonomousSystemNumber, organization: value.organization,
                source: value.source, datasetVersion: value.datasetVersion,
                latitude: value.latitude, longitude: value.longitude,
                accuracyRadiusKilometers: value.accuracyRadiusKilometers)
        })
    }
    public func lookup(_ address: String, expectedVersion: String? = nil) async throws -> IPInformationRecord? {
        try Task.checkCancellation()
        let numeric = try NumericIPAddress(address)
        guard numeric.classification == .publicInternet else { return nil }
        guard let snapshot else { return nil }
        let version = snapshot.metadata.datasetVersion
        guard expectedVersion == nil || expectedVersion == version else { return nil }
        let key = version + ":" + numeric.canonical
        clock &+= 1
        if var cached = cache[key] { cached.used = clock; cache[key] = cached; return cached.value?.addressed(address) }
        let pending: Lookup
        if let existing = lookups[key] { pending = existing }
        else {
            guard lookups.count < 16 else { throw IPInformationError.busy }
            let id = UUID(), hook = beforeLookup, language = language
            let task = Task.detached(priority: .utility) { () throws -> IPInformationRecord? in
                if let hook { await hook() }
                try Task.checkCancellation()
                return try snapshot.read(numeric.canonical, language: language)
            }
            pending = Lookup(id: id, snapshotID: snapshot.metadata.id, task: task)
            lookups[key] = pending; readerLookups += 1
        }
        do {
            let value = try await pending.task.value
            if lookups[key]?.id == pending.id { lookups.removeValue(forKey: key) }
            try Task.checkCancellation()
            guard self.snapshot?.metadata.datasetVersion == version else { return nil }
            clock &+= 1; cache[key] = Cached(value: value, used: clock)
            if cache.count > 512, let oldest = cache.min(by: { $0.value.used < $1.value.used })?.key { cache.removeValue(forKey: oldest) }
            return value?.addressed(address)
        } catch {
            if lookups[key]?.id == pending.id { lookups.removeValue(forKey: key) }
            throw error
        }
    }

    public func startDefaultUpdate() throws -> UUID { try startUpdate(release: .dbIPNovember2026) }
    public func startUpdate(release: IPDatabaseRelease) throws -> UUID {
        try release.validate()
        guard activeUpdate == nil else { throw IPInformationError.busy }
        if let metadata = snapshot?.metadata, metadata.source == "DB-IP Lite",
           metadata.releaseLabel == release.month, metadata.city.sha256 == release.city.sha256,
           metadata.asn.sha256 == release.asn.sha256 {
            let id = UUID(); jobs[id] = Task { metadata }; retainJob(id)
            publish(.ready, operation: id); return id
        }
        let id = UUID(); activeUpdate = id
        publish(.downloading, operation: id)
        jobs[id] = Task { try await self.performDownload(id: id, release: release) }
        retainJob(id)
        return id
    }
    public func startImport(city: URL, asn: URL, versionLabel: String,
                            source: String = "Imported MMDB", attribution: String = "User-imported data; retain the dataset's original license.",
                            licenseURL: URL? = nil) throws -> UUID {
        guard activeUpdate == nil else { throw IPInformationError.busy }
        guard city.isFileURL, asn.isFileURL, !versionLabel.isEmpty, versionLabel.utf8.count <= 80,
              !source.isEmpty, source.utf8.count <= 512, !attribution.isEmpty, attribution.utf8.count <= 1_024,
              licenseURL == nil || (licenseURL?.scheme == "https" && licenseURL?.user == nil && licenseURL?.password == nil) else { throw IPInformationError.invalidDatabase }
        let id = UUID(); activeUpdate = id; publish(.validating, operation: id)
        jobs[id] = Task { try await self.performImport(id: id, city: city, asn: asn,
            label: versionLabel, source: source, attribution: attribution, licenseURL: licenseURL) }
        retainJob(id)
        return id
    }
    public func waitForUpdate(_ id: UUID) async throws -> IPDatabaseMetadata {
        guard let task = jobs[id] else { throw IPInformationError.missingOperation }
        return try await task.value
    }
    public func cancelUpdate(_ id: UUID) { if activeUpdate == id { jobs[id]?.cancel() } }
    private func retainJob(_ id: UUID) {
        history.append(id)
        while history.count > 8 { jobs.removeValue(forKey: history.removeFirst()) }
    }
    private func progress(_ id: UUID, bytes: Int64) {
        if activeUpdate == id { publish(.downloading, operation: id, bytes: bytes) }
    }
    private func makeDirectory(_ id: UUID) throws -> URL {
        let directory = root.appendingPathComponent("Snapshots/" + id.uuidString, isDirectory: true)
        guard !FileManager.default.fileExists(atPath: directory.path) else { throw IPInformationError.invalidStorage }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }
    private func performImport(id: UUID, city: URL, asn: URL, label: String,
                               source: String, attribution: String, licenseURL: URL?) async throws -> IPDatabaseMetadata {
        let expected = snapshot?.metadata.id
        let directory: URL
        do { directory = try makeDirectory(id) }
        catch { failed(id, error: error); throw error }
        do {
            let prepared = try await Self.worker {
                let cityHash = try IPDatabaseStorage.copy(city, to: directory.appendingPathComponent("city.mmdb"))
                let asnHash = try IPDatabaseStorage.copy(asn, to: directory.appendingPathComponent("asn.mmdb"))
                return try IPDatabaseStorage.preparePair(directory: directory, label: label, source: source,
                    attribution: attribution, licenseURL: licenseURL, cityHash: cityHash, asnHash: asnHash)
            }
            return try await install(prepared, id: id, expected: expected)
        } catch {
            // The actual worker has joined before its staging bytes retire.
            try? FileManager.default.removeItem(at: directory); failed(id, error: error); throw error
        }
    }
    private func performDownload(id: UUID, release: IPDatabaseRelease) async throws -> IPDatabaseMetadata {
        let expected = snapshot?.metadata.id
        let directory: URL
        do { directory = try makeDirectory(id) }
        catch { failed(id, error: error); throw error }
        do {
            let city = try await archive(release.city, id: id, offset: 0)
            let size = try IPDatabaseStorage.regularFileSize(city, maximum: 128 * 1_024 * 1_024)
            let asn = try await archive(release.asn, id: id, offset: Int64(size))
            publish(.validating, operation: id)
            let prepared = try await Self.worker {
                let cityURL = directory.appendingPathComponent("city.mmdb"), asnURL = directory.appendingPathComponent("asn.mmdb")
                try IPDatabaseStorage.expand(city, to: cityURL); try IPDatabaseStorage.expand(asn, to: asnURL)
                guard try IPDatabaseStorage.digest(cityURL, maximum: IPDatabaseStorage.maximumDatabaseBytes) == release.city.sha256,
                      try IPDatabaseStorage.digest(asnURL, maximum: IPDatabaseStorage.maximumDatabaseBytes) == release.asn.sha256 else { throw IPInformationError.checksumMismatch }
                return try IPDatabaseStorage.preparePair(directory: directory, label: release.month, source: "DB-IP Lite",
                    attribution: "IP data by DB-IP.com", licenseURL: URL(string: "https://creativecommons.org/licenses/by/4.0/"),
                    cityHash: release.city.sha256, asnHash: release.asn.sha256, month: release.month, validateImport: false)
            }
            return try await install(prepared, id: id, expected: expected,
                archives: [release.city.archiveSHA256, release.asn.archiveSHA256])
        } catch {
            try? FileManager.default.removeItem(at: directory); failed(id, error: error); throw error
        }
    }
    private func archive(_ artifact: IPDatabaseRelease.Artifact, id: UUID, offset: Int64) async throws -> URL {
        let target = root.appendingPathComponent("Downloads/" + artifact.archiveSHA256 + ".gz")
        if FileManager.default.fileExists(atPath: target.path) {
            let checksum = try await Self.worker { try IPDatabaseStorage.digest(target, maximum: 128 * 1_024 * 1_024) }
            if checksum == artifact.archiveSHA256 { return target }
            throw IPInformationError.checksumMismatch
        }
        let received = try await download(artifact.url, 128 * 1_024 * 1_024, { [weak self] count in
            Task { await self?.progress(id, bytes: offset + count) }
        })
        defer { if received.temporary { try? FileManager.default.removeItem(at: received.url) } }
        let stage = root.appendingPathComponent("Staging/" + id.uuidString + "-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: stage) }
        let checksum = try await Self.worker { try IPDatabaseStorage.copy(received.url, to: stage) }
        guard checksum == artifact.archiveSHA256 else { throw IPInformationError.checksumMismatch }
        try Task.checkCancellation()
        try FileManager.default.moveItem(at: stage, to: target)
        return target
    }
    private func install(_ prepared: IPDatabaseSnapshot, id: UUID, expected: UUID?, archives: Set<String>? = nil) async throws -> IPDatabaseMetadata {
        publish(.installing, operation: id)
        if let beforeCommit { await beforeCommit() }
        try Task.checkCancellation()
        guard activeUpdate == id else { throw IPInformationError.versionChanged }
        let root = root
        try await Self.worker { try IPDatabaseStorage.commit(prepared, root: root, expected: expected) }
        // Cancellation after the atomic pointer commit cannot report rollback:
        // the new verified snapshot is the durable truth and must be published.
        snapshot = prepared; cache.removeAll()
        var keep = Set(lookups.values.map(\.snapshotID)); keep.insert(prepared.metadata.id)
        if let expected { keep.insert(expected) }
        let retained = keep
        // A housekeeping failure must not misreport a completed atomic commit
        // as a failed/rolled-back update. Unexpected paths remain untouched.
        try? await Self.worker { try IPDatabaseStorage.retireUnused(root: root, snapshots: retained, archives: archives) }
        activeUpdate = nil
        publish(.ready, operation: id)
        return prepared.metadata
    }
    private func failed(_ id: UUID, error: Error) {
        guard activeUpdate == id else { return }
        activeUpdate = nil
        if error is CancellationError || Task.isCancelled { publish(.cancelled, operation: id) }
        else { publish(.failed, operation: id, message: (error as? IPInformationError ?? .invalidDownload).localizedDescription) }
    }
    private static func worker<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        let task = Task.detached(priority: .utility, operation: body)
        let budget = IPWorkerBudget()
        let deadline = Task {
            do { try await Task.sleep(for: .seconds(120)); budget.expire(); task.cancel() }
            catch { }
        }
        defer { deadline.cancel() }
        do { return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() } }
        catch { if budget.expired { throw IPInformationError.timedOut }; throw error }
    }
}

private final class IPWorkerBudget: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var expired: Bool { lock.withLock { value } }
    func expire() { lock.withLock { value = true } }
}
