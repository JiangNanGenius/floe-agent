// FloeApp — durable, content-free Office stage diagnostics.
//
// The device PPT/PPTX edit stall could not be attributed from the App side:
// the pinned host logs bounded `[FloeOffice]` stages, but nothing persisted
// the App-side chain (edit intent -> working copy -> native controller ->
// engine init -> document import -> permission -> first painted slide ->
// exit interlock) with one correlation identity. A user-visible spinner
// therefore produced no durable evidence of which stage never arrived.
//
// This recorder is the App-side half of that contract:
//
// * one correlation identity per mounted session (UUID) plus the monotonic
//   open generation, so a trace can order one session's stages;
// * bounded, content-free facts only: stage names, counters, booleans and
//   the pinned host's own `renderDiagnostics` summary (never document text,
//   paths or bytes);
// * two durable channels: the unified log (`[FloeOfficeStage]` lines, read
//   back with `simctl spawn log show` or Console.app) and a bounded JSONL
//   file in Application Support that a cloud run pulls from the app
//   container for verification;
// * bounded retention: a fixed number of events per process and a fixed
//   maximum file size, so a stuck session can never flood disk or log.
//
// The recorder never claims an engine open, render, save or close. It only
// records what the App observed.

import Foundation

/// One App-observed stage event for one Office session generation.
struct OfficeStageEvent: Codable, Equatable, Sendable {
    let session: String
    let generation: Int
    let stage: String
    let detail: [String: String]
    let at: Date
}

/// Main-actor, bounded, content-free stage recorder shared by every Office
/// surface (Workspace preview, IDE tab, Notes, fullscreen editor).
@MainActor
final class OfficeStageRecorder {
    /// The process-wide recorder used by the App.
    static let shared = OfficeStageRecorder()

    /// Console prefix a device/CI log query can filter on.
    static let consolePrefix = "[FloeOfficeStage]"

    /// Launch-environment override for the JSONL path. The App never reads
    /// document data from the environment; this only redirects diagnostics.
    static let environmentOverrideKey = "FLOE_OFFICE_STAGE_TRACE_PATH"

    /// Maximum retained events per process. Oldest events are dropped first.
    static let defaultEventLimit = 512
    /// Maximum JSONL bytes on disk; the file is rewritten smaller when it
    /// would exceed this bound.
    static let defaultFileLimit = 262_144

    private let fileURL: URL?
    private let eventLimit: Int
    private let fileLimit: Int
    private(set) var events: [OfficeStageEvent] = []

    init(fileURL: URL? = nil,
         eventLimit: Int = OfficeStageRecorder.defaultEventLimit,
         fileLimit: Int = OfficeStageRecorder.defaultFileLimit) {
        self.eventLimit = max(1, eventLimit)
        self.fileLimit = max(1_024, fileLimit)
        if let fileURL {
            self.fileURL = fileURL
        } else if let override = ProcessInfo.processInfo.environment[Self.environmentOverrideKey],
                  !override.isEmpty {
            self.fileURL = URL(fileURLWithPath: override, isDirectory: false)
        } else {
            let support = try? FileManager.default.url(for: .applicationSupportDirectory,
                                                       in: .userDomainMask,
                                                       appropriateFor: nil, create: true)
            self.fileURL = support?
                .appendingPathComponent("FloeAgent/OfficeDiagnostics", isDirectory: true)
                .appendingPathComponent("office-stage.jsonl", isDirectory: false)
        }
    }

    /// Records one App-observed stage. Facts are sanitized and bounded; the
    /// call is safe from a stuck session (no unbounded growth, no throwing).
    func record(session: String,
                generation: Int,
                stage: String,
                detail: [String: String] = [:]) {
        let event = OfficeStageEvent(session: session,
                                     generation: generation,
                                     stage: stage,
                                     detail: Self.sanitize(detail),
                                     at: Date())
        events.append(event)
        if events.count > eventLimit {
            events.removeFirst(events.count - eventLimit)
        }
        NSLog("%@ session=%@ generation=%d stage=%@ %@",
              Self.consolePrefix, session, generation, stage,
              event.detail.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: " "))
        persist()
    }

    /// All retained events for one correlation identity, in order.
    func trace(session: String) -> [OfficeStageEvent] {
        events.filter { $0.session == session }
    }

    /// Every retained event, in order.
    var allEvents: [OfficeStageEvent] { events }

    /// Optional on-disk trace location (nil when no Application Support root
    /// exists, for example an unusual sandbox).
    var traceFileURL: URL? { fileURL }

    /// Test/qualification hook: clears the in-memory ring and removes the
    /// trace file. Never called from the product UI.
    func reset() {
        events.removeAll()
        if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
    }

    /// True when a detail key/value pair can never carry document content or a
    /// filesystem path. Keys are fixed stage vocabulary; values are counters,
    /// booleans, identifiers and engine type names.
    static func isContentFreeValue(_ value: String) -> Bool {
        guard !value.contains("/"), !value.contains("\\"), !value.contains("\n"),
              value.count <= 160 else { return false }
        return true
    }

    private static func sanitize(_ detail: [String: String]) -> [String: String] {
        var clean: [String: String] = [:]
        for (key, value) in detail {
            let safeKey = String(key.prefix(48).filter { $0.isLetter || $0.isNumber || $0 == "." || $0 == "_" || $0 == "-" })
            guard !safeKey.isEmpty else { continue }
            let collapsed = value
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\r", with: " ")
            guard isContentFreeValue(collapsed) else { continue }
            clean[safeKey] = String(collapsed.prefix(160))
        }
        return clean
    }

    private func persist() {
        guard let fileURL else { return }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            var encoded = Data()
            for event in events {
                guard let line = try? JSONEncoder().encode(event) else { continue }
                encoded.append(line)
                encoded.append(0x0A)
            }
            // Bounded on disk: keep the newest events that fit the file bound.
            while encoded.count > fileLimit, !events.isEmpty {
                events.removeFirst()
                encoded = Data()
                for event in events {
                    guard let line = try? JSONEncoder().encode(event) else { continue }
                    encoded.append(line)
                    encoded.append(0x0A)
                }
            }
            try encoded.write(to: fileURL, options: .atomic)
        } catch {
            // Diagnostics must never fail a document operation.
        }
    }
}
