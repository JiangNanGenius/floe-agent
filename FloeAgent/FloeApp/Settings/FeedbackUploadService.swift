// FloeApp — Explicit, redacted user feedback upload through FormBold.
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
    static let endpoint = URL(string: "https://formbold.com/s/oJaR2")!
    static let maximumProblemCharacters = 8_000
    static let maximumDiagnosticsCharacters = 240_000

    /// Uploads only after the user explicitly presses Submit. FormBold accepts
    /// normal named form fields, so diagnostics travel as bounded UTF-8 text;
    /// this avoids requiring FormBold's separately billed file-upload feature.
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

        let problem = SecretRedactor.redact(
            String(submission.problem.prefix(maximumProblemCharacters))
        )
        let diagnostics = submission.diagnostics.map {
            SecretRedactor.redact(String($0.suffix(maximumDiagnosticsCharacters)))
        }
        let info = Bundle.main.infoDictionary
        var fields: [(String, String)] = [
            ("subject", "Floe Agent problem report"),
            ("problem", problem),
            ("message", problem),
            ("submission_id", submission.id.uuidString),
            ("app_version", info?["CFBundleShortVersionString"] as? String ?? "unknown"),
            ("app_build", info?["CFBundleVersion"] as? String ?? "unknown"),
            ("os", ProcessInfo.processInfo.operatingSystemVersionString),
            ("locale", Locale.current.identifier),
            ("diagnostics_included", diagnostics == nil ? "false" : "true")
        ]
        if let diagnostics {
            fields.append(("diagnostics", diagnostics))
        }

        var body = Data()
        for (name, value) in fields {
            body.appendUTF8("--\(boundary)\r\n")
            body.appendUTF8("Content-Disposition: form-data; name=\"\(name)\"\r\n")
            body.appendUTF8("Content-Type: text/plain; charset=utf-8\r\n\r\n")
            body.appendUTF8(value)
            body.appendUTF8("\r\n")
        }
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
}

private extension Data {
    mutating func appendUTF8(_ value: String) {
        append(contentsOf: value.utf8)
    }
}
#endif
