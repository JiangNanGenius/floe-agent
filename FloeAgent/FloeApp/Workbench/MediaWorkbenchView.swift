// FloeApp — Unified media workbench view.
//
// One image/video workbench for Files, chat/workspace previews and Canvas.
// iPad desktop layout: assets/layers left, large preview center, properties
// right, video timeline bottom. Narrow iPad/iPhone collapse panels into
// drawers; every interactive control is at least 44pt. Fullscreen preview and
// resizing preserve the editing session because the center owns all state.
// The AI drawer opens only on request and shows the current selection, the
// pending proposal and durable generation jobs.

import SwiftUI
import AVFoundation
import FloeCore
import FloeWorkbench
#if canImport(UIKit)
import UIKit
#endif

struct MediaWorkbenchView: View {
    @ObservedObject var center: WorkbenchCenter
    var title: String
    var onExported: ((URL) -> Void)?
    /// Entrance-owned write-back: exports image bytes into the caller's own
    /// destination (workspace file commit, Canvas derived asset, …).
    var onSaveToSource: ((ImageExportOptions) async throws -> Void)?

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        GeometryReader { geometry in
            // Desktop three-column layout requires genuinely wide, landscape
            // usable bounds: portrait iPad and narrow split widths use the
            // drawer layout so the preview never collapses into a strip.
            let compact = geometry.size.width < 1180
                || geometry.size.width < geometry.size.height * 1.05
            VStack(spacing: 0) {
                toolbar(compact: compact)
                Divider()
                if compact {
                    compactLayout
                } else {
                    regularLayout
                }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .background(Color(uiColor: .systemBackground))
        .sheet(item: $center.drawer) { drawer in
            drawerContent(drawer)
                .presentationDetents([.medium, .large])
        }
        .sheet(item: $center.aiReview) { request in
            WorkbenchAIReviewSheet(center: center, request: request)
        }
        .sheet(isPresented: $center.showsProjectLibrary) {
            WorkbenchProjectLibraryView(center: center)
        }
        .fullScreenCover(isPresented: $center.isFullscreenPreview) {
            WorkbenchFullscreenPreview(center: center)
        }
        .alert(item: $center.alert) { alert in
            Alert(title: Text(alert.title), message: Text(alert.message),
                  dismissButton: .default(Text(WorkbenchText.t("好", "OK"))))
        }
        .onAppear {
            Task { await center.reloadPendingProposals() }
        }
    }

    // MARK: - Layouts

    private var regularLayout: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                WorkbenchAssetsPanel(center: center)
                    .frame(width: 270)
                Divider()
                centerPreview
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                WorkbenchPropertiesPanel(center: center)
                    .frame(width: 310)
            }
            if center.project?.kind == .video {
                Divider()
                WorkbenchVideoTimeline(center: center)
                    .frame(height: 210)
            }
        }
    }

    private var compactLayout: some View {
        VStack(spacing: 0) {
            centerPreview
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            if center.project?.kind == .video {
                WorkbenchVideoTimeline(center: center, compact: true)
                    .frame(height: 170)
            }
            Divider()
            HStack(spacing: 4) {
                compactButton(WorkbenchText.t("素材/图层", "Assets/Layers"), systemImage: "square.3.layers.3d", drawer: .assets)
                compactButton(WorkbenchText.t("属性", "Properties"), systemImage: "slider.horizontal.3", drawer: .properties)
                compactButton(WorkbenchText.t("AI", "AI"), systemImage: "sparkles", drawer: .ai)
                compactButton(WorkbenchText.t("导出", "Export"), systemImage: "square.and.arrow.up", drawer: .export)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 4)
            .padding(.vertical, 6)
        }
    }

    private var centerPreview: some View {
        WorkbenchPreview(center: center)
    }

    // MARK: - Toolbar

    private func toolbar(compact: Bool) -> some View {
        HStack(spacing: 8) {
            if compact == false {
                Text(center.project.map { "\($0.name) · r\($0.revision)" } ?? "")
                    .font(.headline)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            toolbarButton("arrow.uturn.backward", WorkbenchText.t("撤销", "Undo"),
                          identifier: "workbench.undo", disabled: !center.canUndo()) { center.undo() }
            toolbarButton("arrow.uturn.forward", WorkbenchText.t("重做", "Redo"),
                          identifier: "workbench.redo", disabled: !center.canRedo()) { center.redo() }
            toolbarButton("folder", WorkbenchText.t("项目", "Projects"),
                          identifier: "workbench.projects") { center.showsProjectLibrary = true }
            if compact {
                // Narrow/iPhone width: secondary actions move into one
                // overflow menu so the row can never exceed the screen and
                // clip the trailing controls.
                Menu {
                    Button {
                        center.showsProjectLibrary = true
                    } label: {
                        Label(WorkbenchText.t("项目", "Projects"), systemImage: "folder")
                    }
                    Button {
                        center.compareWithSource.toggle()
                    } label: {
                        Label(WorkbenchText.t("对比原图", "Compare"), systemImage: "rectangle.on.rectangle")
                    }
                    Button {
                        center.isFullscreenPreview = true
                    } label: {
                        Label(WorkbenchText.t("全屏", "Fullscreen"), systemImage: "arrow.up.left.and.arrow.down.right")
                    }
                    Button {
                        Task { await center.saveNow() }
                    } label: {
                        Label(WorkbenchText.t("保存项目", "Save project"), systemImage: "square.and.arrow.down")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .frame(minWidth: 44, minHeight: 44)
                }
                .accessibilityIdentifier("workbench.more")
            } else {
                toolbarButton("rectangle.on.rectangle", WorkbenchText.t("对比原图", "Compare"),
                              identifier: "workbench.compare", highlighted: center.compareWithSource) {
                    center.compareWithSource.toggle()
                }
                toolbarButton("arrow.up.left.and.arrow.down.right", WorkbenchText.t("全屏", "Fullscreen"),
                              identifier: "workbench.fullscreen") { center.isFullscreenPreview = true }
                toolbarButton("square.and.arrow.down", WorkbenchText.t("保存项目", "Save project"),
                              identifier: "workbench.save") {
                    Task { await center.saveNow() }
                }
            }
            toolbarButton("square.and.arrow.up", WorkbenchText.t("导出", "Export"),
                          identifier: "workbench.export") {
                center.drawer = .export
            }
            toolbarButton("sparkles", WorkbenchText.t("AI", "AI"),
                          identifier: "workbench.ai", highlighted: !center.pendingProposals.isEmpty) {
                center.drawer = .ai
            }
            if center.busy {
                ProgressView()
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func toolbarButton(_ systemImage: String, _ label: String, identifier: String,
                               disabled: Bool = false, highlighted: Bool = false,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(label, systemImage: systemImage)
                .labelStyle(.iconOnly)
                .frame(minWidth: 44, minHeight: 44)
                .foregroundStyle(highlighted ? Color.accentColor : Color.primary)
        }
        .disabled(disabled)
        .accessibilityLabel(Text(label))
        .accessibilityIdentifier(identifier)
    }

    private func compactButton(_ label: String, systemImage: String, drawer: WorkbenchCenter.Drawer) -> some View {
        Button {
            center.drawer = drawer
        } label: {
            Label(label, systemImage: systemImage)
                .labelStyle(.titleAndIcon)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .accessibilityIdentifier("workbench.drawer.\(drawer.rawValue)")
    }

    // MARK: - Drawers

    @ViewBuilder
    private func drawerContent(_ drawer: WorkbenchCenter.Drawer) -> some View {
        NavigationStack {
            Group {
                switch drawer {
                case .assets:
                    WorkbenchAssetsPanel(center: center)
                case .properties:
                    WorkbenchPropertiesPanel(center: center)
                case .ai:
                    WorkbenchAIDrawer(center: center)
                case .export:
                    WorkbenchExportPanel(center: center, onExported: onExported,
                                         onSaveToSource: onSaveToSource)
                }
            }
            .navigationTitle(drawerTitle(drawer))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(WorkbenchText.t("完成", "Done")) { center.drawer = nil }
                }
            }
            .alert(item: $center.alert) { alert in
                Alert(title: Text(alert.title), message: Text(alert.message),
                      dismissButton: .default(Text(WorkbenchText.t("好", "OK"))))
            }
        }
    }

    private func drawerTitle(_ drawer: WorkbenchCenter.Drawer) -> String {
        switch drawer {
        case .assets: WorkbenchText.t("素材与图层", "Assets & Layers")
        case .properties: WorkbenchText.t("属性", "Properties")
        case .ai: WorkbenchText.t("AI 助手", "AI Assistant")
        case .export: WorkbenchText.t("导出", "Export")
        }
    }
}

// MARK: - Preselection entry

/// Bootstraps a workbench project from entrance-owned source URLs and then
/// shows the workbench. Kept separate so every entrance (Files, workspace
/// preview, Canvas, chat preview) shares one preparation path.
struct WorkbenchBootstrapSheet: View {
    @ObservedObject var center: WorkbenchCenter
    var title: String
    var kind: MediaProjectKind
    var urls: [URL]
    var musicURL: URL? = nil
    var owner: WorkbenchCenter.Owner
    var onExported: ((URL) -> Void)?
    var onSaveToSource: ((ImageExportOptions) async throws -> Void)?
    /// Production entrances offer to resume a saved project for the same
    /// source; deterministic UI fixtures start fresh.
    var allowsResume = true

    @Environment(\.dismiss) private var dismiss
    @State private var ready = false
    @State private var failure: String?
    @State private var resumeCandidate: MediaProjectStore.ProjectSummary?

    var body: some View {
        Group {
            if ready, center.project != nil {
                WorkbenchSheet(center: center, title: title, onExported: onExported,
                               onSaveToSource: onSaveToSource)
            } else if let candidate = resumeCandidate, let failure {
                // Opening a source that already has a saved project offers to
                // resume it instead of silently starting over.
                VStack(spacing: 14) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.largeTitle)
                        .foregroundStyle(.tint)
                    Text(WorkbenchText.t("发现已保存的项目", "Saved project found"))
                        .font(.headline)
                    Text(WorkbenchText.t(
                        "“\(candidate.name)”已有 \(candidate.revision) 次修订。继续编辑会保留已有图层/时间线/撤销历史；新建会从当前素材重新开始。",
                        "“\(candidate.name)” has \(candidate.revision) revisions. Resume keeps its layers/timeline/undo history; start fresh rebuilds from the current media."))
                        .font(.callout)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 24)
                    if !failure.isEmpty {
                        Text(failure)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Button(WorkbenchText.t("继续编辑", "Resume")) {
                            Task { await resume(candidate) }
                        }
                        .buttonStyle(.borderedProminent)
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("workbench.bootstrap.resume")
                        Button(WorkbenchText.t("新建项目", "Start fresh")) {
                            Task { await prepare(ignoringSavedProject: true) }
                        }
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("workbench.bootstrap.fresh")
                        Button(WorkbenchText.t("关闭", "Close")) { dismiss() }
                            .frame(minHeight: 44)
                    }
                }
                .padding()
            } else if ready, let failure {
                // Bootstrap failures must never look like a blank workbench.
                VStack(spacing: 14) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundStyle(.orange)
                    Text(WorkbenchText.t("无法打开工作台", "Could not open the workbench"))
                        .font(.headline)
                    Text(failure)
                        .font(.callout)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 24)
                    HStack {
                        Button(WorkbenchText.t("重试", "Retry")) {
                            Task { await prepare() }
                        }
                        .buttonStyle(.borderedProminent)
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("workbench.bootstrap.retry")
                        Button(WorkbenchText.t("关闭", "Close")) { dismiss() }
                            .frame(minHeight: 44)
                    }
                }
                .padding()
            } else {
                ProgressView(WorkbenchText.t("正在准备工作台…", "Preparing workbench…"))
                    .task { await prepare() }
            }
        }
        .alert(item: $center.alert) { alert in
            Alert(title: Text(alert.title), message: Text(alert.message),
                  dismissButton: .default(Text(WorkbenchText.t("好", "OK"))))
        }
    }

    @MainActor
    private func prepare(ignoringSavedProject: Bool = false) async {
        ready = false
        failure = nil
        resumeCandidate = nil
        center.closeProject()
        if !ignoringSavedProject, allowsResume,
           let existing = await center.findResumableProject(sourceURLs: urls, kind: kind, owner: owner),
           existing.id != center.project?.id {
            resumeCandidate = existing
            failure = ""
            ready = true
            return
        }
        if kind == .image, let url = urls.first {
            await center.startImageProject(sourceURL: url, owner: owner)
        } else {
            await center.startVideoProject(clipURLs: urls, musicURL: musicURL, owner: owner)
        }
        if center.project == nil {
            failure = center.alert?.message
                ?? WorkbenchText.t("没有生成可编辑的项目；请检查素材后重试。",
                                   "No editable project was created; check the source media and retry.")
            if center.alert == nil {
                center.alert = .init(title: WorkbenchText.t("打开失败", "Open failed"), message: failure ?? "")
            }
        }
        ready = true
    }

    @MainActor
    private func resume(_ candidate: MediaProjectStore.ProjectSummary) async {
        ready = false
        failure = nil
        await center.openProject(id: candidate.id)
        if center.project == nil {
            failure = center.alert?.message
                ?? WorkbenchText.t("无法打开已保存的项目。", "Could not open the saved project.")
            // Fall back to the fresh-start flow rather than a dead end.
            await prepare(ignoringSavedProject: true)
            return
        }
        resumeCandidate = nil
        ready = true
    }
}

/// Presents the workbench for the current center state and closes the
/// presenting sheet when the user is done. Entrances own the creation of the
/// project (image/video) before showing this.
struct WorkbenchSheet: View {
    @ObservedObject var center: WorkbenchCenter
    var title: String
    var onExported: ((URL) -> Void)?
    var onSaveToSource: ((ImageExportOptions) async throws -> Void)?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            MediaWorkbenchView(center: center, title: title, onExported: onExported,
                               onSaveToSource: onSaveToSource)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(WorkbenchText.t("关闭", "Close")) {
                            center.closeProject()
                            dismiss()
                        }
                        .accessibilityIdentifier("workbench.close")
                    }
                }
        }
    }
}

// MARK: - Saved project library

/// Reopen entry: lists saved projects from the current editing context and
/// opens one on tap. Opening uses the project's recorded owner/workspace via
/// `WorkbenchCenter.openProject`, so assets keep resolving from their own
/// root even when another workspace is currently open.
struct WorkbenchProjectLibraryView: View {
    @ObservedObject var center: WorkbenchCenter
    @Environment(\.dismiss) private var dismiss
    @State private var projects: [MediaProjectStore.ProjectSummary] = []

    var body: some View {
        NavigationStack {
            Group {
                if projects.isEmpty {
                    ContentUnavailableView(WorkbenchText.t("没有已保存的项目", "No saved projects"),
                                           systemImage: "folder",
                                           description: Text(WorkbenchText.t(
                                            "在此工作台编辑并保存后，项目会出现在这里。",
                                            "Projects appear here after you edit and save them in this workbench.")))
                } else {
                    List(projects) { summary in
                        Button {
                            Task {
                                await center.openProject(id: summary.id)
                                dismiss()
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Image(systemName: summary.kind == .video ? "film" : "photo")
                                    Text(summary.name).font(.body.weight(.medium)).lineLimit(1)
                                    Spacer()
                                    Text("r\(summary.revision)")
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                                Text(summary.updatedAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                if !summary.workspacePath.isNilOrEmpty {
                                    Text(summary.workspacePath ?? "")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                        .lineLimit(1)
                                }
                            }
                            .frame(minHeight: 44)
                        }
                        .accessibilityIdentifier("workbench.projects.row.\(summary.id.uuidString)")
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle(WorkbenchText.t("已保存的项目", "Saved projects"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(WorkbenchText.t("完成", "Done")) { dismiss() }
                }
            }
            .task {
                projects = await center.savedProjectsForCurrentContext()
            }
        }
    }
}

private extension Optional where Wrapped == String {
    var isNilOrEmpty: Bool {
        switch self {
        case .none: true
        case .some(let value): value.isEmpty
        }
    }
}

// MARK: - Preview surface

struct WorkbenchPreview: View {
    @ObservedObject var center: WorkbenchCenter

    var body: some View {
        ZStack {
            Color(uiColor: .secondarySystemBackground)
            if center.project?.kind == .video {
                WorkbenchVideoSurface(center: center)
            } else {
                WorkbenchImagePreview(center: center)
            }
        }
        .clipped()
    }
}

// MARK: - Fullscreen preview keeps the same session

struct WorkbenchFullscreenPreview: View {
    @ObservedObject var center: WorkbenchCenter

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            WorkbenchPreview(center: center)
                .ignoresSafeArea(edges: .bottom)
            VStack {
                HStack {
                    Spacer()
                    Button {
                        center.isFullscreenPreview = false
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title)
                            .foregroundStyle(.white)
                            .frame(minWidth: 44, minHeight: 44)
                    }
                    .accessibilityIdentifier("workbench.fullscreen.close")
                }
                Spacer()
            }
            .padding()
        }
    }
}
