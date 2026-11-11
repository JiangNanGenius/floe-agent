// SPDX-License-Identifier: MPL-2.0
#if canImport(SwiftUI)
import SwiftUI
import UniformTypeIdentifiers

/// A native details/import/update surface. The App supplies its persistent
/// service and navigation entry; closing this view only ends observation.
@MainActor
public struct IPInformationDatabaseView: View {
    private let service: IPInformationService
    private let onDatabaseChanged: @MainActor @Sendable () -> Void
    @Environment(\.locale) private var locale
    @State private var state: IPInformationState?
    @State private var showPicker = false
    @State private var pickingCity = true
    @State private var city: URL?
    @State private var asn: URL?
    @State private var importLabel = "import"
    @State private var error: String?

    public init(service: IPInformationService, onDatabaseChanged: @escaping @MainActor @Sendable () -> Void = {}) {
        self.service = service; self.onDatabaseChanged = onDatabaseChanged
    }
    private func text(_ english: String, _ chinese: String) -> String {
        locale.language.languageCode?.identifier == "zh" ? chinese : english
    }
    public var body: some View {
        Form {
            Section(text("Installed database", "已安装数据库")) {
                if let metadata = state?.metadata {
                    LabeledContent(text("Source", "来源"), value: metadata.source)
                    LabeledContent(text("Version", "版本"), value: metadata.releaseLabel)
                    LabeledContent(text("Installed", "安装时间"), value: metadata.installedAt.formatted(date: .abbreviated, time: .omitted))
                    Text(metadata.attribution).font(.caption)
                    if let license = metadata.licenseURL { Link(text("Data license", "数据许可"), destination: license) }
                } else { Text(text("No offline database installed.", "尚未安装离线数据库。")) }
            }
            Section(text("Download", "下载")) {
                Text(text("Verified DB-IP Lite: November 2026", "已核验的 DB-IP Lite：2026 年 11 月"))
                Link("DB-IP.com", destination: URL(string: "https://db-ip.com/db/lite.php")!)
                if state?.isUpdating == true {
                    ProgressView(text("Updating database…", "正在更新数据库…"))
                    if let count = state?.downloadedBytes, count > 0 {
                        Text(ByteCountFormatter.string(fromByteCount: count, countStyle: .file)).font(.caption)
                    }
                    if let operation = state?.operationID {
                        Button(text("Cancel update", "取消更新"), role: .cancel) { Task { await service.cancelUpdate(operation) } }
                    }
                } else {
                    Button(text("Install verified edition", "安装已核验版")) {
                        Task { do { _ = try await service.startDefaultUpdate() } catch { self.error = safeMessage(error) } }
                    }
                }
            }
            Section(text("Import MMDB files", "导入 MMDB 文件")) {
                Button(city?.lastPathComponent ?? text("Choose City database", "选择地区数据库")) { pickingCity = true; showPicker = true }
                Button(asn?.lastPathComponent ?? text("Choose ASN database", "选择 ASN 数据库")) { pickingCity = false; showPicker = true }
                TextField(text("Version label", "版本标记"), text: $importLabel)
                Button(text("Import pair", "导入数据库")) {
                    guard let city, let asn else { return }
                    Task {
                        do { _ = try await service.startImport(city: city, asn: asn, versionLabel: importLabel) }
                        catch { self.error = safeMessage(error) }
                    }
                }.disabled(city == nil || asn == nil || importLabel.isEmpty)
            }.disabled(state?.isUpdating == true)
            if let message = state?.message { Section { Text(message) } }
            if state?.phase == .cancelled { Section { Text(text("Update cancelled. Your installed database is unchanged.", "更新已取消，已安装数据库保持不变。")) } }
        }
        .navigationTitle(text("IP databases", "IP 信息库"))
        .fileImporter(isPresented: $showPicker, allowedContentTypes: [.data], allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls): if pickingCity { city = urls.first } else { asn = urls.first }
            case .failure(let failure): error = safeMessage(failure)
            }
        }
        .alert(text("Database update", "数据库更新"), isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button(text("OK", "好"), role: .cancel) { error = nil }
        } message: { Text(error ?? "") }
        .task {
            var version: String?
            for await value in await service.updates() {
                state = value
                if value.metadata?.datasetVersion != version {
                    version = value.metadata?.datasetVersion; onDatabaseChanged()
                }
            }
        }
    }
    private func safeMessage(_ error: Error) -> String {
        (error as? IPInformationError ?? .invalidDownload).localizedDescription
    }
}
#endif
