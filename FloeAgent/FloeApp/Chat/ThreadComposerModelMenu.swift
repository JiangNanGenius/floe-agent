// SPDX-License-Identifier: MPL-2.0

import FloeCore
import Foundation
import SwiftUI

/// The model menu used by the thread composer on iPad and Mac. The host
/// supplies eligible models and performs any preparation needed to select one.
struct ThreadComposerModelMenu<Trigger: View, ExtraActions: View>: View {
    let models: [ModelProfile]
    let providers: [ProviderProfile]
    var appleSystemModelID: String? = nil
    let selectedModelID: UUID?
    let onSelect: (ModelProfile) -> Void
    @ViewBuilder let trigger: () -> Trigger
    @ViewBuilder let extraActions: () -> ExtraActions

    var body: some View {
        Menu {
            ForEach(groups) { group in
                Section {
                    ForEach(group.models) { model in
                        Button { onSelect(model) } label: {
                            if selectedModelID == model.id {
                                Label { Text(verbatim: model.displayName) } icon: { Image(systemName: "checkmark") }
                            } else {
                                Text(verbatim: model.displayName)
                            }
                        }
                        .accessibilityIdentifier("composer.model.option.\(model.id.uuidString)")
                    }
                } header: {
                    sectionHeader(group)
                }
            }
            extraActions()
        } label: {
            trigger()
        }
    }

    private struct Group: Identifiable {
        let id: String
        let title: LocalizedStringKey
        var cloudProvider: String? = nil
        var beta = false
        let models: [ModelProfile]
    }

    private var groups: [Group] {
        let device = models.filter { $0.providerID == ProviderProfile.onDeviceProviderID }
        let local = device.filter { $0.remoteModelID != appleSystemModelID }
        let apple = device.filter { $0.remoteModelID == appleSystemModelID }
        var result: [Group] = []
        if !local.isEmpty {
            result.append(.init(id: "local-mlx", title: "composer.model.group.on_device", beta: true, models: sorted(local)))
        }
        if !apple.isEmpty {
            result.append(.init(id: "local-apple", title: "composer.model.group.apple", models: sorted(apple)))
        }
        let cloud = Dictionary(grouping: models.filter { $0.providerID != ProviderProfile.onDeviceProviderID }, by: \.providerID)
        let cloudGroups = cloud.map { id, models in
            Group(id: id.uuidString, title: "composer.model.group.cloud_prefix",
                cloudProvider: providerName(id), models: sorted(models))
        }.sorted { lhs, rhs in
            let order = (lhs.cloudProvider ?? "").localizedCaseInsensitiveCompare(rhs.cloudProvider ?? "")
            return order == .orderedSame ? lhs.id < rhs.id : order == .orderedAscending
        }
        return result + cloudGroups
    }

    private func sectionHeader(_ group: Group) -> some View {
        HStack(spacing: 6) {
            if let name = group.cloudProvider {
                Text(verbatim: "\(String(localized: "composer.model.group.cloud_prefix")) · \(name)")
            } else {
                Text(group.title)
            }
            if group.beta {
                Text("localmodels.beta_badge")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(FloeTheme.pending)
            }
        }
    }

    private func providerName(_ id: UUID) -> String {
        guard let provider = providers.first(where: { $0.id == id }) else {
            return String(localized: "composer.model.group.unknown_provider")
        }
        let custom = provider.displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        return custom.flatMap { $0.isEmpty ? nil : $0 } ?? provider.kind.rawValue
    }

    private func sorted(_ models: [ModelProfile]) -> [ModelProfile] {
        models.sorted { lhs, rhs in
            let order = lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName)
            return order == .orderedSame ? lhs.id.uuidString < rhs.id.uuidString : order == .orderedAscending
        }
    }
}
