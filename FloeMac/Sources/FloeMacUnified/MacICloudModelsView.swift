// SPDX-License-Identifier: MPL-2.0

import CloudKit
import SwiftUI

struct MacICloudModelsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var workspace: HostAgentWorkspace
    let providerID: UUID?
    var modelID: UUID? = nil
    let onImport: (UUID) -> Void

    @State private var entries: [MacCloudModelEntry] = []
    @State private var busy = false
    @State private var finished = false
    @State private var confirmPublish = false
    @State private var message: LocalizedStringKey?
    @State private var accountGeneration = UUID()

    private var savedProvider: HostAgentProvider? {
        let models = workspace.providers.filter { $0.profile.id == providerID }
        if let modelID { return models.first { $0.model.id == modelID } }
        return models.count == 1 ? models.first : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("mac.icloud.models").font(.title2.weight(.semibold))
            Text("mac.icloud.scope").font(.callout).foregroundStyle(.secondary)
            if let message { Text(message).font(.callout).foregroundStyle(.secondary) }
            if entries.isEmpty && finished {
                Text("mac.icloud.empty").frame(maxWidth: .infinity, maxHeight: .infinity)
                    .foregroundStyle(.secondary)
            } else {
                List(entries) { entry in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(verbatim: entry.model.displayName)
                            Text(verbatim: entry.providerName).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("mac.icloud.addToMac") {
                            guard workspace.importCloudModel(entry) else {
                                message = "mac.icloud.importFailed"
                                return
                            }
                            onImport(entry.model.id)
                            dismiss()
                        }
                    }
                }
                .listStyle(.inset)
                .disabled(busy)
            }
            HStack {
                Button("mac.icloud.refresh") { synchronize() }.disabled(busy)
                if let savedProvider,
                   MacCloudModelEntry.accepts(savedProvider.profile, model: savedProvider.model) {
                    Button("mac.icloud.publish") { confirmPublish = true }.disabled(busy)
                }
                if busy { ProgressView().controlSize(.small) }
                Spacer()
                Button("mac.icloud.done") { dismiss() }.disabled(busy)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520, height: 390)
        .interactiveDismissDisabled(busy)
        .onAppear { if !busy && !finished { synchronize() } }
        .onReceive(NotificationCenter.default.publisher(for: .CKAccountChanged)) { _ in
            accountGeneration = UUID()
            entries = []
            finished = false
            message = "mac.icloud.accountChanged"
        }
        .confirmationDialog("mac.icloud.confirmPublish", isPresented: $confirmPublish, titleVisibility: .visible) {
            Button("mac.icloud.publish") {
                if let savedProvider { synchronize(publishing: savedProvider.model.id) }
            }
        } message: {
            if let savedProvider { Text(verbatim: savedProvider.displayTitle) }
        }
    }

    private func synchronize(publishing id: UUID? = nil) {
        guard !busy else { return }
        let generation = accountGeneration
        busy = true
        message = nil
        Task {
            defer { busy = false }
            do {
                let loaded = try await workspace.synchronizeCloudModels(publishingModelID: id)
                guard generation == accountGeneration else { return }
                entries = loaded
                finished = true
                if id != nil { message = "mac.icloud.published" }
            } catch {
                guard generation == accountGeneration else { return }
                switch error as? MacICloudModelError {
                case .setupRequired: message = "mac.icloud.setupRequired"
                case .signInRequired: message = "mac.icloud.signIn"
                case .accountChanged: message = "mac.icloud.accountChanged"
                case .invalidProvider: message = "mac.icloud.providerConflict"
                case .uploadPending: message = "mac.icloud.uploadPending"
                default: message = "mac.icloud.unavailable"
                }
            }
        }
    }
}
