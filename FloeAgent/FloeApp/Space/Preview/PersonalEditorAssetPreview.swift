// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import UIKit
import FloeWorkbench
import FloeMusicCore
import FloeMusicNative

/// A real material thumbnail. Only its explicit preview button opens the
/// read-only route; existing insert/select/trim actions keep their own owner.
struct PersonalEditorAssetPreview: View {
    let sourceID: String
    let title: String
    var opensQuickPreview = true
    let request: @MainActor (Int) async throws -> PersonalContentPreviewRequest
    @State private var thumbnail: PersonalContentPreviewRequest?
    @State private var failed = false
    @State private var opening = false
    @State private var token = UUID()
    @State private var openTask: Task<Void, Never>?
    @State private var presented: Presented?
    private struct Presented: Identifiable { let id = UUID(); let request: PersonalContentPreviewRequest; let title: String }
    var body: some View {
        Group {
            if opensQuickPreview { Button(action: open) { content }.buttonStyle(.borderless) }
            else { content.accessibilityHidden(true) }
        }
        .accessibilityLabel(previewText("预览", "Preview") + " · " + title)
        .accessibilityHidden(!opensQuickPreview)
        .task(id: sourceID) {
            thumbnail = nil; failed = false
            do {
                let value = try await request(128)
                guard !Task.isCancelled else { return }; thumbnail = value
            } catch { if !Task.isCancelled { failed = true } }
        }
        .sheet(item: $presented) { item in PersonalContentQuickPreview(request: item.request, title: item.title) }
        .onChange(of: sourceID) { _, _ in openTask?.cancel(); token = UUID(); opening = false; presented = nil }
        .onDisappear { openTask?.cancel(); openTask = nil; token = UUID(); opening = false }
    }
    private var content: some View {
        ZStack {
            Color(uiColor: .secondarySystemBackground)
            if let thumbnail { PersonalContentPreviewView(request: thumbnail) }
            else if failed { Text(previewText("暂无预览", "No preview")).font(.system(size: 9)).foregroundStyle(.secondary).multilineTextAlignment(.center) }
            else { ProgressView().controlSize(.mini) }
            if opening { ProgressView().controlSize(.mini).padding(4).background(.regularMaterial, in: Circle()) }
        }.clipShape(.rect(cornerRadius: 5))
    }
    private func open() {
        guard !opening else { return }
        let current = UUID(); token = current; opening = true
        openTask = Task {
            defer { if token == current { opening = false; openTask = nil } }
            do {
                let value = try await request(1_024)
                try await value.validate()
                guard !Task.isCancelled, token == current else { return }
                presented = .init(request: value, title: title)
            } catch { if !Task.isCancelled, token == current { failed = true; thumbnail = nil } }
        }
    }
}

@MainActor enum PersonalEditorPreviewRequests {
    static func mediaAsset(session: MediaV2Session, asset: MediaAssetReference, pixels: Int,
                           seconds: Double = 0) async throws -> PersonalContentPreviewRequest {
        let id = session.id, revision = session.document.revision, root = session.root.standardizedFileURL.resolvingSymlinksInPath()
        guard session.document.asset(asset.id) == asset else { throw PersonalContentPreviewError.sourceChanged }
        let url = asset.relativePath.hasPrefix("/") ? URL(fileURLWithPath: asset.relativePath) : root.appendingPathComponent(asset.relativePath)
        let kind: PersonalContentPreviewProducers.FileKind = asset.kind == .image ? .image : asset.kind == .audio ? .audio : .video
        return try await PersonalContentPreviewProducers.file(ownerID: "media:\(id):\(previewHash(Data(root.path.utf8)))",
            objectID: asset.id.uuidString, revision: String(revision), root: root, url: url, kind: kind,
            maximumPixelSize: pixels, expectedSHA256: asset.contentHash, seconds: seconds, validate: {
                guard session.id == id, session.root.standardizedFileURL.resolvingSymlinksInPath() == root,
                      session.document.revision == revision, session.document.asset(asset.id) == asset else {
                    throw PersonalContentPreviewError.sourceChanged
                }
            })
    }
    static func mediaClip(session: MediaV2Session, track: MediaPreparedTrack, clip: MediaPreparedClip, pixels: Int) async throws -> PersonalContentPreviewRequest {
        let document = session.document, project = session.project
        let validate: @MainActor @Sendable () async throws -> Void = {
            guard session.document.id == document.id, session.document.revision == document.revision,
                  session.document.trackGraph.tracks.first(where: { $0.id == track.id })?.clips.first(where: { $0.id == clip.id }) == clip else {
                throw PersonalContentPreviewError.sourceChanged
            }
        }
        let base: PersonalContentPreviewRequest
        if track.kind == .caption, let text = clip.captionText {
            base = .init(key: .init(ownerID: "media:\(session.id)", objectID: clip.id.uuidString,
                revision: String(document.revision), variant: "caption:\(previewHash(Data(session.root.path.utf8))):\(previewHash(Data(text.utf8)))", maximumPixelSize: pixels), validate: validate,
                produce: { .init(.text(text), provenance: .readableText) })
        } else if track.kind == .visual {
            base = try await PersonalContentPreviewProducers.media(project: project, root: session.root,
                ownerID: "media:\(session.id)", maximumPixelSize: pixels, seconds: clip.timelineRange.startSeconds, validate: validate)
        } else if let assetID = clip.assetID, let asset = document.asset(assetID) {
            base = try await mediaAsset(session: session, asset: asset, pixels: pixels, seconds: clip.sourceRange.startSeconds)
        } else { throw PersonalContentPreviewError.notPrepared }
        let key = PersonalContentPreviewKey(ownerID: base.key.ownerID, objectID: "clip:\(clip.id)", revision: base.key.revision,
            variant: base.key.variant, maximumPixelSize: pixels)
        return .init(key: key, validate: { try await validate(); try await base.validate() }, produce: base.produce)
    }

    static func musicAsset(session: MusicProjectSession, asset: MusicAsset, pixels: Int) async throws -> PersonalContentPreviewRequest {
        let revision = session.document.revision, root = session.root.standardizedFileURL.resolvingSymlinksInPath()
        guard session.document.assets.first(where: { $0.id == asset.id }) == asset else { throw PersonalContentPreviewError.sourceChanged }
        let url = try await session.repository.resolvedURL(for: asset)
        let validate: @MainActor @Sendable () async throws -> Void = {
            guard session.document.revision == revision, session.document.assets.first(where: { $0.id == asset.id }) == asset,
                  try await session.repository.resolvedURL(for: asset) == url else { throw PersonalContentPreviewError.sourceChanged }
        }
        if asset.kind != .midiFile {
            if case .unsupportedRaw = asset.kind { throw PersonalContentPreviewError.unsupported }
            return try await PersonalContentPreviewProducers.file(ownerID: "music:\(session.id)", objectID: asset.id.rawValue,
                revision: "\(revision):\(asset.sourceRevision)", root: root, url: url, kind: .audio,
                maximumPixelSize: pixels, expectedSHA256: asset.contentHash, validate: validate)
        }
        let file = try await personalPreviewOffMain { try PersonalPreviewFile(root: root, url: url, maximumBytes: 8 * 1_024 * 1_024) }
        let key = PersonalContentPreviewKey(ownerID: "music:\(session.id)", objectID: asset.id.rawValue,
            revision: "\(revision):\(asset.sourceRevision)", variant: file.identity.token, maximumPixelSize: pixels)
        let sampleRate = session.document.tempoMap.sampleRate
        return .init(key: key, validate: { try await validate(); try file.validate() }, produce: {
            let sequence = try await personalPreviewOffMain {
                try file.verifyHash(asset.contentHash)
                let value = try MusicMIDINoteImport.read(url: url, sampleRate: sampleRate)
                guard value.source.contentHash == asset.contentHash else { throw PersonalContentPreviewError.sourceChanged }
                try file.validate(); return value
            }
            guard let clip = sequence.tracks.flatMap(\.clips).first else { throw PersonalContentPreviewError.notPrepared }
            return try midiClip(clip, maximumPixelSize: key.maximumPixelSize)
        })
    }
    static func musicClip(session: MusicProjectSession, clip: FloeMusicCore.MusicClip, pixels: Int) async throws -> PersonalContentPreviewRequest {
        let revision = session.document.revision
        let validate: @MainActor @Sendable () async throws -> Void = {
            guard session.document.revision == revision,
                  session.document.tracks.flatMap(\.clips).first(where: { $0.id == clip.id }) == clip else { throw PersonalContentPreviewError.sourceChanged }
        }
        if case .audio(let audio) = clip.body {
            guard let asset = session.document.assets.first(where: { $0.id == audio.assetID }) else { throw PersonalContentPreviewError.unavailable }
            return try await musicAsset(session: session, asset: asset, pixels: pixels)
        }
        return .init(key: .init(ownerID: "music:\(session.id)", objectID: clip.id.rawValue, revision: String(revision), maximumPixelSize: pixels),
            validate: validate, produce: { try midiClip(clip, maximumPixelSize: pixels) })
    }

    /// Draws only actual MIDI note events, with tick and pitch axes. This is
    /// deliberately a note preview; no waveform, synthesizer or mixed audio.
    static func midiClip(_ clip: FloeMusicCore.MusicClip, maximumPixelSize: Int) throws -> PersonalContentPreviewArtifact {
        guard case .midi(let payload) = clip.body, !payload.notes.isEmpty else { throw PersonalContentPreviewError.notPrepared }
        guard payload.notes.count <= 10_000, payload.durationTicks > 0 else { throw PersonalContentPreviewError.tooLarge }
        try Task.checkCancellation()
        let edge = CGFloat(min(1_024, max(64, maximumPixelSize)))
        let size = CGSize(width: edge, height: max(64, edge * 0.625))
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        let lower = max(0, (payload.notes.map(\.pitch).min() ?? 60) - 1), upper = min(127, (payload.notes.map(\.pitch).max() ?? 72) + 1)
        let count = max(1, upper - lower + 1)
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.systemBackground.setFill(); context.fill(CGRect(origin: .zero, size: size))
            let area = CGRect(x: 22, y: 6, width: max(1, size.width - 28), height: max(1, size.height - 22))
            let height = area.height / CGFloat(count)
            for pitch in lower...upper {
                let y = area.minY + CGFloat(upper - pitch) * height
                UIColor.secondaryLabel.withAlphaComponent(0.12).setFill(); context.fill(CGRect(x: area.minX, y: y, width: area.width, height: 0.5))
                if pitch == lower || pitch == upper || pitch % 12 == 0 {
                    (String(pitch) as NSString).draw(at: CGPoint(x: 1, y: y), withAttributes: [.font: UIFont.systemFont(ofSize: 8), .foregroundColor: UIColor.secondaryLabel])
                }
            }
            for note in payload.notes {
                let x = area.minX + CGFloat(Double(note.startTick.value) / Double(payload.durationTicks)) * area.width
                let width = max(1, CGFloat(Double(note.durationTicks) / Double(payload.durationTicks)) * area.width)
                let y = area.minY + CGFloat(upper - note.pitch) * height
                UIColor.systemTeal.withAlphaComponent(0.45 + 0.55 * Double(note.velocity) / 127).setFill()
                context.fill(CGRect(x: x, y: y, width: width, height: max(1, height - 1)))
            }
            ("0–\(payload.durationTicks) ticks" as NSString).draw(at: CGPoint(x: 22, y: size.height - 13),
                withAttributes: [.font: UIFont.systemFont(ofSize: 9), .foregroundColor: UIColor.secondaryLabel])
        }
        guard let bytes = image.pngData() else { throw PersonalContentPreviewError.unavailable }
        return .init(.image(bytes), provenance: .moduleSnapshot, detail: previewText("MIDI 音符，非混音波形", "MIDI notes, not a mixed waveform"))
    }
}
#endif
