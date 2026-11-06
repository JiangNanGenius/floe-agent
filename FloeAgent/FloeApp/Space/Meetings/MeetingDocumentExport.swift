// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import FloeCore
import FloeDocuments
import FloeMeetings
import FloeNotes
import FloeTools

enum MeetingDocumentFormat: String, Sendable {
    case word, pdf, notebookPDF, sources
}

struct MeetingSourceIndex: Codable, Sendable {
    struct Media: Codable, Sendable { let sessionID: UUID; let displayName: String; let fileName: String? }
    struct Segment: Codable, Sendable {
        let segmentID: UUID
        let originalSessionID: UUID
        let start: Double
        let end: Double
        let speaker: String
        let text: String
    }
    struct Anchor: Codable, Sendable { let id: UUID; let text: String; let source: SourceReference }
    struct Summary: Codable, Sendable {
        let id: UUID
        let createdAt: Date
        let window: MediaTimeRange?
        let segmentIDs: [UUID]?
        let sourceStatus: String
    }
    let schemaVersion: Int
    let meetingID: UUID
    let title: String
    let capturedAt: Date
    let selectedTemplate: String
    let personalNoteID: UUID
    let personalNoteRevision: Int
    let media: [Media]
    let segments: [Segment]
    let notes: [Anchor]
    let decisions: [Anchor]
    let todos: [Anchor]
    let summaries: [Summary]
    var exportedFileName: String?
    var exportedSHA256: String?
}

private struct MeetingDocumentSnapshot: Sendable {
    let title: String
    let paragraphs: [String]
    var index: MeetingSourceIndex
    let notebook: NoteDocument
}

extension MeetingProjectSession {
    func meetingTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0, seconds < 1_000_000_000 else { return "--:--" }
        let ms = Int64((seconds * 1000).rounded())
        return String(format: "%02lld:%02lld:%02lld.%03lld", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, ms % 1000)
    }
    func sourceDescription(_ source: SourceReference) -> String? {
        switch source {
        case .recording(let session, let range):
            let original = originalCaptureSession(for: session)
            let recording = recordings.first { $0.id == original }
            let number = recordings.firstIndex { $0.id == original }.map { $0 + 1 } ?? 1
            let name = recording?.sourceFile.map { URL(fileURLWithPath: $0).lastPathComponent }
                ?? IDELanguageRunText.t("现场录音 \(number)", "Recording \(number)")
            return "\(name) · \(meetingTime(range.start))–\(meetingTime(range.end))"
        case .segment(let id):
            guard let segment = transcript.first(where: { $0.id == id }) else { return nil }
            return sourceDescription(.recording(session: segment.sessionID, range: segment.range))
        case .importedFile(let file, let range):
            let name = URL(fileURLWithPath: file).lastPathComponent
            return range.map { "\(name) · \(meetingTime($0.start))–\(meetingTime($0.end))" } ?? name
        case .none: return nil
        }
    }
    private func normalizedSource(_ source: SourceReference) -> SourceReference {
        switch source {
        case .recording(let session, let range): return .recording(session: originalCaptureSession(for: session), range: range)
        case .importedFile(let file, let range): return .importedFile(fileName: URL(fileURLWithPath: file).lastPathComponent, range: range)
        default: return source
        }
    }
    private func speakerLabel(_ id: SpeakerID?) -> String {
        guard var current = id else { return IDELanguageRunText.t("未标注发言人", "Unlabelled speaker") }
        var visited: Set<SpeakerID> = []
        while let speaker = speakers.first(where: { $0.id == current }), let next = speaker.mergedInto,
              visited.insert(current).inserted { current = next }
        return speakers.first(where: { $0.id == current })?.label ?? IDELanguageRunText.t("未标注发言人", "Unlabelled speaker")
    }
    private func documentSnapshot() async throws -> MeetingDocumentSnapshot {
        await loadNotebook()
        guard let document = notebook.document, notebook.pendingWrites == 0,
              !notebook.unsavedDocumentIDs.contains(document.id) else { throw NoteError.conflict }
        let store = try await NotesRepository.shared.store()
        let saved = try await store.document(document.id)
        guard notebook.pendingWrites == 0, !notebook.unsavedDocumentIDs.contains(document.id),
              notebook.document?.id == saved.id, notebook.document?.revision == saved.revision,
              saved.deletedAt == nil else { throw NoteError.conflict }
        _ = try MeetingExport.cues(segments: transcript)
        let capturedAt = Date()
        func t(_ zh: String, _ en: String) -> String { IDELanguageRunText.t(zh, en) }
        var paragraphs = [meeting.createdAt.formatted(date: .abbreviated, time: .shortened),
            t("当前纪要模板：", "Selected minutes template: ") + minutesTemplate.title]
        func section(_ title: String, _ values: [String]) {
            guard !values.isEmpty else { return }
            paragraphs += ["", title]
            paragraphs += values.flatMap { $0.components(separatedBy: .newlines) }
        }
        section(t("个人笔记（文字）", "Personal notes (text)"), [NoteTextContent.reading(saved).text].filter { !$0.isEmpty })
        section(t("会议笔记", "Meeting notes"), notes.map { $0.body + (sourceDescription($0.source).map { " [\($0)]" } ?? "") })
        section(t("AI 纪要", "AI minutes"), summaries.map { $0.createdAt.formatted(date: .abbreviated, time: .shortened) + "\n" + $0.text })
        section(t("累计结论", "Decisions"), decisions.map { $0.text + (sourceDescription($0.source).map { " [\($0)]" } ?? "") })
        section(t("跟进事项", "Follow-ups"), todos.filter { $0.status != .dismissed }.map {
            ($0.status == .done ? "[x] " : "[ ] ") + $0.text + (sourceDescription($0.source).map { " [\($0)]" } ?? "")
        })
        section(t("会议问答", "Meeting questions"), intelligence.answers.map { $0.question + "\n" + $0.answer })
        section(t("逐字稿与原片时间", "Transcript and source times"), transcript.map {
            "[\(sourceDescription(.recording(session: $0.sessionID, range: $0.range)) ?? meetingTime($0.range.start))] \(speakerLabel($0.speakerID)): \($0.text)"
        })
        guard paragraphs.count <= 40_000, paragraphs.reduce(0, { $0 + $1.utf8.count }) <= 8 * 1_024 * 1_024 else {
            throw NoteError.invalidOperation(t("会议文字过长，请先导出逐字稿或部分笔记。", "The meeting is too long for one document. Export the transcript or selected notes first."))
        }
        var seen: Set<CaptureSessionID> = []
        let media = recordings.compactMap { recording -> MeetingSourceIndex.Media? in
            let original = originalCaptureSession(for: recording.id)
            guard seen.insert(original).inserted else { return nil }
            let source = recordings.first { $0.id == original } ?? recording
            let actualFile = source.sourceFile.map { URL(fileURLWithPath: $0).lastPathComponent }
                ?? (try? mediaFile(for: source).lastPathComponent)
            let number = recordings.firstIndex { $0.id == original }.map { $0 + 1 } ?? 1
            return .init(sessionID: original.rawValue, displayName: source.sourceFile.map { URL(fileURLWithPath: $0).lastPathComponent }
                ?? t("现场录音 \(number)", "Recording \(number)"), fileName: actualFile)
        }
        let index = MeetingSourceIndex(schemaVersion: 1, meetingID: id, title: meeting.title, capturedAt: capturedAt,
            selectedTemplate: minutesTemplate.rawValue, personalNoteID: saved.id, personalNoteRevision: saved.revision,
            media: media, segments: transcript.map { .init(segmentID: $0.id.rawValue,
                originalSessionID: originalCaptureSession(for: $0.sessionID).rawValue, start: $0.range.start,
                end: $0.range.end, speaker: speakerLabel($0.speakerID), text: $0.text) },
            notes: notes.map { .init(id: $0.id.rawValue, text: $0.body, source: normalizedSource($0.source)) },
            decisions: decisions.map { .init(id: $0.id.rawValue, text: $0.text, source: normalizedSource($0.source)) },
            todos: todos.map { .init(id: $0.id.rawValue, text: $0.text, source: normalizedSource($0.source)) },
            summaries: summaries.map { .init(id: $0.id.rawValue, createdAt: $0.createdAt,
                window: $0.window, segmentIDs: intelligence.summarySourceIDs?[$0.id.rawValue],
                sourceStatus: intelligence.summarySourceIDs?[$0.id.rawValue] == nil ? "notRecorded" : "recorded") })
        return MeetingDocumentSnapshot(title: meeting.title, paragraphs: paragraphs, index: index, notebook: saved)
    }
    func startDocumentExport(_ format: MeetingDocumentFormat) {
        guard documentExportTask == nil else { return }
        let cancellation = CancellationToken()
        documentExportCancellation = cancellation
        isExportingDocument = true; diagnostic = nil
        documentExportTask = Task { [self] in
            defer { documentExportTask = nil; documentExportCancellation = nil; isExportingDocument = false }
            do {
                let snapshot = try await documentSnapshot()
                let result = try await writeDocument(snapshot, format: format, cancellation: cancellation)
                try Task.checkCancellation(); try cancellation.throwIfCancelled()
                export = result.file; exportSourceIndex = result.index
            } catch is CancellationError {} catch { diagnostic = error.localizedDescription }
        }
    }
    func cancelDocumentExport() { documentExportCancellation?.cancel(); documentExportTask?.cancel() }
    func cancelDocumentExportAndWait() async {
        let task = documentExportTask
        cancelDocumentExport()
        await task?.value
    }
    private func writeDocument(_ snapshot: MeetingDocumentSnapshot, format: MeetingDocumentFormat,
                               cancellation: CancellationToken) async throws -> (file: URL, index: URL) {
        let parent = root.appendingPathComponent("Exports", isDirectory: true)
        let name = "meeting-" + UUID().uuidString.lowercased()
        let staging = parent.appendingPathComponent("." + name + ".partial", isDirectory: true)
        let final = parent.appendingPathComponent(name, isDirectory: true)
        let ownedRoot = root.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        guard parent.standardizedFileURL.resolvingSymlinksInPath().path.hasPrefix(ownedRoot) else { throw PersonalContentError.invalidProject }
        guard FileManager.default.fileExists(atPath: root.appendingPathComponent("meeting.sqlite").path) else { throw PersonalContentError.missingDocument }
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        do {
            var index = snapshot.index
            let stem = NotesExport.fileName(snapshot.title)
            let output: URL
            switch format {
            case .word, .pdf:
                let word = staging.appendingPathComponent(stem).appendingPathExtension("docx")
                let writer = Task.detached(priority: .userInitiated) {
                    try Task.checkCancellation()
                    try OfficeDocumentBuilder.createWord(at: word, title: snapshot.title, paragraphs: snapshot.paragraphs)
                    try Task.checkCancellation()
                }
                try await withTaskCancellationHandler { try await writer.value } onCancel: { writer.cancel() }
                try cancellation.throwIfCancelled()
                if format == .word { output = word }
                else {
                    #if canImport(FloeOfficeNative) && canImport(WebKit)
                    let hash = try FloeDigest.sha256Hex(ofFileAt: word)
                    let pdf = try await OfficePDFExportService.export(.init(sourceURL: word, sourceSHA256: hash,
                        formatExtension: "docx", plan: .init(), ownedDirectory: staging, cancellation: cancellation))
                    output = staging.appendingPathComponent(stem).appendingPathExtension("pdf")
                    try FileManager.default.copyItem(at: pdf.pdfURL, to: output)
                    #else
                    throw NoteError.invalidOperation(IDELanguageRunText.t("此安装暂不能生成会议 PDF，请导出 Word。", "This installation cannot generate a meeting PDF. Export Word instead."))
                    #endif
                }
            case .notebookPDF:
                let store = try await NotesRepository.shared.store()
                let artifact = try await NotesExport.pdf(document: snapshot.notebook, store: store) { _, _ in }
                defer { artifact.lease?.release() }
                try cancellation.throwIfCancelled()
                output = staging.appendingPathComponent(stem + "-notes").appendingPathExtension("pdf")
                try FileManager.default.copyItem(at: artifact.url, to: output)
            case .sources: output = staging.appendingPathComponent(stem + ".sources.json")
            }
            try Task.checkCancellation(); try cancellation.throwIfCancelled()
            if format != .sources {
                let values = try output.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                guard values.isRegularFile == true, let bytes = values.fileSize, bytes > 0, bytes <= 64 * 1_024 * 1_024 else { throw PersonalContentError.invalidProject }
                index.exportedFileName = output.lastPathComponent
                index.exportedSHA256 = try FloeDigest.sha256Hex(ofFileAt: output)
            }
            let indexURL = format == .sources ? output : staging.appendingPathComponent(stem + ".sources.json")
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(index)
            guard data.count <= 16 * 1_024 * 1_024 else { throw PersonalContentError.invalidProject }
            try data.write(to: indexURL, options: .atomic)
            try Task.checkCancellation(); try cancellation.throwIfCancelled()
            guard FileManager.default.fileExists(atPath: root.appendingPathComponent("meeting.sqlite").path) else { throw PersonalContentError.missingDocument }
            try FileManager.default.moveItem(at: staging, to: final)
            return (final.appendingPathComponent(output.lastPathComponent), final.appendingPathComponent(indexURL.lastPathComponent))
        } catch {
            #if canImport(FloeOfficeNative)
            if await OfficeAutomaticExecutionGate.shared.isQuarantined { throw error }
            #endif
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
    }
}
#endif
