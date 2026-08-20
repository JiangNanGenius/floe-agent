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
    private static let diagnosticsChunkBytes = 7_000

    /// Uploads only after the user explicitly presses Submit. The public app
    /// endpoint is server-rate-limited and deliberately requires no reusable
    /// secret in the IPA.
    static func upload(
        _ submission: FeedbackSubmission,
        session: URLSession = .shared
    ) async throws -> FeedbackUploadReceipt {
        let request = try makeRequest(submission)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw FeedbackUploadError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            throw FeedbackUploadError.rejected(statusCode: http.statusCode)
        }
        guard let reportID = reportID(from: data), !reportID.isEmpty else {
            throw FeedbackUploadError.invalidResponse
        }
        return FeedbackUploadReceipt(reportID: reportID)
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
            SecretRedactor.redact(String($0.suffix(maximumDiagnosticsCharacters)))
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
            for (index, chunk) in utf8Chunks(diagnostics, maximumBytes: diagnosticsChunkBytes).prefix(19).enumerated() {
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
        // Attach the write token from Keychain so the server accepts the
        // upload. The token is entered once in Settings and never hardcoded.
        if let token = FeedbackTokenStore.readToken() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = body
        return request
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
