// SPDX-License-Identifier: MPL-2.0
import Foundation
import Observation
import FloeElectronicsCore

/// The App supplies this adapter over the shared remote catalogue/download
/// service. It never exposes URLs or cache paths to the UI or a model.
public protocol EDRemoteLibraryServing: Sendable {
    func status() async throws -> ElectronicsRemoteStatus
    func refresh(progress: ElectronicsRemoteProgress) async throws -> ElectronicsRemoteRefreshReceipt
    func searchLibraries(text: String, offset: Int, limit: Int) async throws -> ElectronicsRemoteLibraryPage
    func searchParts(libraryID: String, text: String, kind: String?, status: String?,
                     offset: Int, limit: Int, progress: ElectronicsRemoteProgress) async throws -> ElectronicsRemotePartPage
    func searchModels(text: String, format: String?, offset: Int, limit: Int) async throws -> ElectronicsRemoteModelPage
    func install(libraryID: String, partID: String,
                 progress: ElectronicsRemoteProgress) async throws -> ElectronicsRemoteInstallResult
    func downloadModel(id: String, progress: ElectronicsRemoteProgress) async throws -> ElectronicsRemoteModelReceipt
    func isModelCached(reference: EDAFootprintModelReference) async -> Bool
}

public enum EDRemoteLibraryPhase: Equatable, Sendable {
    case idle
    case loading
    case installing
    case downloading
}

/// Observable UI state for the online catalogue. The controller owns a task
/// but the actual downloads/installs are performed by the injected App service,
/// so dismissing the sheet never abandons a submitted native install.
@MainActor @Observable public final class EDRemoteLibraryController {
    public let service: any EDRemoteLibraryServing
    public private(set) var status: ElectronicsRemoteStatus?
    public private(set) var libraries: [ElectronicsRemoteLibrarySummary] = []
    public private(set) var parts: [ElectronicsRemotePartSummary] = []
    public private(set) var models: [ElectronicsRemoteModelRecord] = []
    public private(set) var phase = EDRemoteLibraryPhase.idle
    public private(set) var message: String?
    public private(set) var diagnostic: String?
    public private(set) var progressReceived: Int64 = 0
    public private(set) var progressExpected: Int64?
    public private(set) var lastInstall: ElectronicsRemoteInstallResult?
    public private(set) var partTotal = 0
    public private(set) var nextPartOffset: Int?
    public var selectedLibraryID: String? {
        didSet { if oldValue != selectedLibraryID { parts = []; partTotal = 0; nextPartOffset = nil; lastInstall = nil } }
    }
    public var query = ""
    public var includeReviewRequired = false
    public var onInstalled: (@MainActor (ElectronicsRemoteInstallResult) -> Void)?
    @ObservationIgnored private var operation: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var retryAction: RetryAction?

    private enum RetryAction {
        case refresh
        case searchParts
        case install(libraryID: String, partID: String)
        case downloadModel(id: String)
    }

    public init(service: any EDRemoteLibraryServing) { self.service = service }

    public var busy: Bool { phase != .idle }
    public var canCancel: Bool { operation != nil && busy }
    public var canRetry: Bool { !busy && retryAction != nil }
    public var selectedLibrary: ElectronicsRemoteLibrarySummary? {
        libraries.first { $0.id == selectedLibraryID }
    }
    public var librarySelection: [ElectronicsRemoteLibrarySummary] {
        libraries.sorted { $0.id < $1.id }
    }

    public func start() {
        guard status == nil, operation == nil else { return }
        submit(.loading) {
            let status = try await self.service.status()
            self.status = status
            guard status.installed else {
                self.message = edText("先刷新官方目录，再搜索或安装元件。", "Refresh the official catalogue before searching or installing parts.")
                return
            }
            let page = try await self.service.searchLibraries(text: "", offset: 0, limit: 100)
            self.libraries = page.libraries
            if self.selectedLibraryID == nil { self.selectedLibraryID = page.libraries.first?.id }
        }
    }

    public func refresh() {
        retryAction = .refresh
        submit(.loading) {
            _ = try await self.service.refresh(progress: self.progress())
            self.status = try await self.service.status()
            let page = try await self.service.searchLibraries(text: "", offset: 0, limit: 100)
            self.libraries = page.libraries
            if self.selectedLibraryID == nil { self.selectedLibraryID = page.libraries.first?.id }
            self.message = edText("目录已更新。", "Catalogue updated.")
            self.retryAction = nil
        }
    }

    public func searchParts(reset: Bool = true) {
        guard let libraryID = selectedLibraryID else {
            message = edText("请先选择一个数据源。", "Choose a source first.")
            return
        }
        retryAction = .searchParts
        let offset = reset ? 0 : (nextPartOffset ?? 0)
        submit(.loading) {
            let page = try await self.service.searchParts(libraryID: libraryID, text: self.query,
                kind: nil, status: self.includeReviewRequired ? nil : "converted",
                offset: offset, limit: 100, progress: self.progress())
            if reset || offset == 0 {
                self.parts = page.parts
            } else {
                self.parts += page.parts
            }
            self.partTotal = page.total; self.nextPartOffset = page.nextOffset
            self.message = page.total == 0
                ? edText("没有匹配的已转换记录。可显示待复核项，但它们不能安装。", "No matching converted records. Review-required records can be shown but cannot be installed.")
                : nil
            self.retryAction = nil
        }
    }

    public func loadMoreParts() {
        guard nextPartOffset != nil else { return }
        retryAction = .searchParts
        searchParts(reset: false)
    }

    public func install(_ part: ElectronicsRemotePartSummary) {
        guard part.status == "converted" else {
            message = edText("此记录需要先复核，不能直接安装。原始记录仍可查看或下载。", "This record needs review and cannot be installed directly. Its original record remains readable and downloadable.")
            return
        }
        guard let libraryID = selectedLibraryID else {
            message = edText("请先选择元件所属的数据源。", "Choose the source library first.")
            return
        }
        retryAction = .install(libraryID: libraryID, partID: part.id)
        lastInstall = nil
        submit(.installing) {
            let result = try await self.service.install(libraryID: libraryID, partID: part.id,
                progress: self.progress())
            self.lastInstall = result
            self.message = edText("已安装到本机元件库。可从现有元件选择器放置。", "Installed into the native library. Place it from the existing part chooser.")
            self.onInstalled?(result)
            self.retryAction = nil
        }
    }

    public func downloadModel(_ id: String) {
        retryAction = .downloadModel(id: id)
        submit(.downloading) {
            _ = try await self.service.downloadModel(id: id, progress: self.progress())
            self.message = edText("三维模型已验证并缓存，可在 PCB 三维视图中显示。", "The 3D model is verified and cached for the PCB 3D view.")
            self.retryAction = nil
        }
    }

    public func downloadModel(for reference: EDAFootprintModelReference) {
        guard let id = reference.modelID else {
            message = edText("此封装记录的三维引用没有对应的可下载模型。", "This footprint reference has no matching downloadable model in the catalogue.")
            return
        }
        downloadModel(id)
    }

    public func isModelCached(_ reference: EDAFootprintModelReference) async -> Bool {
        await service.isModelCached(reference: reference)
    }

    public func cancel() {
        guard let operation else { return }
        operation.cancel()
        message = edText("正在取消…", "Cancelling…")
    }

    public func retry() {
        guard !busy, let retryAction else { return }
        switch retryAction {
        case .refresh: refresh()
        case .searchParts: searchParts()
        case .install(let libraryID, let partID):
            if let part = parts.first(where: { $0.id == partID && $0.library == libraryID }) { install(part) }
        case .downloadModel(let id): downloadModel(id)
        }
    }

    public func clearMessage() { message = nil; diagnostic = nil; retryAction = nil }

    private func submit(_ phase: EDRemoteLibraryPhase,
                        _ body: @escaping @MainActor () async throws -> Void) {
        guard operation == nil else { return }
        self.phase = phase; message = nil; diagnostic = nil
        progressReceived = 0; progressExpected = nil
        let generation = UUID(); self.generation = generation
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await body()
                if self.generation == generation { self.phase = .idle }
            } catch where error is CancellationError || (error as? ElectronicsRemoteError) == .cancelled
                || (error as? ElectronicsRemoteInstallError) == .cancelled {
                if self.generation == generation {
                    self.phase = .idle
                    self.message = edText("操作已取消，已有内容未改变。", "Cancelled. Existing content is unchanged.")
                    self.retryAction = nil
                }
            } catch {
                if self.generation == generation {
                    self.phase = .idle
                    self.diagnostic = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
                    self.message = Self.friendly(error)
                }
            }
            if self.generation == generation { self.operation = nil }
        }
        operation = task
    }

    private func progress() -> ElectronicsRemoteProgress {
        let generation = generation
        return ElectronicsRemoteProgress { [weak self] received, expected in
            Task { @MainActor [weak self] in
                guard let self, self.generation == generation else { return }
                self.progressReceived = received; self.progressExpected = expected
            }
        }
    }

    private static func friendly(_ error: Error) -> String {
        if let error = error as? ElectronicsRemoteInstallError {
            switch error {
            case .reviewRequired: return edText("此记录需要复核，不能安装。原始内容仍保留。", "This record requires review and cannot be installed. Its original content is retained.")
            case .unsupported: return edText("此记录尚无本机安装适配，原始记录仍可下载。", "This record has no native install adapter yet. Its original remains downloadable.")
            case .budget: return edText("本机元件库已达到容量上限，请先停用不用的库。已有库未改变。", "The native library reached its capacity limit. Disable an unused library first; existing libraries are unchanged.")
            case .integrity: return edText("下载内容未通过校验，未安装。", "The downloaded content failed verification and was not installed.")
            case .invalidRecord: return edText("目录记录不完整，未安装。", "The catalogue record is incomplete and was not installed.")
            case .cancelled: return edText("操作已取消。", "Cancelled.")
            }
        }
        if let error = error as? ElectronicsRemoteError {
            switch error {
            case .notReady: return edText("请先刷新官方目录。", "Refresh the official catalogue first.")
            case .integrity, .invalidAsset, .invalidCatalog, .invalidManifest, .invalidRelease:
                return edText("目录或文件未通过校验，未安装。", "The catalogue or file failed verification; nothing was installed.")
            case .unavailable: return edText("数据源暂时不可用，请重试。", "The data source is temporarily unavailable. Retry.")
            case .limits: return edText("文件超过安全大小限制，未安装。", "The file exceeds the safety limit and was not installed.")
            case .cancelled: return edText("操作已取消。", "Cancelled.")
            default: return edText("操作未完成，已有内容未改变。", "The operation did not finish; existing content is unchanged.")
            }
        }
        return edText("操作未完成，已有内容未改变。", "The operation did not finish; existing content is unchanged.")
    }
}
