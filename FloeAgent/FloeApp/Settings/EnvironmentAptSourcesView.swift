#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import FloeCore
import FloeExecution

struct EnvironmentAptSourcesView: View {
    let environmentID: String
    @State private var state: LinuxGuestAptSourceState?
    @State private var loadedEnvironmentID: String?
    @State private var draft = "system"
    @State private var working = false
    @State private var error: String?
    @State private var operation: Operation?

    private struct Operation: Hashable {
        let id = UUID()
        let environmentID: String
        let selection: String?
    }
    private struct Owner: Hashable {
        let environmentID: String
        let operation: Operation?
    }

    private var catalog: LinuxPackageSourceCatalog? { try? LinuxPackageSourceCatalog.bundled() }
    private var currentState: LinuxGuestAptSourceState? { loadedEnvironmentID == environmentID ? state : nil }
    private var title: String { OfficeInkText.t("Debian 软件源", "Debian source") }

    var body: some View {
        Form {
            Section {
                Picker(title, selection: $draft) {
                    Text(OfficeInkText.t("系统现有", "System configuration")).tag("system")
                    if let catalog {
                        ForEach(catalog.apt) { preset in Text(preset.displayName).tag(preset.id) }
                    }
                }.disabled(working)
                Button(OfficeInkText.t("应用", "Apply")) {
                    operation = Operation(environmentID: environmentID, selection: draft)
                }.disabled(working || currentState == nil || draft == currentState?.selection)
            } footer: {
                Text(OfficeInkText.t("仅切换此环境的软件源。原配置保留，选择“系统现有”即可恢复。", "Changes only this environment. Your original configuration is preserved; choose System configuration to restore it."))
            }
            if let state = currentState {
                Section(OfficeInkText.t("当前生效", "Active source")) {
                    Text(state.selection == "system"
                         ? OfficeInkText.t("系统现有", "System configuration")
                         : catalog?.apt.first(where: { $0.id == state.selection })?.displayName ?? title)
                    if let uri = state.uri { Text(uri).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                    Text(OfficeInkText.t("切换后请返回刷新软件索引，再安装软件。", "After switching, refresh the package index before installing software."))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if working {
                ProgressView(operation?.environmentID == environmentID && operation?.selection != nil
                    ? OfficeInkText.t("正在保存软件源…", "Saving package sources…")
                    : OfficeInkText.t("正在读取软件源…", "Reading package sources…"))
            }
            if let error {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(FloeTheme.destructive)
                    Button("action.reload") { operation = Operation(environmentID: environmentID, selection: nil) }
                        .disabled(working)
                    Button(OfficeInkText.t("使用系统现有配置", "Use system configuration")) {
                        operation = Operation(environmentID: environmentID, selection: "system")
                    }.disabled(working)
                }
            }
        }
        .navigationTitle(title)
        // Both reads and writes belong to this exact destination/environment.
        // Pop/replacement cancels the existing runner and cannot write UI
        // state or replay a previous environment's pending selection.
        .task(id: Owner(environmentID: environmentID, operation: operation)) {
            let request = operation?.environmentID == environmentID ? operation : nil
            let owner = Owner(environmentID: environmentID, operation: operation)
            working = true
            error = nil
            do {
                let service = try await FloePlatformServices.shared.languagePackageService()
                let result = try await service.aptSource(environmentID: owner.environmentID, selection: request?.selection)
                guard !Task.isCancelled, operation == owner.operation else { return }
                state = result
                loadedEnvironmentID = owner.environmentID
                draft = result.selection
                working = false
            } catch {
                guard !Task.isCancelled, operation == owner.operation else { return }
                self.error = error.localizedDescription
                // A verification failure can mean a manual config changed;
                // require a fresh actual read rather than showing old state.
                state = nil
                loadedEnvironmentID = nil
                working = false
            }
        }
    }
}
#endif
