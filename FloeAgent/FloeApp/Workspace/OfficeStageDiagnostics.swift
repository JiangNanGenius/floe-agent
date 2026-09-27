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
        // A relaunch must not forget the trace written by the previous
        // process: recover the bounded tail before any new event can rewrite
        // the file.
        recoverFromDisk()
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

    /// Bounded, content-free trace text for the redacted diagnostics export.
    ///
    /// The recorder's sanitizer already guarantees every retained detail is
    /// content-free (fixed vocabulary, counters, booleans, type names); this
    /// renderer additionally caps the line count and the encoded bytes, so a
    /// stuck session can never enlarge a diagnostics bundle. The newest events
    /// are retained; each line carries an absolute UTC timestamp, a short
    /// session prefix, the open generation, the stage name and the sanitized
    /// detail pairs, so stages recorded before a crash or a relaunch still
    /// correlate with the current process. `events_exported` counts the lines
    /// actually rendered, never the events merely selected before the byte
    /// bound trimmed the body.
    func exportText(lineLimit: Int = 120, maxBytes: Int = 16_384) -> String {
        let boundedLines = max(1, lineLimit)
        let boundedBytes = max(512, maxBytes)
        let newest = events.suffix(boundedLines)
        var collectedNewestFirst: [String] = []
        // Reserve room for the header; the composed text is re-checked below
        // because the real header (with its rendered count) is only known
        // after the body has been bounded.
        var total = 96
        for event in newest.reversed() {
            let line = Self.render(event)
            if total + line.utf8.count + 1 > boundedBytes { break }
            collectedNewestFirst.append(line)
            total += line.utf8.count + 1
        }
        var lines = Array(collectedNewestFirst.reversed())
        var text = Self.compose(events: events.count, lines: lines)
        while text.utf8.count > boundedBytes, !lines.isEmpty {
            lines.removeFirst() // the oldest rendered line
            text = Self.compose(events: events.count, lines: lines)
        }
        return text
    }

    /// One bounded export line: absolute UTC time, correlation identity and
    /// sanitized facts.
    private static func render(_ event: OfficeStageEvent) -> String {
        let details = event.detail
            .map { "\($0.key)=\($0.value)" }
            .sorted()
            .joined(separator: " ")
        return "at=\(exportTimestamp.string(from: event.at))"
            + " session=\(event.session.prefix(8))"
            + " generation=\(event.generation)"
            + " stage=\(event.stage)\(details.isEmpty ? "" : " " + details)"
    }

    private static func compose(events: Int, lines: [String]) -> String {
        let header = "events_retained=\(events) events_exported=\(lines.count)"
        guard !lines.isEmpty else { return header }
        return ([header] + lines).joined(separator: "\n")
    }

    private static let exportTimestamp: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()

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

    /// Collapses control characters and caps the length of an untrusted string
    /// field. Returns nil when the value is not content-free (a filesystem
    /// path, or more than the value bound), matching the detail sanitizer's
    /// policy, so a crafted JSONL line is dropped instead of exported.
    private static func sanitizeToken(_ value: String) -> String? {
        let collapsed = value
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        guard isContentFreeValue(collapsed) else { return nil }
        return String(collapsed.prefix(160))
    }

    /// Decodes one on-disk JSONL line. A malformed line (including a torn
    /// tail line from a process killed mid-write) or a line whose identity
    /// fields are not content-free is dropped; every surviving field is
    /// re-sanitized because the file is untrusted input.
    private static func decodeRecoveredLine(_ data: Data) -> OfficeStageEvent? {
        guard !data.isEmpty,
              let raw = try? JSONDecoder().decode(OfficeStageEvent.self, from: data),
              let session = sanitizeToken(raw.session),
              let stage = sanitizeToken(raw.stage) else {
            return nil
        }
        return OfficeStageEvent(session: session,
                                generation: raw.generation,
                                stage: stage,
                                detail: sanitize(raw.detail),
                                at: raw.at)
    }

    /// Restores the bounded tail of a trace written by an earlier process so a
    /// crash, a watchdog kill or a relaunch does not erase the stages that led
    /// to it, and so the next `record` appends to that tail instead of
    /// replacing the file.
    ///
    /// The file is untrusted input:
    /// * only the last `fileLimit` bytes are read (the writer never exceeds
    ///   that bound), so a replaced or corrupted file cannot enlarge memory;
    /// * every line is decoded independently — a malformed or torn line is
    ///   skipped, never fatal;
    /// * every decoded field is re-sanitized (`sanitize` for details,
    ///   `sanitizeToken` for identity names), so a crafted line cannot smuggle
    ///   a path, a document fragment or an over-long value into the export;
    /// * at most the newest `eventLimit` events are retained.
    private func recoverFromDisk() {
        guard let fileURL, let handle = try? FileHandle(forReadingFrom: fileURL) else { return }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd(), size > 0 else { return }
        let readBound = UInt64(fileLimit)
        let start = size > readBound ? size - readBound : 0
        // `seekToEnd` left the handle at EOF; always move it to the window
        // start (which is zero for every ordinary, in-bound file).
        do { try handle.seek(toOffset: start) } catch { return }
        guard let data = try? handle.readToEnd(), !data.isEmpty else { return }
        var recovered: [OfficeStageEvent] = []
        recovered.reserveCapacity(min(eventLimit, 512))
        for line in data.split(separator: 0x0A) {
            guard let event = Self.decodeRecoveredLine(Data(line)) else { continue }
            recovered.append(event)
        }
        if recovered.count > eventLimit {
            recovered.removeFirst(recovered.count - eventLimit)
        }
        events = recovered
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
