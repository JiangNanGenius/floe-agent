import SwiftUI
import FloeToolboxUtilities

#if os(iOS)
import UIKit
import ARKit
import RealityKit

/// AR measurement workbench: real world-tracked plane raycasts, polyline
/// length and single-plane polygon area. Camera starts only from the
/// explicit Start control and always stops on exit or scene background.
public struct ToolboxSpatialMeasurementView: View {
    @StateObject private var session = SpatialMeasurementSession()
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.locale) private var locale
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var unit: SpatialMeasurementUnit

    public init() {
        _unit = State(initialValue: SpatialMeasurementUnit.default(metric: Locale.current.measurementSystem == .metric))
    }

    private func t(_ zh: String, _ en: String) -> String { workbenchText(zh, en, locale) }

    public var body: some View {
        GeometryReader { geometry in
            let wide = geometry.size.width >= 760 && !typeSize.isAccessibilitySize
            let layout = wide
                ? AnyLayout(HStackLayout(alignment: .top, spacing: 0))
                : AnyLayout(VStackLayout(spacing: 0))
            // Keep the camera subtree's identity when rotating or resizing;
            // replacing its ARView would also replace its world coordinate frame.
            layout {
                VStack(spacing: 0) { topBar; cameraArea; controlBar }
                if wide { Divider() }
                ScrollView {
                    readoutPanel.padding(wide ? 20 : 16)
                }
                .frame(width: wide ? 320 : nil)
                .frame(maxHeight: wide ? .infinity : min(180, geometry.size.height * 0.25))
                .background(.background.secondary)
            }
        }
        .background(.background)
        .navigationTitle(t("AR 测量", "AR Measure"))
        .onAppear { session.unit = unit; session.sceneBecameActive() }
        .onChange(of: unit) { _, value in session.unit = value }
        .onChange(of: scenePhase) { _, phase in
            if phase == .inactive || phase == .background {
                session.sceneBecameInactive(fullyBackground: phase == .background)
            } else if phase == .active {
                session.sceneBecameActive()
            }
        }
        .onDisappear { session.stop() }
    }

    // MARK: - Chrome

    private var topBar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                Label(statusText, systemImage: statusSymbol).font(.subheadline)
                Spacer(minLength: 8)
                snapshotControls
                Button(role: .destructive) { session.stop() } label: {
                    Text(t("停止", "Stop")).frame(minHeight: 44)
                }.disabled(session.phase != .running && session.phase != .paused && !session.isStarting)
                    .accessibilityIdentifier("toolbox.measure.stop")
            }
            VStack(alignment: .leading, spacing: 4) {
                Label(statusText, systemImage: statusSymbol).font(.subheadline)
                HStack(spacing: 12) {
                    snapshotControls
                    Spacer(minLength: 4)
                    Button(role: .destructive) { session.stop() } label: {
                        Text(t("停止", "Stop")).frame(minHeight: 44)
                    }.disabled(session.phase != .running && session.phase != .paused && !session.isStarting)
                        .accessibilityIdentifier("toolbox.measure.stop")
                }
            }
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 44)
        .background(.bar)
    }

    @ViewBuilder private var snapshotControls: some View {
        Button {
            Task { await session.captureSnapshot(summary: accessibilitySummary + "\n" + t("近似测量", "Approximate measurement")) }
        } label: {
            Image(systemName: "camera").frame(width: 44, height: 44)
        }
        .disabled((session.phase != .running && session.phase != .paused) || session.samples.count < 2)
        .accessibilityLabel(t("拍摄测量快照", "Capture measurement snapshot"))
        if let image = session.snapshotImage {
            ShareLink(item: Image(uiImage: image),
                      preview: SharePreview(t("测量结果", "Measurement result"), image: Image(uiImage: image))) {
                Image(systemName: "square.and.arrow.up").frame(width: 44, height: 44)
            }.accessibilityLabel(t("分享测量结果", "Share measurement result"))
        }
    }

    private var controlBar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                modePicker
                unitMenu
                Spacer(minLength: 8)
                editControls
                addButton
            }
            VStack(spacing: 8) {
                HStack(spacing: 12) { modePicker; unitMenu; Spacer(minLength: 4) }
                HStack(spacing: 12) { editControls; addButton }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var modePicker: some View {
        Picker(t("测量方式", "Mode"), selection: Binding(get: { session.mode }, set: { session.setMode($0) })) {
            Text(t("长度", "Length")).tag(SpatialMeasurementSession.Mode.length)
            Text(t("面积", "Area")).tag(SpatialMeasurementSession.Mode.area)
        }
        .pickerStyle(.segmented)
        .frame(width: 180)
        .accessibilityIdentifier("toolbox.measure.mode")
    }

    private var unitMenu: some View {
        Menu {
            Picker(t("单位", "Units"), selection: $unit) {
                ForEach(SpatialMeasurementUnit.allCases, id: \.self) { option in
                    Text(unitTitle(option)).tag(option)
                }
            }
        } label: {
            Text(unit.symbol).frame(minHeight: 44).frame(minWidth: 44)
        }
        .accessibilityIdentifier("toolbox.measure.unit")
    }

    @ViewBuilder private var editControls: some View {
        Button { session.undo() } label: {
            Image(systemName: "arrow.uturn.backward").frame(width: 44, height: 44)
        }
        .disabled(session.samples.isEmpty)
        .accessibilityLabel(session.polygonClosed ? t("重新打开图形", "Reopen shape") : t("撤销上一点", "Undo last point"))
        .accessibilityIdentifier("toolbox.measure.undo")
        Button { session.clear() } label: {
            Image(systemName: "trash").frame(width: 44, height: 44)
        }
        .disabled(session.samples.isEmpty)
        .accessibilityLabel(t("清除全部点", "Clear all points"))
        .accessibilityIdentifier("toolbox.measure.clear")
        if session.mode == .area {
            Button { session.closePolygon() } label: {
                Image(systemName: session.polygonClosed ? "checkmark.circle.fill" : "checkmark.circle")
                    .frame(width: 44, height: 44)
            }
            .disabled(!session.readout.canClose)
            .accessibilityLabel(t("闭合图形", "Close shape"))
            .accessibilityIdentifier("toolbox.measure.close")
        }
    }

    private var addButton: some View {
        Button { session.placePoint() } label: {
            Label(t("添加点", "Add point"), systemImage: "plus.viewfinder")
                .frame(minHeight: 44)
        }
        .buttonStyle(.borderedProminent)
        .disabled(!session.canPlacePoint)
        .accessibilityIdentifier("toolbox.measure.add")
    }

    // MARK: - Camera area

    @ViewBuilder private var cameraArea: some View {
        switch session.phase {
        case .running, .paused:
            ZStack {
                SpatialMeasurementARContainer(session: session)
                    .clipped()
                    .accessibilityHidden(true)
                reticle
                labelsOverlay
                if session.phase == .running {
                    planeHint
                }
                if session.phase == .paused {
                    pausedOverlay
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(cameraSummary)
        case .idle:
            placeholder(symbol: "ruler",
                        title: t("AR 测量", "AR Measure"),
                        description: t("对准表面后添加点，也可轻点画面选点。面积需沿同一平面逐个选择边角，再闭合图形。结果为近似值。", "Aim at a surface and add points, or tap the camera image. For area, select corners in order on one plane, then close the shape. Results are approximate.")) {
                if session.isStarting { ProgressView(t("正在准备相机", "Preparing camera")) }
                Button { session.requestStart() } label: {
                    Label(t("开始测量", "Start measuring"), systemImage: "play.fill")
                        .frame(minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .disabled(session.isStarting)
                .accessibilityIdentifier("toolbox.measure.start")
            }
        case .denied:
            placeholder(symbol: "camera.fill",
                        title: t("没有相机权限", "No camera access"),
                        description: t("AR 测量需要相机权限来识别平面。", "AR Measure needs camera access to detect surfaces.")) {
                Button { openSettings() } label: {
                    Text(t("打开设置", "Open Settings")).frame(minHeight: 44)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("toolbox.measure.settings")
            }
        case .unavailable:
            placeholder(symbol: "ruler",
                        title: t("此设备不支持", "Not supported on this device"),
                        description: t("此设备无法使用 AR 世界追踪。需要支持 ARKit 的 iPhone 或 iPad。", "AR world tracking is unavailable here. Use an ARKit-capable iPhone or iPad."))
        case .cameraBusy:
            placeholder(symbol: "camera",
                        title: t("相机正在使用中", "Camera in use"),
                        description: t("请先关闭其他相机工具或窗口，再重试。", "Close the other camera tool or window, then try again.")) {
                Button(t("重试", "Try Again")) { session.requestStart() }.frame(minHeight: 44)
                    .accessibilityIdentifier("toolbox.measure.retry")
            }
        case .failed(let message):
            placeholder(symbol: "exclamationmark.triangle",
                        title: t("无法启动测量", "Unable to start"),
                        description: message) {
                Button { session.requestStart() } label: {
                    Text(t("重试", "Try Again")).frame(minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("toolbox.measure.retry")
            }
        }
    }

    private func placeholder(symbol: String, title: String, description: String) -> some View {
        placeholder(symbol: symbol, title: title, description: description) { EmptyView() }
    }

    private func placeholder<Actions: View>(symbol: String, title: String, description: String,
                                            @ViewBuilder actions: () -> Actions) -> some View {
        VStack(spacing: 16) {
            ContentUnavailableView(title, systemImage: symbol, description: Text(description))
            actions()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }

    private var reticle: some View {
        ZStack {
            Circle().stroke(reticleColor, lineWidth: 2).frame(width: 26, height: 26)
            Circle().fill(reticleColor).frame(width: 3, height: 3)
        }
        .shadow(color: .black.opacity(0.45), radius: 1)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var reticleColor: Color {
        switch session.target {
        case .ready(let estimated): estimated ? .yellow : .green
        case .blocked: .orange
        case .unavailable, .searching: .white
        }
    }

    private var planeHint: some View {
        VStack {
            Spacer()
            Text(targetHint)
                .font(.subheadline)
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .multilineTextAlignment(.center)
                .background(Color.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal, 12)
                .padding(.bottom, 16)
                .accessibilityIdentifier("toolbox.measure.target")
        }
        .allowsHitTesting(false)
    }

    private var labelsOverlay: some View {
        ForEach(session.labels) { label in
            Text(label.text)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.white)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Color.black.opacity(0.5), in: Capsule())
                .position(label.position)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    private var pausedOverlay: some View {
        ZStack {
            Color.black.opacity(0.4)
            VStack(spacing: 12) {
                Text(t("已暂停", "Paused")).font(.headline).foregroundStyle(.white)
                Button { session.resume() } label: {
                    Text(session.isStarting ? t("正在恢复", "Resuming") : t("继续", "Resume")).frame(minWidth: 120, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .disabled(session.isStarting)
                .accessibilityIdentifier("toolbox.measure.resume")
            }
        }
        .allowsHitTesting(true)
    }

    // MARK: - Readout

    private var readoutPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            GroupBox(t("状态", "Status")) {
                VStack(alignment: .leading, spacing: 8) {
                    LabeledContent(t("追踪", "Tracking")) { Text(statusText) }
                    LabeledContent(t("平面", "Surface")) {
                        Text(session.hasDetectedPlane ? t("已识别", "Detected") : t("未识别", "None yet"))
                    }
                    Text(t("结果为近似值，精度取决于光线与表面纹理。", "Results are approximate and depend on lighting and surface texture."))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
            GroupBox(session.mode == .length ? t("长度", "Length") : t("面积", "Area")) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(primaryValue).font(.title2.monospacedDigit())
                        Spacer()
                        Text(t("共 \(session.samples.count) 点", "\(session.samples.count) points"))
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    if session.mode == .area {
                        LabeledContent(session.polygonClosed ? t("周长", "Perimeter") : t("已描长度", "Drawn length")) {
                            Text(unit.format(session.readout.totalLength)).monospacedDigit()
                        }
                    } else if !session.readout.segmentLengths.isEmpty {
                        Divider()
                        ForEach(Array(session.readout.segmentLengths.enumerated()), id: \.offset) { index, length in
                            LabeledContent(t("段 \(index + 1)", "Segment \(index + 1)")) {
                                Text(unit.format(length)).monospacedDigit()
                            }
                        }
                        Divider()
                        LabeledContent(t("总长度", "Total")) {
                            Text(unit.format(session.readout.totalLength)).monospacedDigit()
                        }
                    }
                    if session.mode == .area, session.polygonClosed {
                        Label(t("图形已闭合", "Shape closed"), systemImage: "checkmark.circle.fill")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }
            if let issue = session.readout.issue {
                Label(issueText(issue), systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("toolbox.measure.issue")
            }
            Text(accessibilitySummary)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .accessibilityHidden(false)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var primaryValue: String {
        if session.mode == .area {
            return session.readout.area.map(unit.areaFormat) ?? "—"
        }
        guard session.samples.count >= 2 else { return "—" }
        return unit.format(session.readout.totalLength)
    }

    private var primaryAccessibilityValue: String {
        if session.mode == .area {
            return session.readout.area.map(unit.areaAccessibilityFormat) ?? t("面积未完成", "Area not completed")
        }
        guard session.samples.count >= 2 else { return t("长度未完成", "Length not completed") }
        return unit.accessibilityFormat(session.readout.totalLength)
    }

    private var cameraSummary: String {
        switch session.phase {
        case .running, .paused:
            return accessibilitySummary
        default:
            return t("相机未启动", "Camera is off")
        }
    }

    private var accessibilitySummary: String {
        let count = session.samples.count
        if session.mode == .area, session.readout.area != nil {
            if session.polygonClosed {
                return t("已测量 \(count) 个点，面积 \(primaryAccessibilityValue)，周长 \(unit.accessibilityFormat(session.readout.totalLength))", "\(count) points measured, area \(primaryAccessibilityValue), perimeter \(unit.accessibilityFormat(session.readout.totalLength))")
            }
            return t("已放置 \(count) 个点，预览面积 \(primaryAccessibilityValue)，请闭合图形。", "\(count) points placed, preview area \(primaryAccessibilityValue). Close the shape to finish.")
        }
        if session.mode == .area { return t("已放置 \(count) 个点，请在同一平面上选择至少三个边角。", "\(count) points placed. Select at least three corners on the same surface.") }
        if count < 2 { return t("已放置 \(count) 个点，请添加下一点测量长度。", "\(count) points placed. Add another point to measure length.") }
        return t("已测量 \(count) 个点，总长度 \(primaryAccessibilityValue)", "\(count) points measured, total length \(primaryAccessibilityValue)")
    }

    // MARK: - Copy

    private var statusText: String {
        switch session.phase {
        case .idle: return session.isStarting ? t("正在准备相机", "Preparing camera") : t("尚未开始", "Not started")
        case .paused: return t("已暂停", "Paused")
        case .denied: return t("没有相机权限", "No camera access")
        case .unavailable: return t("此设备不支持", "Not supported here")
        case .cameraBusy: return t("相机正在使用中", "Camera in use")
        case .failed: return t("会话已停止", "Session stopped")
        case .running: break
        }
        switch session.tracking {
        case .normal:
            return session.canPlacePoint ? t("可以添加点", "Ready to add a point") : t("对准表面", "Aim at a surface")
        case .initializing:
            return t("正在初始化", "Initializing")
        case .limited(let reason):
            switch reason {
            case "excessiveMotion": return t("移动过快", "Moving too fast")
            case "insufficientFeatures": return t("缺少特征点", "Not enough detail")
            case "relocalizing": return t("正在重新定位", "Relocalizing")
            default: return t("追踪受限", "Tracking limited")
            }
        case .notAvailable:
            return t("追踪不可用", "Tracking unavailable")
        }
    }

    private var targetHint: String {
        if session.polygonClosed { return t("图形已闭合，可撤销闭合或清除后重新测量。", "Shape closed. Reopen it with Undo, or clear to measure again.") }
        switch session.tracking {
        case .initializing: return t("缓慢移动设备，保持表面在画面中", "Move slowly and keep the surface in view")
        case .notAvailable: return t("追踪暂时不可用，请保持相机无遮挡", "Tracking is unavailable. Keep the camera unobstructed")
        case .limited(let reason):
            if reason == "relocalizing" { return t("回到暂停前的位置；无法恢复时可停止后重新开始", "Return to the previous location, or stop and start again") }
            return t("缓慢移动，对准光线充足、有纹理的表面", "Move slowly toward a well-lit, textured surface")
        case .normal: break
        }
        switch session.target {
        case .ready(let estimated):
            if estimated { return t("已找到估计表面，可添加长度点；结果为近似值", "Estimated surface found. Add a length point; the result is approximate") }
            return t("准星已对准平面，添加点或轻点画面选点", "Surface ready. Add a point or tap the camera image")
        case .blocked(let issue): return issueText(issue)
        case .searching, .unavailable:
            return session.mode == .area
                ? t("将准星对准已识别平面，按边角顺序选点", "Aim at a detected surface and select corners in order")
                : t("缓慢移动设备，将准星对准表面", "Move slowly and aim the reticle at a surface")
        }
    }

    private var statusSymbol: String {
        switch session.tracking {
        case .normal: return session.hasDetectedPlane ? "checkmark.circle.fill" : "viewfinder"
        case .initializing: return "hourglass"
        case .limited: return "exclamationmark.triangle.fill"
        case .notAvailable: return "xmark.circle"
        }
    }

    private func unitTitle(_ option: SpatialMeasurementUnit) -> String {
        switch option {
        case .millimeter: return t("毫米", "Millimeters")
        case .centimeter: return t("厘米", "Centimeters")
        case .meter: return t("米", "Meters")
        case .inch: return t("英寸", "Inches")
        case .foot: return t("英尺", "Feet")
        }
    }

    private func issueText(_ issue: SpatialMeasurementSession.Issue) -> String {
        switch issue {
        case .noSurface:
            return t("未检测到平面：请先将准星对准已识别的平面。", "No surface detected. Aim the reticle at a detected plane first.")
        case .mixedPlanes:
            return t("面积需要在同一个平面上测量。", "Area must be measured on a single plane.")
        case .notCoplanar:
            return t("这些点不在同一平面上。", "These points are not on the same plane.")
        case .selfIntersecting:
            return t("图形自相交，请撤销后重新选点。", "The shape crosses itself. Undo and pick points again.")
        case .degenerate:
            return t("请移动到下一个边角，避免重复点或同一直线。", "Move to the next corner. Avoid duplicate or collinear points.")
        case .invalidPoint:
            return t("此位置不可靠，请重新对准表面。", "This position is unreliable. Aim at the surface again.")
        case .pointLimit:
            return t("已达到 64 个点，请完成或清除后重新测量。", "The 64-point limit is reached. Finish, or clear to measure again.")
        }
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString),
              UIApplication.shared.canOpenURL(url) else { return }
        UIApplication.shared.open(url)
    }
}

@MainActor private struct SpatialMeasurementARContainer: UIViewRepresentable {
    let session: SpatialMeasurementSession

    func makeCoordinator() -> Coordinator { Coordinator(session: session) }

    func makeUIView(context: Context) -> ARView {
        let view = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)
        view.addGestureRecognizer(UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tap(_:))))
        session.attach(view)
        return view
    }

    func updateUIView(_ uiView: ARView, context: Context) {
        session.attach(uiView)
    }

    static func dismantleUIView(_ uiView: ARView, coordinator: Coordinator) {
        coordinator.session.detach(uiView)
    }

    @MainActor final class Coordinator: NSObject {
        let session: SpatialMeasurementSession
        init(session: SpatialMeasurementSession) { self.session = session }
        @objc func tap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended, let view = recognizer.view else { return }
            session.placePoint(at: recognizer.location(in: view))
        }
    }
}

#else

public struct ToolboxSpatialMeasurementView: View {
    public init() {}

    public var body: some View {
        ContentUnavailableView("AR Measure",
                               systemImage: "ruler",
                               description: Text("AR measurement requires a world-tracking capable iPhone or iPad."))
    }
}

#endif
