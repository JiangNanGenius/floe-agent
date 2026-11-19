// SPDX-License-Identifier: MPL-2.0

import AppKit
import FloeCore
import FloeProviders
import SwiftUI
import UniformTypeIdentifiers

struct MacImageWorkbenchView: View {
    @ObservedObject var images: MacImageGeneration
    let openSettings: () -> Void
    var attachToTask: ((URL) -> Bool)?
    @State private var prompt = ""
    @State private var selectedID: UUID?
    @State private var preview: NSImage?
    @State private var exportFailed = false
    @State private var attachmentFailed = false

    private var selection: MacImageGeneration.ResultItem? {
        images.history.first(where: { $0.id == selectedID }) ?? images.history.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("mac.images.prompt", text: $prompt, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...5)
                .disabled(images.isGenerating)
            HStack {
                Button(action: openSettings) {
                    Label(images.configuration?.modelID ?? String(localized: "mac.images.configure"), systemImage: "slider.horizontal.3")
                }
                Spacer()
                if images.isGenerating {
                    ProgressView().controlSize(.small)
                    Button("host.chat.stop") { images.cancel() }
                } else {
                    Button("mac.images.generate") { images.generate(prompt: prompt) }
                        .buttonStyle(.borderedProminent)
                        .disabled(images.configuration == nil || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            if let notice = images.notice {
                ErrorEventView(message: notice)
            }
            Divider()
            if images.history.isEmpty {
                ContentUnavailableView("mac.images.empty", systemImage: "photo.on.rectangle")
            } else {
                HSplitView {
                    List(selection: $selectedID) {
                        ForEach(images.history) { item in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.prompt).lineLimit(2)
                                Text(item.createdAt, format: .dateTime.month().day().hour().minute())
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            .tag(item.id)
                        }
                    }
                    .frame(minWidth: 160, idealWidth: 218)
                    VStack(alignment: .leading, spacing: 8) {
                        if let preview {
                            Image(nsImage: preview).resizable().scaledToFit()
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .accessibilityLabel(Text(selection?.prompt ?? ""))
                        } else {
                            ContentUnavailableView("mac.images.unavailable", systemImage: "photo")
                        }
                        if let item = selection {
                            HStack {
                                Button("mac.images.reusePrompt") { prompt = item.prompt }.disabled(images.isGenerating)
                                Spacer()
                                if let attachToTask {
                                    Button("mac.images.attachToTask") {
                                        attachmentFailed = !attachToTask(images.imageURL(for: item))
                                    }
                                    .disabled(preview == nil)
                                }
                                Button("mac.images.saveAs") { export(item) }.disabled(preview == nil)
                            }
                        }
                    }
                    .padding(10)
                    .frame(minWidth: 220, maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .padding(18)
        .onChange(of: images.history.first?.id, initial: true) { _, id in selectedID = id }
        .onChange(of: selection?.id, initial: true) { _, _ in
            preview = selection.flatMap { images.imageData(for: $0).flatMap(NSImage.init(data:)) }
        }
        .alert("mac.images.exportFailed", isPresented: $exportFailed) {
            Button("OK", role: .cancel) {}
        }
        .alert("mac.workspace.attachFailed", isPresented: $attachmentFailed) {
            Button("OK", role: .cancel) {}
        }
    }

    private func export(_ item: MacImageGeneration.ResultItem) {
        let source = images.imageURL(for: item)
        let panel = NSSavePanel()
        if let type = UTType(filenameExtension: source.pathExtension) { panel.allowedContentTypes = [type] }
        panel.nameFieldStringValue = item.filename
        panel.begin { response in
            guard response == .OK, let target = panel.url else { return }
            guard let data = images.imageData(for: item) else { exportFailed = true; return }
            do { try data.write(to: target, options: .atomic) }
            catch { exportFailed = true }
        }
    }
}

struct MacImageSettingsView: View {
    @ObservedObject var images: MacImageGeneration
    @State private var presetID: ProviderTemplateID = .openAI
    @State private var endpoint = ""
    @State private var modelID = ""
    @State private var key = ""
    @State private var status: String?

    private let presets = ProviderPreset.imagePresets

    private var canUseSavedKey: Bool {
        guard let configuration = images.configuration else { return false }
        return configuration.presetID == presetID && configuration.endpoint == endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
            && images.hasCredential
    }

    var body: some View {
        Form {
            Section {
                Picker("mac.images.provider", selection: Binding(
                    get: { presetID },
                    set: { id in
                        guard id != presetID else { return }
                        presetID = id
                        endpoint = presets.first(where: { $0.id == id })?.defaultBaseURL.absoluteString ?? ""
                        modelID = ""
                        key = ""
                        status = nil
                    }
                )) {
                    ForEach(presets) { preset in Text(preset.displayName).tag(preset.id) }
                }
                TextField("host.chat.endpoint", text: Binding(
                    get: { endpoint }, set: { if endpoint != $0 { endpoint = $0; key = ""; status = nil } }
                )).textContentType(.URL)
                TextField("host.chat.modelID", text: $modelID)
                SecureField(canUseSavedKey ? "mac.images.replaceKey" : "host.chat.key", text: $key)
            }
            Section {
                Button("host.chat.save") { save() }
                    .disabled(modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              || endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              || (!canUseSavedKey && key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                              || images.isGenerating)
                if let status { Text(status).foregroundStyle(.secondary).textSelection(.enabled) }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            if let configuration = images.configuration {
                presetID = configuration.presetID
                endpoint = configuration.endpoint
                modelID = configuration.modelID
            } else {
                endpoint = presets.first(where: { $0.id == presetID })?.defaultBaseURL.absoluteString ?? ""
            }
        }
    }

    private func save() {
        do {
            try images.save(.init(presetID: presetID, endpoint: endpoint, modelID: modelID),
                            apiKey: key.isEmpty ? nil : key)
            key = ""
            status = String(localized: "mac.images.settingsSaved")
        } catch {
            status = error.localizedDescription
        }
    }
}
