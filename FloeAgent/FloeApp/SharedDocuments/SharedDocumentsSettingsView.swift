// SPDX-License-Identifier: MPL-2.0
#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI

struct SharedDocumentsSettingsView: View {
    @ObservedObject var center: SharedDocumentsCenter
    @State private var isRefreshing = false

    var body: some View {
        Form {
            Section {
                Label(SharedDocumentsCopy.cardSubtitle, systemImage: "folder")
                switch center.domainState {
                case .unknown:
                    ProgressView()
                case .registered:
                    Text(SharedDocumentsCopy.registeredSubtitle)
                        .foregroundStyle(.secondary)
                case .failed:
                    Text(SharedDocumentsCopy.registrationFailedMessage)
                        .foregroundStyle(.secondary)
                }
                Button(SharedDocumentsCopy.refreshAction) {
                    refresh()
                }
                .disabled(isRefreshing)
            }
        }
        .navigationTitle(SharedDocumentsCopy.locationName)
        .task { await center.registerDomainIfNeeded() }
    }

    private func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        Task {
            await center.registerDomainIfNeeded()
            isRefreshing = false
        }
    }
}
#endif
