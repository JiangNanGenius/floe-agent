//
//  ExporterViewModel.swift
//  VideoEditorKit
//
//  Created by Adriano Souza Costa on 23.03.2026.
//

import Foundation
import Observation

@MainActor
@Observable
final class ExporterViewModel {

    // MARK: - Public Properties

    let video: Video
    let editingConfiguration: VideoEditingConfiguration
    let watermark: VideoWatermarkRenderRequest?

    var showAlert = false
    var exportProgress: Double = .zero
    var isSavingBeforeExport = false
    var selectedQuality: VideoQuality

    var renderState: ExportState = .unknown {
        didSet {
            guard shouldHandleRenderStateTransition(from: oldValue, to: renderState) else { return }
            handleRenderStateChange(renderState)
        }
    }

    var isInteractionDisabled: Bool {
        renderState == .loading
    }

    var canExportVideo: Bool {
        !isInteractionDisabled && selectedQualityAvailability?.isEnabled == true
    }

    var canCancelExport: Bool {
        renderState == .loading
    }

    var shouldShowLoadingView: Bool {
        switch renderState {
        case .loading:
            true
        case .unknown, .loaded, .failed:
            false
        }
    }

    var shouldShowFailureMessage: Bool {
        if case .failed = renderState {
            return true
        }

        return false
    }

    var exportActionTitle: String {
        shouldShowFailureMessage ? VideoEditorStrings.tryAgain : VideoEditorStrings.export
    }

    var progressText: String {
        exportProgress.formatted(.percent.precision(.fractionLength(0)))
    }

    var errorMessage: String {
        if case .failed(let error) = renderState {
            error.localizedDescription
        } else {
            VideoEditorStrings.exportButtonFallbackMessage
        }
    }

    enum ExportState: Identifiable, Equatable {

        case unknown, loading
        case loaded(ExportedVideo)
        case failed(Error)

        var id: Int {
            switch self {
            case .unknown: return 0
            case .loading: return 1
            case .loaded: return 2
            case .failed: return 3
            }
        }

        static func == (lhs: ExporterViewModel.ExportState, rhs: ExporterViewModel.ExportState) -> Bool {
            switch (lhs, rhs) {
            case (.unknown, .unknown), (.loading, .loading):
                true
            case (.loaded(let lhsVideo), .loaded(let rhsVideo)):
                lhsVideo == rhsVideo
            case (.failed, .failed):
                true
            default:
                false
            }
        }

    }

    enum ExportCancellationReason {

        case user
        case backgroundInterruption

    }

    enum ExportPreparationResult: Equatable, Sendable {

        case render
        case usePreparedVideo(ExportedVideo)
        case cancelled

    }

    // MARK: - Private Properties

    typealias RenderVideo =
        @Sendable (
            _ video: Video,
            _ editingConfiguration: VideoEditingConfiguration,
            _ quality: VideoQuality,
            _ watermark: VideoWatermarkRenderRequest?,
            _ onProgress: VideoEditor.ProgressHandler?
        ) async throws -> URL
    typealias PrepareExport = (VideoQuality) async -> ExportPreparationResult

    private let renderVideo: RenderVideo
    private let loadExportedVideo: @Sendable (URL) async -> ExportedVideo
    private let exportQualities: [ExportQualityAvailability]
    private let lifecycleCoordinator: ExportLifecycleCoordinator
    private let lifecycleNow: @Sendable () -> Date

    @ObservationIgnored private var exportTask: Task<Void, Never>?
    @ObservationIgnored private var currentExportRunID = 0
    @ObservationIgnored private var lifecycleInactiveStart: Date?

    // MARK: - Initializer

    init(
        _ video: Video,
        editingConfiguration: VideoEditingConfiguration = .initial,
        exportQualities: [ExportQualityAvailability] = ExportQualityAvailability.allEnabled,
        watermark: VideoWatermarkConfiguration? = nil,
        renderVideo: @escaping RenderVideo = { video, editingConfiguration, quality, watermark, onProgress in
            try await VideoEditor.startRender(
                video: video,
                editingConfiguration: editingConfiguration,
                videoQuality: quality,
                watermark: watermark,
                onProgress: onProgress
            )
        },
        loadExportedVideo: @escaping @Sendable (URL) async -> ExportedVideo = { url in
            await ExportedVideo.load(from: url)
        },
        lifecycleCoordinator: ExportLifecycleCoordinator = .init(),
        lifecycleNow: @escaping @Sendable () -> Date = Date.init
    ) {
        self.video = video
        self.editingConfiguration = editingConfiguration
        self.watermark = VideoWatermarkRenderRequest(watermark)
        let normalizedExportQualities = Self.normalizedExportQualities(exportQualities)
        self.exportQualities = Self.sortedExportQualities(normalizedExportQualities)
        self.selectedQuality = Self.defaultSelectedQuality(for: normalizedExportQualities)
        self.renderVideo = renderVideo
        self.loadExportedVideo = loadExportedVideo
        self.lifecycleCoordinator = lifecycleCoordinator
        self.lifecycleNow = lifecycleNow
    }

    // MARK: - Public Methods

    func export() async -> ExportedVideo? {
        let exportRunID = beginExportRun()
        let exportQuality = selectedQuality

        return await export(runID: exportRunID, selectedQuality: exportQuality)
    }

    func exportVideo(
        showsSavingBeforeExport: Bool = false,
        preparingExport: @escaping PrepareExport = { _ in .render },
        onExported: @escaping (ExportedVideo) -> Void
    ) {
        exportTask?.cancel()
        let exportRunID = beginExportRun()
        let exportQuality = selectedQuality
        isSavingBeforeExport = showsSavingBeforeExport
        renderState = .loading

        exportTask = Task { [weak self] in
            guard let self else { return }

            defer {
                Task { @MainActor [weak self] in
                    guard self?.isCurrentExportRun(exportRunID) == true else { return }
                    self?.exportTask = nil
                }
            }

            let preparationResult = await preparingExport(exportQuality)

            guard !Task.isCancelled else {
                self.finishCancelledPreparation(runID: exportRunID)
                return
            }

            switch preparationResult {
            case .cancelled:
                self.finishCancelledPreparation(runID: exportRunID)
                return
            case .usePreparedVideo(let exportedVideo):
                self.finishPreparedExport(exportedVideo, runID: exportRunID)
                guard !Task.isCancelled else { return }
                onExported(exportedVideo)
                return
            case .render:
                self.finishPreparingExport(runID: exportRunID)
            }

            guard
                let exportedVideo = await self.export(
                    runID: exportRunID,
                    selectedQuality: exportQuality
                ),
                !Task.isCancelled
            else { return }
            onExported(exportedVideo)
        }
    }

    func retryExport(
        showsSavingBeforeExport: Bool = false,
        preparingExport: @escaping PrepareExport = { _ in .render },
        onExported: @escaping (ExportedVideo) -> Void
    ) {
        showAlert = false
        exportVideo(
            showsSavingBeforeExport: showsSavingBeforeExport,
            preparingExport: preparingExport,
            onExported: onExported
        )
    }

    func cancelExport() {
        cancelExport(reason: .user)
    }

    func cancelExport(reason: ExportCancellationReason) {
        exportTask?.cancel()
        exportTask = nil
        isSavingBeforeExport = false

        switch reason {
        case .user:
            renderState = .unknown
        case .backgroundInterruption:
            renderState = .failed(ExporterError.backgroundInterruption)
        }
    }

    func handleLifecycleStateChange(_ lifecycleState: ExportLifecycleState) {
        let isExporting = renderState == .loading
        let lifecycleNow = lifecycleNow()

        if lifecycleState == .inactive, isExporting, lifecycleInactiveStart == nil {
            lifecycleInactiveStart = lifecycleNow
        }

        guard
            let cancellationReason = lifecycleCoordinator.cancellationReason(
                for: lifecycleState,
                isExporting: isExporting,
                inactiveStart: lifecycleInactiveStart,
                now: lifecycleNow
            )
        else {
            if !isExporting || lifecycleState != .inactive {
                lifecycleInactiveStart = nil
            }
            return
        }

        lifecycleInactiveStart = nil
        cancelExport(reason: cancellationReason)
    }

    func selectQuality(_ quality: VideoQuality) {
        guard
            isInteractionDisabled == false,
            availability(for: quality)?.isEnabled == true
        else { return }

        selectedQuality = quality
    }

    func isSelectedQuality(_ quality: VideoQuality) -> Bool {
        selectedQuality == quality
    }

    // MARK: - Private Methods

    private func export(
        runID: Int,
        selectedQuality: VideoQuality
    ) async -> ExportedVideo? {
        renderState = .loading

        do {
            let url = try await renderVideo(video, editingConfiguration, selectedQuality, watermark) {
                [weak self] progress in
                await MainActor.run {
                    guard self?.isCurrentExportRun(runID) == true else { return }
                    self?.exportProgress = progress.clamped(to: 0...1)
                }
            }
            try Task.checkCancellation()

            let exportedVideo = await loadExportedVideo(url)
            try Task.checkCancellation()

            guard isCurrentExportRun(runID) else { return nil }
            renderState = .loaded(exportedVideo)
            return exportedVideo
        } catch is CancellationError {
            if isCurrentExportRun(runID), renderState == .loading {
                renderState = .unknown
            }
            return nil
        } catch {
            guard isCurrentExportRun(runID) else { return nil }
            renderState = .failed(error)
            return nil
        }
    }

    private func handleRenderStateChange(_ state: ExportState) {
        switch state {
        case .unknown:
            showAlert = false
            resetProgress()
        case .loading:
            showAlert = false
            exportProgress = .zero
        case .loaded:
            exportProgress = 1
        case .failed:
            resetProgress()
            showAlert = true
        }
    }

    private func shouldHandleRenderStateTransition(
        from oldState: ExportState,
        to newState: ExportState
    ) -> Bool {
        switch (oldState, newState) {
        case (.failed, .failed):
            true
        default:
            oldState != newState
        }
    }

    private func resetProgress() {
        exportProgress = .zero
    }

    private func finishPreparingExport(runID: Int) {
        guard isCurrentExportRun(runID) else { return }
        isSavingBeforeExport = false
    }

    private func finishCancelledPreparation(runID: Int) {
        guard isCurrentExportRun(runID), renderState == .loading else { return }
        isSavingBeforeExport = false
        renderState = .unknown
    }

    private func finishPreparedExport(_ exportedVideo: ExportedVideo, runID: Int) {
        guard isCurrentExportRun(runID), renderState == .loading else { return }
        isSavingBeforeExport = false
        renderState = .loaded(exportedVideo)
    }

    private func beginExportRun() -> Int {
        currentExportRunID += 1
        return currentExportRunID
    }

    private func isCurrentExportRun(_ runID: Int) -> Bool {
        runID == currentExportRunID
    }

    private var selectedQualityAvailability: ExportQualityAvailability? {
        availability(for: selectedQuality)
    }

    private func availability(for quality: VideoQuality) -> ExportQualityAvailability? {
        exportQualities.first(where: { $0.quality == quality })
    }

    private static func defaultSelectedQuality(
        for exportQualities: [ExportQualityAvailability]
    ) -> VideoQuality {
        let sortedQualities = sortedExportQualities(exportQualities)

        if sortedQualities.contains(where: { $0.quality == .original && $0.isEnabled }) {
            return .original
        }

        if let enabledQuality = sortedQualities.first(where: \.isEnabled)?.quality {
            return enabledQuality
        }

        return sortedQualities.first?.quality ?? .low
    }

    private static func normalizedExportQualities(
        _ exportQualities: [ExportQualityAvailability]
    ) -> [ExportQualityAvailability] {
        let original = ExportQualityAvailability.enabled(.original)
        let nonOriginalQualities = exportQualities.filter { $0.quality != .original }

        return nonOriginalQualities + [original]
    }

    private static func sortedExportQualities(
        _ exportQualities: [ExportQualityAvailability]
    ) -> [ExportQualityAvailability] {
        exportQualities.sorted {
            if $0.order == $1.order {
                return $0.quality.rawValue < $1.quality.rawValue
            }

            return $0.order < $1.order
        }
    }

}

enum ExportLifecycleState: Equatable, Sendable {

    case active
    case inactive
    case background

}

struct ExportLifecycleCoordinator: Sendable {

    // MARK: - Private Properties

    private var inactiveGracePeriod: TimeInterval {
        1
    }

    // MARK: - Public Methods

    func cancellationReason(
        for lifecycleState: ExportLifecycleState,
        isExporting: Bool,
        inactiveStart: Date? = nil,
        now: Date = Date()
    ) -> ExporterViewModel.ExportCancellationReason? {
        guard isExporting else { return nil }

        switch lifecycleState {
        case .inactive:
            return nil
        case .active:
            guard
                let inactiveStart,
                now.timeIntervalSince(inactiveStart) >= inactiveGracePeriod
            else {
                return nil
            }

            return .backgroundInterruption
        case .background:
            return .backgroundInterruption
        }
    }

}
