// SPDX-License-Identifier: MPL-2.0
import Foundation
import Observation
import FloeElectronicsCore

/// Library preparation and imports belong to a service shared by originals,
/// not to a sheet. Closing a chooser never cancels a submitted install.
@MainActor @Observable public final class EDLibraryController {
    public typealias Importer = @Sendable ([URL]) async throws -> EDALibraryImportDraft
    public let store: EDALibraryStore
    public private(set) var catalog = EDALibraryCatalog(inventoryRevision: 0, entries: [], preferences: .init())
    public private(set) var busy = false
    public private(set) var ready = false
    public private(set) var canCancel = false
    public private(set) var message: String?
    public private(set) var diagnostic: String?
    public private(set) var importDraft: EDALibraryImportDraft?
    public private(set) var importRevision: UInt64?
    private let importer: Importer?
    @ObservationIgnored private var preparation: Task<EDALibraryCatalog, Error>?
    @ObservationIgnored private var operation: Task<Void, Never>?
    @ObservationIgnored private var association: Task<EDALibraryEntry, Error>?
    public init(store: EDALibraryStore, importer: Importer? = nil) { self.store = store; self.importer = importer }
    public var canImport: Bool { importer != nil }
    public func start() {
        guard !ready, preparation == nil else { return }
        Task { do { _ = try await prepare() } catch {} }
    }
    @discardableResult public func prepare() async throws -> EDALibraryCatalog {
        if let preparation { return try await preparation.value }
        if ready { return catalog }
        busy = true; message = nil
        let store = store
        let task = Task<EDALibraryCatalog, Error> {
            let packages = try await Task.detached(priority: .utility) {
                let paths = Bundle.module.urls(forResourcesWithExtension: "json", subdirectory: "Libraries") ?? []
                guard !paths.isEmpty else { throw EDAError.missing("bundled electronics library") }
                return try paths.sorted { $0.lastPathComponent < $1.lastPathComponent }.map { try EDALibraryPackage.decode(Data(contentsOf: $0)) }
            }.value
            guard Set(packages.map(\.id)).count == packages.count else { throw EDAError.duplicate("bundled library identity") }
            let index = try await store.inventory()
            for package in packages {
                let hash = try EDALibraryDigest.sha256(EDALibraryDigest.encoded(package))
                if let installed = index.installed.first(where: { $0.packageID == package.id && $0.version == package.version }) {
                    guard installed.sha256 == hash else { throw EDAError.duplicate("bundled library version differs from installed bytes") }
                } else {
                    _ = try await store.install(package, activate: index.activeVersions[package.id] == nil)
                }
            }
            return try await store.catalog()
        }
        preparation = task
        do {
            let value = try await task.value
            catalog = value; ready = true; preparation = nil; busy = operation != nil; diagnostic = nil
            return value
        } catch {
            preparation = nil; busy = operation != nil; diagnostic = String(describing: error)
            message = edText("无法载入元件库，请重试。已有设计仍可编辑。", "Couldn’t load the library. Retry; your existing design remains editable.")
            throw error
        }
    }
    public func refresh() async throws { catalog = try await store.catalog() }
    public func reportContentFailure(_ error: Error) {
        diagnostic = String(describing: error)
        message = edText("库更新已下载，暂未应用。请在库更新中重试。旧版本仍可使用。", "Library update downloaded but not applied. Retry in library updates; the previous version remains available.")
    }

    public func snapshot(_ reference: EDALibraryReference) async throws -> EDALibrarySnapshot {
        _ = try await prepare(); return try await store.snapshot(reference)
    }
    public func isFavorite(_ entry: EDALibraryEntry) -> Bool {
        catalog.preferences.favorites.contains(EDALibraryPreferences.key(packageID: entry.reference.packageID, partID: entry.reference.partID))
    }
    public func toggleFavorite(_ entry: EDALibraryEntry) {
        submit {
            try await self.store.setFavorite(packageID: entry.reference.packageID, partID: entry.reference.partID, enabled: !self.isFavorite(entry))
            try await self.refresh()
        }
    }
    public func recordUse(_ snapshot: EDALibrarySnapshot) async {
        do { try await store.recordUse(packageID: snapshot.packageID, partID: snapshot.part.id); try await refresh() }
        catch { diagnostic = String(describing: error); message = edText("元件已放置，最近使用暂未更新。", "Part placed. Recent items couldn’t be updated.") }
    }
    public func inspect(_ urls: [URL]) {
        guard let importer else { return }
        submit(cancellable: true) {
            let current = try await self.store.inventory()
            let value = try await importer(urls)
            try Task.checkCancellation()
            self.importDraft = value; self.importRevision = current.revision
        }
    }
    public func cancelCurrentOperation() { if canCancel { operation?.cancel() } }
    public func cancelImport() { guard !busy else { return }; importDraft = nil; importRevision = nil }
    public func acceptImport() {
        guard let package = importDraft?.package else { return }
        let expected = importRevision
        submit {
            _ = try await self.store.install(package, expectedInventoryRevision: expected)
            try await self.refresh(); self.importDraft = nil; self.importRevision = nil
        }
    }
    public func associate(symbol: EDALibraryReference, footprint: EDALibraryReference, map: EDALibraryPinMap, name: String?,
        cancelled: @escaping @Sendable () -> Bool = { false }) async throws -> EDALibraryEntry {
        _ = try await prepare()
        guard !busy, association == nil else { throw EDAError.invalid("library operation is busy") }
        busy = true; message = nil
        let revision = catalog.inventoryRevision, store = store
        let task = Task<EDALibraryEntry, Error> {
            defer { self.busy = false; self.association = nil }
            do {
                guard !cancelled() else { throw EDAError.cancelled }
                let source = try await store.snapshot(symbol), physical = try await store.snapshot(footprint)
                let package = try await Task.detached(priority: .userInitiated) {
                    try EDALibraryBinding.package(symbol: source, footprint: physical, pinMap: map, name: name)
                }.value
                _ = try await store.install(package, expectedInventoryRevision: revision, cancelled: cancelled)
                let current = try await store.catalog(); self.catalog = current
                guard let entry = current.entries.first(where: { $0.reference.packageID == package.id }) else { throw EDAError.missing("installed association") }
                self.diagnostic = nil; return entry
            } catch {
                self.diagnostic = String(describing: error)
                self.message = edText("未能保存元件组合。请核对引脚映射后重试。", "Couldn’t save this combination. Check the pin mapping and retry.")
                throw error
            }
        }
        association = task; return try await task.value
    }
    public func activate(packageID: String, version: String) {
        submit {
            let package = try await self.store.package(id: packageID, version: version)
            _ = try await self.store.install(package, expectedInventoryRevision: self.catalog.inventoryRevision)
            try await self.refresh()
        }
    }
    private func submit(cancellable: Bool = false, _ body: @escaping @MainActor () async throws -> Void) {
        guard operation == nil, !busy else { return }; busy = true; canCancel = cancellable; message = nil
        operation = Task {
            defer { self.busy = false; self.canCancel = false; self.operation = nil }
            do { _ = try await self.prepareIfNeededDuringOperation(); try await body(); self.diagnostic = nil }
            catch where error is CancellationError || (error as? EDAError) == .cancelled { self.diagnostic = nil; self.message = nil }
            catch {
                self.diagnostic = String(describing: error)
                self.message = edText("未能更新元件库。请重试；原有内容已保留。", "Couldn’t update the library. Retry; existing content is preserved.")
            }
        }
    }
    private func prepareIfNeededDuringOperation() async throws -> EDALibraryCatalog {
        if ready { return catalog }
        return try await prepare()
    }
}
