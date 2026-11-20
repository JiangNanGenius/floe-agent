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
    static var title: String { FloeL10n.l("app.core_aimodel_inspection.core_ai_model_functions") }

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
                    Label(FloeL10n.l("app.core_aimodel_inspection.choose_model"), systemImage: "doc.badge.gearshape")
                }
                .disabled(worker != nil)
                .accessibilityIdentifier("diagnostics.coreai.choose")
            } footer: {
                Text(FloeL10n.l("app.core_aimodel_inspection.choose_a_aimodel_or_aimodelc"))
            }
            switch phase {
            case .idle:
                EmptyView()
            case .reading(let file, let cancelling):
                Section {
                    HStack {
                        ProgressView()
                        Text(cancelling ? FloeL10n.l("app.core_aimodel_inspection.cancelling") : FloeL10n.l("app.core_aimodel_inspection.reading_model"))
                    }
                    Button(FloeL10n.l("cad.scene.cancel")) {
                        worker?.cancel()
                        phase = .reading(file, cancelling: true)
                    }
                    .disabled(cancelling)
                } header: { Text(verbatim: file) }
            case .functions(let file, let names):
                Section {
                    if names.isEmpty {
                        Text(FloeL10n.l("app.core_aimodel_inspection.the_model_lists_no_functions"))
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
                        DisclosureGroup(FloeL10n.l("app.core_aimodel_inspection.error_details")) {
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
                    phase = .failed(FloeL10n.l("app.core_aimodel_inspection.the_selected_file_could_not"), detail: error.localizedDescription)
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
                    phase = .failed(FloeL10n.l("app.core_aimodel_inspection.choose_a_aimodel_or_aimodelc_2"), detail: nil)
                case CoreAIModelInspection.InspectionError.notDownloaded:
                    phase = .failed(FloeL10n.l("app.core_aimodel_inspection.download_the_model_in_files"), detail: nil)
                default:
                    phase = .failed(FloeL10n.l("app.core_aimodel_inspection.check_the_model_file_and"), detail: error.localizedDescription)
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
