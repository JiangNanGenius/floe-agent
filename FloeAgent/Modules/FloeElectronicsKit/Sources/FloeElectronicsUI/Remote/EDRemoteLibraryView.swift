// SPDX-License-Identifier: MPL-2.0
import SwiftUI
import Foundation
import FloeElectronicsCore

/// Compact online catalogue for the shared native library. Search and install
/// are real service calls; install only returns after an exact native
/// reference reads back. 3D bytes are downloaded separately per model.
public struct EDRemoteLibrarySheet: View {
    @Bindable private var controller: EDRemoteLibraryController
    @Environment(\.dismiss) private var dismiss
    @State private var showingDiagnostics = false

    public init(controller: EDRemoteLibraryController) { self.controller = controller }

    public var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                statusBar
                if let message = controller.message {
                    messageBar(message)
                }
                if controller.busy { progressBar }
                searchBar
                partList
            }
            .navigationTitle(edText("在线元件库", "Online library"))
            .edLibraryInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(edText("完成", "Done")) { dismiss() }
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        controller.refresh()
                    } label: { Label(edText("刷新目录", "Refresh catalogue"), systemImage: "arrow.clockwise") }
                        .disabled(controller.busy)
                    Menu {
                        Toggle(edText("显示待复核记录", "Show review-required"), isOn: Binding(
                            get: { controller.includeReviewRequired },
                            set: { value in controller.includeReviewRequired = value; controller.searchParts() }))
                        if let model = controller.lastInstall?.models.first, let id = model.modelID {
                            Button(edText("下载三维模型", "Download 3D model")) { controller.downloadModel(id) }
                        }
                        if controller.diagnostic != nil {
                            Button(edText("诊断详情", "Diagnostics")) { showingDiagnostics = true }
                        }
                    } label: { Image(systemName: "ellipsis.circle") }
                }
            }
            .sheet(isPresented: $showingDiagnostics) {
                NavigationStack {
                    ScrollView { Text(controller.diagnostic ?? "").font(.caption.monospaced()).textSelection(.enabled).padding() }
                        .navigationTitle(edText("诊断", "Diagnostics"))
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button(edText("完成", "Done")) { showingDiagnostics = false } } }
                }
            }
            .task { controller.start() }
        }
        .accessibilityIdentifier("electronics.remote.sheet")
    }

    private var statusBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "shippingbox.and.arrow.backward")
                .foregroundStyle(.tint)
            if let status = controller.status {
                if status.installed {
                    Text(status.dataVersion ?? "")
                        .font(.caption.monospaced())
                    Text("·").foregroundStyle(.secondary)
                    Text(String(status.sourceCount) + edText(" 个来源", " sources") + " · " + String(status.modelCount) + edText(" 个三维记录", " 3D records"))
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(edText("尚未安装官方目录。", "Official catalogue is not installed.")).font(.callout)
                }
            } else {
                Text(edText("读取目录状态…", "Reading catalogue status…")).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if controller.status?.installed == false {
                Button(edText("刷新目录", "Refresh catalogue")) { controller.refresh() }.buttonStyle(.borderedProminent).disabled(controller.busy)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(.bar)
    }

    private func messageBar(_ message: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
            Text(message).font(.caption).fixedSize(horizontal: false, vertical: true)
            Spacer()
            if controller.canRetry {
                Button(edText("重试", "Retry")) { controller.retry() }.font(.caption).disabled(controller.busy)
            }
            Button { controller.clearMessage() } label: { Image(systemName: "xmark") }
                .accessibilityLabel(edText("关闭提示", "Dismiss message"))
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(.orange.opacity(0.12))
    }

    private var progressBar: some View {
        HStack(spacing: 10) {
            if let expected = controller.progressExpected, expected > 0 {
                ProgressView(value: Double(controller.progressReceived), total: Double(expected)).frame(maxWidth: 280)
                Text(edText("下载 ", "Downloading ") + byteText(controller.progressReceived))
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ProgressView().controlSize(.small)
                Text(controller.phase == .installing ? edText("正在安装并校验…", "Installing and verifying…")
                     : controller.phase == .downloading ? edText("正在下载并校验三维模型…", "Downloading and verifying 3D model…")
                     : edText("正在处理…", "Working…")).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if controller.canCancel { Button(edText("取消", "Cancel")) { controller.cancel() }.font(.caption) }
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(.quaternary)
    }

    private var searchBar: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Menu {
                    ForEach(controller.librarySelection, id: \.id) { library in
                        Button {
                            controller.selectedLibraryID = library.id
                            controller.searchParts()
                        } label: {
                            Text(library.id + " · " + String(library.recordCount))
                        }
                    }
                } label: {
                    Label(controller.selectedLibraryID ?? edText("选择数据源", "Choose source"), systemImage: "books.vertical")
                        .lineLimit(1)
                }
                .disabled(controller.busy || controller.libraries.isEmpty)
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField(edText("型号、封装或记录名", "Part, footprint or record"), text: $controller.query)
                        .textFieldStyle(.plain).autocorrectionDisabled().onSubmit { controller.searchParts() }
                    if !controller.query.isEmpty {
                        Button { controller.query = ""; controller.searchParts() } label: { Image(systemName: "xmark.circle.fill") }
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(9).background(.quaternary, in: RoundedRectangle(cornerRadius: 9))
                Button(edText("搜索", "Search")) { controller.searchParts() }
                    .buttonStyle(.bordered).disabled(controller.busy || controller.selectedLibraryID == nil)
            }
            if let library = controller.selectedLibrary {
                HStack(spacing: 8) {
                    if let license = library.licenseID { badge(license, color: .secondary) }
                    Text(String(library.recordCount) + edText(" 条二维记录", " 2D records"))
                    if let converted = library.statuses["converted"] { Text("· " + String(converted) + edText(" 可直接转换", " converted")) }
                    if let review = library.statuses["reviewRequired"], review > 0 { Text("· " + String(review) + edText(" 待复核", " review")) .foregroundStyle(.orange) }
                    Spacer()
                }.font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(16)
    }

    private var partList: some View {
        Group {
            if controller.status?.installed != true {
                ContentUnavailableView {
                    Label(edText("官方目录未安装", "Catalogue not installed"), systemImage: "icloud.slash")
                } description: {
                    Text(edText("联网刷新目录后才能搜索和安装元件。已有设计不受影响。", "Refresh the catalogue to search and install parts. Existing designs are unaffected."))
                }
            } else if controller.phase == .loading && controller.parts.isEmpty {
                ProgressView(edText("正在读取记录…", "Reading records…")).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if controller.parts.isEmpty {
                ContentUnavailableView {
                    Label(edText("没有匹配记录", "No matching records"), systemImage: "magnifyingglass")
                } description: {
                    Text(edText("尝试更短的型号或封装名。只有已转换记录可直接安装。", "Try a shorter part or footprint name. Only converted records can install directly."))
                }
            } else {
                List {
                    Section {
                        ForEach(controller.parts) { part in
                            partRow(part)
                        }
                        if controller.nextPartOffset != nil {
                            Button(edText("载入更多", "Load more")) { controller.loadMoreParts() }
                                .disabled(controller.busy)
                        }
                    } header: {
                        Text(String(controller.partTotal) + edText(" 条结果", " results"))
                    }
                    if let install = controller.lastInstall { installedSection(install) }
                }
                .listStyle(.plain)
            }
        }
    }

    private func partRow(_ part: ElectronicsRemotePartSummary) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: part.kind == "symbol" ? "point.3.connected.trianglepath.dotted" : "square.grid.3x3")
                .foregroundStyle(part.status == "converted" ? Color.accentColor : Color.secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(part.name).font(.body.weight(.medium)).lineLimit(1)
                Text(part.sourcePath).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            statusBadge(part.status)
            Button {
                controller.install(part)
            } label: {
                Label(edText("安装", "Install"), systemImage: "arrow.down.circle")
            }
            .buttonStyle(.bordered)
            .disabled(controller.busy || part.status != "converted")
            .accessibilityLabel(edText("安装 ", "Install ") + part.name)
        }
        .padding(.vertical, 3)
    }

    private func installedSection(_ install: ElectronicsRemoteInstallResult) -> some View {
        Section(edText("已安装", "Installed")) {
            VStack(alignment: .leading, spacing: 6) {
                Label(install.partName, systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                Text(install.reference.packageID + " · " + install.reference.version)
                    .font(.caption2.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                Text(edText("原生引用已读回。请从现有元件选择器放置。", "Native reference read back. Place it from the existing part chooser."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(Array(install.models.enumerated()), id: \.offset) { _, model in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.fileName).font(.caption)
                        Text(model.format.uppercased() + (model.gitBlobSHA1.map { " · " + String($0.prefix(12)) } ?? ""))
                            .font(.caption2.monospaced()).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if model.format.lowercased() == "step" || model.format.lowercased() == "stp"
                        || model.format.lowercased() == "iges" || model.format.lowercased() == "igs" {
                        Button(edText("下载三维", "Download 3D")) {
                            if let id = model.modelID { controller.downloadModel(id) }
                        }.buttonStyle(.bordered).disabled(controller.busy || model.modelID == nil)
                    } else {
                        Text(edText("暂不渲染", "No preview")).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func statusBadge(_ status: String) -> some View {
        switch status {
        case "converted": badge(edText("已转换", "Converted"), color: .green)
        case "reviewRequired": badge(edText("待复核", "Review"), color: .orange)
        default: badge(edText("不支持", "Unsupported"), color: .secondary)
        }
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text).font(.caption2.weight(.semibold))
            .padding(.horizontal, 7).padding(.vertical, 3)
            .foregroundStyle(color).background(color.opacity(0.12), in: Capsule())
    }

    private func byteText(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(0, value), countStyle: .file)
    }
}
