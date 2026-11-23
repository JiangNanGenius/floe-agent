// SPDX-License-Identifier: MPL-2.0

// Desktop multi-track timeline editor for the Mac creative workbench.
//
// Split layout: track list + proportional clip strips on the left, preview
// and clip/grade inspector on the right. The draft is the single source of
// truth: every control mutates the validated value-typed model, auto-persists
// through the staged `MacTimelineDraftStore`, and re-arms a debounced
// AVPlayer preview rebuilt from the same composition plan used for export,
// so the preview and the rendered file cannot drift apart.
//
// The owner routes (`saveToTask`/`addToCanvas`) are captured by the presenting
// view, exactly like the basic media editor; inputs are only ever read.

import AppKit
import AVKit
import FloeCore
import SwiftUI
import UniformTypeIdentifiers

struct MacTimelineSelection: Hashable {
    var trackID: UUID
    var clipID: UUID?
}

struct MacTimelineEditorView: View {
    let store: MacTimelineDraftStore
    @State var draft: MacTimelineDraft
    var saveToTask: ((URL) async -> Bool)?
    var addToCanvas: ((URL) -> Void)?
    var onDraftsChanged: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @State private var assets: [URL: MacTimelineAssetInfo] = [:]
    @State private var selection = MacTimelineSelection(trackID: UUID())
    @State private var player: AVPlayer?
    @State private var previewNotice: String?
    @State private var errorMessage: String?
    @State private var nameDraft = ""
    @State private var persistedRevision: Int64 = -1
    @State private var renameTrack: MacTimelineTrack?
    @State private var renameClip: MacTimelineClip?
    @State private var confirmDeleteDraft = false
    @State private var exportTask: Task<Void, Never>?
    @State private var persistTask: Task<Void, Never>?
    @State private var previewTask: Task<Void, Never>?

    // Export footer state.
    @State private var isExporting = false
    @State private var exportProgress = 0.0
    @State private var exported: URL?
    @State private var exportError: String?
    @State private var routeFailed = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HSplitView {
                trackList
                    .frame(minWidth: 420, idealWidth: 520, maxWidth: 720)
                VStack(spacing: 0) {
                    previewPane
                    Divider()
                    inspector
                }
                .frame(minWidth: 380, idealWidth: 440)
            }
            Divider()
            exportFooter
        }
        .frame(minWidth: 940, minHeight: 620)
        .task { await open() }
        .onDisappear(perform: close)
        .alert(MacTimelineEditorStrings.errorTitle, isPresented: Binding(
            get: { errorMessage != nil || exportError != nil },
            set: { if !$0 { errorMessage = nil; exportError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(verbatim: errorMessage ?? exportError ?? "") }
        .alert(MacTimelineEditorStrings.deleteDraftTitle, isPresented: $confirmDeleteDraft) {
            Button(MacTimelineEditorStrings.deleteDraftConfirm, role: .destructive) {
                persistTask?.cancel(); previewTask?.cancel()
                try? store.remove(id: draft.id)
                onDraftsChanged()
                dismiss()
            }
            Button(MacTimelineEditorStrings.cancel, role: .cancel) {}
        }
        .sheet(item: $renameTrack) { track in
            MacTimelineRenameSheet(title: MacTimelineEditorStrings.renameTrack,
                                   value: track.name) { newName in
                mutate { try $0.renameTrack(track.id, name: newName) }
            }
        }
        .sheet(item: $renameClip) { clip in
            MacTimelineRenameSheet(title: MacTimelineEditorStrings.renameClip,
                                   value: clip.title) { newName in
                mutateClip(clip.id) { $0.title = newName }
            }
        }
    }

    // MARK: Chrome

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "timeline.selection")
            TextField(MacTimelineEditorStrings.draftNamePlaceholder, text: $nameDraft)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 240)
                .onSubmit { commitName() }
            Text(verbatim: String(format: MacTimelineEditorStrings.durationFormat,
                                  draft.totalDurationSeconds))
                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
            Menu {
                Button(MacTimelineEditorStrings.duplicateDraft) { duplicateDraft() }
                Button(MacTimelineEditorStrings.deleteDraft, role: .destructive) {
                    confirmDeleteDraft = true
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }.accessibilityLabel(MacTimelineEditorStrings.draftActions)
            Spacer()
            Button(MacTimelineEditorStrings.close) { dismiss() }
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("mac.timelineEditor.close")
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    // MARK: Track list

    private var trackList: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button { addTrack(.visual) } label: {
                    Label(MacTimelineEditorStrings.addVideoTrack, systemImage: "film")
                }
                Button { addTrack(.audio) } label: {
                    Label(MacTimelineEditorStrings.addAudioTrack, systemImage: "waveform")
                }
                Button { addTrack(.caption) } label: {
                    Label(MacTimelineEditorStrings.addCaptionTrack, systemImage: "captions.bubble")
                }
                Spacer()
                Button { importMedia() } label: {
                    Label(MacTimelineEditorStrings.addMedia, systemImage: "plus.rectangle.on.folder")
                }
                Menu {
                    Button(MacSubtitleStrings.importButton) { importSubtitles() }
                    if !draft.captionCues.isEmpty {
                        Button(MacSubtitleStrings.exportSRT) { exportSubtitles(format: .srt) }
                        Button(MacSubtitleStrings.exportVTT) { exportSubtitles(format: .vtt) }
                    }
                } label: {
                    Image(systemName: "captions.bubble.fill")
                }.accessibilityLabel(MacTimelineEditorStrings.subtitleMenu)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .disabled(isExporting)
            Divider()
            if draft.tracks.isEmpty {
                ContentUnavailableView(MacTimelineEditorStrings.emptyTracks,
                                       systemImage: "timeline.selection",
                                       description: Text(MacTimelineEditorStrings.emptyTracksHint))
            } else {
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(draft.tracks.enumerated()), id: \.element.id) { index, track in
                            trackRow(track, index: index)
                        }
                    }
                    .padding(12)
                }
            }
        }
    }

    private func trackRow(_ track: MacTimelineTrack, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: track.kind == .visual ? "film"
                      : track.kind == .audio ? "waveform" : "captions.bubble")
                    .foregroundStyle(.secondary)
                Button(track.name) { renameTrack = track }
                    .buttonStyle(.plain).font(.callout.weight(.medium))
                    .lineLimit(1)
                Text(verbatim: track.kind == .caption
                     ? MacTimelineEditorStrings.captionKind
                     : String(format: MacTimelineEditorStrings.clipCountFormat, track.clips.count))
                    .font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                Toggle("", isOn: Binding(get: { track.isMuted },
                                         set: { value in mutate { try $0.setTrackMuted(track.id, muted: value) } }))
                    .toggleStyle(.checkbox).labelsHidden()
                    .help(MacTimelineEditorStrings.muteTrack)
                Button { moveTrack(track.id, direction: -1) } label: {
                    Image(systemName: "chevron.up")
                }.buttonStyle(.borderless).disabled(index == 0)
                    .help(MacTimelineEditorStrings.moveTrackUp)
                Button { moveTrack(track.id, direction: 1) } label: {
                    Image(systemName: "chevron.down")
                }.buttonStyle(.borderless).disabled(index == draft.tracks.count - 1)
                    .help(MacTimelineEditorStrings.moveTrackDown)
                Button { removeTrack(track.id) } label: {
                    Image(systemName: "minus.circle")
                }.buttonStyle(.borderless).foregroundStyle(.red)
                    .help(MacTimelineEditorStrings.removeTrack)
            }
            if track.kind != .caption {
                HStack(spacing: 6) {
                    Text(MacTimelineEditorStrings.volume).font(.caption2).foregroundStyle(.secondary)
                    Slider(value: Binding(get: { track.volume },
                                          set: { value in mutate { try $0.setTrackVolume(track.id, volume: value) } }),
                           in: 0...2)
                        .controlSize(.small).labelsHidden().frame(maxWidth: 140)
                    Text(String(format: "%.2f", track.volume))
                        .font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            clipStrip(track)
        }
        .padding(8)
        .background(selection.trackID == track.id
                    ? Color.accentColor.opacity(0.10) : Color(nsColor: .underPageBackgroundColor),
                    in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8)
            .stroke(selection.trackID == track.id ? Color.accentColor : .clear, lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture { selection = MacTimelineSelection(trackID: track.id, clipID: nil) }
    }

    private func clipStrip(_ track: MacTimelineTrack) -> some View {
        let total = max(draft.totalDurationSeconds, 1)
        return ScrollView(.horizontal) {
            HStack(spacing: 4) {
                ForEach(track.clips) { clip in
                    clipBar(track: track, clip: clip, total: total)
                }
                if track.clips.isEmpty {
                    Text(MacTimelineEditorStrings.dropHint)
                        .font(.caption2).foregroundStyle(.tertiary)
                        .frame(height: 40)
                }
            }
            .padding(.horizontal, 2)
        }
    }

    private func clipBar(track: MacTimelineTrack, clip: MacTimelineClip, total: Double) -> some View {
        let selected = selection.clipID == clip.id
        let width = max(64, clip.timelineRange.durationSeconds / total * 480)
        return VStack(alignment: .leading, spacing: 2) {
            HStack {
                Image(systemName: clip.isMuted ? "speaker.slash.fill" : "speaker.wave.1.fill")
                    .font(.caption2)
                Text(verbatim: clip.captionText ?? clip.title)
                    .font(.caption).lineLimit(1)
            }
            Text(verbatim: String(format: "%.1fs → %.1fs",
                                  clip.timelineRange.startSeconds, clip.timelineEnd))
                .font(.caption2).monospacedDigit().foregroundStyle(.secondary)
        }
        .padding(6)
        .frame(width: width, height: 44, alignment: .leading)
        .background(selected ? Color.accentColor.opacity(0.25) : Color.secondary.opacity(0.14),
                    in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6)
            .stroke(selected ? Color.accentColor : Color.secondary.opacity(0.4), lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture { selection = MacTimelineSelection(trackID: track.id, clipID: clip.id) }
        .contextMenu {
            Button(MacTimelineEditorStrings.selectClip) {
                selection = MacTimelineSelection(trackID: track.id, clipID: clip.id)
            }
            Button(MacTimelineEditorStrings.renameClip) { renameClip = clip }
            Button(MacTimelineEditorStrings.removeClip, role: .destructive) {
                mutate { try $0.removeClip(trackID: track.id, clipID: clip.id) }
                if selection.clipID == clip.id { selection.clipID = nil }
            }
        }
        .accessibilityIdentifier("mac.timeline.clip.\(clip.id.uuidString)")
    }

    // MARK: Preview

    private var previewPane: some View {
        Group {
            if let notice = previewNotice {
                ContentUnavailableView(MacTimelineEditorStrings.previewUnavailable,
                                       systemImage: "film",
                                       description: Text(verbatim: notice))
            } else if let player {
                MacTimelinePlayerView(player: player)
                    .padding(10)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minHeight: 220, idealHeight: 300)
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    // MARK: Inspector

    private var inspector: some View {
        Group {
            if let selected = selectedClip {
                MacClipInspector(track: selected.track, clip: selected.clip, assets: assets,
                                 onMutate: { replacement in
                                     // Value-based handoff: the parent
                                     // re-validates against track siblings.
                                     let target = selected.clip.id
                                     mutateClip(target) { $0 = replacement }
                                 },
                                 onRetitle: { renameClip = selected.clip },
                                 onRemove: {
                                     mutate { try $0.removeClip(trackID: selected.track.id, clipID: selected.clip.id) }
                                     selection.clipID = nil
                                 })
                .id(selected.clip.id)
            } else if let track = draft.track(selection.trackID) {
                MacTrackInspector(track: track) { newName in
                    mutate { try $0.renameTrack(track.id, name: newName) }
                }
            } else {
                ContentUnavailableView(MacTimelineEditorStrings.nothingSelected,
                                       systemImage: "sidebar.right")
            }
        }
        .frame(minHeight: 200, idealHeight: 260)
        .padding(10)
    }

    private var selectedClip: (track: MacTimelineTrack, clip: MacTimelineClip)? {
        guard let clipID = selection.clipID,
              let pair = draft.clip(clipID), pair.track.id == selection.trackID else { return nil }
        return pair
    }

    // MARK: Export footer

    private var exportFooter: some View {
        VStack(alignment: .leading, spacing: 8) {
            if isExporting {
                HStack(spacing: 10) {
                    ProgressView(value: exportProgress).controlSize(.small)
                    Text(MacMediaEditStrings.exportProgress).foregroundStyle(.secondary)
                    Spacer()
                    Button(MacMediaEditStrings.cancelExport) { exportTask?.cancel() }
                        .accessibilityIdentifier("mac.timelineEditor.cancelExport")
                }
            } else if let exported {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text(MacMediaEditStrings.exportedReady).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    if let addToCanvas {
                        Button(MacMediaEditStrings.addToCanvas) {
                            addToCanvas(exported)
                            dismiss()
                        }
                    }
                    if let saveToTask {
                        Button(MacMediaEditStrings.saveToTask) {
                            Task { @MainActor in
                                if await saveToTask(exported) { dismiss() } else { routeFailed = true }
                            }
                        }
                    }
                    Button(MacMediaEditStrings.export) { saveAs(exported) }
                    Button(MacMediaEditStrings.done) { dismiss() }
                        .keyboardShortcut(.defaultAction)
                }
                .alert(MacCanvasText.routeFailed, isPresented: $routeFailed) {
                    Button("OK", role: .cancel) {}
                }
            } else {
                HStack {
                    Text(verbatim: missingAssetsNotice)
                        .font(.caption).foregroundStyle(.orange).lineLimit(1)
                    Spacer()
                    Button(MacTimelineEditorStrings.exportVideo) { startExport() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!draft.hasRenderableVideo)
                        .accessibilityIdentifier("mac.timelineEditor.export")
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    private var missingAssetsNotice: String {
        let missing = draft.tracks.flatMap(\.clips).compactMap(\.sourceURL)
            .filter { assets[$0] == nil }
        guard !missing.isEmpty else { return "" }
        return String(format: MacTimelineEditorStrings.missingAssetsFormat, missing.count)
    }

    // MARK: Draft lifecycle

    private func open() async {
        nameDraft = draft.name
        persistedRevision = draft.revision
        await probeMissingAssets()
        rebuildPreviewNow()
    }

    private func close() {
        persistTask?.cancel(); previewTask?.cancel(); exportTask?.cancel()
        player?.pause(); player = nil
        flushPersist()
    }

    /// Probes every referenced media URL once; files that no longer exist
    /// stay out of the catalog and render as skipped, never deleted.
    private func probeMissingAssets() async {
        var updated = assets
        let urls = Set(draft.tracks.flatMap { $0.clips.compactMap(\.sourceURL) })
        for url in urls where updated[url] == nil {
            if let info = try? await MacTimelineAssetProber.probe(url) {
                updated[url] = info
            }
        }
        assets = updated
    }

    private func mutate(_ change: (inout MacTimelineDraft) throws -> Void) {
        do {
            var next = draft
            try change(&next)
            draft = next
            schedulePersist()
            schedulePreview()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func mutateClip(_ id: UUID, change: (inout MacTimelineClip) throws -> Void) {
        guard let pair = draft.clip(id) else { return }
        do {
            var clip = pair.clip
            try change(&clip)
            // `replaceClip` re-validates overlap against the track siblings.
            mutate { try $0.replaceClip(trackID: pair.track.id, clip: clip) }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func schedulePersist() {
        persistTask?.cancel()
        persistTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            flushPersist()
        }
    }

    private func flushPersist() {
        do {
            try store.save(draft, expectedRevision: persistedRevision)
            persistedRevision = draft.revision
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func schedulePreview() {
        previewTask?.cancel()
        previewTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            rebuildPreviewNow()
        }
    }

    private func rebuildPreviewNow() {
        let frozen = draft, catalog = assets
        previewTask?.cancel()
        previewTask = Task { @MainActor in
            do {
                let build = try await MacTimelineCompositionBuilder.build(draft: frozen, assets: catalog)
                guard !Task.isCancelled, draft.id == frozen.id else { return }
                let item = AVPlayerItem(asset: build.composition)
                item.videoComposition = build.videoComposition
                item.audioMix = build.audioMix
                if let player {
                    player.replaceCurrentItem(with: item)
                } else {
                    player = AVPlayer(playerItem: item)
                }
                previewNotice = nil
            } catch MacTimelineExportError.emptyTimeline {
                previewNotice = MacTimelineExportStrings.emptyTimeline
                player?.replaceCurrentItem(with: nil)
            } catch {
                previewNotice = error.localizedDescription
                player?.replaceCurrentItem(with: nil)
            }
        }
    }

    // MARK: Actions

    private func commitName() {
        mutate { try $0.rename(nameDraft) }
        nameDraft = draft.name
    }

    private func duplicateDraft() {
        do {
            var copy = draft
            copy.id = UUID()
            copy.name = draft.name + (FloeL10n.isChinese ? " 副本" : " Copy")
            try copy.rename(copy.name)
            try store.save(copy)
            onDraftsChanged()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func addTrack(_ kind: MacTrackKind) {
        mutate { value in
            let track = try value.addTrack(kind)
            selection = MacTimelineSelection(trackID: track.id, clipID: nil)
        }
    }

    private func moveTrack(_ id: UUID, direction: Int) {
        guard let from = draft.trackIndex(id) else { return }
        mutate { try $0.moveTrack(id, to: from + direction) }
    }

    private func removeTrack(_ id: UUID) {
        mutate { try $0.removeTrack(id) }
        if selection.trackID == id { selection = MacTimelineSelection(trackID: UUID(), clipID: nil) }
    }

    private func importMedia() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.movie, .audio, .image]
        guard panel.runModal() == .OK else { return }
        Task { await insertMedia(panel.urls) }
    }

    private func insertMedia(_ urls: [URL]) async {
        for url in urls {
            do {
                let info = try await MacTimelineAssetProber.probe(url)
                assets[url] = info
                try insertProbedMedia(url: url, info: info)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Media-kind routing with iPad parity: movies and images join visual
    /// tracks (images default to a 5s still, like the iPad image import),
    /// audio joins audio tracks. New clips are appended after the track's
    /// current content so reordering is always explicit.
    private func insertProbedMedia(url: URL, info: MacTimelineAssetInfo) throws {
        let title = url.deletingPathExtension().lastPathComponent
        if info.isStillImage {
            try insertClip(MacTimelineClip.media(
                sourceURL: url, title: title, timelineStart: 0,
                duration: 5), kind: .visual)
        } else if info.isVisualMovie {
            try insertClip(MacTimelineClip.media(
                sourceURL: url, title: title, timelineStart: 0,
                duration: info.duration), kind: .visual)
        } else if info.hasAudio {
            try insertClip(MacTimelineClip.media(
                sourceURL: url, title: title, timelineStart: 0,
                duration: info.duration), kind: .audio)
        } else {
            throw MacTimelineExportError.unsupportedSource(url.lastPathComponent)
        }
    }

    private func insertClip(_ clip: MacTimelineClip, kind: MacTrackKind) throws {
        var value = draft
        var trackID = selection.trackID
        if value.track(trackID)?.kind != kind {
            if let existing = value.tracks.first(where: { $0.kind == kind && !$0.isMuted }) {
                trackID = existing.id
            } else {
                trackID = try value.addTrack(kind).id
            }
        }
        guard let target = value.track(trackID) else { throw MacTimelineError.missingTrack(trackID) }
        var clip = clip
        // Append after the track's current end; fall back to the timeline end.
        let start = max(target.duration, 0)
        clip.timelineRange = try .seconds(start: start, duration: clip.timelineRange.durationSeconds)
        try value.addClip(clip, toTrack: trackID)
        draft = value
        selection = MacTimelineSelection(trackID: trackID, clipID: clip.id)
        schedulePersist()
        schedulePreview()
    }

    private func importSubtitles() {
        let panel = NSOpenPanel()
        var types: [UTType] = [.plainText, .data]
        if let srt = UTType(filenameExtension: "srt") { types.append(srt) }
        if let vtt = UTType(filenameExtension: "vtt") { types.append(vtt) }
        panel.allowedContentTypes = types
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let data = try Data(contentsOf: url)
            guard let text = String(data: data, encoding: .utf8) else {
                throw MacSubtitleImportError(.malformed)
            }
            let cues = try MacSubtitleCodec.parse(text)
            mutate { try $0.importCues(cues) }
        } catch let failure as MacSubtitleCodec.Failure {
            errorMessage = MacSubtitleImportError(failure).localizedDescription
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func exportSubtitles(format: MacSubtitleCodec.Format) {
        do {
            let content = try MacSubtitleCodec.encode(draft.captionCues, format: format)
            let panel = NSSavePanel()
            panel.allowedContentTypes = [UTType(filenameExtension: format == .srt ? "srt" : "vtt") ?? .plainText]
            panel.nameFieldStringValue = "\(draft.name).\(format == .srt ? "srt" : "vtt")"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try Data(content.utf8).write(to: url, options: .atomic)
        } catch {
            errorMessage = MacSubtitleStrings.exportFailed + "\n" + error.localizedDescription
        }
    }

    // MARK: Export

    private func startExport() {
        isExporting = true
        exportProgress = 0
        exported = nil
        exportError = nil
        let frozen = draft, catalog = assets
        exportTask = Task { @MainActor in
            defer { isExporting = false }
            do {
                let destination = FileManager.default.temporaryDirectory
                    .appendingPathComponent("FloeTimeline-\(frozen.id.uuidString)-\(UUID().uuidString).mp4")
                let exporter = MacTimelineExporter()
                try await exporter.export(draft: frozen, assets: catalog, to: destination) { [self] value in
                    Task { @MainActor in exportProgress = value }
                }
                guard !Task.isCancelled else { return }
                exportProgress = 1
                exported = destination
            } catch is CancellationError {
                exportError = MacMediaEditStrings.cancelled
            } catch let error as LocalizedError {
                exportError = error.localizedDescription
            } catch {
                exportError = error.localizedDescription
            }
        }
    }

    private func saveAs(_ url: URL) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.nameFieldStringValue = "\(draft.name).mp4"
        panel.begin { response in
            guard response == .OK, let target = panel.url else { return }
            do {
                let manager = FileManager.default
                if manager.fileExists(atPath: target.path) {
                    _ = try manager.replaceItemAt(target, withItemAt: url)
                } else {
                    try manager.copyItem(at: url, to: target)
                }
            } catch {
                routeFailed = true
            }
        }
    }
}

// MARK: - Player

private struct MacTimelinePlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.videoGravity = .resizeAspect
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }

    static func dismantleNSView(_ view: AVPlayerView, coordinator: Void) {
        view.player?.pause()
        view.player = nil
    }
}

// MARK: - Track inspector

private struct MacTrackInspector: View {
    let track: MacTimelineTrack
    let onRename: (String) -> Void
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(MacTimelineEditorStrings.trackSection).font(.headline)
            HStack {
                Text(MacTimelineEditorStrings.trackName)
                TextField(track.name, text: $name)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { commit() }
            }
            Text(verbatim: String(format: MacTimelineEditorStrings.trackSummaryFormat,
                                  track.clips.count, track.duration))
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
        }
        .onAppear { name = track.name }
    }

    private func commit() {
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty { onRename(title) }
    }
}

// MARK: - Clip inspector

private struct MacClipInspector: View {
    let track: MacTimelineTrack
    let clip: MacTimelineClip
    let assets: [URL: MacTimelineAssetInfo]
    /// Receives the fully validated replacement clip; the parent commits it
    /// against the draft (value-based handoff, no inout across view
    /// boundaries).
    let onMutate: (MacTimelineClip) -> Void
    let onRetitle: () -> Void
    let onRemove: () -> Void
    @State private var applyError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(clip.captionText != nil
                         ? MacTimelineEditorStrings.captionClip
                         : MacTimelineEditorStrings.mediaClip)
                        .font(.headline)
                    Spacer()
                    Button(MacTimelineEditorStrings.renameClip) { onRetitle() }
                }
                if let captionText = clip.captionText {
                    CaptionClipFields(clip: clip, text: captionText,
                                      onMutate: { mutation in
                                          let submit = mutation
                                          apply(submit)
                                      },
                                      onApply: { value in apply { $0.captionText = value } })
                } else {
                    mediaFields
                }
                Divider()
                HStack {
                    Toggle(MacTimelineEditorStrings.muteClip,
                           isOn: Binding(get: { clip.isMuted },
                                         set: { value in apply { $0.isMuted = value } }))
                    Spacer()
                    Button(MacTimelineEditorStrings.removeClip, role: .destructive) {
                        onRemove()
                    }
                }
                if track.kind != .caption {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(MacTimelineEditorStrings.clipVolume)
                            .font(.caption).foregroundStyle(.secondary)
                        Slider(value: Binding(get: { clip.volume },
                                              set: { value in apply { $0.volume = value } }),
                               in: 0...2).labelsHidden()
                    }
                }
                if track.kind == .visual, clip.captionText == nil {
                    Divider()
                    MacGradeSection(clip: clip) { grade in
                        apply { $0.grade = grade }
                    }
                }
            }
        }
        .alert(MacTimelineEditorStrings.errorTitle, isPresented: Binding(
            get: { applyError != nil }, set: { if !$0 { applyError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(verbatim: applyError ?? "") }
    }

    private var mediaFields: some View {
        VStack(alignment: .leading, spacing: 8) {
            MacTimeValueField(label: MacTimelineEditorStrings.timelineStart,
                              value: clip.timelineRange.startSeconds) { value in
                apply { clip in
                    let range = try MacTimeRange.seconds(
                        start: value, duration: clip.timelineRange.durationSeconds)
                    clip.timelineRange = range
                }
            }
            MacTimeValueField(label: MacTimelineEditorStrings.timelineDuration,
                              value: clip.timelineRange.durationSeconds) { value in
                apply { clip in
                    guard value > 0 else { throw MacTimelineError.invalidTime }
                    let timeline = try MacTimeRange.seconds(
                        start: clip.timelineRange.startSeconds, duration: value)
                    let source = try MacTimeRange.seconds(
                        start: clip.sourceRange.startSeconds, duration: value)
                    clip.timelineRange = timeline
                    clip.sourceRange = source
                }
            }
            if let url = clip.sourceURL, let info = assets[url] {
                MacTimeValueField(label: MacTimelineEditorStrings.sourceStart,
                                  value: clip.sourceRange.startSeconds) { value in
                    apply { clip in
                        guard value >= 0,
                              value + clip.sourceRange.durationSeconds <= info.duration + 0.05 else {
                            throw MacTimelineError.invalidTime
                        }
                        let range = try MacTimeRange.seconds(
                            start: value, duration: clip.sourceRange.durationSeconds)
                        clip.sourceRange = range
                    }
                }
                Text(verbatim: String(format: MacTimelineEditorStrings.sourceDurationFormat, info.duration))
                    .font(.caption).foregroundStyle(.secondary)
            } else if let url = clip.sourceURL {
                Label(String(format: MacTimelineEditorStrings.missingAssetFormat, url.lastPathComponent),
                      systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
    }

    /// Routes the mutation through the validated clip initializer so
    /// geometry/overlap/caption rules refuse bad values with a visible
    /// error, then hands the validated value to the parent.
    private func apply(_ change: (inout MacTimelineClip) throws -> Void) {
        var next = clip
        do {
            try change(&next)
            let revalidated = try MacTimelineClip(
                id: next.id, sourceURL: next.sourceURL, title: next.title,
                timelineRange: next.timelineRange, sourceRange: next.sourceRange,
                isMuted: next.isMuted, volume: next.volume,
                captionText: next.captionText, grade: next.grade)
            onMutate(revalidated)
        } catch {
            applyError = error.localizedDescription
        }
    }
}

/// Caption clip geometry + text. The text edits locally and commits
/// explicitly; empty text is rejected by the model instead of being forced.
/// Geometry submits a mutation closure; multi-statement bodies keep the
/// Swift 6 checker on the contextual `inout` signature.
private struct CaptionClipFields: View {
    let clip: MacTimelineClip
    let text: String
    let onMutate: ((inout MacTimelineClip) throws -> Void) -> Void
    let onApply: (String) -> Void
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            MacTimeValueField(label: MacTimelineEditorStrings.timelineStart,
                              value: clip.timelineRange.startSeconds) { value in
                onMutate { clip in
                    let range = try MacTimeRange.seconds(
                        start: value, duration: clip.timelineRange.durationSeconds)
                    clip.timelineRange = range
                }
            }
            MacTimeValueField(label: MacTimelineEditorStrings.timelineDuration,
                              value: clip.timelineRange.durationSeconds) { value in
                guard value > 0 else { throw MacTimelineError.invalidTime }
                onMutate { clip in
                    let timeline = try MacTimeRange.seconds(
                        start: clip.timelineRange.startSeconds, duration: value)
                    let source = try MacTimeRange.seconds(start: 0, duration: value)
                    clip.timelineRange = timeline
                    clip.sourceRange = source
                }
            }
            TextEditor(text: $draft)
                .font(.body)
                .frame(minHeight: 72)
                .border(Color.secondary.opacity(0.3))
            HStack {
                Spacer()
                Button(MacTimelineEditorStrings.applyCaption) {
                    let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    onApply(trimmed)
                }
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .onAppear { draft = text }
    }
}

// MARK: - Grade section

private struct MacGradeSection: View {
    let clip: MacTimelineClip
    let onApply: (MacVideoGrade?) -> Void
    @State private var draft = MacVideoGrade()
    @State private var tone = MacToneRange.midtones
    @State private var importingLUT = false
    @State private var lutError: String?

    private enum MacToneRange: String, CaseIterable {
        case shadows, midtones, highlights
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(MacTimelineEditorStrings.gradeSection).font(.headline)
            filterPicker
            toneCurveControls
            colorWheels
            hslControls
            lutRow
            HStack {
                Button(MacTimelineEditorStrings.applyGrade) {
                    var value = draft
                    if value.isEmpty { value.filterID = "CIPhotoEffectChrome" }
                    onApply(value.isEmpty ? nil : value)
                }
                Button(MacTimelineEditorStrings.removeGrade) {
                    draft = MacVideoGrade()
                    onApply(nil)
                }
                .disabled(clip.grade == nil)
            }
        }
        .onAppear(perform: load)
    }

    private func load() {
        draft = clip.grade ?? MacVideoGrade()
    }

    private var filterPicker: some View {
        Picker(MacTimelineEditorStrings.gradeFilter, selection: Binding(
            get: { draft.filterID ?? "" },
            set: { value in
                draft.filterID = value.isEmpty ? nil : value
                if !value.isEmpty { draft.colorLUT = nil; draft.lutName = nil }
            })) {
            Text(MacTimelineEditorStrings.gradeFilterNone).tag("")
            Text(MacTimelineEditorStrings.gradeFilterMono).tag("CIPhotoEffectMono")
            Text(MacTimelineEditorStrings.gradeFilterNoir).tag("CIPhotoEffectNoir")
            Text(MacTimelineEditorStrings.gradeFilterChrome).tag("CIPhotoEffectChrome")
            Text(MacTimelineEditorStrings.gradeFilterFade).tag("CIPhotoEffectFade")
            Text(MacTimelineEditorStrings.gradeFilterInstant).tag("CIPhotoEffectInstant")
            Text(MacTimelineEditorStrings.gradeFilterSepia).tag("CISepiaTone")
        }
    }

    private var toneCurveControls: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(MacTimelineEditorStrings.gradeToneCurve).font(.subheadline).foregroundStyle(.secondary)
            toneSlider(MacTimelineEditorStrings.gradeShadows, index: 1)
            toneSlider(MacTimelineEditorStrings.gradeMidtones, index: 2)
            toneSlider(MacTimelineEditorStrings.gradeHighlights, index: 3)
        }
    }

    private func toneSlider(_ title: String, index: Int) -> some View {
        HStack(spacing: 8) {
            Text(title).frame(width: 76, alignment: .trailing)
                .font(.caption).foregroundStyle(.secondary)
            Slider(value: Binding(
                get: { (draft.toneCurve?[safe: index]?.y ?? MacGradeSection.identityPoint(index)) },
                set: { value in
                    var curve = draft.toneCurve ?? MacGradeSection.identityCurve
                    curve[index].y = min(1, max(0, value))
                    draft.toneCurve = curve
                }), in: 0...1).labelsHidden()
        }
    }

    private var colorWheels: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(MacTimelineEditorStrings.gradeWheels).font(.subheadline).foregroundStyle(.secondary)
            Picker("", selection: $tone) {
                Text(MacTimelineEditorStrings.gradeShadows).tag(MacToneRange.shadows)
                Text(MacTimelineEditorStrings.gradeMidtones).tag(MacToneRange.midtones)
                Text(MacTimelineEditorStrings.gradeHighlights).tag(MacToneRange.highlights)
            }.pickerStyle(.segmented).labelsHidden()
            balanceSlider("R", \.red)
            balanceSlider("G", \.green)
            balanceSlider("B", \.blue)
            Toggle(MacTimelineEditorStrings.gradePreserveLuminance,
                   isOn: Binding(get: { draft.colorBalance?.preserveLuminance ?? true },
                                 set: { value in
                                     var balance = draft.colorBalance ?? MacColorBalance()
                                     balance.preserveLuminance = value
                                     draft.colorBalance = balance
                                 }))
        }
    }

    private func balanceSlider(_ title: String,
                               _ key: WritableKeyPath<MacRGBBalance, Double>) -> some View {
        HStack(spacing: 8) {
            Text(title).frame(width: 76, alignment: .trailing)
                .font(.caption).foregroundStyle(.secondary)
            Slider(value: Binding(
                get: { selectedBalance[keyPath: key] },
                set: { value in
                    var balance = draft.colorBalance ?? MacColorBalance()
                    var range = selectedBalance
                    range[keyPath: key] = min(1, max(-1, value))
                    setSelectedBalance(range, into: &balance)
                    draft.colorBalance = balance
                }), in: -1...1).labelsHidden()
        }
    }

    private var selectedBalance: MacRGBBalance {
        let balance = draft.colorBalance ?? MacColorBalance()
        switch tone {
        case .shadows: return balance.shadows
        case .highlights: return balance.highlights
        case .midtones: return balance.midtones
        }
    }

    private func setSelectedBalance(_ value: MacRGBBalance, into balance: inout MacColorBalance) {
        switch tone {
        case .shadows: balance.shadows = value
        case .highlights: balance.highlights = value
        case .midtones: balance.midtones = value
        }
    }

    private var hslControls: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(MacTimelineEditorStrings.gradeHSL).font(.subheadline).foregroundStyle(.secondary)
            hslSlider(MacTimelineEditorStrings.gradeHueShift, \.hueShift, -180...180)
            hslSlider(MacTimelineEditorStrings.gradeSaturationScale, \.saturationScale, 0...2)
            hslSlider(MacTimelineEditorStrings.gradeLightnessShift, \.lightnessShift, -1...1)
            hslSlider(MacTimelineEditorStrings.gradeMix, \.mix, 0...1)
        }
    }

    private func hslSlider(_ title: String,
                           _ key: WritableKeyPath<MacHSLSecondary, Double>,
                           _ range: ClosedRange<Double>) -> some View {
        HStack(spacing: 8) {
            Text(title).frame(width: 96, alignment: .trailing)
                .font(.caption).foregroundStyle(.secondary)
            Slider(value: Binding(
                get: { (draft.secondary ?? MacHSLSecondary())[keyPath: key] },
                set: { value in
                    var secondary = draft.secondary ?? MacHSLSecondary()
                    secondary[keyPath: key] = value
                    draft.secondary = secondary
                }), in: range).labelsHidden()
        }
    }

    private var lutRow: some View {
        HStack(spacing: 8) {
            Button(MacTimelineEditorStrings.gradeImportLUT) { importingLUT = true }
            if let lutName = draft.lutName {
                Text(verbatim: lutName).font(.caption).lineLimit(1)
                    .foregroundStyle(.secondary)
                Button(MacTimelineEditorStrings.gradeClearLUT) {
                    draft.colorLUT = nil; draft.lutName = nil
                }
            }
        }
        .fileImporter(isPresented: $importingLUT, allowedContentTypes: [.plainText, .data]) { result in
            do {
                let url = try result.get()
                guard url.pathExtension.lowercased() == "cube" else {
                    throw MacVideoGradeError.invalidLUT(MacTimelineEditorStrings.gradeLUTExtension)
                }
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                let text = try String(contentsOf: url, encoding: .utf8)
                draft.colorLUT = try MacColorLUT.parseCube(text)
                draft.lutName = url.lastPathComponent
                draft.filterID = nil
            } catch {
                lutError = error.localizedDescription
            }
        }
        .alert(MacSubtitleStrings.importFailed, isPresented: Binding(
            get: { lutError != nil }, set: { if !$0 { lutError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(verbatim: lutError ?? "") }
    }

    private static let identityCurve: [MacCurvePoint] = [
        .init(x: 0, y: 0), .init(x: 0.25, y: 0.25), .init(x: 0.5, y: 0.5),
        .init(x: 0.75, y: 0.75), .init(x: 1, y: 1),
    ]

    private static func identityPoint(_ index: Int) -> Double {
        identityCurve[index].y
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

// MARK: - Value field + rename sheet

private struct MacTimeValueField: View {
    let label: String
    let value: Double
    let onCommit: (Double) throws -> Void
    @State private var text = ""
    @State private var failure: String?

    var body: some View {
        HStack(spacing: 8) {
            Text(label).frame(width: 110, alignment: .trailing)
                .font(.caption).foregroundStyle(.secondary)
            TextField(String(format: "%.2f", value), text: $text)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 110)
                .onSubmit(commit)
                .onChange(of: value) { _, new in text = String(format: "%.2f", new) }
            Text("s").font(.caption).foregroundStyle(.tertiary)
        }
        .onAppear { text = String(format: "%.2f", value) }
        .alert(label, isPresented: Binding(
            get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(verbatim: failure ?? "") }
    }

    private func commit() {
        guard let parsed = Double(text.replacingOccurrences(of: ",", with: ".")),
              parsed.isFinite else {
            failure = MacTimelineError.invalidTime.localizedDescription
            return
        }
        do {
            try onCommit(parsed)
        } catch {
            failure = error.localizedDescription
        }
    }
}

private struct MacTimelineRenameSheet: View {
    let title: String
    let value: String
    let onSave: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.headline)
            TextField(value, text: $text).frame(width: 300)
            HStack {
                Spacer()
                Button(MacTimelineEditorStrings.cancel, role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(MacTimelineEditorStrings.save) {
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { onSave(trimmed) }
                    dismiss()
                }.keyboardShortcut(.defaultAction)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .onAppear { text = value }
    }
}

// MARK: - Bilingual strings

enum MacTimelineEditorStrings {
    static var draftNamePlaceholder: String { t(en: "Timeline name", zh: "时间线名称") }
    static var durationFormat: String { t(en: "Duration %.2fs", zh: "时长 %.2f 秒") }
    static var draftActions: String { t(en: "Draft Actions", zh: "草稿操作") }
    static var duplicateDraft: String { t(en: "Duplicate Draft", zh: "复制草稿") }
    static var deleteDraft: String { t(en: "Delete Draft…", zh: "删除草稿…") }
    static var deleteDraftTitle: String { t(en: "Delete this timeline draft?", zh: "删除此时间线草稿？") }
    static var deleteDraftConfirm: String { t(en: "Delete", zh: "删除") }
    static var cancel: String { t(en: "Cancel", zh: "取消") }
    static var save: String { t(en: "Save", zh: "保存") }
    static var close: String { t(en: "Close", zh: "关闭") }
    static var errorTitle: String { t(en: "Timeline", zh: "时间线") }
    static var addVideoTrack: String { t(en: "Video", zh: "视频") }
    static var addAudioTrack: String { t(en: "Audio", zh: "音频") }
    static var addCaptionTrack: String { t(en: "Captions", zh: "字幕") }
    static var addMedia: String { t(en: "Add Media…", zh: "添加媒体…") }
    static var subtitleMenu: String { t(en: "Subtitles", zh: "字幕") }
    static var emptyTracks: String { t(en: "No tracks yet", zh: "还没有轨道") }
    static var emptyTracksHint: String {
        t(en: "Add a video, audio or caption track, then add media to it.", zh: "添加视频、音频或字幕轨道，然后再加入媒体。")
    }
    static var captionKind: String { t(en: "captions", zh: "字幕") }
    static var clipCountFormat: String { t(en: "%d clip(s)", zh: "%d 个片段") }
    static var muteTrack: String { t(en: "Mute track", zh: "静音轨道") }
    static var moveTrackUp: String { t(en: "Move up", zh: "上移") }
    static var moveTrackDown: String { t(en: "Move down", zh: "下移") }
    static var removeTrack: String { t(en: "Remove track", zh: "移除轨道") }
    static var volume: String { t(en: "Volume", zh: "音量") }
    static var dropHint: String { t(en: "Use Add Media to place clips here.", zh: "使用“添加媒体”加入片段。") }
    static var selectClip: String { t(en: "Select", zh: "选择") }
    static var renameClip: String { t(en: "Rename Clip…", zh: "重命名片段…") }
    static var removeClip: String { t(en: "Remove Clip", zh: "移除片段") }
    static var previewUnavailable: String { t(en: "Preview Unavailable", zh: "预览不可用") }
    static var nothingSelected: String { t(en: "Select a clip or track", zh: "选择一个片段或轨道") }
    static var exportVideo: String { t(en: "Export Video…", zh: "导出视频…") }
    static var missingAssetsFormat: String {
        t(en: "%d source file(s) missing — affected clips are skipped.", zh: "%d 个源文件缺失，相应片段将被跳过。")
    }
    static var trackSection: String { t(en: "Track", zh: "轨道") }
    static var trackName: String { t(en: "Name", zh: "名称") }
    static var trackSummaryFormat: String {
        t(en: "%d clip(s) · ends at %.2fs", zh: "%d 个片段 · 结束于 %.2f 秒")
    }
    static var captionClip: String { t(en: "Caption Clip", zh: "字幕片段") }
    static var mediaClip: String { t(en: "Clip", zh: "片段") }
    static var muteClip: String { t(en: "Mute clip", zh: "静音片段") }
    static var clipVolume: String { t(en: "Clip volume", zh: "片段音量") }
    static var timelineStart: String { t(en: "Timeline start", zh: "时间线起点") }
    static var timelineDuration: String { t(en: "Timeline duration", zh: "时间线时长") }
    static var sourceStart: String { t(en: "Source start", zh: "源起点") }
    static var sourceDurationFormat: String { t(en: "Source duration: %.2fs", zh: "源时长：%.2f 秒") }
    static var missingAssetFormat: String { t(en: "%@ is missing on disk.", zh: "磁盘上找不到 %@。") }
    static var gradeSection: String { t(en: "Grade", zh: "调色") }
    static var applyGrade: String { t(en: "Apply to Clip", zh: "应用到片段") }
    static var removeGrade: String { t(en: "Remove Grade", zh: "移除调色") }
    static var gradeFilter: String { t(en: "Filter", zh: "滤镜") }
    static var gradeFilterNone: String { t(en: "None", zh: "无") }
    static var gradeFilterMono: String { t(en: "Mono", zh: "黑白") }
    static var gradeFilterNoir: String { t(en: "Noir", zh: "黑色电影") }
    static var gradeFilterChrome: String { t(en: "Chrome", zh: "鲜艳") }
    static var gradeFilterFade: String { t(en: "Fade", zh: "褪色") }
    static var gradeFilterInstant: String { t(en: "Instant", zh: "即时成像") }
    static var gradeFilterSepia: String { t(en: "Sepia", zh: "棕褐色") }
    static var gradeToneCurve: String { t(en: "Tone curve", zh: "色调曲线") }
    static var gradeShadows: String { t(en: "Shadows", zh: "阴影") }
    static var gradeMidtones: String { t(en: "Midtones", zh: "中间调") }
    static var gradeHighlights: String { t(en: "Highlights", zh: "高光") }
    static var gradeWheels: String { t(en: "Color balance", zh: "色彩平衡") }
    static var gradePreserveLuminance: String { t(en: "Preserve luminance", zh: "保持亮度") }
    static var gradeHSL: String { t(en: "HSL secondary", zh: "HSL 辅助调色") }
    static var gradeHueShift: String { t(en: "Hue shift", zh: "色相偏移") }
    static var gradeSaturationScale: String { t(en: "Saturation", zh: "饱和度") }
    static var gradeLightnessShift: String { t(en: "Lightness shift", zh: "亮度偏移") }
    static var gradeMix: String { t(en: "Mix", zh: "混合") }
    static var gradeImportLUT: String { t(en: "Import .cube LUT…", zh: "导入 .cube LUT…") }
    static var gradeClearLUT: String { t(en: "Clear", zh: "清除") }
    static var gradeLUTExtension: String { t(en: "expected a .cube file", zh: "需要 .cube 文件") }
    static var applyCaption: String { t(en: "Apply Caption", zh: "应用字幕") }
    static var renameTrack: String { t(en: "Rename Track", zh: "重命名轨道") }

    private static func t(en: String, zh: String) -> String {
        FloeL10n.isChinese ? zh : en
    }
}
