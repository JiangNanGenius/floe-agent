// SPDX-License-Identifier: MPL-2.0

#if canImport(CoreAI)
import CoreAI
import Foundation

@available(iOS 27.0, macOS 27.0, *)
enum CoreAIModelInspection {
    enum InspectionError: Error { case unsupportedFile, notDownloaded }

    @concurrent
    static func functionNames(in url: URL) async throws -> [String] {
        try Task.checkCancellation()
        guard url.isFileURL, ["aimodel", "aimodelc"].contains(url.pathExtension.lowercased()) else {
            throw InspectionError.unsupportedFile
        }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey,
                                                     .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
        if values.isUbiquitousItem == true, values.ubiquitousItemDownloadingStatus == .notDownloaded {
            throw InspectionError.notDownloaded
        }
        guard values.isDirectory == true || values.isRegularFile == true else {
            throw InspectionError.unsupportedFile
        }
        try Task.checkCancellation()
        let model = try await AIModel(contentsOf: url)
        try Task.checkCancellation()
        return model.functionNames.sorted()
    }
}

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import UniformTypeIdentifiers
import FloeCore

@available(iOS 27.0, *)
struct CoreAIModelInspectionView: View {
    static var title: String { copy("Core AI 模型函数", "Core AI Model Functions") }

    private enum Phase {
        case idle, reading(String, cancelling: Bool), functions(String, [String]), failed(String, detail: String?)
    }

    @State private var choosing = false
    @State private var phase: Phase = .idle
    @State private var worker: Task<Void, Never>?

    var body: some View {
        Form {
            Section {
                Button {
                    choosing = true
                } label: {
                    Label(Self.copy("选择模型", "Choose Model"), systemImage: "doc.badge.gearshape")
                }
                .disabled(worker != nil)
                .accessibilityIdentifier("diagnostics.coreai.choose")
            } footer: {
                Text(Self.copy("选择设备上的 .aimodel 或 .aimodelc 文件以查看函数列表。",
                               "Choose a .aimodel or .aimodelc file on this device to see its functions."))
            }
            switch phase {
            case .idle:
                EmptyView()
            case .reading(let file, let cancelling):
                Section {
                    HStack {
                        ProgressView()
                        Text(cancelling ? Self.copy("正在取消…", "Cancelling…") : Self.copy("正在读取模型…", "Reading model…"))
                    }
                    Button(Self.copy("取消", "Cancel")) {
                        worker?.cancel()
                        phase = .reading(file, cancelling: true)
                    }
                    .disabled(cancelling)
                } header: { Text(verbatim: file) }
            case .functions(let file, let names):
                Section {
                    if names.isEmpty {
                        Text(Self.copy("模型未列出函数。", "The model lists no functions."))
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(names, id: \.self) { name in
                            Text(verbatim: name).font(.body.monospaced()).textSelection(.enabled)
                        }
                    }
                } header: { Text(verbatim: file) }
            case .failed(let message, let detail):
                Section {
                    Text(message)
                    if let detail {
                        DisclosureGroup(Self.copy("错误详情", "Error Details")) {
                            Text(verbatim: detail).textSelection(.enabled)
                        }
                    }
                }
            }
        }
        .navigationTitle(Self.title)
        .fileImporter(isPresented: $choosing, allowedContentTypes: ["aimodel", "aimodelc"].compactMap { UTType(filenameExtension: $0) }) { result in
            switch result {
            case .success(let url): inspect(url)
            case .failure(let error):
                if (error as? CocoaError)?.code != .userCancelled {
                    phase = .failed(Self.copy("无法打开所选文件。", "The selected file could not be opened."), detail: error.localizedDescription)
                }
            }
        }
        .onDisappear { worker?.cancel() }
    }

    private func inspect(_ url: URL) {
        guard worker == nil else { return }
        let name = url.lastPathComponent
        phase = .reading(name, cancelling: false)
        worker = Task(priority: .utility) {
            defer { worker = nil }
            do {
                let names = try await CoreAIModelInspection.functionNames(in: url)
                try Task.checkCancellation()
                phase = .functions(name, names)
            } catch {
                if Task.isCancelled || error is CancellationError || (error as? CocoaError)?.code == .userCancelled {
                    phase = .idle
                    return
                }
                switch error {
                case CoreAIModelInspection.InspectionError.unsupportedFile:
                    phase = .failed(Self.copy("请选择 .aimodel 或 .aimodelc 文件。", "Choose a .aimodel or .aimodelc file."), detail: nil)
                case CoreAIModelInspection.InspectionError.notDownloaded:
                    phase = .failed(Self.copy("请先在“文件”中下载模型，再重新选择。", "Download the model in Files, then choose it again."), detail: nil)
                default:
                    phase = .failed(Self.copy("无法读取此模型。请检查文件及其设备兼容性。", "Check the model file and its compatibility with this device."), detail: error.localizedDescription)
                }
            }
        }
    }

    private static func copy(_ chinese: String, _ english: String) -> String {
        FloeL10n.isChinese ? chinese : english
    }
}
#endif
#endif
