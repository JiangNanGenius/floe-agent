// FloeApp — Explicit, redacted user feedback upload to Floe's own service.
//
// SPDX-License-Identifier: MPL-2.0

#if canImport(UIKit)
import Foundation
import ImageIO
import UIKit
import FloeCore

struct FeedbackImageAttachment: Sendable, Equatable, Codable, Identifiable {
    let id: UUID
    let filename: String
    let mimeType: String
    let data: Data

    init(
        id: UUID = UUID(),
        filename: String,
        mimeType: String = "image/jpeg",
        data: Data
    ) {
        self.id = id
        self.filename = filename
        self.mimeType = mimeType
        self.data = data
    }
}

struct FeedbackSubmission: Sendable, Equatable, Codable {
    let id: UUID
    let problem: String
    let diagnostics: String?
    let imageAttachments: [FeedbackImageAttachment]

    init(
        id: UUID = UUID(),
        problem: String,
        diagnostics: String?,
        imageAttachments: [FeedbackImageAttachment] = []
    ) {
        self.id = id
        self.problem = problem.trimmingCharacters(in: .whitespacesAndNewlines)
        self.diagnostics = diagnostics
        self.imageAttachments = imageAttachments
    }
}

struct FeedbackUploadReceipt: Sendable, Equatable {
    let reportID: String
}

enum FeedbackUploadError: LocalizedError, Equatable {
    case emptyProblem
    case invalidImage
    case imageTooLarge
    case tooManyImages
    case invalidResponse
    case rateLimited(retryAfterSeconds: Int?)
    case rejected(statusCode: Int)

    var errorDescription: String? {
        switch self {
        case .emptyProblem:
            String(localized: "feedback.error.empty")
        case .invalidImage:
            String(localized: "feedback.error.invalid_image")
        case .imageTooLarge:
            String(localized: "feedback.error.image_too_large")
        case .tooManyImages:
            String(localized: "feedback.error.too_many_images")
        case .invalidResponse:
            String(localized: "feedback.error.invalid_response")
        case .rateLimited(let seconds):
            if let seconds {
                "反馈服务请求过于频繁，请在 \(seconds) 秒后重试。报告已保存在本机。"
            } else {
                "反馈服务请求过于频繁，请稍后重试。报告已保存在本机。"
            }
        case .rejected(let statusCode):
            String(format: String(localized: "feedback.error.rejected"), statusCode)
        }
    }
}

enum FeedbackUploadService {
    static let endpoint = URL(string: "https://www.floe-agent.com/api/v1/public/reports")!
    static let maximumProblemCharacters = 8_000
    static let maximumImageCount = 3
    static let maximumImageBytes = 2 * 1_024 * 1_024
    static let maximumTotalImageBytes = 6 * 1_024 * 1_024
    // The service accepts at most twenty 8 KiB events. Reserve one event for
    // the report summary and keep every diagnostics chunk comfortably below
    // the server's UTF-8 byte limit.
    static let maximumDiagnosticsCharacters = 120_000
    /// Transport byte bound: nineteen 7,000-byte chunks. The renderer must
    /// satisfy both this and the legacy character bound; a mostly-ASCII
    /// report is limited by characters, a CJK report by bytes.
    static let maximumDiagnosticsBytes = 131_072
    private static let diagnosticsChunkBytes = 7_000
    private static let maximumDiagnosticsChunks = 19

    /// Uploads only after the user explicitly presses Submit. The public app
    /// endpoint is server-rate-limited and deliberately requires no reusable
    /// secret in the IPA.
    static func upload(
        _ submission: FeedbackSubmission,
        session: URLSession = .shared,
        maximumAttempts: Int = 3
    ) async throws -> FeedbackUploadReceipt {
        let request = try makeRequest(submission)
        let attemptLimit = min(max(1, maximumAttempts), 3)
        for attempt in 0..<attemptLimit {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw FeedbackUploadError.invalidResponse
            }
            if http.statusCode == 429 {
                let serverDelay = retryAfterSeconds(from: http)
                guard attempt + 1 < attemptLimit else {
                    throw FeedbackUploadError.rateLimited(retryAfterSeconds: serverDelay)
                }
                // Respect a bounded server window. When the header is absent,
                // use a short exponential delay. Reusing the request preserves
                // the submission idempotency key, so a lost success response
                // cannot create duplicate reports.
                let delay = min(serverDelay ?? (1 << attempt), 30)
                try await Task.sleep(for: .seconds(delay))
                continue
            }
            guard (200...299).contains(http.statusCode) else {
                throw FeedbackUploadError.rejected(statusCode: http.statusCode)
            }
            guard let reportID = reportID(from: data), !reportID.isEmpty else {
                throw FeedbackUploadError.invalidResponse
            }
            return FeedbackUploadReceipt(reportID: reportID)
        }
        throw FeedbackUploadError.invalidResponse
    }

    static func retryAfterSeconds(from response: HTTPURLResponse) -> Int? {
        guard let value = response.value(forHTTPHeaderField: "Retry-After")?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        if let seconds = Int(value) { return max(1, seconds) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
        guard let date = formatter.date(from: value) else { return nil }
        return max(1, Int(ceil(date.timeIntervalSinceNow)))
    }

    static func makeRequest(
        _ submission: FeedbackSubmission,
        boundary: String = "FloeBoundary-\(UUID().uuidString)"
    ) throws -> URLRequest {
        guard !submission.problem.isEmpty else {
            throw FeedbackUploadError.emptyProblem
        }
        guard submission.imageAttachments.count <= maximumImageCount else {
            throw FeedbackUploadError.tooManyImages
        }
        guard submission.imageAttachments.allSatisfy({
            $0.mimeType == "image/jpeg" && isJPEG($0.data) && $0.data.count <= maximumImageBytes
        }) else {
            throw FeedbackUploadError.invalidImage
        }
        guard submission.imageAttachments.reduce(0, { $0 + $1.data.count }) <= maximumTotalImageBytes else {
            throw FeedbackUploadError.imageTooLarge
        }

        let redactedProblem = SecretRedactor.redact(
            String(submission.problem.prefix(maximumProblemCharacters))
        )
        let problem = utf8Chunks(redactedProblem, maximumBytes: 7_800).first ?? ""
        let diagnostics = submission.diagnostics.map {
            boundedDiagnostics(SecretRedactor.redact($0))
        }
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = info?["CFBundleVersion"] as? String ?? "unknown"
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        var events = [ReportEvent(
            clientEventID: "feedback-\(submission.id.uuidString)",
            occurredAt: reportTimestamp(),
            level: "info",
            category: "feedback",
            message: problem,
            appVersion: version,
            appBuild: build,
            osVersion: os,
            deviceModel: deviceModel,
            sessionID: submission.id.uuidString,
            metadata: [
                "diagnostics_included": diagnostics == nil ? "false" : "true",
                "image_attachment_count": String(submission.imageAttachments.count)
            ]
        )]
        if let diagnostics {
            for (index, chunk) in diagnosticsChunks(diagnostics).enumerated() {
                events.append(ReportEvent(
                    clientEventID: "diagnostics-\(submission.id.uuidString)-\(index)",
                    occurredAt: reportTimestamp(),
                    level: "info",
                    category: "feedback",
                    message: chunk,
                    appVersion: version,
                    appBuild: build,
                    osVersion: os,
                    deviceModel: deviceModel,
                    sessionID: submission.id.uuidString,
                    metadata: ["kind": "diagnostics", "part": String(index + 1)]
                ))
            }
        }

        let manifest = ReportManifest(problem: problem, locale: Locale.current.identifier, events: events)
        let manifestData = try JSONEncoder().encode(manifest)
        guard let manifestString = String(data: manifestData, encoding: .utf8) else {
            throw FeedbackUploadError.invalidResponse
        }

        var body = Data()
        body.appendUTF8("--\(boundary)\r\n")
        body.appendUTF8("Content-Disposition: form-data; name=\"manifest\"\r\n")
        body.appendUTF8("Content-Type: application/json; charset=utf-8\r\n\r\n")
        body.appendUTF8(manifestString)
        body.appendUTF8("\r\n")
        for attachment in submission.imageAttachments {
            body.appendUTF8("--\(boundary)\r\n")
            body.appendUTF8(
                "Content-Disposition: form-data; name=\"attachments\"; filename=\"\(safeFilename(attachment.filename))\"\r\n"
            )
            body.appendUTF8("Content-Type: image/jpeg\r\n")
            body.appendUTF8("X-Floe-Attachment-ID: \(attachment.id.uuidString)\r\n\r\n")
            body.append(attachment.data)
            body.appendUTF8("\r\n")
        }
        body.appendUTF8("--\(boundary)--\r\n")

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue(
            "multipart/form-data; boundary=\(boundary)",
            forHTTPHeaderField: "Content-Type"
        )
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(submission.id.uuidString, forHTTPHeaderField: "Idempotency-Key")
        // Attach the write token from Keychain so the server accepts the
        // upload. The token is entered once in Settings and never hardcoded.
        if let token = FeedbackTokenStore.readToken() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = body
        return request
    }

    /// Preserves the environment/header, every current diagnostic section and
    /// the newest failure trace. A plain head/tail bound silently deleted the
    /// middle of the document: a large MetricKit full-payload block (often
    /// from an older build) sits before the Office stage trace, the local
    /// inference evidence and the durable task summaries, so all of those
    /// newer sections vanished from the uploaded report.
    ///
    /// `DiagnosticsExporter` labels each region with a stable
    /// `== section <id> ==` header. This bound allocates a per-section byte
    /// allowance instead, keeps the oldest and newest lines of a truncated
    /// region, and writes explicit per-section truncation counts. The result
    /// always satisfies both `maximumDiagnosticsBytes` (the 19-chunk
    /// transport) and `maximumDiagnosticsCharacters`. Unstructured text
    /// (older exports, pasted logs) falls back to a byte- and
    /// character-bounded head/tail with an explicit omission count.
    static func boundedDiagnostics(_ text: String) -> String {
        let sections = parseDiagnosticsSections(text)
        guard sections.contains(where: { $0.id != nil }) else {
            return legacyBoundedDiagnostics(text)
        }

        var rendered: [String] = []
        var usedBytes = 0
        var usedCharacters = 0
        // Reserve one truncation marker per possible section so a marker can
        // never push the assembled report past the transport bound.
        let markerReserve = 240
        let markerBudget = (DiagnosticsSection.allCases.count + 1) * markerReserve
        let bodyBudgetBytes = max(0, maximumDiagnosticsBytes - markerBudget)
        let bodyBudgetCharacters = max(0, maximumDiagnosticsCharacters - markerBudget)
        for slice in sections {
            let header = slice.id?.header
            let headerCost = header.map { $0.utf8.count + 1 } ?? 0
            let remainingBytes = max(0, bodyBudgetBytes - usedBytes - headerCost)
            let remainingCharacters = max(0, bodyBudgetCharacters - usedCharacters - headerCost)
            let body: String
            if slice.id == .metricKitFullPayloads {
                body = metricKitFullPayloadStub(slice.body)
            } else if let id = slice.id {
                let allowance = min(sectionAllowance(id), remainingBytes, remainingCharacters)
                body = boundedSection(id: id, body: slice.body, allowance: allowance)
            } else {
                // Unlabelled preamble from a partially updated export: keep it
                // (identity fields live there) but never at the cost of the
                // named sections.
                let allowance = min(2_000, remainingBytes, remainingCharacters)
                body = boundedSection(id: .reportIdentity, body: slice.body, allowance: allowance)
                if body.isEmpty { continue }
            }
            let contribution = header.map { $0 + "\n" + body } ?? body
            if !rendered.isEmpty {
                usedBytes += 1
                usedCharacters += 1
            }
            rendered.append(contribution)
            usedBytes += contribution.utf8.count
            usedCharacters += contribution.count
        }
        return rendered.joined(separator: "\n")
    }

    /// UTF-8 chunks exactly as the upload sends them. The section-aware bound
    /// keeps the payload within `maximumDiagnosticsChunks`; if a future
    /// caller passes an unbounded string anyway, the overflow is made
    /// explicit (oldest middle dropped, newest tail kept) instead of being
    /// silently truncated by `prefix`.
    static func diagnosticsChunks(_ value: String) -> [String] {
        let chunks = utf8Chunks(value, maximumBytes: diagnosticsChunkBytes)
        guard chunks.count > maximumDiagnosticsChunks else { return chunks }
        let keptHead = Array(chunks.prefix(maximumDiagnosticsChunks - 1))
        let dropped = chunks.dropFirst(maximumDiagnosticsChunks - 1).dropLast()
        let droppedBytes = dropped.reduce(0) { $0 + $1.utf8.count }
        let marker = "[client diagnostics overflow: \(droppedBytes) middle bytes/\(dropped.count) chunks omitted]\n"
        let newest = clippedSuffix(chunks[chunks.count - 1],
                                   maximumBytes: max(0, diagnosticsChunkBytes - marker.utf8.count))
        return keptHead + [marker + newest]
    }

    // MARK: - Section parsing and budgeting

    struct DiagnosticsSectionSlice {
        let id: DiagnosticsSection?
        let lines: [String]

        var body: String { lines.joined(separator: "\n") }
    }

    static func parseDiagnosticsSections(_ text: String) -> [DiagnosticsSectionSlice] {
        var slices: [DiagnosticsSectionSlice] = []
        var currentID: DiagnosticsSection?
        var currentLines: [String] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let string = String(line)
            if let id = DiagnosticsSection.section(forHeader: string) {
                slices.append(DiagnosticsSectionSlice(id: currentID, lines: currentLines))
                currentID = id
                currentLines = []
            } else {
                currentLines.append(string)
            }
        }
        slices.append(DiagnosticsSectionSlice(id: currentID, lines: currentLines))
        return slices
    }

    /// Per-section byte allowance inside the global transport bound. The
    /// sections that carry the current diagnosis (Office stages, local
    /// inference, run outcomes, concise MetricKit summaries) get a guaranteed
    /// share; the recent log absorbs whatever is left, and the full MetricKit
    /// payloads are never uploaded (the version-labelled summaries carry the
    /// crash metadata and attributed frames).
    static func sectionAllowance(_ id: DiagnosticsSection) -> Int {
        switch id {
        case .reportIdentity: return 6_000
        case .executionTrace: return 16_000
        case .systemRuntime: return 3_000
        case .officeStageTrace: return 26_000
        case .localInference: return 26_000
        case .taskSummaries: return 8_000
        case .metricKitSummaries: return 34_000
        case .metricKitFullPayloads: return 0
        case .recentLog: return maximumDiagnosticsBytes
        }
    }

    /// How much of a truncated section's head (first lines) is kept. Sections
    /// written newest-last keep a small head so the oldest retained context
    /// survives next to the current tail; newest-first sections (MetricKit
    /// summaries, durable run summaries) keep most of the head because the
    /// newest record is the current evidence.
    static func headShare(_ id: DiagnosticsSection) -> Double {
        switch id {
        case .reportIdentity, .systemRuntime, .executionTrace: return 1.0
        case .taskSummaries, .metricKitSummaries: return 0.75
        default: return 0.2
        }
    }

    private static func boundedSection(id: DiagnosticsSection,
                                       body: String,
                                       allowance: Int) -> String {
        let bodyBytes = body.utf8.count
        guard bodyBytes > allowance else { return body }
        // Reserve room for the explicit truncation marker. The marker is the
        // only content allowed to exceed the allowance, and it is tiny.
        let markerReserve = 240
        let usable = max(0, allowance - markerReserve)
        let headBudget = min(usable, Int(Double(usable) * headShare(id)))
        let tailBudget = max(0, usable - headBudget)

        let lines = body.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let head = leadingLines(lines, maximumBytes: headBudget)
        let tail = trailingLines(lines, maximumBytes: tailBudget, excludingFirst: head.lineCount)
        let omittedLines = max(0, lines.count - head.lineCount - tail.lineCount)
        let omittedBytes = max(0, bodyBytes - head.bytes - tail.bytes)
        let marker = "-- section \(id.rawValue) truncated by client: kept head=\(head.lineCount)"
            + " tail=\(tail.lineCount) of \(lines.count) lines; omitted=\(omittedLines)"
            + " lines/\(omittedBytes) bytes --"
        return ([head.text] + [marker] + [tail.text]).filter { !$0.isEmpty }.joined(separator: "\n")
    }

    private static func metricKitFullPayloadStub(_ body: String) -> String {
        let bytes = body.utf8.count
        guard bytes > 0 else { return "no MetricKit full payloads retained" }
        let lines = body.split(separator: "\n", omittingEmptySubsequences: false).count
        return "-- section metrickit_full_payloads omitted by client:"
            + " \(lines) payload lines/\(bytes) bytes dropped;"
            + " concise version-labelled summaries retained above --"
    }

    private struct BoundedLines {
        let text: String
        let lineCount: Int
        let bytes: Int
    }

    private static func leadingLines(_ lines: [String], maximumBytes: Int) -> BoundedLines {
        guard let first = lines.first else { return BoundedLines(text: "", lineCount: 0, bytes: 0) }
        var chosen: [String] = []
        var bytes = 0
        for line in lines {
            let lineBytes = line.utf8.count + (chosen.isEmpty ? 0 : 1)
            if bytes + lineBytes > maximumBytes { break }
            chosen.append(line)
            bytes += lineBytes
        }
        if chosen.isEmpty {
            let clipped = clippedPrefix(first, maximumBytes: maximumBytes)
            return BoundedLines(text: clipped, lineCount: clipped.isEmpty ? 0 : 1, bytes: clipped.utf8.count)
        }
        return BoundedLines(text: chosen.joined(separator: "\n"), lineCount: chosen.count, bytes: bytes)
    }

    private static func trailingLines(_ lines: [String],
                                      maximumBytes: Int,
                                      excludingFirst skip: Int) -> BoundedLines {
        guard lines.count > skip else { return BoundedLines(text: "", lineCount: 0, bytes: 0) }
        var chosenNewestFirst: [String] = []
        var bytes = 0
        var index = lines.count - 1
        while index >= skip {
            let line = lines[index]
            let lineBytes = line.utf8.count + (chosenNewestFirst.isEmpty ? 0 : 1)
            if bytes + lineBytes > maximumBytes { break }
            chosenNewestFirst.append(line)
            bytes += lineBytes
            index -= 1
        }
        if chosenNewestFirst.isEmpty {
            let clipped = clippedSuffix(lines[lines.count - 1], maximumBytes: maximumBytes)
            return BoundedLines(text: clipped, lineCount: clipped.isEmpty ? 0 : 1, bytes: clipped.utf8.count)
        }
        return BoundedLines(text: chosenNewestFirst.reversed().joined(separator: "\n"),
                            lineCount: chosenNewestFirst.count,
                            bytes: bytes)
    }

    /// Unstructured fallback for payloads without section headers.
    private static func legacyBoundedDiagnostics(_ text: String) -> String {
        let totalBytes = text.utf8.count
        guard totalBytes > maximumDiagnosticsBytes || text.count > maximumDiagnosticsCharacters else {
            return text
        }
        let headBudget = min(24_000, maximumDiagnosticsBytes / 6)
        var tailBudget = 0
        var omission = ""
        for _ in 0..<3 {
            omission = "\n\n== middle diagnostics omitted by client: kept \(headBudget) oldest bytes"
                + " and \(tailBudget) newest bytes of \(totalBytes) bytes ==\n\n"
            let byteBudget = maximumDiagnosticsBytes - headBudget - omission.utf8.count
            let characterBudget = maximumDiagnosticsCharacters - headBudget - omission.count
            tailBudget = max(0, min(byteBudget, characterBudget))
        }
        let head = clippedPrefix(text, maximumBytes: headBudget)
        let tail = clippedSuffix(text, maximumBytes: tailBudget)
        guard head.utf8.count + tail.utf8.count + omission.utf8.count < totalBytes else { return text }
        return head + omission + tail
    }

    static func clippedPrefix(_ text: String, maximumBytes: Int) -> String {
        guard maximumBytes > 0 else { return "" }
        guard text.utf8.count > maximumBytes else { return text }
        var result = ""
        var bytes = 0
        for scalar in text.unicodeScalars {
            let size = String(scalar).utf8.count
            if bytes + size > maximumBytes { break }
            result.unicodeScalars.append(scalar)
            bytes += size
        }
        return result
    }

    static func clippedSuffix(_ text: String, maximumBytes: Int) -> String {
        guard maximumBytes > 0 else { return "" }
        guard text.utf8.count > maximumBytes else { return text }
        var scalars: [Unicode.Scalar] = []
        var bytes = 0
        for scalar in text.unicodeScalars.reversed() {
            let size = String(scalar).utf8.count
            if bytes + size > maximumBytes { break }
            scalars.append(scalar)
            bytes += size
        }
        var result = ""
        for scalar in scalars.reversed() {
            result.unicodeScalars.append(scalar)
        }
        return result
    }

    private static var deviceModel: String {
        var system = utsname()
        uname(&system)
        return withUnsafePointer(to: &system.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
    }

    private static func safeFilename(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let scalars = value.unicodeScalars.map { allowed.contains($0) ? Character(String($0)) : "_" }
        let sanitized = String(scalars).prefix(96)
        return sanitized.isEmpty ? "feedback-image.jpg" : String(sanitized)
    }

    private static func isJPEG(_ data: Data) -> Bool {
        data.count >= 4
            && data[data.startIndex] == 0xFF
            && data[data.index(after: data.startIndex)] == 0xD8
            && data[data.index(data.endIndex, offsetBy: -2)] == 0xFF
            && data[data.index(before: data.endIndex)] == 0xD9
    }

    private static func utf8Chunks(_ value: String, maximumBytes: Int) -> [String] {
        var chunks: [String] = []
        var current = ""
        var size = 0
        for scalar in value.unicodeScalars {
            let scalarString = String(scalar)
            let scalarSize = scalarString.utf8.count
            if size + scalarSize > maximumBytes, !current.isEmpty {
                chunks.append(current)
                current = ""
                size = 0
            }
            current.append(scalarString)
            size += scalarSize
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    private static func reportTimestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }

    static func reportID(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let direct = object["report_id"] as? String ?? object["reportId"] as? String
            ?? object["id"] as? String {
            return direct
        }
        if let report = object["report"] as? [String: Any] {
            return report["id"] as? String
        }
        return nil
    }
}

/// Failed uploads remain recoverable and shareable. The stored package is
/// already redacted and contains no credentials or raw audio.
enum PendingFeedbackReportStore {
    static func save(_ submission: FeedbackSubmission) throws -> URL {
        let root = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("FloeAgent/PendingFeedback", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let safe = FeedbackSubmission(
            id: submission.id,
            problem: SecretRedactor.redact(submission.problem),
            diagnostics: submission.diagnostics.map { SecretRedactor.redact($0) },
            imageAttachments: submission.imageAttachments
        )
        let url = root.appendingPathComponent("report-\(submission.id.uuidString).json")
        try JSONEncoder().encode(safe).write(to: url, options: [.atomic, .completeFileProtection])
        return url
    }

    static func remove(id: UUID) {
        guard let root = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        ) else { return }
        try? FileManager.default.removeItem(
            at: root.appendingPathComponent("FloeAgent/PendingFeedback/report-\(id.uuidString).json")
        )
    }
}

/// Converts a Photos picker result into a bounded JPEG before upload. The
/// re-encode strips EXIF/location metadata while preserving a useful screenshot
/// resolution and keeps the report within the server's multipart limits.
enum FeedbackImageProcessor {
    static func makeAttachment(data: Data, index: Int) throws -> FeedbackImageAttachment {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw FeedbackUploadError.invalidImage
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 2_048,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw FeedbackUploadError.invalidImage
        }
        let image = UIImage(cgImage: thumbnail)
        for quality in [0.82, 0.68, 0.52, 0.38] {
            guard let encoded = image.jpegData(compressionQuality: quality) else { continue }
            if encoded.count <= FeedbackUploadService.maximumImageBytes {
                return FeedbackImageAttachment(
                    filename: "feedback-image-\(index + 1).jpg",
                    data: encoded
                )
            }
        }
        throw FeedbackUploadError.imageTooLarge
    }
}

private struct ReportManifest: Encodable {
    let problem: String
    let locale: String
    let events: [ReportEvent]
}

private struct ReportEvent: Encodable {
    let clientEventID: String
    let occurredAt: String
    let level: String
    let category: String
    let message: String
    let appVersion: String
    let appBuild: String
    let osVersion: String
    let deviceModel: String
    let sessionID: String
    let metadata: [String: String]

    enum CodingKeys: String, CodingKey {
        case clientEventID = "client_event_id"
        case occurredAt = "occurred_at"
        case level, category, message
        case appVersion = "app_version"
        case appBuild = "app_build"
        case osVersion = "os_version"
        case deviceModel = "device_model"
        case sessionID = "session_id"
        case metadata
    }
}

private extension Data {
    mutating func appendUTF8(_ value: String) {
        append(contentsOf: value.utf8)
    }
}
#endif
