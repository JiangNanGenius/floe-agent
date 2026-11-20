// SPDX-License-Identifier: MPL-2.0
import SwiftUI
import FloeGameAuthoring
#if os(iOS)
import UIKit
#else
import AppKit
#endif

public enum GameProjectOverviewAction: String, CaseIterable, Sendable { case aiModify, simpleEdit, ide, play, files, history, importProject }

public struct GameProjectOverviewContent: Sendable {
    public let title: String
    public let engineSummary: String
    public let description: String
    public let iconPNG: Data?
    public let previewPNG: Data?
    public let lastSaved: Date?
    public let hasFiles: Bool
    public init(title: String, engineSummary: String, description: String = "", iconPNG: Data? = nil,
                previewPNG: Data? = nil, lastSaved: Date? = nil, hasFiles: Bool = true) {
        self.title = title; self.engineSummary = engineSummary; self.description = description
        self.iconPNG = iconPNG; self.previewPNG = previewPNG; self.lastSaved = lastSaved
        self.hasFiles = hasFiles
    }
}

/// Content for the existing Space editor container. The outer App retains its
/// navigation, independent project assistant and presentation ownership.
/// Hosts that run from their own toolbar can use the IDE as their file browser.
public struct GameProjectOverviewView: View {
    public let content: GameProjectOverviewContent
    public let pendingAction: GameProjectOverviewAction?
    public let status: String?
    public let onCreateStarter: (@MainActor () -> Void)?
    public let usesWorkspaceIDE: Bool
    public let showEngineSummary: Bool
    public let onAction: @MainActor (GameProjectOverviewAction) -> Void
    @Environment(\.locale) private var locale

    public init(content: GameProjectOverviewContent, pendingAction: GameProjectOverviewAction? = nil,
                status: String? = nil, showEngineSummary: Bool = true, usesWorkspaceIDE: Bool = false,
                onCreateStarter: (@MainActor () -> Void)? = nil,
                onAction: @escaping @MainActor (GameProjectOverviewAction) -> Void) {
        self.usesWorkspaceIDE = usesWorkspaceIDE
        self.onCreateStarter = onCreateStarter
        self.content = content; self.pendingAction = pendingAction; self.status = status
        self.showEngineSummary = showEngineSummary; self.onAction = onAction
    }
    private var zh: Bool { locale.language.languageCode?.identifier == "zh" }
    public var body: some View {
        GeometryReader { geometry in
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                if !content.hasFiles || content.previewPNG != nil {
                    preview(height: content.hasFiles ? max(180, min(360, geometry.size.height * 0.32)) : 220)
                }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) { ForEach(primary, id: \.self) { actionButton($0) } }
                    LazyVGrid(columns: [.init(.flexible()), .init(.flexible())], spacing: 12) { ForEach(primary, id: \.self) { actionButton($0) } }
                }
                VStack(spacing: 0) {
                    if !usesWorkspaceIDE {
                        detailButton(.files)
                        Divider().padding(.leading, 54)
                    }
                    detailButton(.history)
                }.background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 16))
                if let status {
                    HStack(spacing: 8) {
                        if pendingAction != nil { ProgressView().controlSize(.small) }
                        Text(status).font(.subheadline).foregroundStyle(.secondary)
                    }.accessibilityElement(children: .combine)
                } else if let date = content.lastSaved {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle").foregroundStyle(.green)
                        Text(zh ? "已保存" : "Saved")
                        Text(date, style: .date)
                        Text(date, style: .time)
                    }.font(.footnote).foregroundStyle(.secondary)
                }
            }.padding(24).frame(maxWidth: 1_240).frame(maxWidth: .infinity)
        }
        }
    }
    private var primary: [GameProjectOverviewAction] {
        guard content.hasFiles else { return [.ide, .aiModify] }
        return usesWorkspaceIDE ? [.simpleEdit, .ide, .aiModify] : [.play, .simpleEdit, .ide, .aiModify]
    }
    private var header: some View {
        HStack(alignment: .top, spacing: 18) {
            Group {
                if let data = content.iconPNG, let image = decodedImage(data) { image.resizable().scaledToFill() }
                else { Image(systemName: "gamecontroller.fill").resizable().scaledToFit().padding(18).foregroundStyle(.tint).background(.tint.opacity(0.1)) }
            }.frame(width: 76, height: 76).clipShape(RoundedRectangle(cornerRadius: 18)).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(content.title).font(.title2.weight(.semibold)).textSelection(.enabled)
                if showEngineSummary { Text(content.engineSummary).font(.subheadline).foregroundStyle(.secondary) }
                if !content.description.isEmpty { Text(content.description).font(.subheadline).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 0)
        }
    }
    private func preview(height: CGFloat) -> some View {
        Group {
            if !content.hasFiles {
                ContentUnavailableView {
                    Label(zh ? "开始制作游戏" : "Start your game", systemImage: "gamecontroller")
                } description: {
                    Text(zh ? "导入游戏文件夹或 ZIP，也可以创建新工程。" : "Import a game folder or ZIP, or create a new project.")
                } actions: {
                    Button { onAction(.importProject) } label: {
                        Label(pendingAction == .importProject ? (zh ? "正在导入" : "Importing") : (zh ? "导入游戏" : "Import game"),
                              systemImage: "square.and.arrow.down")
                    }.buttonStyle(.borderedProminent).disabled(pendingAction != nil)
                    .accessibilityIdentifier("game.overview.import")
                    if let onCreateStarter {
                        Button(zh ? "创建起始模板" : "Create starter", action: onCreateStarter)
                            .disabled(pendingAction != nil)
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity).background(.quaternary.opacity(0.5))
            } else if let bytes = content.previewPNG, let image = decodedImage(bytes) { image.resizable().scaledToFill().accessibilityLabel(zh ? "游戏预览" : "Game preview") }
            else {
                Rectangle().fill(.quaternary.opacity(0.5))
                    .overlay { Label(zh ? "运行后显示游戏画面" : "Run to capture a preview", systemImage: "photo").foregroundStyle(.secondary) }
            }
        }.frame(height: height).clipShape(RoundedRectangle(cornerRadius: 18))
    }
    private func actionButton(_ action: GameProjectOverviewAction) -> some View {
        Button { onAction(action) } label: {
            HStack(spacing: 8) {
                if pendingAction == action { ProgressView().controlSize(.small) }
                else { Image(systemName: symbol(action)) }
                Text(title(action)).lineLimit(1).minimumScaleFactor(0.85)
            }.font(.headline).frame(minWidth: 140, maxWidth: .infinity, minHeight: 52)
                .foregroundStyle(action == .play ? Color.white : Color.primary)
                .background(action == .play ? Color.accentColor : Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
                .contentShape(RoundedRectangle(cornerRadius: 14))
        }.buttonStyle(.plain).disabled(pendingAction != nil).accessibilityIdentifier("game.overview." + action.rawValue)
    }
    private func detailButton(_ action: GameProjectOverviewAction) -> some View {
        Button { onAction(action) } label: {
            HStack(spacing: 16) {
                Image(systemName: symbol(action)).frame(width: 24).foregroundStyle(.tint)
                Text(title(action)).foregroundStyle(.primary)
                Spacer(); Image(systemName: "chevron.right").foregroundStyle(.tertiary).font(.subheadline)
            }.padding(.horizontal, 18).frame(minHeight: 54).contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(pendingAction != nil).accessibilityIdentifier("game.overview." + action.rawValue)
    }
    private func title(_ action: GameProjectOverviewAction) -> String {
        switch action {
        case .aiModify: zh ? "AI 修改" : "Edit with AI"
        case .simpleEdit: zh ? "简易编辑" : "Quick edit"
        case .ide: zh ? "打开 IDE" : "Open IDE"
        case .play: zh ? "运行" : "Run"
        case .files: zh ? "工程文件" : "Project files"
        case .history: zh ? "源码管理" : "Source control"
        case .importProject: zh ? "导入文件" : "Import files"
        }
    }
    private func symbol(_ action: GameProjectOverviewAction) -> String {
        switch action {
        case .aiModify: "sparkles"
        case .simpleEdit: "square.and.pencil"
        case .ide: "chevron.left.forwardslash.chevron.right"
        case .play: "play"
        case .files: "folder"
        case .history: "clock.arrow.circlepath"
        case .importProject: "square.and.arrow.down"
        }
    }
    private func decodedImage(_ data: Data) -> Image? {
#if os(iOS)
        UIImage(data: data).map { Image(uiImage: $0) }
#else
        NSImage(data: data).map { Image(nsImage: $0) }
#endif
    }
}
