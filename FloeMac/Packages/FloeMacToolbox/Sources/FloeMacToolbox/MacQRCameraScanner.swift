import AVFoundation
import AppKit
import Combine
import SwiftUI
import Observation
import FloeMacMediaSystem

enum MacQRCameraState: Equatable {
    case checking
    case unavailable(String)
    case denied
    case ready
    case failed(String)
}

private enum MacQRCameraError: Error {
    case noCamera
    case configuration
    case noQRSupport
}

@MainActor
protocol MacQRCaptureControlling: AnyObject {
    var previewSession: AVCaptureSession? { get }
    var onStopped: (@MainActor () -> Void)? { get set }
    func start() async -> Bool
    func stop()
}

enum MacQRCameraAuthorization: Sendable {
    case authorized
    case denied
    case unavailable
}

/// QR scanning and the other media tools use the same app-owned camera
/// broker and the same stop-completion rules.
@MainActor
enum MacQRCaptureAdmission {
    static func start(after wait: @MainActor () async -> Bool,
                      whileCurrent current: @MainActor () -> Bool,
                      operation: @MainActor () async -> Bool) async -> Bool {
        guard await wait(), !Task.isCancelled, current() else { return false }
        return await operation()
    }
}

@MainActor
private final class MacQRCaptureAdapter: MacQRCaptureControlling {
    private let camera: MacCameraController
    private let environment: MacToolboxMediaEnvironment
    private let monitor: MacQRCameraMonitor
    private let canCapture: @MainActor () -> Bool
    var onStopped: (@MainActor () -> Void)?

    init(environment: MacToolboxMediaEnvironment,
         canCapture: @escaping @MainActor () -> Bool = { false },
         onCode: @escaping @Sendable (String) -> Void) {
        let camera = environment.makeCameraController()
        self.camera = camera
        self.environment = environment
        self.canCapture = canCapture
        monitor = MacQRCameraMonitor(isRunning: { camera.running })
        camera.setCaptureAvailability(canCapture)
        camera.onLiveCodes = { codes in
            guard let code = codes.first(where: { $0.symbology == AVMetadataObject.ObjectType.qr.rawValue }) else { return }
            onCode(code.payload)
        }
    }

    var previewSession: AVCaptureSession? { camera.session }
    func start() async -> Bool {
        guard await MacQRCaptureAdmission.start(after: { await environment.cameraRegistry.retryRetiredStops() },
                                                whileCurrent: canCapture,
                                                operation: { await camera.start() }) else { return false }
        guard camera.supportsQRCode else { camera.stop(); return false }
        monitor.start { [weak self] in self?.onStopped?() }
        return true
    }
    func stop() {
        monitor.stop()
        onStopped = nil
        environment.retireCamera(camera)
    }
}

/// Observation callbacks are delivered before assignment; read the state on
/// the next main-actor turn and fence callbacks from an earlier run.
@MainActor
final class MacQRCameraMonitor {
    private let isRunning: @MainActor () -> Bool
    private var generation = UUID()
    private var onStopped: (@MainActor () -> Void)?

    init(isRunning: @escaping @MainActor () -> Bool) { self.isRunning = isRunning }
    func start(onStopped: @escaping @MainActor () -> Void) {
        generation = UUID()
        self.onStopped = onStopped
        watch(generation)
    }
    func stop() { generation = UUID(); onStopped = nil }

    private func watch(_ token: UUID) {
        guard generation == token else { return }
        withObservationTracking {
            _ = isRunning()
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.generation == token else { return }
                if self.isRunning() {
                    self.watch(token)
                } else {
                    self.generation = UUID()
                    self.onStopped?()
                }
            }
        }
    }
}

/// The same payload from two runs is two distinct observations.
struct MacQRCameraResult: Equatable {
    let code: String
    let run: UUID
}

/// Synchronous fence for a single presented sheet, including binding writes
/// that dismiss it before SwiftUI invokes onDisappear.
@MainActor
final class MacQRPresentationGate {
    private(set) var ticket: UUID?
    func open() { ticket = UUID() }
    func close() { ticket = nil }
    func close(ifCurrent expected: UUID?) {
        guard let expected, ticket == expected else { return }
        ticket = nil
    }
    func isCurrent(_ expected: UUID?) -> Bool {
        guard let expected else { return false }
        return ticket == expected
    }
}

@MainActor
final class MacQRCameraModel: ObservableObject {
    @Published private(set) var state: MacQRCameraState = .checking
    @Published private(set) var latestResult: MacQRCameraResult?
    var latestCode: String? { latestResult?.code }
    private let usageDescription: @MainActor () -> Bool
    private let authorize: @MainActor () async -> MacQRCameraAuthorization
    private let admissionValid: @MainActor () -> Bool
    private let makeController: @MainActor (@escaping @Sendable (String) -> Void) throws -> any MacQRCaptureControlling
    private var controller: (any MacQRCaptureControlling)?
    private var started = false
    @Published private(set) var awaitingPermission = false
    private var generation = UUID()
    private var schedulingGeneration = UUID()
    private var scheduledStart: Task<Void, Never>?
    private var presentationClosed = false

    init(
        usageDescription: @escaping @MainActor () -> Bool = MacQRCameraModel.systemHasUsageDescription,
        authorize: @escaping @MainActor () async -> MacQRCameraAuthorization = MacQRCameraModel.systemAuthorization,
        admissionValid: @escaping @MainActor () -> Bool = { true },
        makeController: @escaping @MainActor (@escaping @Sendable (String) -> Void) throws -> any MacQRCaptureControlling = {
            MacQRCaptureAdapter(environment: .shared, onCode: $0)
        }
    ) {
        self.usageDescription = usageDescription
        self.authorize = authorize
        self.admissionValid = admissionValid
        self.makeController = makeController
    }

    private func text(_ zh: String, _ en: String) -> String {
        MacToolboxText.t(zh, en, .current)
    }

    var session: AVCaptureSession? { controller?.previewSession }

    var hasUsageDescription: Bool { usageDescription() }

    private static func systemHasUsageDescription() -> Bool {
        guard let text = Bundle.main.object(forInfoDictionaryKey: "NSCameraUsageDescription") as? String else {
            return false
        }
        return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func systemAuthorization() async -> MacQRCameraAuthorization {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            return .authorized
        case .notDetermined:
            let granted = await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .video) { granted in
                    continuation.resume(returning: granted)
                }
            }
            return granted ? .authorized : .denied
        case .denied, .restricted:
            return .denied
        @unknown default:
            return .unavailable
        }
    }

    /// Both an automatic presentation and a retry use one owned task. The
    /// generation is captured before dispatch, not when the task eventually runs.
    @discardableResult
    func scheduleStart() -> Task<Void, Never>? {
        guard !presentationClosed else { return nil }
        scheduledStart?.cancel()
        let ticket = UUID()
        schedulingGeneration = ticket
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            guard !Task.isCancelled, !self.presentationClosed,
                  self.schedulingGeneration == ticket else { return }
            await self.start()
            if self.schedulingGeneration == ticket { self.scheduledStart = nil }
        }
        scheduledStart = task
        return task
    }

    func scheduleStartIfNeeded() {
        guard !started, scheduledStart == nil, !presentationClosed else { return }
        _ = scheduleStart()
    }

    func closePresentation() {
        presentationClosed = true
        stop()
    }

    func start() async {
        guard !presentationClosed, !Task.isCancelled else { return }
        guard admissionValid() else {
            state = .unavailable(text("相机暂不可用，请重试。", "Camera unavailable. Try again."))
            return
        }
        guard !started else { return }
        let run = UUID()
        generation = run
        started = true
        latestResult = nil
        state = .checking
        guard hasUsageDescription else {
            state = .unavailable(text("此版本尚未声明相机用途，请先在 Mac 宿主中加入相机用途说明。",
                                      "This build does not declare camera usage. Add NSCameraUsageDescription to the host before enabling camera scanning."))
            return
        }
        awaitingPermission = true
        let authorization = await authorize()
        guard started, generation == run else { return }
        guard !Task.isCancelled, !presentationClosed, admissionValid() else { stop(); return }
        awaitingPermission = false
        switch authorization {
        case .authorized:
            await configure(run: run)
        case .denied:
            state = .denied
        case .unavailable:
            state = .unavailable(text("此版本无法使用相机。", "Camera access is not available in this build."))
        }
    }

    func stop() {
        // Fence both permission completions and already queued metadata
        // callbacks before releasing the controller.
        generation = UUID()
        schedulingGeneration = UUID()
        scheduledStart?.cancel()
        scheduledStart = nil
        started = false
        awaitingPermission = false
        latestResult = nil
        let previousController = controller
        controller = nil
        previousController?.stop()
        state = .unavailable(text("相机已停止，点按重试以继续。", "Camera stopped. Select Try again to continue."))
    }

    /// The run identity survives publication and is checked again immediately
    /// before the UI hands the value to the QR work model.
    func mayDeliverResult(_ result: MacQRCameraResult) -> Bool {
        started && !presentationClosed && admissionValid() &&
            generation == result.run && latestResult == result
    }

    private func configure(run: UUID) async {
        guard started, generation == run else { return }
        guard !presentationClosed, !Task.isCancelled, admissionValid() else { stop(); return }
        do {
            let controller = try makeController({ [weak self] value in
                Task { @MainActor in
                    guard let self, self.started, self.generation == run,
                          !self.presentationClosed, self.admissionValid(),
                          self.latestResult == nil else { return }
                    self.latestResult = MacQRCameraResult(code: value, run: run)
                }
            })
            self.controller = controller
            controller.onStopped = { [weak self] in
                guard let self, self.started, self.generation == run else { return }
                self.generation = UUID()
                self.started = false
                self.latestResult = nil
                self.controller?.stop()
                self.controller = nil
                self.state = .failed(self.text("相机已中断，请重试。", "Camera interrupted. Try again."))
            }
            let running = await controller.start()
            guard started, generation == run else { return }
            guard !presentationClosed, !Task.isCancelled, admissionValid() else { stop(); return }
            if running {
                state = .ready
            } else {
                controller.stop()
                self.controller = nil
                state = .failed(text("相机不可用或正在被其他工具使用。", "The camera is unavailable or in use by another tool."))
            }
        } catch MacQRCameraError.noCamera {
            state = .unavailable(text("这台 Mac 没有可用相机。", "No camera is available on this Mac."))
        } catch MacQRCameraError.noQRSupport {
            state = .unavailable(text("可用相机不支持二维码识别。", "The available camera does not support QR metadata."))
        } catch {
            state = .failed(text("无法启动相机。请关闭其他相机应用后重试。",
                                 "The camera could not be started. Close other camera apps and try again."))
        }
    }
}

struct MacQRCameraSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    let onResult: (String) -> Void
    private let presentation: MacQRPresentationGate
    private let presentationTicket: UUID?
    @StateObject private var model: MacQRCameraModel
    @State private var finished = false
    @State private var windowReference = MacQRWindowReference()

    init(mediaEnvironment: MacToolboxMediaEnvironment, presentation: MacQRPresentationGate,
         onResult: @escaping (String) -> Void) {
        self.onResult = onResult
        self.presentation = presentation
        let presentationTicket = presentation.ticket
        self.presentationTicket = presentationTicket
        let reference = MacQRWindowReference()
        let registry = mediaEnvironment.cameraRegistry
        let ticket = registry.makeCameraAdmissionTicket()
        _windowReference = State(initialValue: reference)
        let mayCapture: @MainActor () -> Bool = {
            guard let ticket else { return false }
            return presentation.isCurrent(presentationTicket) &&
                registry.isCameraAdmissionCurrent(ticket) && reference.canCapture
        }
        let model = MacQRCameraModel(admissionValid: mayCapture, makeController: {
            MacQRCaptureAdapter(environment: mediaEnvironment, canCapture: mayCapture, onCode: $0)
        })
        reference.onWindowAvailable = { [weak model] in model?.scheduleStartIfNeeded() }
        _model = StateObject(wrappedValue: model)
    }

    private func t(_ zh: String, _ en: String) -> String {
        MacToolboxText.t(zh, en, locale)
    }

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Label(t("扫描二维码", "Scan QR code"), systemImage: "camera")
                    .font(.title2.weight(.semibold))
                Spacer()
                Button(t("取消", "Cancel")) { close() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("mac.toolbox.qr.camera.cancel")
            }
            Group {
                switch model.state {
                case .checking:
                    ProgressView(t("正在启动相机…", "Starting camera…"))
                case .denied:
                    VStack(spacing: 12) {
                        Label(t("需要相机权限", "Camera access needed"), systemImage: "camera.fill")
                            .font(.headline)
                        Text(t("允许 Floe 使用相机后即可扫描，也可以取消并选择图片识别。",
                               "Allow Floe to use the camera, or cancel and choose an image instead."))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        Button(t("打开相机设置", "Open Camera Settings")) {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .accessibilityIdentifier("mac.toolbox.qr.camera.settings")
                    }
                case .unavailable(let message):
                    VStack(spacing: 12) {
                        Label(t("相机不可用", "Camera unavailable"), systemImage: "camera")
                            .font(.headline)
                        Text(message)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        Button(t("重试", "Try again")) {
                            model.stop()
                            startCamera()
                        }
                    }
                    .accessibilityIdentifier("mac.toolbox.qr.camera.unavailable")
                case .failed(let message):
                    VStack(spacing: 12) {
                        Label(t("无法启动相机", "Unable to start camera"), systemImage: "exclamationmark.triangle")
                            .font(.headline)
                        Text(message)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        Button(t("重试", "Try again")) {
                            model.stop()
                            startCamera()
                        }
                    }
                case .ready:
                    if let session = model.session {
                        MacQRCameraPreview(session: session)
                            .frame(minWidth: 480, minHeight: 360)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .accessibilityLabel(t("相机预览，对准二维码", "Camera preview. Point at a QR code."))
                            .accessibilityIdentifier("mac.toolbox.qr.camera.preview")
                        Text(t("将二维码放入画面，识别后会自动返回。",
                               "Place the QR code in view. The result returns automatically."))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        ProgressView(t("正在启动相机…", "Starting camera…"))
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(24)
        .frame(width: 620, height: 560)
        .background(MacQRWindowTracker(reference: windowReference))
        .task { if windowReference.canCapture { model.scheduleStartIfNeeded() } }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didMiniaturizeNotification)) { notification in
            if windowReference.contains(notification) { model.stop() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { notification in
            if windowReference.contains(notification) {
                presentation.close(ifCurrent: presentationTicket)
                model.closePresentation()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            if !model.awaitingPermission { model.stop() }
        }
        .onChange(of: model.latestResult) { _, result in
            guard !finished, let result, model.mayDeliverResult(result) else { return }
            finished = true
            presentation.close(ifCurrent: presentationTicket)
            model.closePresentation()
            onResult(result.code)
            dismiss()
        }
        .onDisappear {
            finished = true
            presentation.close(ifCurrent: presentationTicket)
            model.closePresentation()
        }
    }

    private func close() {
        finished = true
        presentation.close(ifCurrent: presentationTicket)
        model.closePresentation()
        dismiss()
    }

    private func startCamera() {
        _ = model.scheduleStart()
    }
}

private struct MacQRCameraPreview: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> MacQRCameraPreviewView {
        MacQRCameraPreviewView(session: session)
    }

    func updateNSView(_ nsView: MacQRCameraPreviewView, context: Context) {}
}

private final class MacQRCameraPreviewView: NSView {
    private let previewLayer: AVCaptureVideoPreviewLayer

    init(session: AVCaptureSession) {
        previewLayer = AVCaptureVideoPreviewLayer(session: session)
        super.init(frame: .zero)
        wantsLayer = true
        previewLayer.videoGravity = .resizeAspectFill
        layer = previewLayer
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        previewLayer.frame = bounds
    }
}

@MainActor
final class MacQRWindowReference {
    weak var window: NSWindow?
    var onWindowAvailable: (@MainActor () -> Void)?
    var canCapture: Bool {
        guard NSApp.isActive, let window, window.isVisible, !window.isMiniaturized else { return false }
        guard let parent = window.sheetParent else { return true }
        return parent.isVisible && !parent.isMiniaturized
    }
    func contains(_ notification: Notification) -> Bool {
        guard let window, let sender = notification.object as? NSWindow else { return false }
        return Self.owns(window, parent: window.sheetParent, sender: sender)
    }
    static func owns(_ window: AnyObject?, parent: AnyObject?, sender: AnyObject?) -> Bool {
        guard let window, let sender else { return false }
        return window === sender || parent === sender
    }
}

private struct MacQRWindowTracker: NSViewRepresentable {
    let reference: MacQRWindowReference
    func makeNSView(context: Context) -> MacQRWindowTrackingView {
        let view = MacQRWindowTrackingView()
        view.reference = reference
        return view
    }
    func updateNSView(_ view: MacQRWindowTrackingView, context: Context) {
        view.reference = reference
        reference.window = view.window
    }
}

@MainActor
private final class MacQRWindowTrackingView: NSView {
    weak var reference: MacQRWindowReference?
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        reference?.window = window
        if window != nil { reference?.onWindowAvailable?() }
    }
}
