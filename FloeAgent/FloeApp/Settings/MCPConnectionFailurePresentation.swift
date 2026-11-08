// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeCore
import FloeTools

/// User copy is chosen only from local typed errors, never remote text. The
/// full redacted diagnostic stays in this attempt's RAM-owned center record.
nonisolated struct MCPConnectionFailurePresentation: Equatable, Sendable {
    enum Reason: Sendable { case incompatibleService, credentials, timedOut, serviceUnavailable, connectionFailed }
    let reason: Reason
    let diagnostic: String
    static let displayByteLimit = 16_384

    init(error: Error, credential: String? = nil) {
        if let client = error as? MCPClientError {
            switch client {
            case .unsupportedProtocolVersion: reason = .incompatibleService
            case .authenticationRequired: reason = .credentials
            case .httpError(let status, _) where status == 401 || status == 403: reason = .credentials
            case .timedOut: reason = .timedOut
            case .httpError(let status, _) where (500...599).contains(status): reason = .serviceUnavailable
            default: reason = .connectionFailed
            }
        } else if let url = error as? URLError, url.code == .timedOut {
            reason = .timedOut
        } else { reason = .connectionFailed }
        diagnostic = Self.redacted(error.localizedDescription, credential: credential)
    }
    /// Compatibility for an older/custom feature adapter. Its raw string can
    /// only enter explicit diagnostics; it cannot select instructions or cause.
    init(legacyDiagnostic: String, credential: String? = nil) {
        reason = .connectionFailed
        diagnostic = Self.redacted(legacyDiagnostic, credential: credential)
    }
    func message(chinese: Bool) -> String {
        switch reason {
        case .incompatibleService:
            chinese ? "当前服务暂不兼容。请稍后重试或更新应用。" : "This service is currently incompatible. Try again later or update the app."
        case .credentials:
            chinese ? "请检查此账户的密钥后重试。" : "Check this account’s credentials, then retry."
        case .timedOut:
            chinese ? "连接超时，请重试。" : "The connection timed out. Try again."
        case .serviceUnavailable:
            chinese ? "服务暂时无法响应，请稍后重试。" : "The service is temporarily unavailable. Try again shortly."
        case .connectionFailed:
            chinese ? "暂时无法连接，请重试。" : "Unable to connect right now. Try again."
        }
    }
    var localizedMessage: String { message(chinese: FloeL10n.isChinese) }
    var displayDiagnostic: String { String(decoding: diagnostic.utf8.prefix(Self.displayByteLimit), as: UTF8.self) }
    var displayIsTruncated: Bool { diagnostic.utf8.count > Self.displayByteLimit }
    static var diagnosticsTitle: String { FloeL10n.isChinese ? "连接诊断" : "Connection Diagnostics" }
    static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let client = error as? MCPClientError {
            switch client { case .cancelled, .disconnected: return true; default: break }
        }
        return (error as? URLError)?.code == .cancelled
    }
    private static func redacted(_ value: String, credential: String?) -> String {
        let secret = credential?.trimmingCharacters(in: .whitespacesAndNewlines)
        var safe = SecretRedactor.redact(value, secret: secret)
        // HTTP URLs in diagnostics may echo a sensitive endpoint query or
        // fragment. Keep origin/path for diagnosis; never show URL credentials.
        if let regex = try? NSRegularExpression(pattern: #"https?://[^\s\"'<>]+"#, options: .caseInsensitive) {
            for match in regex.matches(in: safe, range: NSRange(safe.startIndex..., in: safe)).reversed() {
                guard let range = Range(match.range, in: safe), var url = URLComponents(string: String(safe[range])) else { continue }
                url.user = nil; url.password = nil; url.query = nil; url.fragment = nil
                if let cleaned = url.string { safe.replaceSubrange(range, with: cleaned) }
            }
        }
        // Preserve the protocol/JSON and line breaks, while suppressing raw
        // terminal control characters on the explicitly opened plain-text view.
        return String(String.UnicodeScalarView(safe.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) || $0 == "\n" || $0 == "\t" }))
    }
}

/// The center's same server + refresh generation bind diagnostics to a single
/// attempt. This is not a second connection state owner or persisted history.
nonisolated struct MCPConnectionFailureRecord: Sendable {
    let server: MCPServerConfiguration
    let generation: UInt64
    let presentation: MCPConnectionFailurePresentation
    func matches(server current: MCPServerConfiguration, generation currentGeneration: UInt64) -> Bool {
        current.enabled && current == server && generation == currentGeneration
    }
}

#if canImport(UIKit)
import SwiftUI
import UIKit

struct MCPConnectionDiagnosticText: View {
    let failure: MCPConnectionFailurePresentation
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: failure.displayDiagnostic)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
            if failure.displayIsTruncated {
                Text(FloeL10n.isChinese ? "诊断较长，仅显示前一部分。" : "This diagnostic is long; only the first part is shown.")
                    .font(.caption).foregroundStyle(.secondary)
                Button(FloeL10n.isChinese ? "复制完整诊断" : "Copy Full Diagnostic") {
                    UIPasteboard.general.string = failure.diagnostic
                }.frame(minHeight: 44)
            }
        }
    }
}
#endif
