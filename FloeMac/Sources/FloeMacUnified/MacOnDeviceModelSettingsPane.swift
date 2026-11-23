// SPDX-License-Identifier: MPL-2.0

import FloeLocalModelCatalog
import SwiftUI

@available(macOS 15.4, *)
struct MacOnDeviceModelSettingsPane: View {
    @ObservedObject var model: MacLocalModelsSettingsModel
    let selectedModelID: UUID?
    let useAsDefault: (UUID) -> Bool
    @State private var removeTarget: MacLocalModelsSettingsModel.EntryItem?
    @State private var benchmark: Benchmark?

    private struct Benchmark {
        let name: String
        let tokensPerSecond: Double
    }

    var body: some View {
        Form {
            if let reason = model.runtimeSupport.unavailableReason {
                Section { Text(reason).foregroundStyle(.secondary) }
            }
            if model.isDownloading {
                Section {
                    if let progress = model.progress {
                        ProgressView(value: progress.fractionCompleted)
                        HStack {
                            Button("mac.localModels.pause") {
                                Task { await model.pauseDownload(id: progress.modelID) }
                            }
                            Button("mac.localModels.cancelDownload", role: .destructive) {
                                Task { await model.cancelDownload(id: progress.modelID) }
                            }
                        }
                    } else {
                        ProgressView("mac.localModels.preparing")
                    }
                }
            }
            Section("mac.settings.localModels") {
                ForEach(model.items) { item in row(item) }
            }
            if let error = model.activeError {
                Section { Text(error).foregroundStyle(.secondary).textSelection(.enabled) }
            }
            if let benchmark {
                Section("mac.localModels.benchmark") {
                    LabeledContent(benchmark.name) {
                        Text(String(format: String(localized: "mac.localModels.benchmarkRate"), benchmark.tokensPerSecond))
                    }
                }
            }
        }
        .task { await model.refresh() }
        .formStyle(.grouped)
        .confirmationDialog("mac.localModels.confirmRemoval", isPresented: Binding(
            get: { removeTarget != nil }, set: { if !$0 { removeTarget = nil } }
        ), titleVisibility: .visible, presenting: removeTarget) { target in
            Button("mac.localModels.remove", role: .destructive) {
                Task { await model.remove(id: target.id) }
            }
        } message: { target in
            Text(target.catalogEntry.displayName)
        }
    }

    private func row(_ item: MacLocalModelsSettingsModel.EntryItem) -> some View {
        let entry = item.catalogEntry
        let installed = item.state == .installed
        let selectable = CuratedLocalModelCatalog.entries.contains { $0.id == item.id }
        return HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.displayName).font(.headline)
                Text(ByteCountFormatter.string(fromByteCount: item.installedBytes ?? entry.approximateDownloadBytes, countStyle: .file))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if installed {
                if selectedModelID == entry.profileID {
                    Label("mac.localModels.default", systemImage: "checkmark").foregroundStyle(.secondary)
                }
                Menu("mac.localModels.actions") {
                    if selectable {
                        Button("mac.localModels.makeDefault") { _ = useAsDefault(entry.profileID) }
                        Button("mac.localModels.load") { Task { await model.load(id: entry.id) } }
                        Button("mac.localModels.unload") { Task { await model.unload(id: entry.id) } }
                        Button("mac.localModels.benchmark") {
                            Task {
                                benchmark = nil
                                if let rate = await model.benchmark(id: entry.id)?.tokensPerSecond {
                                    benchmark = .init(name: entry.displayName, tokensPerSecond: rate)
                                }
                            }
                        }
                    }
                    Button("mac.localModels.remove", role: .destructive) { removeTarget = item }
                }
                .disabled(model.isBusy)
            } else {
                Button(item.state == .resumable ? String(localized: "mac.localModels.resume") : String(localized: "mac.localModels.download")) {
                    model.download(entry)
                }
                .disabled(!selectable || model.isBusy || !model.runtimeSupport.isSupported)
            }
        }
        .padding(.vertical, 4)
    }
}
