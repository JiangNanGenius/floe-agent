import SwiftUI
import FloeToolboxUtilities

#if os(iOS)
import AVFoundation
import UIKit

/// Live camera magnifier with hardware zoom, tap focus, freeze-frame, and a
/// user-driven torch. The camera starts only from an explicit tap, owns the
/// shared capture lease while visible, and stops (torch off) on exit or when
/// the scene leaves the foreground.
@MainActor public struct ToolboxMagnifierView: View {
    public init() {}

    @Environment(\.locale) private var locale
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ObservedObject private var service = OpticsCaptureService.shared

    @State private var lease: OpticsCaptureLease?
    @State private var busyNotice = false
    @State private var frozenImage: UIImage?
    @State private var frozenScale: CGFloat = 1
    @State private var zoomDraft: CGFloat = 1
    @State private var focusReticle: CGPoint?
    @State private var freezeGeneration = UUID()
    @StateObject private var preview = OpticsPreviewHost()

    private enum Surface: Equatable {
        case idle, starting, denied, busy, interrupted, running, frozen
    }

    private var surface: Surface {
        guard service.owns(lease) else { return .idle }
        if service.authorization == .denied { return .denied }
        if case .cameraBusy = service.issue { return .busy }
        if service.issue == .interrupted { return .interrupted }
        if frozenImage != nil { return .frozen }
        if service.running { return .running }
        if lease != nil { return .starting }
        return .idle
    }

    private var useTwoColumnBar: Bool {
        sizeClass == .regular && dynamicTypeSize < .accessibility1
    }

    public var body: some View {
        Group {
            switch surface {
            case .idle: idlePanel
            case .starting: startingPanel
            case .denied: deniedPanel
            case .busy: busyPanel
            case .interrupted: interruptedPanel
            case .running: runningSurface
            case .frozen: frozenSurface
            }
        }
        .background(.background)
        .navigationTitle(workbenchText("放大镜", "Magnifier", locale))
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if surface == .running || surface == .frozen {
                controlBar
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.bar)
            }
        }
        .onAppear {
            zoomDraft = max(1, min(service.zoomFactor, service.maximumZoomFactor))
        }
        .onDisappear(perform: stop)
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { stop() }
        }
    }

    // MARK: - Surfaces

    private var idlePanel: some View {
        OpticsMessagePanel(
            systemImage: "camera.viewfinder",
            title: workbenchText("放大镜", "Magnifier", locale),
            message: workbenchText("使用相机实时放大画面，支持对焦、冻结和照明。", "Use the camera to magnify live view with focus, freeze, and lighting.", locale),
            actionTitle: workbenchText("开始", "Start", locale),
            actionIdentifier: "toolbox.magnifier.start",
            note: busyNotice ? workbenchText("相机正被其他工具使用，请稍后再试。", "The camera is in use by another tool. Try again shortly.", locale) : nil
        ) {
            start()
        }
    }

    private var startingPanel: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text(workbenchText("正在启动相机…", "Starting the camera…", locale))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var deniedPanel: some View {
        OpticsMessagePanel(
            systemImage: "camera.fill",
            title: workbenchText("需要相机权限", "Camera Access Needed", locale),
            message: workbenchText("请在“设置 › 隐私与安全性 › 相机”中允许访问后重新打开放大镜。", "Allow camera access in Settings › Privacy & Security › Camera, then open the magnifier again.", locale),
            actionTitle: nil, actionIdentifier: nil, note: nil
        ) {}
        .accessibilityIdentifier("toolbox.magnifier.denied")
    }

    private var busyPanel: some View {
        OpticsMessagePanel(
            systemImage: "camera.fill",
            title: workbenchText("相机正在使用中", "Camera in Use", locale),
            message: workbenchText("系统相机或其他应用正在使用相机。关闭后再试，放大镜不会抢占相机。", "The system camera or another app is using the camera. Close it and retry; the magnifier will not take the camera over.", locale),
            actionTitle: workbenchText("重试", "Retry", locale),
            actionIdentifier: "toolbox.magnifier.retry",
            note: nil
        ) { retry() }
        .accessibilityIdentifier("toolbox.magnifier.busy")
    }

    private var interruptedPanel: some View {
        OpticsMessagePanel(
            systemImage: "exclamationmark.triangle",
            title: workbenchText("相机已中断", "Camera Interrupted", locale),
            message: workbenchText("相机被系统暂时中断，可尝试恢复。", "The camera was temporarily interrupted by the system. You can try to resume.", locale),
            actionTitle: workbenchText("恢复", "Resume", locale),
            actionIdentifier: "toolbox.magnifier.resume",
            note: nil
        ) { retry() }
        .accessibilityIdentifier("toolbox.magnifier.interrupted")
    }

    private var runningSurface: some View {
        OpticsCameraPreview(session: service.session, host: preview)
            .overlay(alignment: .center) {
                if let focusReticle {
                    Image(systemName: "viewfinder")
                        .font(.title3)
                        .foregroundStyle(.tint)
                        .position(focusReticle)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { point in
                guard let lease, service.owns(lease), service.focusTapSupported,
                      let layer = preview.layer else { return }
                service.focus(atPreviewPoint: point, previewLayer: layer, lease: lease)
                showReticle(at: point)
            }
            .accessibilityLabel(workbenchText("相机预览，轻点对焦", "Camera preview, tap to focus", locale))
            .accessibilityIdentifier("toolbox.magnifier.preview")
    }

    private var frozenSurface: some View {
        GeometryReader { geometry in
            Image(uiImage: frozenImage ?? UIImage())
                .resizable()
                .scaledToFit()
                .scaleEffect(frozenScale)
                .frame(width: geometry.size.width, height: geometry.size.height)
                .contentShape(Rectangle())
                .gesture(
                    MagnificationGesture()
                        .onChanged { value in
                            frozenScale = max(1, min(8, value))
                        }
                )
                .onTapGesture(count: 2) {
                    withAnimation { frozenScale = 1 }
                }
        }
        .background(.black)
        .accessibilityLabel(workbenchText("已冻结的画面，双指缩放查看", "Frozen frame. Pinch to inspect.", locale))
        .accessibilityIdentifier("toolbox.magnifier.frozen")
    }

    // MARK: - Control bar (thin native bar outside the visual content)

    private var controlBar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) { controlsRow }
            VStack(spacing: 10) { controlsRow }
        }
    }

    private var controlsRow: some View {
        Group {
            if frozenImage == nil {
                freezeButton
            } else {
                resumeButton
            }
            torchButton
            zoomControl
        }
    }

    private var freezeButton: some View {
        OpticsBarButton(
            title: workbenchText("冻结", "Freeze", locale),
            systemImage: "camera.aperture",
            identifier: "toolbox.magnifier.freeze"
        ) { freeze() }
    }

    private var resumeButton: some View {
        OpticsBarButton(
            title: workbenchText("继续", "Resume", locale),
            systemImage: "play.fill",
            identifier: "toolbox.magnifier.resumeLive"
        ) { unfreeze() }
    }

    private var torchButton: some View {
        OpticsBarButton(
            title: service.torchOn ? workbenchText("关灯", "Light Off", locale)
                                   : workbenchText("开灯", "Light On", locale),
            systemImage: service.torchOn ? "flashlight.on.fill" : "flashlight.off.fill",
            identifier: "toolbox.magnifier.torch"
        ) {
            guard let lease else { return }
            service.setTorch(on: !service.torchOn, lease: lease)
        }
        .disabled(!service.torchSupported)
        .opacity(service.torchSupported ? 1 : 0.45)
        .accessibilityHint(service.torchSupported
                           ? workbenchText("开关照明", "Toggle the light.", locale)
                           : workbenchText("此设备不支持手电筒", "Torch is not supported on this device.", locale))
    }

    private var zoomControl: some View {
        HStack(spacing: 10) {
            Text(zoomLabel)
                .font(.system(.callout, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(minWidth: 52, alignment: .trailing)
                .accessibilityLabel(workbenchText("变焦", "Zoom", locale))
            Slider(value: $zoomDraft, in: 1...max(1, service.maximumZoomFactor))
                .disabled(frozenImage != nil)
                .accessibilityIdentifier("toolbox.magnifier.zoom")
                .onChange(of: zoomDraft) { _, value in
                    guard let lease else { return }
                    service.setZoomFactor(value, lease: lease)
                }
        }
        .frame(minHeight: 44)
    }

    private var zoomLabel: String {
        if frozenImage != nil {
            return String(format: "%.1f×", frozenScale)
        }
        return String(format: "%.1f×", zoomDraft)
    }

    // MARK: - Actions

    private func start() {
        guard scenePhase == .active, lease == nil else { return }
        guard let newLease = service.acquire(.magnifier) else {
            busyNotice = true
            return
        }
        busyNotice = false
        lease = newLease
        service.requestStart(lease: newLease)
    }

    private func retry() {
        stop()
        start()
    }

    private func stop() {
        if let lease {
            service.release(lease)
        }
        lease = nil
        frozenImage = nil
        frozenScale = 1
        focusReticle = nil
        freezeGeneration = UUID()
    }

    private func freeze() {
        guard let lease, service.owns(lease) else { return }
        let token = UUID()
        freezeGeneration = token
        Task {
            let image = await service.renderLastFrame(lease: lease)
            guard freezeGeneration == token, service.owns(lease), !Task.isCancelled else { return }
            guard let image else { return }
            frozenImage = image
            frozenScale = 1
        }
    }

    private func unfreeze() {
        freezeGeneration = UUID()
        frozenImage = nil
        frozenScale = 1
    }

    private func showReticle(at point: CGPoint) {
        focusReticle = point
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(900))
            if focusReticle == point { focusReticle = nil }
        }
    }
}

// MARK: - Preview host

/// Holds the live preview layer so tap-to-focus can convert coordinates.
@MainActor final class OpticsPreviewHost: ObservableObject {
    weak var layer: AVCaptureVideoPreviewLayer?
}

struct OpticsCameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    let host: OpticsPreviewHost

    func makeUIView(context: Context) -> OpticsPreviewUIView {
        let view = OpticsPreviewUIView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        Task { @MainActor in host.layer = view.previewLayer }
        return view
    }

    func updateUIView(_ uiView: OpticsPreviewUIView, context: Context) {
        if uiView.previewLayer.session !== session {
            uiView.previewLayer.session = session
        }
        Task { @MainActor in host.layer = uiView.previewLayer }
    }
}

final class OpticsPreviewUIView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
}

// MARK: - Shared small pieces

struct OpticsBarButton: View {
    let title: String
    let systemImage: String
    let identifier: String
    let action: () -> Void
    @Environment(\.locale) private var locale

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.body)
                .frame(minHeight: 44)
                .padding(.horizontal, 14)
        }
        .buttonStyle(.bordered)
        .accessibilityIdentifier(identifier)
    }
}

struct OpticsMessagePanel: View {
    let systemImage: String
    let title: String
    let message: String
    let actionTitle: String?
    let actionIdentifier: String?
    let note: String?
    let action: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: systemImage)
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text(title).font(.title2.weight(.semibold))
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
            if let actionTitle {
                Button(action: action) {
                    Label(actionTitle, systemImage: "play.fill")
                        .font(.body)
                        .frame(minHeight: 44)
                        .padding(.horizontal, 18)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier(actionIdentifier ?? "")
            }
            if let note {
                Label(note, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }
}

#else
/// Capture requires iOS; other platforms get a truthful unsupported surface.
@MainActor public struct ToolboxMagnifierView: View {
    public init() {}

    @Environment(\.locale) private var locale

    public var body: some View {
        InstrumentUnavailableSurface(
            title: workbenchText("放大镜", "Magnifier", locale),
            message: workbenchText("此平台不支持相机采集，放大镜不可用。", "Camera capture is not supported on this platform, so the magnifier is unavailable.", locale),
            systemImage: "camera.viewfinder"
        )
        .navigationTitle(workbenchText("放大镜", "Magnifier", locale))
    }
}
#endif
