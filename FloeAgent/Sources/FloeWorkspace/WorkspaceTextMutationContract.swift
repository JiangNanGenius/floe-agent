// FloeWorkspace — Shared text-mutation contract.
//
// SPDX-License-Identifier: MPL-2.0
//
// One Foundation-only contract backs every `workspace.applyPatch`
// implementation (the iPad/Linux `WorkspaceFileService` and the unified Mac
// host's pinned-descriptor tool lane) so a single-file unified diff is parsed
// and applied with byte-identical semantics on every platform. The contract
// operates on the *decoded* text: callers decode with
// `WorkspaceTextPolicy.decodeUTF8` (which re-attaches a leading BOM) and split
// on "\n", so CRLF newlines inside lines and a UTF-8 BOM survive the
// read/modify/write round trip unchanged.
//
// Deliberate scope: parsing and sequential hunk application only. Filesystem
// access, locking, staging, conflict detection and publication stay with each
// host's proven mutation path.

import Foundation

/// Shared single-file editing and receipt contract.
public enum WorkspaceTextMutationContract {
    public enum Change: String, Sendable { case created, modified, unchanged, saved }

    public static func paths(_ path: String?, from: String? = nil, kind: String? = nil,
                             change: Change? = nil) -> String {
        guard let path else { return " paths={}" }
        var fields = ["path": path]
        fields["from"] = from
        fields["kind"] = kind
        fields["change"] = change?.rawValue
        guard let data = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys, .withoutEscapingSlashes]) else {
            return " paths={}"
        }
        return " paths=" + String(decoding: data, as: UTF8.self)
    }

    public static func savedReceipt(_ summary: String, path: String?, change: Change) -> String {
        summary + paths(path) + " change=\(change.rawValue) saved=true"
    }

    /// One parsed unified-diff hunk.
    public struct Hunk: Sendable, Equatable {
        public var oldStart: Int
        public var oldCount: Int
        public var newStart: Int
        public var newCount: Int
        /// Lines expected in the file (context + removals, in order).
        public var oldLines: [String]
        /// Replacement lines (context + additions, in order).
        public var newLines: [String]
        public var addedCount: Int
        public var removedCount: Int
        /// Raw body lines for re-emission (diff generation only).
        public var body: [String]

        public init(
            oldStart: Int, oldCount: Int, newStart: Int, newCount: Int,
            oldLines: [String], newLines: [String],
            addedCount: Int, removedCount: Int, body: [String]
        ) {
            self.oldStart = oldStart
            self.oldCount = oldCount
            self.newStart = newStart
            self.newCount = newCount
            self.oldLines = oldLines
            self.newLines = newLines
            self.addedCount = addedCount
            self.removedCount = removedCount
            self.body = body
        }
    }

    /// The verified result of applying every hunk to one revision.
    public struct Application: Sendable, Equatable {
        /// The complete patched text (join the caller's lines with "\n").
        public var text: String
        public var hunksApplied: Int
        public var linesAdded: Int
        public var linesRemoved: Int

        public init(text: String, hunksApplied: Int, linesAdded: Int, linesRemoved: Int) {
            self.text = text
            self.hunksApplied = hunksApplied
            self.linesAdded = linesAdded
            self.linesRemoved = linesRemoved
        }
    }

    /// Deterministic failure surface of the contract. Hosts map this onto
    /// their own tool error (`WorkspaceToolError.invalidPatch`,
    /// `MacAgentWorkspaceToolsError.invalidPatch`, …) so user-facing wording
    /// stays stable per surface.
    public enum ContractError: Error, Equatable, LocalizedError {
        case invalidPatch(String)

        /// The original machine-readable reason.
        public var reason: String {
            switch self {
            case .invalidPatch(let reason): reason
            }
        }

        public var errorDescription: String? { reason }
    }

    /// Parses a unified diff into hunks for one file. Multi-file patches
    /// (more than one `--- `/`+++ ` pair, or `diff --git` headers) throw
    /// `.invalidPatch`.
    public static func parseUnifiedDiff(_ patch: String) throws -> [Hunk] {
        let lines = patch.components(separatedBy: "\n")
        var hunks: [Hunk] = []
        var index = 0
        var sawFileHeader = 0

        while index < lines.count {
            let line = lines[index]
            if line.hasPrefix("diff --git") {
                throw ContractError.invalidPatch(
                    "multi-file patches are not supported; apply one file per call"
                )
            }
            if line.hasPrefix("--- ") {
                sawFileHeader += 1
                if sawFileHeader > 1 {
                    throw ContractError.invalidPatch(
                        "multi-file patches are not supported; apply one file per call"
                    )
                }
                index += 1
                if index < lines.count, lines[index].hasPrefix("+++ ") {
                    index += 1
                }
                continue
            }
            if line.hasPrefix("@@") {
                let (hunk, consumed) = try parseHunk(Array(lines[index...]))
                hunks.append(hunk)
                index += consumed
                continue
            }
            index += 1
        }
        guard !hunks.isEmpty else {
            throw ContractError.invalidPatch("no hunks found")
        }
        return hunks
    }

    /// Applies every hunk to `original` in order, adjusting subsequent hunk
    /// positions by the net growth of earlier ones. Any out-of-range hunk,
    /// context mismatch or line-delta overflow leaves the caller's state
    /// untouched (the application is computed before the host commits it).
    /// `reportCancellation` is invoked before each hunk so a cancelled run can
    /// never be presented as a verified application.
    public static func apply(
        hunks: [Hunk],
        to original: String,
        reportCancellation: (() throws -> Void)? = nil
    ) throws -> Application {
        var lines = original.components(separatedBy: "\n")
        var applied = 0
        var added = 0
        var removed = 0
        var lineDelta = 0
        for hunk in hunks {
            try reportCancellation?()
            let (zeroBased, startUnderflow) = hunk.oldStart.subtractingReportingOverflow(1)
            let (startIndex, startOverflow) = zeroBased.addingReportingOverflow(lineDelta)
            let (endIndex, endOverflow) = startIndex.addingReportingOverflow(hunk.oldLines.count)
            guard !startUnderflow, !startOverflow, !endOverflow,
                  startIndex >= 0, endIndex <= lines.count else {
                throw ContractError.invalidPatch(
                    "hunk @@ -\(hunk.oldStart),\(hunk.oldCount) +\(hunk.newStart),\(hunk.newCount) @@ is out of range"
                )
            }
            let window = Array(lines[startIndex..<endIndex])
            guard window == hunk.oldLines else {
                throw ContractError.invalidPatch(
                    "context mismatch near line \(hunk.oldStart); file contents do not match the patch"
                )
            }
            lines.replaceSubrange(startIndex..<endIndex, with: hunk.newLines)
            let delta = hunk.newLines.count - hunk.oldLines.count
            let (nextDelta, deltaOverflow) = lineDelta.addingReportingOverflow(delta)
            guard !deltaOverflow else {
                throw ContractError.invalidPatch("hunk line delta overflow")
            }
            lineDelta = nextDelta
            applied += 1
            added += hunk.addedCount
            removed += hunk.removedCount
        }
        return Application(
            text: lines.joined(separator: "\n"),
            hunksApplied: applied,
            linesAdded: added,
            linesRemoved: removed
        )
    }

    private static func parseHunk(_ lines: [String]) throws -> (Hunk, Int) {
        guard let header = lines.first else {
            throw ContractError.invalidPatch("truncated hunk")
        }
        // @@ -oldStart,oldCount +newStart,newCount @@
        let pattern = #"^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                  in: header, range: NSRange(header.startIndex..., in: header)
              ),
              let oldStartRange = Range(match.range(at: 1), in: header),
              let newStartRange = Range(match.range(at: 3), in: header),
              let oldStart = Int(header[oldStartRange]),
              let newStart = Int(header[newStartRange])
        else {
            throw ContractError.invalidPatch("malformed hunk header: \(header)")
        }
        let oldCount = match.range(at: 2).location != NSNotFound
            ? Range(match.range(at: 2), in: header).flatMap { Int(header[$0]) } ?? 1
            : 1
        let newCount = match.range(at: 4).location != NSNotFound
            ? Range(match.range(at: 4), in: header).flatMap { Int(header[$0]) } ?? 1
            : 1

        var oldLines: [String] = []
        var newLines: [String] = []
        var added = 0
        var removed = 0
        var consumed = 1
        var seenOld = 0
        var seenNew = 0
        var bodyIndex = 1
        while bodyIndex < lines.count, seenOld < oldCount || seenNew < newCount {
            let line = lines[bodyIndex]
            if line.hasPrefix(#"\ "#) {
                // "\ No newline at end of file" marker: skip.
                bodyIndex += 1
                consumed += 1
                continue
            }
            guard let marker = line.first, marker == " " || marker == "-" || marker == "+" else {
                break
            }
            let content = String(line.dropFirst())
            switch marker {
            case " ":
                oldLines.append(content)
                newLines.append(content)
                seenOld += 1
                seenNew += 1
            case "-":
                oldLines.append(content)
                removed += 1
                seenOld += 1
            default: // "+"
                newLines.append(content)
                added += 1
                seenNew += 1
            }
            bodyIndex += 1
            consumed += 1
        }
        guard seenOld == oldCount, seenNew == newCount else {
            throw ContractError.invalidPatch(
                "hunk truncated: expected -\(oldCount)/+\(newCount) lines, saw -\(seenOld)/+\(seenNew)"
            )
        }
        return (
            Hunk(
                oldStart: oldStart,
                oldCount: oldCount,
                newStart: newStart,
                newCount: newCount,
                oldLines: oldLines,
                newLines: newLines,
                addedCount: added,
                removedCount: removed,
                body: []
            ),
            consumed
        )
    }
}
