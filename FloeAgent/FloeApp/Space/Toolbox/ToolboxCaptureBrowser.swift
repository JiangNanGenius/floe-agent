// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import SwiftUI
import UniformTypeIdentifiers
import FloeToolboxCore

@MainActor enum ToolboxPacketImport {
    static func read(_ url: URL) async throws -> ImportedCapture {
        try await Task.detached(priority: .utility) {
            let scoped = url.startAccessingSecurityScopedResource(); defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true, let size = values.fileSize, size <= 64 * 1_024 * 1_024 else { throw ToolboxError.limit("packet import") }
            return try PacketCaptureImporter.parse(Data(contentsOf: url, options: .mappedIfSafe))
        }.value
    }
    static func append(_ capture: ImportedCapture, to journal: CaptureJournal) async throws {
        // Preserve original packet layer/origin/timestamps. The journal applies redaction and rolling limits.
        for start in stride(from: 0, to: capture.packets.count, by: 256) {
            let end = min(start + 256, capture.packets.count)
            let events = capture.packets[start..<end].map { packet in
                CaptureEvent(bytes: packet.bytes, direction: .observation, layer: .networkPacket, origin: capture.origin,
                    timestamp: packet.timestamp, originalByteCount: packet.originalByteCount,
                    notes: ["linkType=\(packet.linkType)", "interfaceID=\(packet.interfaceID)"])
            }
            try Task.checkCancellation(); try await journal.append(events)
        }
    }
}

struct ToolboxCaptureBrowser: View {
    @EnvironmentObject private var environment: AppEnvironment
    @Environment(\.dismiss) private var dismiss
    @State private var summaries: [ToolboxCaptureSummary] = []
    @State private var selected: ToolboxCaptureSummary?
    @State private var importing = false
    @State private var busy = false
    @State private var failure: String?
    private func store() throws -> ToolboxCaptureStore { ToolboxCaptureStore(database: environment.database, exportRoot: try ToolboxCaptureStore.exportsRoot()) }
    var body: some View {
        NavigationStack {
            List {
                if let failure { Text(failure).foregroundStyle(.secondary) }
                ForEach(summaries) { item in
                    Button { selected = item } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Label(item.title, systemImage: item.kind == "terminal" ? "terminal" : item.kind == "packet" ? "network" : "list.bullet.rectangle").foregroundStyle(.primary)
                            Text(item.updatedAt.timeIntervalSince1970 == 0 ? IDELanguageRunText.t("已保存记录", "Saved capture") : item.updatedAt.formatted()).font(.caption).foregroundStyle(.secondary)
                        }.frame(minHeight: 44)
                    }
                }
            }.overlay { if summaries.isEmpty, !busy { ContentUnavailableView(IDELanguageRunText.t("暂无记录", "No captures"), systemImage: "list.bullet.rectangle") } }
                .navigationTitle(IDELanguageRunText.t("通信与终端记录", "Communication and terminal captures"))
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button(IDELanguageRunText.t("完成", "Done")) { dismiss() } }
                    ToolbarItem(placement: .primaryAction) { Button(IDELanguageRunText.t("导入抓包", "Import packet capture"), systemImage: "square.and.arrow.down") { importing = true }.disabled(busy) }
                }
                .refreshable { await load() }
                .task { await load() }
                .sheet(item: $selected, onDismiss: { Task { await load() } }) { item in ToolboxCaptureDetails(summary: item) }
                .fileImporter(isPresented: $importing, allowedContentTypes: [UTType(filenameExtension: "pcap") ?? .data, UTType(filenameExtension: "pcapng") ?? .data], allowsMultipleSelection: false) { result in
                    Task {
                        busy = true; defer { busy = false }
                        do {
                            guard let url = try result.get().first else { return }
                            let capture = try await ToolboxPacketImport.read(url), repository = try store(), ownerID = UUID()
                            let journal = try await CaptureJournal(ownerID: ownerID, repository: repository,
                                limits: CaptureLimits(maximumRecords: 100_000, maximumBytes: 64 * 1_024 * 1_024, maximumRecordBytes: 1_024 * 1_024))
                            try await repository.describe(captureID: journal.captureID, ownerID: ownerID, title: url.lastPathComponent, kind: "packet")
                            try await ToolboxPacketImport.append(capture, to: journal)
                            await load()
                        } catch { failure = IDELanguageRunText.t("未能导入，请选择有效的 PCAP 或 PCAPNG 文件。", "Unable to import. Choose a valid PCAP or PCAPNG file.") }
                    }
                }
        }
    }
    private func load() async { do { summaries = try await store().summaries(); failure = nil } catch { failure = IDELanguageRunText.t("未能读取记录。", "Unable to read captures.") } }
}

struct ToolboxCaptureDetails: View {
    let summary: ToolboxCaptureSummary
    @EnvironmentObject private var environment: AppEnvironment
    @Environment(\.dismiss) private var dismiss
    @State private var capture: CaptureState?
    @State private var export: URL?
    @State private var failed = false
    var body: some View {
        NavigationStack {
            List {
                if let capture {
                    Section {
                        LabeledContent(IDELanguageRunText.t("记录数", "Records"), value: capture.records.count.formatted())
                        LabeledContent(IDELanguageRunText.t("保留字节", "Retained bytes"), value: capture.retainedBytes.formatted())
                        if capture.droppedRecords > 0 { Text(IDELanguageRunText.t("滚动上限已移除较早记录：", "Earlier records removed by the rolling limit: ") + capture.droppedRecords.formatted()).foregroundStyle(.secondary) }
                        if capture.records.count > 2_000 { Text(IDELanguageRunText.t("此处显示最近 2,000 条；导出保留全部已存记录。", "Showing the latest 2,000 records; exports retain all saved records.")).foregroundStyle(.secondary) }
                    }
                    ForEach(Array(capture.records.suffix(2_000))) { record in
                        DisclosureGroup {
                            Text(record.redacted ? IDELanguageRunText.t("敏感内容已省略", "Sensitive content omitted") : record.layer == .networkPacket ? record.bytes.prefix(512).map { String(format: "%02X", $0) }.joined(separator: " ") : String(decoding: record.bytes.prefix(8_192), as: UTF8.self)).font(.caption.monospaced()).textSelection(.enabled)
                            ForEach(record.notes, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("#\(record.sequence) · \(record.direction.rawValue) · \(record.bytes.count) B").font(.subheadline.monospacedDigit())
                                Text(record.layer == .networkPacket ? "\(record.origin.rawValue.uppercased()) · " + IDELanguageRunText.t("链路包", "Network packet") : IDELanguageRunText.t("应用收发字节", "Application bytes")).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                } else if failed { Text(IDELanguageRunText.t("未能读取记录", "Unable to read the capture")) } else { ProgressView() }
                if let export { ShareLink(item: export) { Label(IDELanguageRunText.t("存储或共享快照", "Save or share snapshot"), systemImage: "square.and.arrow.up") } }
            }.navigationTitle(summary.title).navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button(IDELanguageRunText.t("完成", "Done")) { dismiss() } }
                    ToolbarItem(placement: .primaryAction) { Button(IDELanguageRunText.t("保存快照", "Save snapshot")) { Task { do { if let capture { export = try await repository().saveSnapshot(capture) } } catch { failed = true } } }.disabled(capture == nil) }
                }
                .task { do { capture = try await repository().load(captureID: summary.id, ownerID: summary.ownerID) } catch { failed = true } }
        }
    }
    private func repository() throws -> ToolboxCaptureStore { ToolboxCaptureStore(database: environment.database, exportRoot: try ToolboxCaptureStore.exportsRoot()) }
}
#endif
