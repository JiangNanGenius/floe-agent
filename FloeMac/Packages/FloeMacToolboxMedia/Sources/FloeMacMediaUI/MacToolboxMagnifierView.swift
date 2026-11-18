import SwiftUI
import AppKit
import Combine
import FloeMacMediaCore
import FloeMacMediaSystem

/// Native macOS camera magnifier. The window owns the camera lease only while
/// running, supports hardware zoom when the camera reports a real range, an
/// optional torch, freeze-frame inspection and click-to-focus where supported.
@MainActor
public struct MacToolboxMagnifierView: View {
    @State private var owner: MacMagnifierOwner
    @ObservedObject private var cameraRegistry: MacCameraRegistry
    @State private var windowReference = MacMediaWindowReference()
    @State private var zoomDraft: CGFloat = 1
    @State private var freezeNote: String?

    @Environment(\.locale) private var locale
    @Environment(\.scenePhase) private var scenePhase

    public init(environment: MacToolboxMediaEnvironment? = nil) {
        let resolved = environment ?? .shared
        _owner = State(initialValue: MacMagnifierOwner(environment: resolved))
        _cameraRegistry = ObservedObject(wrappedValue: resolved.cameraRegistry)
    }

    private var camera: MacCameraController { owner.camera }

    public var body: some View {
        VStack(spacing: 0) {
            surface
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if showsControlBar {
                Divider()
                controlBar
            }
        }
        .background(.background)
        .navigationTitle(macToolboxText("放大镜", "Magnifier", locale))
        .background(MacMediaWindowTracker(reference: windowReference))
        .onAppear {
            installCaptureGate()
            zoomDraft = clampedZoom(camera.zoom)
        }
        .onChange(of: camera.maximumZoom) { _, _ in zoomDraft = clampedZoom(camera.zoom) }
        .onChange(of: camera.surface) { _, surface in
            if surface == .running, !NSApp.isActive, !camera.awaitingPermissionPrompt {
                camera.stop()
            }
        }
        .onDisappear { owner.disappear() }
        .onChange(of: cameraRegistry.cameraEpoch) { _, _ in owner.terminationCancelled() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { camera.stop() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            if !camera.awaitingPermissionPrompt { camera.stop() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didMiniaturizeNotification)) { notification in
            if windowReference.shouldStop(for: notification) { owner.windowClosed() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { notification in
            if windowReference.shouldStop(for: notification) { owner.windowClosed() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { notification in
            if windowReference.contains(notification) { owner.windowReopened() }
        }
    }

    private func installCaptureGate() {
        let reference = windowReference
        owner.appear { [weak reference] in reference?.captureAvailable == true }
    }

    private var showsControlBar: Bool {
        camera.surface == .running || camera.surface == .frozen
    }

    // MARK: - Surfaces

    @ViewBuilder
    private var surface: some View {
        switch camera.surface {
        case .idle:
            MacCameraMessagePanel(
                systemImage: "camera.viewfinder",
                title: macToolboxText("放大镜", "Magnifier", locale),
                message: macToolboxText(
                    "使用 Mac 相机实时放大画面，支持数码变焦、按相机能力对焦、冻结与可选照明。",
                    "Magnify the Mac camera live with digital zoom, camera-supported focus, freeze and an optional light.",
                    locale
                ),
                actionTitle: macToolboxText("开始", "Start", locale),
                actionIdentifier: "mac.toolbox.magnifier.start"
            ) { start() }
        case .starting:
            VStack(spacing: 12) {
                ProgressView()
                Text(macToolboxText("正在启动相机…", "Starting the camera…", locale))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        case .denied:
            MacCameraMessagePanel(
                systemImage: "camera.fill",
                title: macToolboxText("需要相机权限", "Camera Access Needed", locale),
                message: macToolboxText(
                    "请在“系统设置 › 隐私与安全性 › 相机”中允许 Floe 访问后重新打开放大镜。",
                    "Allow Floe under System Settings › Privacy & Security › Camera, then reopen the magnifier.",
                    locale
                ),
                actionTitle: macToolboxText("打开系统设置", "Open System Settings", locale),
                actionIdentifier: "mac.toolbox.magnifier.openSettings"
            ) { macOpenPrivacySettings(.camera) }
        case .noDevice:
            MacCameraMessagePanel(
                systemImage: "video.slash",
                title: macToolboxText("未找到相机", "No Camera Found", locale),
                message: macToolboxText(
                    "连接内置或外接相机后重试。连续互通相机需在同一 Apple 账户且满足系统要求。",
                    "Connect a built-in or external camera and retry. Continuity Camera needs the same Apple account and supported systems.",
                    locale
                ),
                actionTitle: macToolboxText("重试", "Retry", locale),
                actionIdentifier: "mac.toolbox.magnifier.retry"
            ) { retry() }
        case .busy:
            MacCameraMessagePanel(
                systemImage: "camera.fill",
                title: macToolboxText("相机正在使用中", "Camera in Use", locale),
                message: macToolboxText(
                    "另一个 Floe 窗口或其他应用正在使用相机。关闭后重试；放大镜不会抢占相机。",
                    "Another Floe window or app is using the camera. Close it and retry; the magnifier never takes the camera over.",
                    locale
                ),
                actionTitle: macToolboxText("重试", "Retry", locale),
                actionIdentifier: "mac.toolbox.magnifier.busyRetry"
            ) { retry() }
        case .interrupted:
            MacCameraMessagePanel(
                systemImage: "exclamationmark.triangle",
                title: macToolboxText("相机已中断", "Camera Interrupted", locale),
                message: macToolboxText(
                    "相机被系统或其他应用暂时占用。恢复操作会重新申请相机并重新开始预览。",
                    "The system or another app took the camera temporarily. Resume requests the camera and restarts the preview.",
                    locale
                ),
                actionTitle: macToolboxText("恢复", "Resume", locale),
                actionIdentifier: "mac.toolbox.magnifier.resume"
            ) { retry() }
        case .failed:
            MacCameraMessagePanel(
                systemImage: "exclamationmark.octagon",
                title: macToolboxText("相机无法启动", "Camera Could Not Start", locale),
                message: camera.lastFailure.map { macMediaFailureText($0, locale) }
                    ?? macToolboxText("请重试。", "Try again.", locale),
                actionTitle: macToolboxText("重试", "Retry", locale),
                actionIdentifier: "mac.toolbox.magnifier.failedRetry"
            ) { retry() }
        case .running:
            runningSurface
        case .frozen:
            frozenSurface
        }
    }

    private var runningSurface: some View {
        ZStack(alignment: .bottomLeading) {
            MacCameraPreview(session: camera.session, zoom: camera.zoom) { devicePoint in
                camera.focus(devicePoint: devicePoint)
            }
            .accessibilityLabel(macToolboxText("相机预览", "Camera preview", locale))
            .accessibilityIdentifier("mac.toolbox.magnifier.preview")
            VStack(alignment: .leading, spacing: 2) {
                if let name = camera.deviceName {
                    Text(name).font(.caption).foregroundStyle(.white.opacity(0.85))
                }
                Text(camera.supportsFocus
                     ? macToolboxText("点按画面对焦", "Click the image to focus", locale)
                     : macToolboxText("此相机不支持点按对焦", "This camera does not support click-to-focus", locale))
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.7))
            }
            .padding(10)
            .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
            .padding(12)
        }
        .background(.black)
        .overlay(alignment: .topTrailing) { freezeFailureNote }
    }

    private var frozenSurface: some View {
        ZStack {
            Color.black
            if let image = camera.frozenImage {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFit()
                    .accessibilityLabel(macToolboxText("已冻结的画面", "Frozen frame", locale))
            } else {
                Text(macToolboxText("已冻结，但当前没有可用画面。", "Frozen, but no frame was available.", locale))
                    .foregroundStyle(.white.opacity(0.8))
            }
        }
        .accessibilityIdentifier("mac.toolbox.magnifier.frozen")
    }

    @ViewBuilder
    private var freezeFailureNote: some View {
        if let freezeNote {
            Text(freezeNote)
                .font(.caption)
                .padding(8)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                .padding(12)
        }
    }

    // MARK: - Controls

    private var controlBar: some View {
        HStack(spacing: 14) {
            Button {
                camera.stop()
            } label: {
                Label(macToolboxText("停止", "Stop", locale), systemImage: "stop.fill")
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(".", modifiers: .command)
            .accessibilityIdentifier("mac.toolbox.magnifier.stop")

            if camera.surface == .frozen {
                Button {
                    camera.unfreeze()
                } label: {
                    Label(macToolboxText("继续", "Resume", locale), systemImage: "play.fill")
                }
                .accessibilityIdentifier("mac.toolbox.magnifier.unfreeze")
            } else {
                Button {
                    freeze()
                } label: {
                    Label(macToolboxText("冻结", "Freeze", locale), systemImage: "camera.aperture")
                }
                .accessibilityIdentifier("mac.toolbox.magnifier.freeze")
            }

            Button {
                camera.setTorch(on: !camera.torchOn)
            } label: {
                Label(camera.torchOn
                      ? macToolboxText("关灯", "Light Off", locale)
                      : macToolboxText("开灯", "Light On", locale),
                      systemImage: camera.torchOn ? "flashlight.on.fill" : "flashlight.off.fill")
            }
            .disabled(!camera.supportsTorch)
            .help(camera.supportsTorch
                  ? macToolboxText("开关相机照明", "Toggle the camera light", locale)
                  : macToolboxText("此相机不支持照明", "This camera has no light", locale))
            .accessibilityIdentifier("mac.toolbox.magnifier.torch")

            Divider().frame(height: 20)

            Text(String(format: "%.1f×", zoomDraft))
                .font(.system(.callout, design: .monospaced))
                .monospacedDigit()
                .frame(minWidth: 46, alignment: .trailing)
            Slider(value: $zoomDraft, in: 1...max(1.01, camera.maximumZoom))
                .frame(minWidth: 120, maxWidth: 220)
                .disabled(camera.surface == .frozen)
                .help(macToolboxText("数码放大画面，不改变相机光学变焦；冻结时按当前倍率裁剪。",
                                     "Digital magnification only; the camera optics are unchanged. Freeze captures the current crop.",
                                     locale))
                .onChange(of: zoomDraft) { _, value in camera.setZoom(value) }
                .accessibilityIdentifier("mac.toolbox.magnifier.zoom")
            Text(macToolboxText("数码变焦", "Digital zoom", locale))
                .font(.caption2)
                .foregroundStyle(.secondary)

            Spacer()

            if let failure = camera.lastFailure, failure != .notAuthorized, failure != .deviceBusy {
                Label(macMediaFailureText(failure, locale), systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    // MARK: - Actions

    private func start() {
        freezeNote = nil
        guard let ticket = owner.startTicket() else { return }
        let selected = camera
        Task {
            let started = await owner.start(ticket: ticket)
            if started {
                if selected === camera { zoomDraft = clampedZoom(selected.zoom) }
                if !NSApp.isActive { selected.stop() }
            }
        }
    }

    private func retry() {
        freezeNote = nil
        guard let ticket = owner.startTicket() else { return }
        Task { _ = await owner.start(ticket: ticket, retry: true) }
    }

    private func freeze() {
        freezeNote = nil
        Task {
            let image = await camera.freeze()
            if image == nil {
                freezeNote = macToolboxText("暂时没有可用画面，请稍后再试。",
                                            "No frame is available yet. Try again shortly.", locale)
            }
        }
    }

    private func clampedZoom(_ value: CGFloat) -> CGFloat {
        max(1, min(value, max(1, camera.maximumZoom)))
    }
}

/// Shared empty/error surface for the Mac camera tools.
struct MacCameraMessagePanel: View {
    let systemImage: String
    let title: String
    let message: String
    let actionTitle: String
    let actionIdentifier: String
    let action: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: systemImage)
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text(title).font(.title2.weight(.semibold))
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
            Button(action: action) {
                Text(actionTitle)
                    .frame(minWidth: 96, minHeight: 28)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier(actionIdentifier)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }
}
