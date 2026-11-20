// SPDX-License-Identifier: MPL-2.0
import FloeCore
import FloeProviders
import SwiftUI

/// Imports an existing account into the independent image or video configuration.
/// The destination is always the saved account's endpoint, never a form draft.
struct MacMediaAccountSettings<Content: View>: View {
    @ObservedObject var workspace: HostAgentWorkspace
    let role: ProviderCatalogServiceRole
    let apply: (ProviderTemplateID, String, String, String) throws -> Void
    @ViewBuilder let content: () -> Content
    @State private var editing = false
    @State private var accountID: UUID?
    @State private var modelID = ""
    @State private var revision = 0
    @State private var message: String?

    private var accounts: [HostProviderAccount] {
        workspace.accounts.filter { account in
            let profile = account.profile
            return profile.isEnabled && !account.apiKey.isEmpty &&
                ProviderServiceOfferResolver.adapterSupportedMediaRoles(for: profile.kind,
                    presetID: account.presetID, baseURL: profile.baseURL).contains(role)
        }
    }
    private var account: HostProviderAccount? { accounts.first { $0.id == accountID } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !accounts.isEmpty {
                Button("mac.creative.importAccount") {
                    select(accounts.first?.id)
                    editing = true
                }.buttonStyle(.link).padding(.horizontal, 20).padding(.top, 8)
            }
            content().id(revision)
        }
        #if FLOE_MAC_HOST_SMOKE
        .onAppear { workspace.smokeMediaSettingsRole = role.rawValue }
        .onChange(of: role) { _, value in workspace.smokeMediaSettingsRole = value.rawValue }
        .onDisappear { if workspace.smokeMediaSettingsRole == role.rawValue { workspace.smokeMediaSettingsRole = nil } }
        #endif
        .sheet(isPresented: $editing) {
            VStack(alignment: .leading, spacing: 12) {
                Text("mac.creative.importAccount").font(.headline)
                Picker("host.chat.provider", selection: Binding(get: { accountID }, set: select)) {
                    ForEach(accounts) { Text(verbatim: $0.name).tag(Optional($0.id)) }
                }
                if let account {
                    Text(verbatim: account.profile.baseURL.absoluteString).font(.caption).foregroundStyle(.secondary)
                    HStack {
                        TextField("host.chat.modelID", text: $modelID)
                        let options = suggestions(account)
                        if !options.isEmpty {
                            Menu { ForEach(options, id: \.self) { id in Button(id) { modelID = id } } }
                            label: { Image(systemName: "chevron.down") }.fixedSize()
                        }
                    }
                }
                if let message { Text(verbatim: message).foregroundStyle(.secondary) }
                HStack {
                    Spacer()
                    Button("mac.creative.cancel", role: .cancel) { editing = false }.keyboardShortcut(.cancelAction)
                    Button("mac.creative.save") { save() }.keyboardShortcut(.defaultAction)
                        .disabled(account == nil || modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }.padding(20).frame(width: 420)
        }
    }

    private func select(_ id: UUID?) {
        accountID = id
        modelID = accounts.first(where: { $0.id == id }).flatMap { suggestions($0).first } ?? ""
        message = nil
    }

    private func suggestions(_ account: HostProviderAccount) -> [String] {
        let selected = account.models.filter { model in
            model.isEnabled && (role == .image ? model.supportsImageGenerationSurface : model.supportsVideoGenerationSurface)
        }.map(\.remoteModelID)
        let registered = Set(account.models.map(\.remoteModelID))
        let catalog = ProviderServiceOfferResolver.officialModelIDs(for: account.profile.kind, role: role)
        return selected + catalog.filter { !registered.contains($0) }
    }

    private func save() {
        guard let account else { return }
        let preset = account.presetID.flatMap(ProviderTemplateID.init(rawValue:))
            ?? ProviderPreset.preset(for: account.profile.kind, baseURL: account.profile.baseURL).id
        do {
            try apply(preset, account.profile.baseURL.absoluteString, modelID, account.apiKey)
            editing = false
            revision += 1
        } catch { message = error.localizedDescription }
    }
}
