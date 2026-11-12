import Foundation
import FloeModels

/// Detects assistant prose that reports an action as successful (creating,
/// writing or saving a file) when the run holds no successful tool receipt at
/// all.
///
/// This is deliberately conservative in both directions:
///  - only strong past-tense/completion claims fire it, negated claims
///    ("未创建", "failed to save") are ignored, and
///  - read/search/discovery receipts never substantiate a new write.
///    One successful mutation candidate is only evidence that some work executed;
///    the terminal checklist/failure gate accounts for unfinished work.
///
/// The observed failure mode was a run with no tool call stating a file was
/// created, or a failed write followed by a success claim. When the gate
/// fires the runtime performs one bounded corrective turn; a second
/// unsubstantiated claim ends the run with an honest, recoverable failure.
struct ActionClaimGate: Sendable {
    struct Receipt: Sendable, Equatable {
        var toolName: String
        var status: ToolResult.Status
        /// Native call/receipt projection, never a model-authored flag.
        /// The descriptor's side-effect bit alone is insufficient evidence.
        var supportsMutationClaim: Bool = false
    }

    enum Directive: Equatable {
        case allow
        case requestCorrection
        case failRun
    }

    func evaluate(
        claim claimText: String,
        receipts: [Receipt],
        correctiveRetries: Int
    ) -> Directive {
        guard Self.hasUnnegatedCompletionClaim(claimText) else { return .allow }
        let hasSuccessfulWorkReceipt = receipts.contains { $0.status == .ok && $0.supportsMutationClaim }
        guard !hasSuccessfulWorkReceipt else { return .allow }
        // Read-only success, denial, cancellation and failure are not evidence
        // that a newly claimed write ran. Never introduce a write merely to
        // justify prose; the correction may instead report verified state.
        if correctiveRetries == 0 { return .requestCorrection }
        return .failRun
    }

    // MARK: - Claim detection (internal for testing)

    static func hasUnnegatedCompletionClaim(_ text: String) -> Bool {
        let lowered = text.lowercased()
        if let value = chineseClaim(in: text) { return value }
        return englishClaim(in: lowered)
    }

    private static let chineseObjectMarkers = [
        "文件", "文档", "档案", "文本", "表格", "笔记", "脚本", "目录",
        "文件夹", "页面", "图片", "照片", "代码"
    ]

    private static func chineseClaim(in text: String) -> Bool? {
        guard chineseObjectMarkers.contains(where: text.contains) else { return nil }
        let patterns = [
            // 已创建 / 已保存 / …
            "已(创建|保存|写入|生成|建立|完成)",
            "成功(创建|保存|写入|生成)",
            "(创建|保存|写入|生成)成功",
            "创建并保存"
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(text.startIndex..., in: text)
            let matches = regex.matches(in: text, range: range)
            for match in matches {
                guard let matchRange = Range(match.range, in: text) else { continue }
                // Ignore negated claims such as 未创建 / 没有保存成功.
                let distance = min(6, text.distance(from: text.startIndex, to: matchRange.lowerBound))
                let prefixStart = text.index(matchRange.lowerBound, offsetBy: -distance)
                let prefix = String(text[prefixStart..<matchRange.lowerBound])
                if !prefix.contains("未"), !prefix.contains("没") {
                    return true
                }
            }
        }
        return false
    }

    private static let englishObjectMarkers = [
        "file", "document", "note", "spreadsheet", "text file", "script",
        "image", "photo", "page", "folder"
    ]

    private static let englishNegations = [
        "not", "n't", "never", "failed to", "unable to", "could not"
    ]

    private static func englishClaim(in text: String) -> Bool {
        guard englishObjectMarkers.contains(where: text.contains) else { return false }
        let patterns = [
            "(successfully|has been|have been|was|were|is now)\\s+([a-z]+\\s+)?(created|saved|written|generated|stored)",
            "i\\s+(have\\s+)?(created|saved|written|wrote|generated|stored)",
            "(created|saved|wrote|written|generated)\\s+(and\\s+(saved|closed)\\s+)?(the\\s+|a\\s+|my\\s+)?(file|document|note|spreadsheet|text file|script|image|photo|page|folder)"
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(text.startIndex..., in: text)
            let matches = regex.matches(in: text, range: range)
            for match in matches {
                guard let matchRange = Range(match.range, in: text) else { continue }
                let distance = min(40, text.distance(from: text.startIndex, to: matchRange.lowerBound))
                let prefixStart = text.index(matchRange.lowerBound, offsetBy: -distance)
                let prefix = String(text[prefixStart..<matchRange.lowerBound])
                // A negated subject is not a completed action. Keep this
                // anchored to this match so "No file was created, but the
                // document was saved" still checks the later success claim.
                let negatedObject = prefix.range(of:
                    #"\b(?:no|neither)\s+(?:new\s+)?(?:file|document|note|spreadsheet|text file|script|image|photo|page|folder)s?\s*$"#,
                    options: .regularExpression) != nil
                let negatedAuxiliary = text[matchRange].range(of: #"\b(?:not|never)\b"#,
                    options: .regularExpression) != nil
                if !negatedObject, !negatedAuxiliary,
                   !englishNegations.contains(where: prefix.contains) {
                    return true
                }
            }
        }
        return false
    }
}
