#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import FloeLocalModels

@MainActor
final class LocalModelsCenter: ObservableObject {
    @Published private(set) var installedIDs: Set<String> = []
    @Published private(set) var activeDownloads: Set<String> = []
    @Published var errorMessage: String?
    let store: LocalModelStore
    var onCatalogChanged: (@Sendable () async -> Void)?

    init(store: LocalModelStore) {
        self.store = store
        Task { await refresh() }
    }

    func refresh() async {
        var installed = Set<String>()
        for entry in CuratedLocalModelCatalog.entries where await store.isInstalled(id: entry.id) {
            installed.insert(entry.id)
        }
        installedIDs = installed
    }

    func download(_ entry: LocalModelCatalogEntry) {
        guard !activeDownloads.contains(entry.id) else { return }
        activeDownloads.insert(entry.id)
        errorMessage = nil
        Task {
            do {
                _ = try await store.download(entry)
                await refresh()
                await onCatalogChanged?()
            }
            catch { errorMessage = error.localizedDescription }
            activeDownloads.remove(entry.id)
        }
    }

    func remove(_ entry: LocalModelCatalogEntry) {
        Task {
            do {
                try await store.remove(id: entry.id)
                await refresh()
                await onCatalogChanged?()
            }
            catch { errorMessage = error.localizedDescription }
        }
    }
}

struct LocalModelsSettingsView: View {
    @ObservedObject var center: LocalModelsCenter

    var body: some View {
        List {
            Section {
                ForEach(CuratedLocalModelCatalog.entries) { entry in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.displayName).font(.headline)
                                Text("\(entry.parameterBillions, specifier: "%.1f")B · \(entry.license)")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if center.activeDownloads.contains(entry.id) {
                                ProgressView()
                            } else if center.installedIDs.contains(entry.id) {
                                Button("localmodels.remove", role: .destructive) { center.remove(entry) }
                            } else {
                                Button("localmodels.download") { center.download(entry) }
                            }
                        }
                        HStack(spacing: 12) {
                            if entry.supportsVision { Label("localmodels.vision", systemImage: "eye") }
                            if entry.supportsReasoning { Label("localmodels.reasoning", systemImage: "brain") }
                            if entry.supportsToolCalling { Label("localmodels.tools", systemImage: "wrench.and.screwdriver") }
                        }.font(.caption).foregroundStyle(.secondary)
                    }.padding(.vertical, 4)
                }
            } footer: {
                Text("localmodels.footer")
            }
            if let errorMessage = center.errorMessage {
                Section { Text(errorMessage).foregroundStyle(.red) }
            }
        }
        .navigationTitle("localmodels.title")
        .task { await center.refresh() }
    }
}
#endif
