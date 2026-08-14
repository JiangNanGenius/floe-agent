#if DEBUG && canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import UniformTypeIdentifiers
import FloeSSH
import FloeVNC

struct SettingsView: View {
    @ObservedObject var diagnostics: M0DiagnosticsModel

    var body: some View {
        List {
            NavigationLink("M0 Technical Validation") {
                M0DiagnosticsView(model: diagnostics)
            }
        }
        .navigationTitle("Settings")
    }
}

struct M0DiagnosticsView: View {
    @ObservedObject var model: M0DiagnosticsModel
    @State private var importsDocument = false

    var body: some View {
        Form {
            Section("CloudKit + iCloud Keychain") {
                LabeledContent("Bootstrap", value: model.bootstrapStatus)
                LabeledContent("Sync", value: model.syncStatus)
                LabeledContent("Providers", value: String(model.providerCount))
                LabeledContent("API key", value: model.secretStatus)
                SecureField("M0 API key", text: $model.apiKey)
                Button("Save and sync test provider") { Task { await model.saveTestProvider() } }
                Button("Fetch and send changes") { Task { await model.refreshSync() } }
                Button("Delete test provider", role: .destructive) { Task { await model.deleteTestProvider() } }
            }

            Section("SSH + jump host") {
                TextField("Target address (Docker: target)", text: $model.targetAddress)
                    .textInputAutocapitalization(.never)
                TextField("Target port", text: $model.targetPort).keyboardType(.numberPad)
                TextField("Target user", text: $model.targetUser).textInputAutocapitalization(.never)
                SecureField("Target password", text: $model.targetPassword)
                TextField("Jump address or Mac LAN IP", text: $model.jumpAddress)
                    .textInputAutocapitalization(.never)
                TextField("Jump port", text: $model.jumpPort).keyboardType(.numberPad)
                TextField("Jump user", text: $model.jumpUser).textInputAutocapitalization(.never)
                SecureField("Jump password", text: $model.jumpPassword)
                Button("Connect SSH PTY") { Task { await model.connectSSH() } }
                LabeledContent("Remote", value: model.remoteStatus)
                TextField("Terminal input", text: $model.terminalInput)
                    .textInputAutocapitalization(.never)
                Button("Send") { Task { await model.sendTerminalInput() } }
                ScrollView(.horizontal) {
                    Text(model.terminalOutput.isEmpty ? "No terminal output" : model.terminalOutput)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
                .frame(minHeight: 100)
            }

            Section("VNC over SSH") {
                TextField("VNC host from target", text: $model.vncHost)
                    .textInputAutocapitalization(.never)
                TextField("VNC port", text: $model.vncPort).keyboardType(.numberPad)
                SecureField("VNC password", text: $model.vncPassword)
                Button("Connect VNC through SSH") { Task { await model.connectVNC() } }
                if let session = model.vncSession {
                    NavigationLink("Open VNC viewer") {
                        VNCViewer(session: session)
                            .background(.black)
                            .navigationTitle("M0 VNC")
                            .navigationBarTitleDisplayMode(.inline)
                    }
                }
                Button("Disconnect remote sessions", role: .destructive) {
                    Task { await model.disconnectRemote() }
                }
            }

            Section("Document file lifecycle") {
                LabeledContent("Result", value: model.documentStatus)
                Button("Choose DOCX/XLSX/PPTX for safe round trip") { importsDocument = true }
            }
        }
        .navigationTitle("M0 Validation")
        .task { await model.bootstrap() }
        .sheet(item: $model.trustPrompt) { challenge in
            M0HostKeyTrustSheet(challenge: challenge, model: model)
        }
        .fileImporter(
            isPresented: $importsDocument,
            allowedContentTypes: [
                UTType(filenameExtension: "docx") ?? .data,
                UTType(filenameExtension: "xlsx") ?? .data,
                UTType(filenameExtension: "pptx") ?? .data
            ]
        ) { result in
            if case .success(let url) = result { Task { await model.probeDocument(url) } }
        }
    }
}

private struct M0HostKeyTrustSheet: View {
    let challenge: HostKeyChallenge
    @ObservedObject var model: M0DiagnosticsModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                LabeledContent("Host", value: "\(challenge.address):\(challenge.port)")
                LabeledContent("Key type", value: challenge.keyType)
                Text(challenge.fingerprintSHA256)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
            }
            .navigationTitle("Trust SSH Host?")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Reject", role: .cancel) {
                        model.resolveTrust(false)
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Trust") {
                        model.resolveTrust(true)
                        dismiss()
                    }
                }
            }
        }
    }
}
#endif
