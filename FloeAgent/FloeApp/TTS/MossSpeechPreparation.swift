// FloeApp — Accepted MOSS flatPause integration into the local speech path.
//
// This is a narrow source-preparation layer, not a model or parameter change:
// MOSS Nano, its default voice, reference assets and sampling options stay
// untouched. Only eligible paragraphs of short, strict ZH/EN alternation get
// their internal full stops softened to fullwidth commas before synthesis.
// Everything else is passed through unchanged.

import Foundation
import FloeProviders

enum MossSpeechPreparation {
    static let mossEngine = "mossTTSNano"

    static func isMossEngine(_ engine: String?) -> Bool {
        engine == mossEngine
    }

    /// Plans complete blank-line paragraphs. Ineligible paragraphs are
    /// returned byte-identical. The caller still owns Markdown/URL projection
    /// and sentence segmentation.
    struct CaptionEdit: Sendable {
        let source: NSRange
        let spoken: NSRange
    }

    struct ParagraphProjection: Sendable {
        let spoken: String
        let edits: [CaptionEdit]
    }

    static func prepareParagraphs(_ text: String, engine: String?) -> String {
        paragraphProjection(text, engine: engine).spoken
    }

    static func paragraphProjection(_ text: String, engine: String?) -> ParagraphProjection {
        guard isMossEngine(engine), !text.isEmpty else {
            return ParagraphProjection(spoken: text, edits: [])
        }
        var sourceOffset = 0
        var spokenOffset = 0
        var edits: [CaptionEdit] = []
        let paragraphs = text.components(separatedBy: "\n\n").map { paragraph -> String in
            let trimmed = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
            let plan = MossProsodyPlanner.flatPause(trimmed)
            var prepared = paragraph
            if plan.eligible, let range = paragraph.range(of: trimmed) {
                let prefix = String(paragraph[..<range.lowerBound])
                prepared = prefix + plan.spoken + String(paragraph[range.upperBound...])
                edits.append(contentsOf: plan.edits.map { edit in
                    CaptionEdit(
                        source: NSRange(location: sourceOffset + prefix.utf16.count + edit.sourceUTF16Start,
                                        length: edit.sourceUTF16Length),
                        spoken: NSRange(location: spokenOffset + prefix.utf16.count + edit.spokenUTF16Start,
                                        length: edit.spokenUTF16Length))
                })
            }
            sourceOffset += paragraph.utf16.count + 2
            spokenOffset += prepared.utf16.count + 2
            return prepared
        }
        return ParagraphProjection(spoken: paragraphs.joined(separator: "\n\n"), edits: edits)
    }
}

/// Bounded batch lookahead for the narrow alternation case. A candidate batch
/// is the set of complete sentences the production segmenter released for one
/// streamed addition. The buffer never crosses an addition, so a single short
/// sentence is spoken immediately instead of waiting for the model to finish.
/// Four alternating short candidates are planned together; the buffer is
/// hard-capped and `finish()`/cancellation always flushes pending complete
/// sentences unchanged.
struct MossProsodyStreamPreparation {
    static let maximumPending = 8

    private var pending: [String] = []

    mutating func accept(_ segments: [String]) -> [String] {
        guard !segments.isEmpty else { return [] }
        var output: [String] = []
        for segment in segments {
            let trimmed = segment.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let kind = MossProsodyPlanner.classify(trimmed)
            if pending.isEmpty {
                if kind != .other {
                    pending = [trimmed]
                } else {
                    output.append(trimmed)
                }
                continue
            }
            let lastKind = MossProsodyPlanner.classify(pending[pending.count - 1])
            if kind != .other, kind.language != nil,
               kind.language != lastKind.language, lastKind.language != nil {
                pending.append(trimmed)
                if pending.count >= 4 {
                    output.append(contentsOf: flushPlanned())
                } else if pending.count >= Self.maximumPending {
                    output.append(contentsOf: flushUnchanged())
                }
            } else {
                output.append(contentsOf: flushUnchanged())
                if kind != .other {
                    pending = [trimmed]
                } else {
                    output.append(trimmed)
                }
            }
        }
        // Never hold a batch open across an addition: a short single sentence
        // must not wait for the next token or model completion.
        output.append(contentsOf: flushUnchanged())
        return output
    }

    mutating func finish() -> [String] {
        flushUnchanged()
    }

    private mutating func flushPlanned() -> [String] {
        let units = pending
        pending = []
        guard !units.isEmpty else { return [] }
        let plan = MossProsodyPlanner.flatPause(units.joined(separator: " "))
        return plan.eligible ? [plan.spoken] : units
    }

    private mutating func flushUnchanged() -> [String] {
        let value = pending
        pending = []
        return value
    }
}
