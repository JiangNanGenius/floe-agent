// SPDX-License-Identifier: MPL-2.0
#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import SwiftUI
import FloeCore
import FloeModels
import FloePersistence
import FloeTools

/// Evidence stays with the run that produced it, even after the workspace changes.
struct RunFileChange: Identifiable, Hashable, Sendable {
    enum ID: Hashable, Sendable { case path(String, workspaceID: UUID?), output(String) }
    enum Action: Hashable, Sendable {
        case added, edited, moved, deleted, saved, delivered
        var title: String {
            switch self {
            case .added: IDELanguageRunText.t("新增", "Added")
            case .edited: IDELanguageRunText.t("修改", "Modified")
            case .moved: IDELanguageRunText.t("移动", "Moved")
            case .deleted: IDELanguageRunText.t("删除", "Deleted")
            case .saved: IDELanguageRunText.t("已保存", "Saved")
            case .delivered: IDELanguageRunText.t("已生成", "Produced")
            }
        }
    }
    enum Evidence: Hashable, Sendable {
        case write(ToolArtifactReference, tool: String)
        case output(RunOutputFile, RunOutputReceiptContext)
    }

    let runID: UUID
    let conversationID: UUID
    let id: ID
    let path: String
    var action: Action
    var evidence: [Evidence]
}

struct RunFileChangeList {
    let runID: UUID
    let conversationID: UUID
    private var files: [RunFileChange.ID: RunFileChange] = [:]
    private var order: [RunFileChange.ID] = []
    // Only keep a requested publication path until its matching result arrives.
    private var publicationPaths: [String: String] = [:]

    init(runID: UUID, conversationID: UUID) {
        self.runID = runID
        self.conversationID = conversationID
    }

    var changes: [RunFileChange] { order.compactMap { files[$0] } }

    mutating func consume(_ event: RunEventRecord, artifactRoot: URL?) {
        guard event.runID == runID, event.kind == .toolRequest || event.kind == .toolResult,
              let fields = try? JSONDecoder().decode([String: String].self, from: Data(event.payloadJSON.utf8)),
              let tool = fields["tool"], let callID = fields["id"] else { return }
        if event.kind == .toolRequest {
            if tool == "workspace.publishOutput", let input = fields["input"],
               let args = try? JSONSerialization.jsonObject(with: Data(input.utf8)) as? [String: Any],
               let path = args["path"] as? String {
                publicationPaths[callID] = Self.relativePath(path)
            }
            return
        }
        let requestedPath = publicationPaths.removeValue(forKey: callID)
        guard fields["status"] == "ok", fields["outcomeUnknown"] != "true" else { return }
        // Legacy receipts have no workspace binding. Keep their run-local
        // group independent of every explicitly identified workspace.
        let workspaceID = fields["workspaceID"].flatMap(UUID.init(uuidString:))
        func pathKey(_ path: String) -> RunFileChange.ID { .path(path, workspaceID: workspaceID) }
        let summary = fields["summary"] ?? ""
        if ["workspace.deleteFile", "workspace.copyFile", "workspace.moveFile"].contains(tool) {
            guard let fields = Self.pathFields(in: summary[...]) else {
                // Older delete receipts did not distinguish files and directories.
                if tool == "workspace.deleteFile", summary.hasPrefix("deleted="),
                   let marker = summary.range(of: " recursive=", options: .backwards),
                   ["true", "false"].contains(String(summary[marker.upperBound...])),
                   let path = Self.relativePath(String(summary.dropFirst("deleted=".count)[..<marker.lowerBound])),
                   files[pathKey(path)] != nil {
                    record(path, key: pathKey(path), action: .deleted)
                }
                return
            }
            guard fields["kind"] == "file", let target = fields["path"], let path = Self.relativePath(target) else { return }
            if tool == "workspace.moveFile", let rawOrigin = fields["from"],
               let origin = Self.relativePath(rawOrigin), origin != path,
               let previous = files.removeValue(forKey: pathKey(origin)) {
                order.removeAll { $0 == pathKey(origin) }
                var moved = RunFileChange(runID: runID, conversationID: conversationID, id: pathKey(path), path: path,
                                          action: previous.action == .added ? .added : .moved, evidence: previous.evidence)
                if let prior = files[pathKey(path)] { moved.evidence = prior.evidence + moved.evidence }
                else { order.append(pathKey(path)) }
                files[pathKey(path)] = moved
            } else {
                let action: RunFileChange.Action
                switch tool {
                case "workspace.deleteFile": action = .deleted
                case "workspace.copyFile": action = fields["change"] == "saved" ? .saved : .added
                default: action = .moved
                }
                record(path, key: pathKey(path), action: action)
            }
            return
        }
        if NativeFileDiffDisposition.result(tool: tool, status: "ok", summary: summary) == .applied {
            let prefix: String
            let delimiter: String
            switch tool {
            case "workspace.createFile": (prefix, delimiter) = ("created=", " bytes=")
            case "workspace.writeFile": (prefix, delimiter) = ("written=", " bytes=")
            case "workspace.applyPatch": (prefix, delimiter) = ("patched=", " hunks=")
            default: (prefix, delimiter) = ("edited=", " bytes=")
            }
            guard summary.hasPrefix(prefix) else { return }
            let marker = summary.range(of: " change=", options: .backwards)
            let operation = marker.map { summary[..<$0.lowerBound] } ?? summary[...]
            let path: String
            let metadata: Substring
            if let marker, let confirmedFields = Self.pathFields(in: operation) {
                guard let raw = confirmedFields["path"], let confirmed = Self.relativePath(raw) else { return }
                path = confirmed
                metadata = summary[marker.lowerBound...]
            } else {
                guard let separator = summary.range(of: delimiter, options: .backwards),
                      let hash = summary[separator.upperBound...].range(of: " sha256="),
                      !summary[hash.upperBound...].contains(" paths="),
                      let historical = Self.relativePath(String(summary.dropFirst(prefix.count)[..<separator.lowerBound])) else { return }
                path = historical
                metadata = summary[separator.lowerBound...]
            }
            if metadata.contains(" change=unchanged saved=true") { return }
            let ref = Self.decode([ToolArtifactReference].self, fields["artifactRefsJSON"])?.first {
                ChatInlineContentCatalog.accepts($0, runID: runID, tool: tool)
                    && ["text/x-diff", "application/vnd.floe.file-preview+json"].contains($0.mimeType)
            }
            // Old records marked identical saves only inside a digest-bound preview.
            if let ref, ref.mimeType == "application/vnd.floe.file-preview+json",
               !metadata.contains(" change=") {
                guard let root = artifactRoot,
                      let verified = try? VerifiedChatInlineArtifact.load(ref, runID: runID, tool: tool, root: root),
                      let preview = try? JSONDecoder().decode(WorkspaceFileChangePreview.self, from: verified.data),
                      Self.relativePath(preview.path) == path, preview.comparison != .unchanged else { return }
            }
            let action: RunFileChange.Action
            if metadata.contains(" change=created saved=true") { action = .added }
            else if metadata.contains(" change=saved saved=true") { action = .saved }
            else { action = .edited }
            record(path, key: pathKey(path), action: action, evidence: ref.map { .write($0, tool: tool) })
        }
        guard let outputs = Self.decode([RunOutputFile].self, fields["outputFilesJSON"]) else { return }
        let context = RunOutputReceiptContext(runID: runID, conversationID: conversationID, callID: callID, toolName: tool)
        for output in RunOutputReceiptGate.accepted(outputs, in: context) {
            // Publishing an existing workspace file alone is not a workspace write.
            // It can supply a verified preview for a file this run already changed.
            if tool == "workspace.publishOutput", let path = requestedPath {
                if files[pathKey(path)] != nil { record(path, key: pathKey(path), action: .delivered, evidence: .output(output, context)) }
            } else if tool != "workspace.publishOutput" {
                record(output.displayName, key: .output(output.outputID), action: .delivered, evidence: .output(output, context))
            }
        }
    }

    private mutating func record(_ path: String, key: RunFileChange.ID, action: RunFileChange.Action, evidence: RunFileChange.Evidence? = nil) {
        if var file = files[key] {
            if file.action == .added && action == .deleted {
                files[key] = nil
                order.removeAll { $0 == key }
                return
            }
            switch (file.action, action) {
            case (_, .delivered), (.added, .edited), (.added, .saved): break
            case (.deleted, .added): file.action = .edited
            default: file.action = action
            }
            if let evidence, !file.evidence.contains(evidence) { file.evidence.append(evidence) }
            files[key] = file
        } else {
            order.append(key)
            files[key] = .init(runID: runID, conversationID: conversationID, id: key, path: path, action: action,
                               evidence: evidence.map { [$0] } ?? [])
        }
    }

    private static func pathFields(in text: Substring) -> [String: String]? {
        var end = text.endIndex
        while let marker = text[..<end].range(of: " paths=", options: .backwards) {
            if let fields = try? JSONDecoder().decode([String: String].self, from: Data(text[marker.upperBound...].utf8)) {
                return fields
            }
            end = marker.lowerBound
        }
        return nil
    }

    private static func relativePath(_ raw: String) -> String? {
        let pieces = raw.split(separator: "/")
        guard !raw.hasPrefix("/"), !pieces.contains(".."), !raw.contains("\0") else { return nil }
        let path = pieces.filter { $0 != "." }.joined(separator: "/")
        return path.isEmpty ? nil : path
    }

    private static func decode<T: Decodable>(_ type: T.Type, _ value: String?) -> T? {
        guard let value else { return nil }
        return try? JSONDecoder().decode(type, from: Data(value.utf8))
    }

    static func load(runID: UUID, conversationID: UUID, answerEventID: UUID? = nil, store: any RunStore) async throws -> [RunFileChange] {
        guard let run = try await store.run(id: runID), run.conversationID == conversationID else { return [] }
        var list = Self(runID: runID, conversationID: conversationID)
        let root = try? FloeArtifactStore.root()
        var sequence = -1
        while true {
            try Task.checkCancellation()
            let page = try await store.events(runID: runID, afterSequence: sequence, limit: 100)
            guard let last = page.last, last.sequence > sequence else { break }
            for event in page {
                if let answerEventID, event.kind == .assistantText {
                    if event.id == answerEventID { return list.changes }
                    // A reply owns only the verified results since the preceding
                    // assistant reply, not the complete multi-reply task.
                    list = Self(runID: runID, conversationID: conversationID)
                } else {
                    list.consume(event, artifactRoot: root)
                }
            }
            sequence = last.sequence
            if page.count < 100 { break }
        }
        // An unbound/missing answer must not borrow another reply's changes.
        return answerEventID == nil ? list.changes : []
    }
}

struct RunFileChangesDisclosure: View {
    let runID: UUID
    let conversationID: UUID
    var answerEventID: UUID? = nil
    @EnvironmentObject private var environment: AppEnvironment
    @State private var changes: [RunFileChange] = []
    @State private var expanded = false

    var body: some View {
        Group {
            if !changes.isEmpty {
                DisclosureGroup(isExpanded: $expanded) {
                    ForEach(changes) { change in
                        DisclosureGroup {
                            RunFileChangeEvidenceView(change: change)
                        } label: {
                            HStack {
                                Text(change.path).lineLimit(2)
                                Spacer()
                                Text(change.action.title).foregroundStyle(.secondary)
                            }
                            .contentShape(Rectangle())
                            .frame(minHeight: 44)
                        }
                    }
                } label: {
                    Label(IDELanguageRunText.t("已更改 \(changes.count) 个文件",
                          changes.count == 1 ? "Changed 1 file" : "Changed \(changes.count) files"),
                          systemImage: "doc.on.doc").font(.subheadline)
                }
                .accessibilityIdentifier("chat.turnFileChanges")
            }
        }
        .task(id: answerEventID ?? runID) {
            let result = try? await RunFileChangeList.load(runID: runID, conversationID: conversationID, answerEventID: answerEventID, store: environment.runStore)
            guard !Task.isCancelled else { return }
            changes = result ?? []
        }
    }
}

private struct RunFileChangeEvidenceView: View {
    let change: RunFileChange

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(change.evidence.enumerated()), id: \.offset) { _, evidence in
                switch evidence {
                case .write(let ref, let tool):
                    RunFileWritePreview(ref: ref, tool: tool, runID: change.runID)
                        .id(ref)
                case .output(let output, let context):
                    RunOutputFileView(receipt: output, context: context)
                }
            }
            if change.evidence.isEmpty {
                Text(change.action == .deleted
                     ? IDELanguageRunText.t("本轮已删除这个文件。", "This file was deleted during this run.")
                     : IDELanguageRunText.t("本轮已记录操作，未保留内容预览。", "This action was recorded without a saved preview."))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("chat.turnFileChangeDetail")
    }
}

private struct RunFileWritePreview: View {
    let ref: ToolArtifactReference
    let tool: String
    let runID: UUID
    @State private var verified: VerifiedChatInlineArtifact?
    @State private var unavailable = false

    var body: some View {
        Group {
            if let verified {
                Text(ref.mimeType == "text/x-diff" ? IDELanguageRunText.t("本轮差异", "Changes in this run") :
                     IDELanguageRunText.t("保存时的内容", "Saved contents")).font(.caption)
                if ref.mimeType == "text/x-diff", let diff = String(data: verified.data, encoding: .utf8) {
                    NativeFileChangeCard(diffText: diff, disposition: .applied, fileURL: verified.fileURL,
                                         expandedByParent: true)
                } else {
                    RichArtifactView(artifact: ref, preverified: verified, fileDiffDisposition: .applied)
                }
            } else if unavailable {
                Text(IDELanguageRunText.t("无法读取这次保存的预览。", "The saved preview is unavailable."))
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .task(id: ref) {
            let result = await Self.load(ref, runID: runID, tool: tool)
            guard !Task.isCancelled else { return }
            verified = result
            unavailable = result == nil
        }
    }

    @concurrent private static func load(_ ref: ToolArtifactReference, runID: UUID, tool: String) async -> VerifiedChatInlineArtifact? {
        guard !Task.isCancelled, let root = try? FloeArtifactStore.root() else { return nil }
        return try? VerifiedChatInlineArtifact.load(ref, runID: runID, tool: tool, root: root)
    }
}
#endif
