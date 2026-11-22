// SPDX-License-Identifier: MPL-2.0
// FloeApp — Shared task-activity presentation (run progress + file changes).
//
// Extracted from the shipping iPad task inspectors (`TaskInspectorViews.swift`
// and `TaskChangesInspectorView.swift`, iPad tag v1.8.72) so the unified Mac
// target can render the same projections from a plain run/event journal
// snapshot. Everything in this file is free of `AppEnvironment`/`AppRouter`:
// platforms inject their own store access, artifact bytes and navigation, and
// a diff is only ever shown through the bounded, digest-verified artifact
// path below — never synthesized and never read from an arbitrary path.

#if canImport(SwiftUI)
import SwiftUI
import FloeCore
import FloeModels
import FloePersistence
import FloeTools

// MARK: - Shared bilingual copy
//
// `ChatBilingualCatalog` wins as soon as the integration owner registers the
// same key in the catalog; until then the identical EN/ZH sentence renders
// inline on both platforms, so no raw dotted key can appear anywhere.

private enum FloeTaskActivityText {
    static let waitingForBackgroundWork = ChatBilingualCatalog.localized(
        key: "state.waiting_for_background_work",
        en: "Waiting for background work", zh: "等待后台任务")
    static let actionChanged = ChatBilingualCatalog.localized(
        key: "workbench.task_changes_inspector_view.changed",
        en: "Changed", zh: "修改")
    static let actionWritten = ChatBilingualCatalog.localized(
        key: "workbench.task_changes_inspector_view.write",
        en: "Write", zh: "写入")
    static let actionCreated = ChatBilingualCatalog.localized(
        key: "chat.thread_detail_view_model.new",
        en: "New", zh: "新建")
    static let actionDeleted = ChatBilingualCatalog.localized(
        key: "workbench.task_changes_inspector_view.delete",
        en: "Delete", zh: "删除")
}

// MARK: - File-change projection (pure)

/// One file-change row: a successful, task-owned workspace mutation backed
/// by a tool result event — never a synthesized fact.
struct FloeTaskActivityChange: Identifiable, Hashable, Sendable {
    let id: UUID
    let runID: UUID
    let path: String
    let action: String
    let summary: String
    let added: Int
    let removed: Int
    let createdAt: Date
    /// The recorded `text/x-diff` receipt, when the tool supplied one.
    let artifact: ToolArtifactReference?

    /// A verified diff can be offered only when a digest-addressed artifact
    /// receipt exists; verification itself happens at open time.
    var hasDiffReceipt: Bool { artifact != nil }
}

enum FloeTaskActivityProjection {
    struct ToolResultPayload: Decodable {
        var tool: String?
        var status: String?
        var summary: String?
        var artifactRefsJSON: String?

        var artifacts: [ToolArtifactReference] {
            guard let artifactRefsJSON,
                  let data = artifactRefsJSON.data(using: .utf8) else { return [] }
            return (try? JSONDecoder().decode([ToolArtifactReference].self, from: data)) ?? []
        }
    }

    /// Successful workspace writes only (`status` absent or `ok`), in the
    /// exact summary vocabulary the workspace tools record. Runs are scanned
    /// in the caller's order; the result is sorted newest-first so both
    /// platforms present identical data.
    static func changes(
        runs: [RunRecord],
        events: [UUID: [RunEventRecord]]
    ) -> [FloeTaskActivityChange] {
        var collected: [FloeTaskActivityChange] = []
        for run in runs {
            for event in events[run.id] ?? [] where event.kind == .toolResult {
                guard let data = event.payloadJSON.data(using: .utf8),
                      let payload = try? JSONDecoder().decode(ToolResultPayload.self, from: data),
                      payload.status == nil || payload.status == "ok",
                      let summary = payload.summary,
                      let parsed = parseChange(summary: summary, tool: payload.tool)
                else { continue }
                collected.append(FloeTaskActivityChange(
                    id: event.id,
                    runID: run.id,
                    path: parsed.path,
                    action: parsed.action,
                    summary: summary,
                    added: parsed.added,
                    removed: parsed.removed,
                    createdAt: event.createdAt,
                    artifact: payload.artifacts.first(where: { ref in
                        ref.relativePath.hasPrefix("ChangeArtifacts/\(run.id.uuidString)/") && FloeVerifiedChangeArtifact.isDiffCandidate(ref)
                    })
                ))
            }
        }
        return collected.sorted { $0.createdAt > $1.createdAt }
    }

    /// The historical summary grammar the workspace tools persist. Unknown
    /// shapes are skipped, not guessed.
    static func parseChange(
        summary: String,
        tool: String?
    ) -> (path: String, action: String, added: Int, removed: Int)? {
        let candidates: [(prefix: String, action: String, delimiter: String)] = [
            ("patched=", FloeTaskActivityText.actionChanged, " hunks="),
            ("written=", FloeTaskActivityText.actionWritten, " bytes="),
            ("created=", FloeTaskActivityText.actionCreated, " bytes="),
            ("deleted=", FloeTaskActivityText.actionDeleted, " ")
        ]
        guard tool?.hasPrefix("workspace.") != false else { return nil }
        for candidate in candidates where summary.hasPrefix(candidate.prefix) {
            let remainder = String(summary.dropFirst(candidate.prefix.count))
            let path = remainder.components(separatedBy: candidate.delimiter).first ?? remainder
            guard !path.isEmpty else { return nil }
            return (
                path,
                candidate.action,
                integer(after: "added=", in: summary),
                integer(after: "removed=", in: summary)
            )
        }
        return nil
    }

    private static func integer(after marker: String, in text: String) -> Int {
        guard let range = text.range(of: marker) else { return 0 }
        let tail = text[range.upperBound...]
        return Int(tail.prefix { $0.isNumber }) ?? 0
    }
}

// MARK: - Verified change artifact (bounded, digest-addressed)

/// The only trustworthy source of diff text for a change row. The reference
/// must name a digest-addressed file under the run-scoped `ChangeArtifacts/`
/// store (the exact shape `workspace.*` tools persist, see
/// `FileTools.changeArtifact`), the byte budget matches the producer's 512 KiB
/// bound, and the bytes must reproduce the recorded size + sha256 receipt.
enum FloeVerifiedChangeArtifact {
    static let maxByteCount = 512 * 1024

    /// Reference-shape check; performs no I/O.
    static func isDiffCandidate(_ artifact: ToolArtifactReference) -> Bool {
        guard artifact.mimeType == "text/x-diff",
              artifact.byteCount > 0,
              artifact.byteCount <= maxByteCount else { return false }
        let parts = artifact.relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts[0] == "ChangeArtifacts",
              UUID(uuidString: String(parts[1])) != nil,
              parts[2].hasSuffix(".diff"),
              !parts.contains("..") else { return false }
        // Digest-addressed name: the file name IS the recorded sha256.
        return parts[2].dropLast(".diff".count) == Substring(artifact.sha256.lowercased())
    }

    /// Content check against the durable receipt: exact byte count and
    /// sha256. Returns the UTF-8 diff only when both match.
    static func verifiedDiffText(
        data: Data,
        artifact: ToolArtifactReference
    ) -> String? {
        guard data.count == artifact.byteCount,
              FloeDigest.sha256Hex(data) == artifact.sha256.lowercased() else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Resolve + verify under an explicit artifact root (the FloeAgent
    /// Application Support store on device; the Mac coordinator supplies its
    /// durable-store root). Never touches a workspace path.
    static func verifiedDiff(
        _ artifact: ToolArtifactReference,
        floeAgentRoot root: URL
    ) throws -> String? {
        guard isDiffCandidate(artifact) else { return nil }
        let data = try FloeArtifactStore.verifiedData(artifact.relativePath, allowed: [.change], maxBytes: maxByteCount,
                                                       expectedSHA256: artifact.sha256, root: root)
        return verifiedDiffText(data: data, artifact: artifact)
    }
}

// MARK: - Run progress row
//
// Extracted from the iPad inspector's private `RunProgressRow`: identical
// title/spinner/goal semantics (`RunStateLocalizer` is the only state→text
// mapping). The optional waiting identifiers stay a caller input because the
// durable reason is read from the run's status events by the platform side.

struct FloeRunProgressRow: View {
    let run: RunRecord
    var waitingJobIdentifiers: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                if waitingJobIdentifiers != nil {
                    Text(FloeTaskActivityText.waitingForBackgroundWork)
                } else {
                    Text(RunStateLocalizer.title(for: run.state))
                }
                Spacer()
                Text(run.startedAt, style: .time).foregroundStyle(.secondary)
            }
            if let waitingJobIdentifiers {
                Text(waitingJobIdentifiers)
                    .font(.caption)
                    .foregroundStyle(FloeTheme.pending)
                    .accessibilityIdentifier("inspector.run.waiting")
            } else if !RunStateLocalizer.isTerminal(run.state) || run.state == "checkpointed" {
                // A non-terminal run shows an indeterminate spinner instead
                // of an invented percentage; a dependency-parked run
                // (`checkpointed`) keeps the same honest in-progress look.
                ProgressView().controlSize(.small)
            }
            Text(run.goal).font(.caption).foregroundStyle(.secondary).lineLimit(3)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - File-change row
//
// Extracted from the iPad change list: identical path/action/counts/time
// presentation. `openDiff` is non-nil exactly when a verified diff can be
// offered; platforms keep their own open behavior (inspector push on iPad,
// sheet on Mac). Swipe actions and file navigation stay on the iPad wrapper.

struct FloeTaskActivityChangeRow: View {
    let change: FloeTaskActivityChange
    var isEnabled: Bool
    let openDiff: () -> Void

    var body: some View {
        Button {
            openDiff()
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(change.path).font(.body.weight(.medium)).lineLimit(2)
                    Spacer()
                    Text(change.action).font(.caption).foregroundStyle(.secondary)
                }
                if change.added > 0 || change.removed > 0 {
                    Text("+\(change.added)  −\(change.removed)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(change.removed > 0 ? FloeTheme.destructive : FloeTheme.success)
                }
                Text(change.createdAt, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityIdentifier("taskActivity.change.\(change.id.uuidString)")
    }
}
#endif
