//
//  EditorTaskCoordinator.swift
//  VideoEditorKit
//
//  Created by Codex on 01.04.2026.
//

import Foundation

@MainActor
final class EditorTaskCoordinator {

    typealias Sleep = @Sendable (Duration) async throws -> Void

    // MARK: - Private Properties

    private let sleep: Sleep

    private var loadVideoTask: Task<Void, Never>?
    private var transcriptionTask: Task<Void, Never>?
    private var thumbnailsTask: Task<Void, Never>?
    private var exportSheetTask: Task<Void, Never>?
    private var toolResetTasks = [ToolEnum: Task<Void, Never>]()
    private var toolResetTokens = [ToolEnum: UUID]()
    private var transcriptionToken: UUID?
    private var thumbnailLoadGeneration = 0

    // MARK: - Initializer

    init(_ sleep: @escaping Sleep) {
        self.sleep = sleep
    }

    deinit {
        loadVideoTask?.cancel()
        transcriptionTask?.cancel()
        thumbnailsTask?.cancel()
        exportSheetTask?.cancel()

        for task in toolResetTasks.values {
            task.cancel()
        }
    }

    // MARK: - Public Methods

    func replaceLoadVideoTask(
        _ operation: @escaping @MainActor () async -> Void
    ) {
        loadVideoTask?.cancel()
        loadVideoTask = Task { await operation() }
    }

    func replaceTranscriptionTask(
        _ operation: @escaping @MainActor (UUID) async -> Void
    ) {
        cancelTranscriptionTask()

        let token = UUID()
        transcriptionToken = token
        transcriptionTask = Task {
            await operation(token)
        }
    }

    func makeThumbnailLoadRequest(
        for videoID: UUID
    ) -> EditorViewModel.ThumbnailLoadRequest {
        cancelThumbnailRequests()
        thumbnailLoadGeneration += 1

        return .init(
            videoID: videoID,
            generation: thumbnailLoadGeneration
        )
    }

    func runThumbnailLoad(
        request: EditorViewModel.ThumbnailLoadRequest,
        operation: @escaping @Sendable () async -> [ThumbnailImage],
        apply: @escaping @MainActor ([ThumbnailImage], EditorViewModel.ThumbnailLoadRequest) -> Void
    ) {
        thumbnailsTask = Task.detached(priority: .userInitiated) {
            let thumbnails = await operation()

            await MainActor.run {
                apply(thumbnails, request)
            }
        }
    }

    func acceptsThumbnailLoadRequest(
        _ request: EditorViewModel.ThumbnailLoadRequest,
        currentVideoID: UUID?
    ) -> Bool {
        !Task.isCancelled
            && currentVideoID == request.videoID
            && thumbnailLoadGeneration == request.generation
    }

    func cancelThumbnailRequests() {
        thumbnailsTask?.cancel()
        thumbnailsTask = nil
        thumbnailLoadGeneration += 1
    }

    func acceptsTranscriptionTask(_ token: UUID) -> Bool {
        !Task.isCancelled && transcriptionToken == token
    }

    func cancelTranscriptionTask() {
        transcriptionTask?.cancel()
        transcriptionTask = nil
        transcriptionToken = nil
    }

    func scheduleExporterPresentation(
        after delay: Duration,
        onFire: @escaping @MainActor () -> Void
    ) {
        exportSheetTask?.cancel()
        exportSheetTask = Task { @MainActor [self] in
            defer { exportSheetTask = nil }

            do {
                try await sleep(delay)
            } catch {
                return
            }

            guard !Task.isCancelled else { return }
            onFire()
        }
    }

    func cancelDeferredTasks() {
        exportSheetTask?.cancel()
        exportSheetTask = nil
        cancelTranscriptionTask()
        cancelPendingToolResetTasks()
    }

    func cancelPendingToolReset(for tool: ToolEnum) {
        toolResetTasks[tool]?.cancel()
        toolResetTasks[tool] = nil
        toolResetTokens[tool] = nil
    }

    func cancelPendingToolResetTasks() {
        for tool in Array(toolResetTasks.keys) {
            cancelPendingToolReset(for: tool)
        }
    }

    func schedulePendingToolReset(
        for tool: ToolEnum,
        after delay: Duration,
        onFire: @escaping @MainActor () -> Void
    ) {
        cancelPendingToolReset(for: tool)

        let token = UUID()
        toolResetTokens[tool] = token
        toolResetTasks[tool] = Task { @MainActor [weak self] in
            guard let self else { return }

            do {
                try await sleep(delay)
            } catch {
                return
            }

            guard !Task.isCancelled else { return }
            guard toolResetTokens[tool] == token else { return }

            onFire()
            toolResetTasks[tool] = nil
            toolResetTokens[tool] = nil
        }
    }

}
