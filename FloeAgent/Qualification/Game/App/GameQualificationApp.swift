// SPDX-License-Identifier: MPL-2.0
import SwiftUI
import UniformTypeIdentifiers
import FloeGameCore
import FloeGameWebKit
import FloeGameAuthoringUI
import FloeGameEditingUI
import FloeGameTouch
import FloeGameTouchUI

@main struct GameQualificationApp: App {
    @StateObject private var host = try! GameQualificationHost()
    var body: some Scene { WindowGroup { QualificationHome(host: host).environment(\.locale, Locale(identifier: "zh-Hans")) } }
}

private enum Detail: String, Identifiable { case files, history, editContract; var id: String { rawValue } }
private struct QualificationHome: View {
    @ObservedObject var host: GameQualificationHost
    @State private var importing = false
    @State private var detail: Detail?
    var body: some View {
        NavigationStack {
            Group {
                if let project = host.project {
                    GameProjectOverviewView(content: .init(title: project.title, engineSummary: engineName,
                        description: "游戏组件独立验证", previewPNG: host.preview, hasFiles: !project.files.isEmpty),
                        status: host.status) { action in
                        switch action {
                        case .importProject: importing = true
                        case .simpleEdit: host.openEditor()
                        case .play: host.start()
                        case .files: detail = .files
                        case .history: host.loadHistory(); detail = .history
                        case .aiModify: detail = .editContract
                        case .ide: host.status = "IDE 交接接口：工程根目录与版本已绑定。"; detail = .files
                        }
                    }.disabled(host.busy)
                } else {
                    ContentUnavailableView {
                        Label("游戏组件验证", systemImage: "gamecontroller")
                    } description: { Text("先新建项目，再导入、整理、编辑和试玩。") } actions: {
                        Button("新建游戏项目") { host.create() }.buttonStyle(.borderedProminent).accessibilityIdentifier("game.create")
                    }
                }
            }.navigationTitle(host.project?.title ?? "游戏组件")
                .safeAreaInset(edge: .bottom) {
                    if !host.verificationSummary.isEmpty { Text(host.verificationSummary).font(.caption).accessibilityIdentifier("game.verify.saved") }
                }
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) { Button("新建") { host.create() }.accessibilityIdentifier("game.new").disabled(host.busy) }
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu("导入", systemImage: "square.and.arrow.down") {
                            Button("选择文件或文件夹") { importing = true }
                            Button("导入 Phaser 示例") { host.importFixture("Phaser-Starter") }.accessibilityIdentifier("game.import.phaser")
                            Button("导入 RPG 数据示例") { host.importFixture("RPG-Data-Fixture") }.accessibilityIdentifier("game.import.rpg")
                        }.accessibilityIdentifier("game.import").disabled(host.project == nil || host.busy)
                    }
                }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item, .folder], allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first { host.importURL(url) }
        }
        .sheet(item: $detail) { value in
            NavigationStack {
                Group {
                    switch value {
                    case .files:
                        List(host.project?.files ?? [], id: \.path) { file in HStack { Text(file.path.value); Spacer(); Text(Int64(file.bytes), format: .byteCount(style: .file)).foregroundStyle(.secondary) } }
                            .navigationTitle("工程文件")
                    case .history:
                        List(host.history, id: \.revision) { item in VStack(alignment: .leading) { Text(item.title); Text(item.revision).font(.caption).foregroundStyle(.secondary); Text("\(item.files.count) 个文件") } }.navigationTitle("版本记录")
                    case .editContract:
                        Form {
                            Section("AI 编辑服务契约验证") { Text("本验证宿主使用确定性模型替身，不调用 AI 账户。将速度改为 240，校验、保存差异，并保持未知字段。") }
                            Button("执行编辑与校验") { host.modifyContractFixture() }.accessibilityIdentifier("game.edit.contract").disabled(host.busy)
                            Text(host.status)
                        }.navigationTitle("编辑闭环验证")
                    }
                }.toolbar { ToolbarItem(placement: .cancellationAction) { Button("完成") { detail = nil } } }
            }
        }
        .fullScreenCover(item: $host.editor, onDismiss: { host.edited() }) { presentation in
            GameEditingSessionView(session: presentation.session, onClose: { host.editor = nil }).environment(\.gameEditLocale, .chinese)
        }
        .fullScreenCover(item: $host.play) { presentation in
            QualificationPlayer(host: host, play: presentation)
        }
    }
    private var engineName: String {
        switch host.engine {
        case .phaser: "Phaser · 2D"
        case .rpgMakerMZ: "RPG Maker MZ · 数据示例"
        case .some(let engine): engine.rawValue
        case .none: "待识别的工程"
        }
    }
}

private struct QualificationPlayer: View {
    @ObservedObject var host: GameQualificationHost
    let play: GameQualificationHost.Play
    @State private var settings = false
    @State private var arranging = false
    @State private var profile: GameTouchProfile
    init(host: GameQualificationHost, play: GameQualificationHost.Play) {
        self.host = host; self.play = play; _profile = State(initialValue: play.controls.profile)
    }
    var body: some View {
        NavigationStack {
            ZStack {
                GamePlayerView(player: play.player, arrangingControls: arranging)
                    .allowsHitTesting(!arranging).ignoresSafeArea(edges: .bottom)
                GameTouchControlsView(service: play.controls, editingLayout: arranging, layoutProfile: profile) { id, anchor in
                    if let id, var button = profile.buttons.first(where: { $0.id == id }) { button.anchor = anchor; try? profile.update(button) }
                    else { profile.stickAnchor = anchor }
                } onFinishLayout: {
                    host.saveControls(profile, controls: play.controls, runID: play.runID)
                    arranging = false
                }
                VStack {
                    HStack {
                        Text("x: " + host.x).accessibilityIdentifier("game.run.x")
                        Text("score: " + host.score).accessibilityIdentifier("game.run.score")
                        Text("input: " + host.touchDispatch).accessibilityIdentifier("game.run.input")
                        Text(host.browserFeatures).accessibilityIdentifier("game.run.browserFeatures")
                        Spacer()
                    }.font(.caption.monospaced()).padding(8).background(.thinMaterial)
                    Spacer()
                }.allowsHitTesting(false)
            }.navigationTitle("触屏试玩验证")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("关闭") { Task { await host.stop(runID: play.runID) } }.accessibilityIdentifier("game.run.close") }
                    ToolbarItem(placement: .topBarTrailing) { Button("键位设置", systemImage: "keyboard") { settings = true }.accessibilityIdentifier("game.touch.settings") }
                }
        }.sheet(isPresented: $settings) {
            NavigationStack {
                GameTouchSettingsView(profile: $profile, editingLayout: $arranging, saving: host.busy, defaults: play.defaultControls,
                    onArrange: { settings = false }) { value in host.saveControls(value, controls: play.controls, runID: play.runID) }
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("完成") { settings = false } } }
            }
        }
    }
}
