// SPDX-License-Identifier: MPL-2.0
import SwiftUI
import UIKit
import FloeCAD
import FloeCore

@MainActor
struct CADOfflineRenderEntry: ViewModifier {
    let document: FloeCADDocument
    let root: URL?
    let workspaceID: UUID?
    let conversationID: UUID?
    @State private var presented = false
    func body(content: Content) -> some View {
        content.toolbar {
            Button { presented = true } label: {
                Label(CADOfflineRenderText.t("离线渲染", "Offline render"), systemImage: "camera.aperture")
            }.accessibilityIdentifier("cad.offlineRender.open")
        }.sheet(isPresented: $presented) {
            CADOfflineRenderView(document: document, root: root, workspaceID: workspaceID, conversationID: conversationID)
        }
    }
}

enum CADOfflineRenderText {
    static func t(_ zh: String, _ en: String) -> String { FloeL10n.isChinese ? zh : en }
}

/// Closing this sheet does not cancel or resubmit a service-owned render.
@MainActor
struct CADOfflineRenderView: View {
    let document: FloeCADDocument
    let root: URL?
    let workspaceID: UUID?
    let conversationID: UUID?
    @EnvironmentObject private var environment: AppEnvironment
    @Environment(\.dismiss) private var dismiss
    @State private var settings = CADOfflineRenderSettings()
    @State private var operation: CADOfflineRenderOperation?
    @State private var starting = false
    @State private var cancelling = false
    @State private var message: String?
    @State private var image: UIImage?
    @State private var imageURL: URL?
    private func t(_ zh: String, _ en: String) -> String { CADOfflineRenderText.t(zh, en) }
    private var canStart: Bool { root != nil && workspaceID != nil && conversationID != nil && !starting && operation?.isRunning != true }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(t("使用路径追踪计算反射、间接光与阴影。首次使用会在当前任务的执行环境中下载并编译渲染器。", "Path tracing computes reflections, indirect light and shadows. The first run downloads and builds the renderer in this task’s execution environment."))
                        .font(.callout).foregroundStyle(.secondary)
                    if root == nil || workspaceID == nil || conversationID == nil {
                        Text(t("请从任务工作区打开此模型，并为任务选择可用的执行环境。", "Open this model from a task workspace and select an available execution environment."))
                    }
                }
                Section(t("图像", "Image")) {
                    Picker(t("质量", "Quality"), selection: $settings.quality) {
                        Text(t("预览 · 16 采样", "Preview · 16 samples")).tag(CADOfflineRenderSettings.Quality.preview)
                        Text(t("工作室 · 64 采样", "Studio · 64 samples")).tag(CADOfflineRenderSettings.Quality.studio)
                        Text(t("精细 · 256 采样", "Final · 256 samples")).tag(CADOfflineRenderSettings.Quality.final)
                    }.accessibilityIdentifier("cad.offlineRender.quality")
                    Picker(t("尺寸", "Size"), selection: $settings.width) {
                        ForEach([640, 1280, 1920, 2560], id: \.self) { width in Text("\(width) × \(width * 3 / 4)").tag(width) }
                    }.onChange(of: settings.width) { _, width in settings.height = width * 3 / 4 }
                    Stepper(value: $settings.maximumBounces, in: 2...16) {
                        LabeledContent(t("光线反弹", "Light bounces"), value: "\(settings.maximumBounces)")
                    }
                    LabeledContent(t("曝光", "Exposure"), value: settings.exposureEV.formatted(.number.precision(.fractionLength(1))))
                    Slider(value: $settings.exposureEV, in: -6...6, step: 0.25).accessibilityLabel(t("曝光", "Exposure"))
                }.disabled(starting || operation?.isRunning == true)
                Section {
                    if starting || operation?.isRunning == true {
                        HStack {
                            ProgressView()
                            Text(operation?.state == .cancelling ? t("正在取消…", "Cancelling…") : t("正在准备并渲染…", "Preparing and rendering…"))
                            Spacer()
                            if let operation {
                                Button(t("取消", "Cancel"), role: .destructive) { cancel(operation.id) }.disabled(cancelling)
                            }
                        }.accessibilityIdentifier("cad.offlineRender.progress")
                    } else {
                        Button(t("准备并渲染", "Prepare and render"), systemImage: "sparkles") { start() }
                            .disabled(!canStart).accessibilityIdentifier("cad.offlineRender.start")
                    }
                    if let operation {
                        LabeledContent(t("状态", "Status"), value: stateTitle(operation.state))
                        if operation.state == .ready {
                            LabeledContent(t("图像尺寸", "Image size"), value: "\(operation.settings.width) × \(operation.settings.height)")
                            Text(t("图像来自启动渲染时的模型快照。", "The image uses the model snapshot taken when this render started."))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if !operation.warnings.isEmpty {
                            DisclosureGroup(t("场景转换详情", "Scene conversion details")) {
                                ForEach(operation.warnings, id: \.self) { Text($0).font(.caption).textSelection(.enabled) }
                            }
                        }
                    }
                    if let message { Text(message).foregroundStyle(.red).textSelection(.enabled) }
                }
                if let image {
                    Section {
                        Image(uiImage: image).resizable().scaledToFit().accessibilityIdentifier("cad.offlineRender.preview")
                        if let imageURL {
                            ShareLink(item: imageURL) { Label(t("保存图像", "Save image"), systemImage: "square.and.arrow.up") }
                                .accessibilityIdentifier("cad.offlineRender.save")
                        }
                    }
                }
            }
            .navigationTitle(t("离线渲染", "Offline render"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(t("完成", "Done")) { dismiss() } } }
            .task(id: operation?.id) {
                if operation == nil, let root, let conversationID {
                    operation = environment.offlineRenderCenter.latest(documentURL: document.url, conversationID: conversationID, workspaceRoot: root)
                }
                while !Task.isCancelled, let current = operation {
                    await refresh()
                    if !current.isRunning { break }
                    do { try await Task.sleep(for: .milliseconds(500)) } catch { break }
                }
            }
        }
    }
    private func stateTitle(_ state: CADOfflineRenderOperation.State) -> String {
        switch state {
        case .preparing: t("准备中", "Preparing")
        case .rendering: t("渲染中", "Rendering")
        case .ready: t("已完成", "Ready")
        case .cancelling: t("正在取消", "Cancelling")
        case .cancelled: t("已取消", "Cancelled")
        case .failed: t("失败", "Failed")
        case .interrupted: t("已中断", "Interrupted")
        }
    }
    private func start() {
        guard let root, let workspaceID, let conversationID, canStart else { return }
        starting = true; message = nil; image = nil; imageURL = nil
        Task {
            defer { starting = false }
            do {
                operation = try await environment.offlineRenderCenter.startFromUI(document: document, settings: settings,
                    workspaceRoot: root, workspaceID: workspaceID, conversationID: conversationID)
            } catch { message = error.localizedDescription }
        }
    }
    private func cancel(_ id: UUID) {
        cancelling = true
        Task {
            defer { cancelling = false }
            do { operation = try await environment.offlineRenderCenter.cancel(id) }
            catch { message = error.localizedDescription }
        }
    }
    private func refresh() async {
        guard let current = operation else { return }
        do {
            let updated = try await environment.offlineRenderCenter.refresh(current.id)
            guard operation?.id == current.id else { return }
            operation = updated; message = updated.error
            if updated.state == .ready, imageURL == nil, let url = try environment.offlineRenderCenter.imageURL(updated) {
                imageURL = url; image = UIImage(contentsOfFile: url.path)
            }
        } catch is CancellationError { }
        catch { message = error.localizedDescription }
    }
}
