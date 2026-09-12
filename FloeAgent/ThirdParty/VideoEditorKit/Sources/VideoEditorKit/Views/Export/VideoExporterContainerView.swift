//
//  VideoExporterContainerView.swift
//  VideoEditorKit
//
//  Created by Adriano Souza Costa on 23.03.2026.
//

import Observation
import SwiftUI

@MainActor
struct VideoExporterContainerView: View {

    // MARK: - Environments

    @Environment(\.dismiss) private var dismiss

    // MARK: - Bindings

    @Binding private var lifecycleState: ExportLifecycleState

    // MARK: - States

    @State private var viewModel: ExporterViewModel

    // MARK: - Body

    var body: some View {
        @Bindable var bindableViewModel = viewModel

        VideoExporterView(
            isAlertPresented: $bindableViewModel.showAlert,
            state: exportPresentationState,
            qualities: exportQualities,
            onSelectQuality: viewModel.selectQuality(_:),
            onBlockedQualityTap: onBlockedQualityTap,
            onExport: exportVideo,
            onRetry: retryExport,
            onCancelExport: viewModel.cancelExport,
            onClose: dismissView
        )
        .onChange(of: lifecycleState) { _, newLifecycleState in
            handleLifecycleStateChange(newLifecycleState)
        }
        .task(id: lifecycleState) {
            handleLifecycleStateChange(lifecycleState)
        }
    }

    // MARK: - Private Properties

    private let exportQualities: [ExportQualityAvailability]
    private let prepareForExport: (VideoQuality) async -> ExporterViewModel.ExportPreparationResult
    private let shouldShowSavingBeforeExport: (VideoQuality) -> Bool
    private let onBlockedQualityTap: (VideoQuality) -> Void
    private let onExported: (ExportedVideo) -> Void

    private var exportPresentationState: VideoExportPresentationState {
        .init(
            selectedQuality: viewModel.selectedQuality,
            exportProgress: viewModel.exportProgress,
            progressText: viewModel.progressText,
            errorMessage: viewModel.errorMessage,
            actionTitle: viewModel.exportActionTitle,
            isInteractionDisabled: viewModel.isInteractionDisabled,
            canExportVideo: viewModel.canExportVideo,
            canCancelExport: viewModel.canCancelExport,
            shouldShowLoadingView: viewModel.shouldShowLoadingView,
            shouldShowFailureMessage: viewModel.shouldShowFailureMessage,
            isSavingBeforeExport: viewModel.isSavingBeforeExport
        )
    }

    // MARK: - Initializer

    init(
        lifecycleState: Binding<ExportLifecycleState>,
        video: Video,
        editingConfiguration: VideoEditingConfiguration,
        exportQualities: [ExportQualityAvailability] = ExportQualityAvailability.allEnabled,
        watermark: VideoWatermarkConfiguration? = nil,
        prepareForExport: @escaping (VideoQuality) async -> ExporterViewModel.ExportPreparationResult = { _ in .render
        },
        shouldShowSavingBeforeExport: @escaping (VideoQuality) -> Bool = { _ in false },
        onBlockedQualityTap: @escaping (VideoQuality) -> Void = { _ in },
        onExported: @escaping (ExportedVideo) -> Void
    ) {
        _lifecycleState = lifecycleState

        _viewModel = State(
            initialValue: ExporterViewModel(
                video,
                editingConfiguration: editingConfiguration,
                exportQualities: exportQualities,
                watermark: watermark
            )
        )

        self.exportQualities = ExportQualityPresentationResolver.normalizedQualities(exportQualities)
        self.prepareForExport = prepareForExport
        self.shouldShowSavingBeforeExport = shouldShowSavingBeforeExport
        self.onBlockedQualityTap = onBlockedQualityTap
        self.onExported = onExported
    }

    init(
        lifecycleState: Binding<ExportLifecycleState>,
        video: Video,
        editingConfiguration: VideoEditingConfiguration,
        exportQualities: [ExportQualityAvailability] = ExportQualityAvailability.allEnabled,
        watermark: VideoWatermarkConfiguration? = nil,
        prepareForExport: @escaping (VideoQuality) async -> VideoExportPreparationResult,
        shouldShowSavingBeforeExport: @escaping (VideoQuality) -> Bool = { _ in false },
        onBlockedQualityTap: @escaping (VideoQuality) -> Void = { _ in },
        onExported: @escaping (ExportedVideo) -> Void
    ) {
        self.init(
            lifecycleState: lifecycleState,
            video: video,
            editingConfiguration: editingConfiguration,
            exportQualities: exportQualities,
            watermark: watermark,
            prepareForExport: { quality in
                switch await prepareForExport(quality) {
                case .render:
                    ExporterViewModel.ExportPreparationResult.render
                case .usePreparedVideo(let exportedVideo):
                    ExporterViewModel.ExportPreparationResult.usePreparedVideo(exportedVideo)
                case .cancelled:
                    ExporterViewModel.ExportPreparationResult.cancelled
                }
            },
            shouldShowSavingBeforeExport: shouldShowSavingBeforeExport,
            onBlockedQualityTap: onBlockedQualityTap,
            onExported: onExported
        )
    }

    // MARK: - Private Methods

    private func exportVideo() {
        viewModel.exportVideo(
            showsSavingBeforeExport: shouldShowSavingBeforeExport(viewModel.selectedQuality),
            preparingExport: prepareForExport,
            onExported: handleExportedVideo
        )
    }

    private func retryExport() {
        viewModel.retryExport(
            showsSavingBeforeExport: shouldShowSavingBeforeExport(viewModel.selectedQuality),
            preparingExport: prepareForExport,
            onExported: handleExportedVideo
        )
    }

    private func dismissView() {
        guard !viewModel.isInteractionDisabled else { return }
        dismiss()
    }

    private func handleLifecycleStateChange(_ lifecycleState: ExportLifecycleState) {
        viewModel.handleLifecycleStateChange(lifecycleState)
    }

    private func handleExportedVideo(_ video: ExportedVideo) {
        dismiss()
        onExported(video)
    }

}

#Preview {
    NavigationStack {
        VideoExporterContainerView(
            lifecycleState: .constant(.active),
            video: Video.mock,
            editingConfiguration: .initial
        ) { _ in }
    }
}
