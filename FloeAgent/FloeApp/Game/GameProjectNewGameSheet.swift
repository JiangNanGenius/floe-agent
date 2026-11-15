// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import FloeCore

/// Normal new-game entry: only the project name is required. It creates a real
/// owned empty project and never guesses an engine, records a default engine or
/// seeds a starter. Engine/root choice, starter preparation and import happen
/// in the project screen after the empty project exists.
struct GameProjectNewGameSheet: View {
    let onCancel: () -> Void
    let onCreated: (PersonalContentRecord) -> Void
    @State private var title = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section(IDELanguageRunText.t("名称", "Name")) {
                    TextField(IDELanguageRunText.t("游戏名称", "Game name"), text: $title)
                        .textInputAutocapitalization(.never)
                        .accessibilityIdentifier("game.new.title")
                }
                if let error {
                    Section { Text(error).foregroundStyle(.red) }
                }
                Section {
                    Text(IDELanguageRunText.t(
                        "先创建空的游戏工程。进入工程后再选择或确认真实引擎和游戏目录，创建起始模板或导入已有工程。",
                        "An empty game project is created first. Choose or confirm the real engine and game folder inside the project, then create a starter or import an existing project."))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle(IDELanguageRunText.t("新建游戏", "New game"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(IDELanguageRunText.t("取消", "Cancel"), action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(IDELanguageRunText.t("创建", "Create")) {
                        Task { await create() }
                    }.disabled(busy
                        || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .overlay { if busy { ProgressView(IDELanguageRunText.t("正在创建", "Creating")) } }
        }
    }

    private func create() async {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else {
            error = IDELanguageRunText.t("请输入名称。", "Enter a name.")
            return
        }
        busy = true
        defer { busy = false }
        do {
            // No engine hint: the empty project must not silently bind the
            // first catalog engine. Selection happens after the real tree
            // exists (starter, import or the user's manual choice).
            let record = try await PersonalContentService.shared.createGame(title: clean)
            onCreated(record)
        } catch {
            self.error = error.localizedDescription
        }
    }
}
#endif
