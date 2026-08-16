// FloeApp — Explicit, redacted user feedback upload to Floe's own service.
//
// SPDX-License-Identifier: MPL-2.0

#if canImport(UIKit)
import Foundation
import FloeCore

struct FeedbackSubmission: Sendable, Equatable {
    let id: UUID
    let problem: String
    let diagnostics: String?

    init(id: UUID = UUID(), problem: String, diagnostics: String?) {
        self.id = id
        self.problem = problem.trimmingCharacters(in: .whitespacesAndNewlines)
        self.diagnostics = diagnostics
    }
}

enum FeedbackUploadError: LocalizedError, Equatable {
    case emptyProblem
    case invalidResponse
    case rejected(statusCode: Int)

    var errorDescription: String? {
        switch self {
        case .emptyProblem:
            String(localized: "feedback.error.empty")
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
    ) async throws {
        let request = try makeRequest(submission)
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw FeedbackUploadError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            throw FeedbackUploadError.rejected(statusCode: http.statusCode)
        }
    }

    static func makeRequest(
        _ submission: FeedbackSubmission,
        boundary: String = "FloeBoundary-\(UUID().uuidString)"
    ) throws -> URLRequest {
        guard !submission.problem.isEmpty else {
            throw FeedbackUploadError.emptyProblem
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
            metadata: ["diagnostics_included": diagnostics == nil ? "false" : "true"]
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
        body.appendUTF8("--\(boundary)--\r\n")

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue(
            "multipart/form-data; boundary=\(boundary)",
            forHTTPHeaderField: "Content-Type"
        )
        request.setValue("application/json", forHTTPHeaderField: "Accept")
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
