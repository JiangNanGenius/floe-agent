// FloeApp — the user-visible in-app browser and takeover surface.

#if canImport(SwiftUI) && canImport(WebKit) && canImport(UIKit)
import SwiftUI
import WebKit

struct BrowserView: View {
    @ObservedObject var center: BrowserSessionCenter
    var previewInteractionID: UUID? = nil
    var expectedSession: BrowserTaskSession? = nil
    var onClose: (() -> Void)? = nil
    @State private var expanded = false

    var body: some View {
        Group {
            if expanded { Color.clear }
            else {
                surface
            }
        }
        .fullScreenCover(isPresented: $expanded) {
            surface
        }
        .task(id: center.conversationID) { await center.recoverHandoff() }
        .navigationTitle("browser.title")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder private var surface: some View {
        if center.previewInteractionID == previewInteractionID,
           expectedSession == nil || center.visibleSession === expectedSession {
            BrowserSurfaceRoot(center: center, expanded: $expanded, interactionID: previewInteractionID, onClose: closeAction)
        }
    }

    private var closeAction: (() -> Void)? {
        if let onClose {
            return { expanded = false; onClose() }
        }
        return expanded ? { expanded = false } : nil
    }
}

extension EnvironmentValues {
    @Entry var showsComposerBrowserPreview = true
    @Entry fileprivate var browserPreviewPresentation: BrowserPreviewPresentation? = nil
}

private final class BrowserPreviewPanel: Identifiable, Sendable {
    enum Mode: Sendable { case watching, interacting }
    let id = UUID()
    let mode: Mode
    let session: BrowserTaskSession
    private let center: BrowserSessionCenter

    init(mode: Mode, session: BrowserTaskSession, center: BrowserSessionCenter) {
        self.mode = mode
        self.session = session
        self.center = center
    }

    deinit {
        // A removed window can discard its presentation state without a binding change.
        // Covering the sheet or backgrounding the scene keeps this same token alive.
        if mode == .interacting {
            Task { @MainActor [center = self.center, id = self.id] in center.closePreviewInteraction(id) }
        }
    }
}

private struct BrowserPreviewPresentation: Sendable {
    let panelID: UUID?
    let open: @MainActor @Sendable (BrowserPreviewPanel.Mode, BrowserTaskSession, BrowserPreviewPageIdentity?, BrowserControlLease?) -> Void
}

extension View {
    func browserPreviewPresenter(center: BrowserSessionCenter, owner: UUID?) -> some View {
        modifier(BrowserPreviewPresenter(center: center, owner: owner))
    }
}

/// The original task surface keeps the sheet when keyboard or window geometry moves its buttons.
private struct BrowserPreviewPresenter: ViewModifier {
    let center: BrowserSessionCenter
    let owner: UUID?
    @State private var panel: BrowserPreviewPanel?

    func body(content: Content) -> some View {
        content
            .environment(\.browserPreviewPresentation, BrowserPreviewPresentation(panelID: panel?.id, open: open))
            .sheet(item: $panel) { shown in
                BrowserLivePreviewSheet(center: center, session: shown.session, panel: shown) {
                    if panel?.id == shown.id { panel = nil }
                }
            }
            .onChange(of: owner) { _, next in
                if let panel, panel.session.conversationID != next { self.panel = nil }
            }
            .onChange(of: panel?.id) { old, _ in
                if let old { center.closePreviewInteraction(old) }
            }
    }

    private func open(_ mode: BrowserPreviewPanel.Mode, session: BrowserTaskSession, page: BrowserPreviewPageIdentity?, lease: BrowserControlLease?) {
        guard panel == nil, owner == session.conversationID, !session.isReleased,
              center.session(for: session.conversationID) === session else { return }
        let request = BrowserPreviewPanel(mode: mode, session: session, center: center)
        switch mode {
        case .watching:
            guard session.isModelActive else { return }
        case .interacting:
            guard center.openPreviewInteraction(session: session, page: page, displayedLease: lease, presentationID: request.id) else { return }
        }
        panel = request
    }
}

/// Resolving a spectator never creates a session, binds the browser, or changes a file route.
struct TaskBrowserLivePreview: View {
    @ObservedObject var center: BrowserSessionCenter
    let conversationID: UUID
    let inlineImage: Bool

    var body: some View {
        if center.taskHandoffsEnabled {
            if let session = center.session(for: conversationID) {
                BrowserLivePreviewControls(center: center, session: session, inlineImage: inlineImage)
                    .id(session.sessionID)
            }
            BrowserReturnedHandoffStatus(center: center, owner: conversationID)
        }
    }
}

private struct BrowserReturnedHandoffStatus: View {
    @ObservedObject var center: BrowserSessionCenter
    let owner: UUID

    private var receipt: BrowserSessionCenter.Handoff? {
        guard let event = center.handoff(for: owner), event.conversationID == owner,
              center.session(for: owner)?.isUserControlling != true,
              center.session(for: owner)?.modelControl == nil else { return nil }
        if event.closedAfterRestart == true { return event }
        guard event.returning, center.conversationID == owner, center.handoff?.id == event.id,
              center.handoffNeedsContinue, !center.returningControl else { return nil }
        return event
    }

    var body: some View {
        if let event = receipt {
            Text(event.closedAfterRestart == true
                ? IDELanguageRunText.t("上次打开的网页已关闭。请返回原任务查看。", "The previous browser page closed. Check the original task.")
                : IDELanguageRunText.t("网页已交还，原任务未运行。请返回原任务查看。", "The browser was returned. The original task is not running. Check the original task."))
                .font(.caption).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.vertical, 4)
                .accessibilityIdentifier("browser.handoff.taskStatus")
        }
    }
}

private struct BrowserLivePreviewControls: View {
    @ObservedObject var center: BrowserSessionCenter
    @ObservedObject var session: BrowserTaskSession
    let inlineImage: Bool
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.browserPreviewPresentation) private var presentation
    @State private var observer = UUID()
    @State private var onScreen = false
    @State private var collapsed = false

    private var shouldSample: Bool {
        scenePhase == .active && session.isModelActive && onScreen && inlineImage && !collapsed && presentation?.panelID == nil
    }

    private var isActive: Bool { session.lastModelActivity != nil || session.isUserControlling }

    var body: some View {
        let page = session.previewPageIdentity
        let lease = session.modelControl
        VStack(spacing: 0) {
            if isActive {
                Divider()
                HStack(spacing: 8) {
                    Image(systemName: session.isUserControlling ? "hand.raised" : "safari")
                        .foregroundStyle(.secondary).accessibilityHidden(true)
                    Text(session.livePreviewStatus(in: center)).font(.caption).lineLimit(2)
                    Spacer(minLength: 0)
                    if session.isModelActive {
                        Button { presentation?.open(.watching, session, page, lease) } label: {
                            Image(systemName: "arrow.up.left.and.arrow.down.right").frame(minWidth: 44, minHeight: 44)
                        }
                        .accessibilityLabel(IDELanguageRunText.t("放大观看", "Enlarge preview"))
                        .accessibilityIdentifier("browser.live.watch")
                        if inlineImage {
                            Button { collapsed.toggle() } label: {
                                Image(systemName: collapsed ? "chevron.down" : "chevron.up").frame(minWidth: 44, minHeight: 44)
                            }
                            .accessibilityLabel(collapsed ? IDELanguageRunText.t("展开预览", "Show preview") : IDELanguageRunText.t("收起预览", "Collapse preview"))
                            .accessibilityIdentifier("browser.live.collapse")
                        }
                    }
                    if session.isUserControlling, let receipt = center.handoff(for: session.conversationID),
                       receipt.humanPresent, center.visibleSession === session {
                        Button(IDELanguageRunText.t("交还给 AI", "Return to AI")) {
                            Task { _ = await center.returnControlIfCurrent(for: session, handoffID: receipt.id) }
                        }
                        .font(.caption.weight(.semibold)).frame(minHeight: 44)
                        .disabled(session.takeoverPending || center.returningControl)
                        .accessibilityIdentifier("browser.live.return")
                    }
                    Button {
                        presentation?.open(.interacting, session, page, lease)
                    } label: {
                        Text(session.isUserControlling ? IDELanguageRunText.t("去操作", "Open browser") : IDELanguageRunText.t("我来操作", "Take over"))
                            .font(.caption.weight(.semibold)).frame(minHeight: 44)
                    }
                    .accessibilityIdentifier("browser.live.takeover")
                }
                .padding(.horizontal, 10)
                .disabled(center.visibleSession === session && (center.returningControl || session.returningToModel))
                .accessibilityElement(children: .contain)
                if shouldSample, let frame = session.livePreviewFrame {
                    BrowserLivePreviewImage(frame: frame)
                        .frame(maxHeight: 132)
                        .padding(.bottom, 6)
                }
            }
        }
        .background(.bar)
        .onAppear { onScreen = true }
        .onDisappear {
            onScreen = false
            session.setLivePreviewObservation(observer, visible: false)
        }
        .onChange(of: shouldSample, initial: true) { _, visible in
            session.setLivePreviewObservation(observer, visible: visible)
        }
    }
}

private struct BrowserLivePreviewSheet: View {
    @ObservedObject var center: BrowserSessionCenter
    @ObservedObject var session: BrowserTaskSession
    let panel: BrowserPreviewPanel
    let close: () -> Void
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            Group {
                switch panel.mode {
                case .interacting:
                    BrowserView(center: center, previewInteractionID: panel.id, expectedSession: session, onClose: close)
                case .watching:
                    VStack(spacing: 16) {
                        if scenePhase == .active, session.isModelActive, let tab = session.activeTab {
                            BrowserZoomablePreview(tab: tab, presentationID: panel.id, priority: 2)
                                .frame(maxHeight: .infinity)
                        }
                        Text(session.livePreviewStatus(in: center)).font(.callout)
                    }
                    .padding()
                    .navigationTitle(IDELanguageRunText.t("浏览器预览", "Browser preview"))
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if panel.mode == .interacting, session.isUserControlling {
                        Button(IDELanguageRunText.t("仅收起", "Close for now"), action: close)
                            .disabled(center.returningControl || session.returningToModel)
                            .accessibilityIdentifier("browser.live.back")
                    } else {
                        Button(IDELanguageRunText.t("返回", "Back"), action: close)
                            .accessibilityIdentifier("browser.live.back")
                    }
                }
            }
        }
        .interactiveDismissDisabled(center.visibleSession === session && (center.returningControl || session.returningToModel))
        .onChange(of: center.conversationID) { _, owner in
            if panel.mode == .interacting, owner != session.conversationID { close() }
        }
        .onChange(of: center.session(for: session.conversationID)?.sessionID) { _, live in
            if live != session.sessionID { close() }
        }
    }
}

private extension BrowserTaskSession {
    func livePreviewStatus(in center: BrowserSessionCenter) -> String {
        if takeoverPending {
            return IDELanguageRunText.t("正在接管浏览器", "Taking over the browser")
        }
        if isUserControlling {
            if center.pendingPanelRequest(for: conversationID)?.show == true {
                return IDELanguageRunText.t("浏览器需要你操作", "The browser needs your input")
            }
            return IDELanguageRunText.t("浏览器由你操作", "You control the browser")
        }
        guard let kind = lastModelActivity?.kind else {
            return IDELanguageRunText.t("当前没有浏览器操作", "No current browser action")
        }
        if kind == .clicking, let label = livePreviewFrame?.clickedLabel {
            return IDELanguageRunText.t("AI 点击了「\(label)」", "AI clicked “\(label)”")
        }
        return BrowserModelStatusBar.description(for: kind)
    }
}

private struct BrowserLivePreviewImage: View {
    let frame: BrowserLivePreviewFrame

    var body: some View {
        Image(uiImage: frame.image)
            .resizable()
            .overlay {
                if let target = frame.normalizedTarget {
                    GeometryReader { area in
                        RoundedRectangle(cornerRadius: 3)
                            .strokeBorder(Color.accentColor, lineWidth: 2)
                            .frame(width: area.size.width * target.width, height: area.size.height * target.height)
                            .position(x: area.size.width * target.midX, y: area.size.height * target.midY)
                    }
                }
            }
            .aspectRatio(frame.image.size, contentMode: .fit)
            .allowsHitTesting(false)
            .accessibilityLabel(IDELanguageRunText.t("网页只读预览", "Read-only page preview"))
            .accessibilityIdentifier("browser.live.image")
    }
}

/// A spectator zooms a UIKit canvas. Its fixed-size child still holds the original WebKit page.
private struct BrowserZoomablePreview: UIViewRepresentable {
    let tab: BrowserTaskSession.Tab
    let presentationID: UUID
    let priority: Int

    final class Viewer: UIScrollView, UIScrollViewDelegate {
        let canvas = UIView()
        let page = BrowserPageMount()
        var fixedSize = CGSize.zero
        private var lastSize = CGSize.zero
        private var lastPageSize = CGSize.zero
        private var pinchStart: CGFloat = 1

        init() {
            super.init(frame: .zero)
            addSubview(canvas)
            canvas.addSubview(page)
            delegate = self
            minimumZoomScale = 1
            maximumZoomScale = 4
            contentInsetAdjustmentBehavior = .never
            accessibilityIdentifier = "browser.live.zoom"
            // Only this outer recognizer handles two-finger input. The original web page
            // keeps its own unscaled layout and never receives a spectator gesture.
            pinchGestureRecognizer?.isEnabled = false
            let pinch = UIPinchGestureRecognizer(target: self, action: #selector(magnify(_:)))
            addGestureRecognizer(pinch)
        }

        required init?(coder: NSCoder) { return nil }

        @objc private func magnify(_ pinch: UIPinchGestureRecognizer) {
            if pinch.state == .began { pinchStart = zoomScale }
            guard pinch.state == .began || pinch.state == .changed || pinch.state == .ended else { return }
            let scale = min(maximumZoomScale, max(minimumZoomScale, pinchStart * pinch.scale))
            guard scale != zoomScale else { return }
            let anchor = pinch.location(in: canvas)
            let location = pinch.location(in: self)
            let relative = CGPoint(x: location.x - bounds.minX, y: location.y - bounds.minY)
            setZoomScale(scale, animated: false)
            let scaled = canvas.convert(anchor, to: self)
            let inset = adjustedContentInset
            let x = max(-inset.left, min(scaled.x - relative.x, contentSize.width - bounds.width + inset.right))
            let y = max(-inset.top, min(scaled.y - relative.y, contentSize.height - bounds.height + inset.bottom))
            setContentOffset(CGPoint(x: x, y: y), animated: false)
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            guard bounds.width > 0, bounds.height > 0, fixedSize.width > 0, fixedSize.height > 0 else { return }
            if lastSize != bounds.size || lastPageSize != fixedSize {
                let zoom = zoomScale
                lastSize = bounds.size
                lastPageSize = fixedSize
                setZoomScale(1, animated: false)
                let fit = min(bounds.width / fixedSize.width, bounds.height / fixedSize.height)
                let fitted = CGSize(width: fixedSize.width * fit, height: fixedSize.height * fit)
                canvas.frame = CGRect(origin: .zero, size: fitted)
                page.bounds = CGRect(origin: .zero, size: fixedSize)
                page.center = CGPoint(x: fitted.width / 2, y: fitted.height / 2)
                page.transform = CGAffineTransform(scaleX: fit, y: fit)
                contentSize = fitted
                setZoomScale(zoom, animated: false)
            }
            centerCanvas()
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { canvas }
        func scrollViewDidZoom(_ scrollView: UIScrollView) { centerCanvas() }
        func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) { centerCanvas() }

        private func centerCanvas() {
            let x = max(0, (bounds.width - canvas.frame.width) / 2)
            let y = max(0, (bounds.height - canvas.frame.height) / 2)
            let inset = UIEdgeInsets(top: y, left: x, bottom: y, right: x)
            if contentInset != inset { contentInset = inset }
            accessibilityValue = "\(Int((zoomScale * 100).rounded()))%"
        }
    }

    func makeUIView(context: Context) -> Viewer { Viewer() }
    func updateUIView(_ view: Viewer, context: Context) {
        view.fixedSize = tab.viewport.fixedSize ?? .zero
        view.page.configure(tab: tab, id: presentationID, readOnly: true, priority: priority, active: true)
        view.setNeedsLayout()
    }

    static func dismantleUIView(_ view: Viewer, coordinator: ()) { view.page.detach() }
}

/// Projects the currently bound task's session. Binding is a presentation
/// choice; the session keeps running (and keeps its own ownership) even when
/// another task's surface is shown.
private struct BrowserSurfaceRoot: View {
    @ObservedObject var center: BrowserSessionCenter
    @Binding var expanded: Bool
    let interactionID: UUID?
    let onClose: (() -> Void)?

    var body: some View {
        if let session = center.visibleSession {
            BrowserSurface(center: center, session: session, expanded: $expanded, interactionID: interactionID, onClose: onClose)
                .id(session.conversationID)
        } else {
            ContentUnavailableView {
                Label(IDELanguageRunText.t("浏览器", "Browser"), systemImage: "safari")
            } description: {
                Text(IDELanguageRunText.t("打开一个任务即可使用它自己的浏览器", "Open a task to use its own browser"))
            }
        }
    }
}

private struct BrowserSurface: View {
    @ObservedObject var center: BrowserSessionCenter
    @ObservedObject var session: BrowserTaskSession
    @Binding var expanded: Bool
    let interactionID: UUID?
    let onClose: (() -> Void)?

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var activeSheet: BrowserSheet?
    @State private var spectator = UUID()
    @Environment(\.scenePhase) private var scenePhase
    @State private var onScreen = false
    @State private var keyboardShown = false
    @State private var protectedDataAvailable = true
    @State private var reminderID: UUID?

    private enum BrowserSheet: String, Identifiable {
        case tabs, settings, ports
        var id: Self { self }
    }

    private struct IdlePeriod: Equatable {
        let handoff: UUID
        let tab: UUID
        let activity: UInt64
        let page: BrowserPreviewPageIdentity?
    }

    private var idlePeriod: IdlePeriod? {
        guard onScreen, scenePhase == .active, protectedDataAvailable, !keyboardShown, activeSheet == nil,
              session.isUserControlling, !session.takeoverPending, session.activeExecutionCount == 0,
              !session.isEditingAddress, !session.isLoading, session.tabLimitNotice == nil, !center.returningControl,
              center.visibleSession === session, center.previewInteractionID == interactionID,
              let receipt = center.handoff(for: session.conversationID), receipt.humanPresent, !receipt.returning,
              receipt.sessionID == session.sessionID, let tab = session.activeTabID else { return nil }
        return IdlePeriod(handoff: receipt.id, tab: tab, activity: session.humanActivitySequence, page: session.previewPageIdentity)
    }

    var body: some View {
        GeometryReader { geometry in
            content(wide: geometry.size.width >= 620 && !dynamicTypeSize.isAccessibilitySize)
        }
        .disabled(center.returningControl || session.returningToModel)
        .background(.background)
        .onAppear {
            onScreen = true
            protectedDataAvailable = UIApplication.shared.isProtectedDataAvailable
        }
        .onDisappear { onScreen = false; reminderID = nil }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in keyboardShown = true }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidHideNotification)) { _ in keyboardShown = false }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.protectedDataWillBecomeUnavailableNotification)) { _ in
            protectedDataAvailable = false
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.protectedDataDidBecomeAvailableNotification)) { _ in
            protectedDataAvailable = true
        }
        .task(id: idlePeriod) { await remindIfIdle(idlePeriod) }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .tabs:
                BrowserTabOverview(session: session)
            case .settings:
                BrowserSettingsSheet(center: center)
            case .ports:
                BrowserPortsSheet()
            }
        }
        .alert(
            IDELanguageRunText.t("标签页上限", "Tab limit"),
            isPresented: Binding(
                get: { session.tabLimitNotice != nil },
                set: { if !$0 { session.clearTabLimitNotice() } }
            )
        ) {
            Button(IDELanguageRunText.t("好", "OK"), role: .cancel) { session.clearTabLimitNotice() }
        } message: {
            Text(session.tabLimitNotice ?? "")
        }
    }

    private func remindIfIdle(_ period: IdlePeriod?) async {
        reminderID = nil
        guard let period, !BrowserHandoffReminder.hasShown(session: session, handoff: period.handoff),
              let web = session.activeWebView else { return }
        // SwiftUI cancels this sleep on input, background, keyboard, tab, sheet or handoff changes.
        do { try await Task.sleep(for: BrowserHandoffReminder.delay) } catch { return }
        guard !Task.isCancelled, idlePeriod == period,
              BrowserHandoffReminder.isVisible(web, in: spectator),
              await BrowserHandoffReminder.pageIsQuiet(web),
              !Task.isCancelled, idlePeriod == period, session.activeWebView === web,
              BrowserHandoffReminder.isVisible(web, in: spectator),
              BrowserHandoffReminder.claim(session: session, handoff: period.handoff) else { return }
        reminderID = period.handoff
    }

    private func handback(_ handoff: UUID?) {
        let presentation = interactionID
        Task { @MainActor in
            guard await center.returnControlIfCurrent(for: session, handoffID: handoff, presentationID: presentation),
                  center.visibleSession === session, center.previewInteractionID == presentation else { return }
            onClose?()
        }
    }

    private func handbackLabel(hasRun: Bool) -> String {
        if onClose != nil {
            return hasRun ? IDELanguageRunText.t("交还并返回", "Return to AI and close") : IDELanguageRunText.t("完成并返回", "Done and close")
        }
        return hasRun ? IDELanguageRunText.t("交还给 AI", "Return to AI") : IDELanguageRunText.t("完成", "Done")
    }

    private func content(wide: Bool) -> some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                if session.usesFixedViewport {
                    HStack {
                        Label(IDELanguageRunText.t("只读浏览", "Read-only browser"), systemImage: "eye")
                        Spacer()
                        Button { activeSheet = .settings } label: { Image(systemName: "gearshape") }
                            .accessibilityLabel(IDELanguageRunText.t("浏览器设置", "Browser settings"))
                        Button { expanded.toggle() } label: {
                            Image(systemName: expanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                        }
                        .accessibilityLabel(IDELanguageRunText.t("切换全屏", "Toggle full screen"))
                    }
                    .padding(.horizontal, 12).frame(minHeight: 44)
                } else {
                    BrowserAddressBar(
                    center: center,
                    session: session,
                    compact: !wide,
                    fullscreen: expanded,
                    showTabs: { activeSheet = .tabs },
                    showSettings: { activeSheet = .settings },
                    showPorts: { activeSheet = .ports }
                ) { expanded.toggle() }
                    if wide { BrowserTabStrip(session: session) }
                }
            }
            .background(.bar)
            BrowserProgressBar(session: session)
            if center.taskHandoffsEnabled && session.isUserControlling {
                let receipt = center.handoff(for: session.conversationID)
                let reminding = reminderID != nil && reminderID == receipt?.id && idlePeriod?.handoff == reminderID
                let unresponsiveNavigation = session.unresponsiveNavigationID
                let status = if unresponsiveNavigation != nil {
                    IDELanguageRunText.t("网页尚未响应", "The page hasn’t responded")
                } else if session.takeoverPending {
                    IDELanguageRunText.t("正在等待上一个网页操作结束", "Waiting for the previous browser action to finish")
                } else if reminding {
                    IDELanguageRunText.t("还在使用这个网页吗？", "Still using this page?")
                } else {
                    IDELanguageRunText.t("网页由你操作", "You control this page")
                }
                HStack(spacing: 8) {
                    Text(center.handoffError ?? status)
                        .font(.caption).lineLimit(2)
                    Spacer()
                    if let unresponsiveNavigation {
                        BrowserCloseUnresponsiveTabButton {
                            guard center.visibleSession === session, center.previewInteractionID == interactionID else { return }
                            session.closeUnresponsiveNavigation(unresponsiveNavigation)
                        }
                        .id(unresponsiveNavigation)
                    } else if session.takeoverPending {
                        Button { session.finishTakeoverIfIdle() } label: {
                            Text(IDELanguageRunText.t("重试接管", "Retry takeover"))
                                .frame(minHeight: 44)
                        }
                        .accessibilityIdentifier("browser.retryTakeover")
                    } else {
                        if reminding {
                            Button(IDELanguageRunText.t("继续由我操作", "Keep control")) { reminderID = nil }
                                .font(.caption).frame(minHeight: 44)
                                .accessibilityIdentifier("browser.handoff.keep")
                        } else if let onClose, interactionID == nil {
                            Button(IDELanguageRunText.t("仅收起", "Close for now"), action: onClose)
                                .font(.caption).frame(minHeight: 44)
                                .accessibilityIdentifier("browser.handoff.close")
                        }
                        Button { handback(receipt?.id) } label: {
                            if center.returningControl {
                                HStack { ProgressView(); Text(IDELanguageRunText.t("正在交还", "Returning control")) }
                            }
                            else { Text(handbackLabel(hasRun: receipt?.runID != nil)) }
                        }
                        .disabled(center.returningControl)
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("browser.handoff.return")
                    }
                }.padding(.horizontal, 12)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("browser.taskHandoff")
            }
            if center.taskHandoffsEnabled && center.handoffNotified {
                Label(IDELanguageRunText.t("已通知原任务", "Original task notified"), systemImage: "checkmark.circle")
                    .font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("browser.taskHandoffNotified")
            }
            if center.taskHandoffsEnabled {
                BrowserReturnedHandoffStatus(center: center, owner: session.conversationID)
            }
            if center.taskHandoffsEnabled && !session.isUserControlling && session.modelControl != nil {
                BrowserModelStatusBar(center: center, session: session, presentationID: spectator)
            }
            Divider()
            Group {
                if session.usesFixedViewport {
                    if scenePhase == .active, session.isModelActive, let tab = session.activeTab {
                        BrowserZoomablePreview(tab: tab, presentationID: spectator, priority: expanded ? 2 : 1)
                    } else {
                        Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                } else {
                    BrowserWebContainer(tab: session.activeTab, presentationID: spectator, priority: interactionID != nil ? 3 : (expanded ? 2 : 0),
                                        active: scenePhase == .active, onUserInteraction: { session.registerUserInput() })
                        .allowsHitTesting(!session.takeoverPending && !center.returningControl && !session.returningToModel)
                }
            }
                .overlay(alignment: .top) {
                    if case .failed(let message) = session.surfaceState {
                        VStack(spacing: 12) {
                            Text(message).font(.callout).multilineTextAlignment(.center)
                            Button(IDELanguageRunText.t("重试", "Retry")) { session.reloadFromUser() }
                                .buttonStyle(.bordered)
                                .disabled(session.takeoverPending)
                        }
                        .padding().frame(maxWidth: 480)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                        .padding()
                    }
                }
                .overlay(alignment: .bottom) { BrowserDownloadBanner(service: session.downloads) }
                .clipped()
        }
    }
}

private struct BrowserCloseUnresponsiveTabButton: View {
    let close: () -> Void
    @State private var confirming = false

    var body: some View {
        Button(role: .destructive) { confirming = true } label: {
            Text(IDELanguageRunText.t("关闭无响应标签页", "Close unresponsive tab"))
                .frame(minHeight: 44)
        }
        .accessibilityIdentifier("browser.closeUnresponsiveTab")
        .confirmationDialog(IDELanguageRunText.t("关闭无响应标签页？", "Close the unresponsive tab?"),
                            isPresented: $confirming, titleVisibility: .visible) {
            Button(IDELanguageRunText.t("关闭标签页", "Close tab"), role: .destructive, action: close)
                .accessibilityIdentifier("browser.confirmCloseUnresponsiveTab")
            Button(IDELanguageRunText.t("取消", "Cancel"), role: .cancel) {}
        } message: {
            Text(IDELanguageRunText.t("这个标签页中未保存的内容可能会丢失。", "Unsaved changes in this tab may be lost."))
        }
    }
}

/// An in-app reminder, once per real handoff. It never returns control on a timer.
@MainActor
enum BrowserHandoffReminder {
    static let delay: Duration = .seconds(120)
    private static let prompted = NSMapTable<BrowserTaskSession, NSUUID>.weakToStrongObjects()

    static func hasShown(session: BrowserTaskSession, handoff: UUID) -> Bool {
        prompted.object(forKey: session) == handoff as NSUUID
    }

    static func claim(session: BrowserTaskSession, handoff: UUID) -> Bool {
        guard !hasShown(session: session, handoff: handoff) else { return false }
        prompted.setObject(handoff as NSUUID, forKey: session)
        return true
    }

    static func isVisible(_ web: WKWebView, in presentation: UUID) -> Bool {
        guard let mount = web.superview as? BrowserPageMount, mount.ownsPage, mount.presentationID == presentation,
              let window = web.window, window.isKeyWindow, window.windowScene?.activationState == .foregroundActive,
              UIApplication.shared.isProtectedDataAvailable, !UIAccessibility.isVoiceOverRunning,
              !UIAccessibility.isSwitchControlRunning, !web.isWritingToolsActive,
              !web.scrollView.isDragging, !web.scrollView.isDecelerating, !web.scrollView.isZooming
        else { return false }
        let keyboard = window.keyboardLayoutGuide.layoutFrame
        if !keyboard.isEmpty, keyboard.minY < window.safeAreaLayoutGuide.layoutFrame.maxY - 1 { return false }
        var top = window.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        guard let top, !top.isBeingDismissed, !top.isBeingPresented,
              let surface = top.viewIfLoaded, web.isDescendant(of: surface),
              let hit = window.hitTest(web.convert(CGPoint(x: web.bounds.midX, y: web.bounds.midY), to: window), with: nil)
        else { return false }
        return hit === web || hit.isDescendant(of: web)
    }

    static func pageIsQuiet(_ web: WKWebView) async -> Bool {
        // This isolated, local probe returns one Boolean. It reads no field values or page text.
        let script = """
            if (document.readyState !== 'complete' || document.visibilityState !== 'visible') return false;
            const focused = document.activeElement;
            if (focused && focused !== document.body && focused !== document.documentElement) return false;
            const potentiallyBusy = 'iframe,frame,object,embed,dialog[open],[aria-modal="true"],[role="dialog"],' +
              'input[type="password"],input[autocomplete*="password" i],input[autocomplete*="one-time-code" i],' +
              'input[autocomplete*="webauthn" i]';
            return !Array.from(document.querySelectorAll(potentiallyBusy)).some(el => el.getClientRects().length > 0);
            """
        let result = try? await web.callAsyncJavaScript(script, arguments: [:], in: nil,
            contentWorld: WKContentWorld.world(name: "FloeBrowserHandoffReminder"))
        return result as? Bool == true
    }
}

/// Live, publicly safe status of the model's current page work plus the
/// visible "I'll take over" affordance. It shows only what the executed
/// action kind proves; without target evidence it never fabricates a click
/// label or page content.
private struct BrowserModelStatusBar: View {
    @ObservedObject var center: BrowserSessionCenter
    @ObservedObject var session: BrowserTaskSession
    let presentationID: UUID

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(activityText)
                .font(.caption)
                .lineLimit(2)
            Spacer(minLength: 8)
            Button {
                session.activeTab?.viewport.preferPresentation(presentationID)
                center.takeControl()
            } label: {
                Text(IDELanguageRunText.t("我来操作", "I'll take over"))
                    .font(.caption.weight(.semibold))
                    .frame(minHeight: 44)
            }
            .accessibilityIdentifier("browser.takeControlInline")
        }
        .padding(.horizontal, 12)
        .background(.thinMaterial)
        .accessibilityIdentifier("browser.modelStatus")
    }

    private var activityText: String {
        let kind = session.lastModelActivity?.kind ?? .observing
        if kind == .clicking, let detail = session.livePreviewFrame?.clickedLabel {
            return IDELanguageRunText.t("AI 点击了「\(detail)」", "AI clicked “\(detail)”")
        }
        return Self.description(for: kind)
    }

    static func description(for kind: BrowserModelActivity.Kind) -> String {
        switch kind {
        case .observing:
            return IDELanguageRunText.t("AI 正在查看网页", "AI is viewing the page")
        case .navigating:
            return IDELanguageRunText.t("AI 正在打开网页", "AI is opening a page")
        case .clicking:
            return IDELanguageRunText.t("AI 正在操作网页", "AI is using the page")
        case .typing:
            return IDELanguageRunText.t("AI 正在填写表单", "AI is filling in a form")
        case .scrolling:
            return IDELanguageRunText.t("AI 正在滚动网页", "AI is scrolling the page")
        case .waiting:
            return IDELanguageRunText.t("AI 正在等待网页", "AI is waiting for the page")
        case .exporting, .downloading:
            return IDELanguageRunText.t("AI 正在保存网页文件", "AI is saving a page file")
        }
    }
}

private struct BrowserSettingsSheet: View {
    @ObservedObject var center: BrowserSessionCenter
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            BrowserSettingsView(settings: center.settingsService, browserCenter: center)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(IDELanguageRunText.t("完成", "Done")) { dismiss() }
                    }
                }
        }
    }
}

private struct BrowserPortsSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            LinuxPortManagementView()
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(IDELanguageRunText.t("完成", "Done")) { dismiss() }
                    }
                }
        }
    }
}

private struct BrowserProgressBar: View {
    @ObservedObject var session: BrowserTaskSession

    var body: some View {
        Group {
            if session.isLoading {
                ProgressView(value: session.estimatedProgress)
                    .progressViewStyle(.linear)
                    .frame(height: 3)
                    .accessibilityLabel(IDELanguageRunText.t("页面载入进度", "Page loading progress"))
            } else {
                Color.clear.frame(height: 3)
            }
        }
    }
}

private struct BrowserTabStrip: View {
    @ObservedObject var session: BrowserTaskSession

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(session.tabs) { tab in
                    BrowserTabChip(session: session, tab: tab)
                }
                Button {
                    session.registerUserInput(reason: "You opened a tab")
                    _ = session.createTab()
                } label: {
                    Image(systemName: "plus")
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(IDELanguageRunText.t("新建标签页", "New tab"))
                .accessibilityIdentifier("browser.newTab")
            }
            .padding(.horizontal, 8)
        }
        .frame(height: 44)
    }
}

private struct BrowserTabChip: View {
    @ObservedObject var session: BrowserTaskSession
    let tab: BrowserTaskSession.Tab

    private var active: Bool { tab.id == session.activeTabID }
    private var title: String {
        let value = tab.webView.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !value.isEmpty { return value }
        if let host = tab.webView.url?.host, !host.isEmpty { return host }
        return IDELanguageRunText.t("新标签页", "New tab")
    }

    var body: some View {
        HStack(spacing: 0) {
            Button {
                session.registerUserInput(reason: "You closed a tab")
                session.close(tab.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(IDELanguageRunText.t("关闭标签页", "Close tab"))
            Button {
                session.registerUserInput(reason: "You switched tabs")
                session.activate(tab.id)
            } label: {
                Text(title)
                    .font(.subheadline)
                    .lineLimit(1)
                    .foregroundStyle(active ? .primary : .secondary)
                    .padding(.trailing, 16)
                    .frame(minWidth: 80, maxWidth: 180, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title)
            .accessibilityAddTraits(active ? .isSelected : [])
        }
        .background(active ? Color(uiColor: .systemBackground) : .clear,
                    in: UnevenRoundedRectangle(topLeadingRadius: 10, topTrailingRadius: 10))
        .accessibilityElement(children: .contain)
    }
}

private struct BrowserTabOverview: View {
    @ObservedObject var session: BrowserTaskSession
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(session.tabs) { tab in
                        Button {
                            session.registerUserInput(reason: "You switched tabs")
                            session.activate(tab.id)
                            dismiss()
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: tab.id == session.activeTabID ? "safari.fill" : "safari")
                                    .foregroundStyle(tab.id == session.activeTabID ? Color.accentColor : .secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(tabTitle(tab)).lineLimit(1)
                                    if let host = tab.webView.url?.host {
                                        Text(host).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                }
                                Spacer()
                                if tab.id == session.activeTabID {
                                    Image(systemName: "checkmark").foregroundStyle(.secondary)
                                }
                            }
                        }
                        .swipeActions {
                            Button(role: .destructive) {
                                session.registerUserInput(reason: "You closed a tab")
                                session.close(tab.id)
                            } label: { Label(IDELanguageRunText.t("关闭", "Close"), systemImage: "xmark") }
                        }
                    }
                }
                Section {
                    Button {
                        session.registerUserInput(reason: "You opened a tab")
                        _ = session.createTab()
                        dismiss()
                    } label: {
                        Label(IDELanguageRunText.t("新建标签页", "New tab"), systemImage: "plus")
                    }
                } footer: {
                    Text(IDELanguageRunText.t(
                        "最多 6 个标签页。关闭最后一个标签页会留下空白页。",
                        "Up to 6 tabs. Closing the last tab leaves a blank tab."
                    ))
                }
            }
            .navigationTitle(IDELanguageRunText.t("标签页", "Tabs"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(IDELanguageRunText.t("完成", "Done")) { dismiss() }
                }
            }
        }
    }

    private func tabTitle(_ tab: BrowserTaskSession.Tab) -> String {
        let value = tab.webView.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? IDELanguageRunText.t("新标签页", "New tab") : value
    }
}

private struct BrowserAddressBar: View {
    @ObservedObject var center: BrowserSessionCenter
    @ObservedObject var session: BrowserTaskSession
    let compact: Bool
    let fullscreen: Bool
    let showTabs: () -> Void
    let showSettings: () -> Void
    let showPorts: () -> Void
    let toggleFullscreen: () -> Void
    @FocusState private var editing: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                if !compact { historyButtons }
                if !compact { Spacer(minLength: 0) }
                addressField
                    .frame(maxWidth: compact ? .infinity : 720)
                if !compact {
                    Spacer(minLength: 0)
                    shareButton
                    fullscreenButton
                }
                browserMenu
            }
            if compact {
                HStack(spacing: 0) {
                    historyButtons
                    Spacer(minLength: 0)
                    shareButton
                    Button(action: showTabs) {
                        Image(systemName: "square.on.square")
                            .overlay { Text("\(session.tabs.count)").font(.system(size: 9, weight: .semibold, design: .rounded)).offset(x: 2, y: -2) }
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel(IDELanguageRunText.t("标签页概览", "Tab overview"))
                    .accessibilityValue("\(session.tabs.count)")
                    .accessibilityIdentifier("browser.tabs.overview")
                    fullscreenButton
                }
            }
        }
        .buttonStyle(.borderless)
        .tint(.primary)
        .padding(.horizontal, 8).padding(.vertical, 4)
    }

    private var addressField: some View {
        HStack(spacing: 6) {
            Image(systemName: "globe")
                .foregroundStyle(.secondary).accessibilityHidden(true)
                .padding(.leading, 12)
            TextField("browser.address", text: Binding(
                get: { editing ? session.addressText : displayedAddress },
                set: { session.addressText = $0 }
            ))
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .keyboardType(.URL).submitLabel(.go).textFieldStyle(.plain)
                .font(.subheadline)
                .multilineTextAlignment(editing ? .leading : .center)
                .focused($editing)
                .onChange(of: editing) { _, value in
                    session.isEditingAddress = value
                    if value { session.registerUserInput(reason: "You are using the address bar") }
                }
                .onChange(of: session.activeTabID) { _, _ in editing = false; session.isEditingAddress = false }
                .onSubmit { editing = false; session.isEditingAddress = false; session.navigateFromAddressBar() }
                .accessibilityIdentifier("browser.address")
                .accessibilityValue(session.addressText)
            button(session.isLoading ? "xmark" : "arrow.clockwise",
                   session.isLoading ? IDELanguageRunText.t("停止载入", "Stop loading") : IDELanguageRunText.t("刷新", "Reload")) {
                if session.isLoading {
                    guard session.registerUserInput(reason: "You stopped loading the page") else { return }
                    session.activeWebView?.stopLoading()
                } else {
                    session.reloadFromUser()
                }
            }
            .accessibilityIdentifier("browser.reload")
        }
        .frame(minHeight: 44)
        .background(Color(uiColor: .tertiarySystemFill), in: Capsule())
        .layoutPriority(1)
    }

    private var displayedAddress: String {
        // Shorten presentation only. Editing, copying and accessibility retain
        // the full address, including the path and a local service's port.
        guard let url = session.activeWebView?.url,
              url.absoluteString == session.addressText,
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host, !host.isEmpty else { return session.addressText }
        let name = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        return url.port.map { "\(name):\($0)" } ?? name
    }

    @ViewBuilder
    private var shareButton: some View {
        if let url = session.activeWebView?.url,
           ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            ShareLink(item: url) {
                Image(systemName: "square.and.arrow.up")
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(IDELanguageRunText.t("分享页面", "Share page"))
            .accessibilityIdentifier("browser.share")
        }
    }

    private var historyButtons: some View {
        Group {
            button("chevron.backward", IDELanguageRunText.t("后退", "Back")) {
                guard session.registerUserInput(reason: "You navigated back") else { return }
                session.activeWebView?.goBack()
            }
                .disabled(!session.canGoBack)
                .accessibilityIdentifier("browser.back")
            button("chevron.forward", IDELanguageRunText.t("前进", "Forward")) {
                guard session.registerUserInput(reason: "You navigated forward") else { return }
                session.activeWebView?.goForward()
            }
                .disabled(!session.canGoForward)
                .accessibilityIdentifier("browser.forward")
        }
    }

    private var fullscreenButton: some View {
        button(fullscreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
               fullscreen ? IDELanguageRunText.t("退出全屏", "Exit full screen") : IDELanguageRunText.t("全屏", "Full screen"),
               action: toggleFullscreen)
            .accessibilityIdentifier("browser.fullscreen")
    }

    private var browserMenu: some View {
        Menu {
            Section {
                Button(IDELanguageRunText.t("后退", "Back"), systemImage: "chevron.backward") {
                    guard session.registerUserInput(reason: "You navigated back") else { return }
                    session.activeWebView?.goBack()
                }
                    .disabled(!session.canGoBack)
                Button(IDELanguageRunText.t("前进", "Forward"), systemImage: "chevron.forward") {
                    guard session.registerUserInput(reason: "You navigated forward") else { return }
                    session.activeWebView?.goForward()
                }
                    .disabled(!session.canGoForward)
                Button(IDELanguageRunText.t("刷新", "Reload"), systemImage: "arrow.clockwise") {
                    session.reloadFromUser()
                }
                Button(IDELanguageRunText.t("复制地址", "Copy address"), systemImage: "doc.on.doc") {
                    UIPasteboard.general.string = session.technicalAddress
                }
                if let url = session.activeWebView?.url {
                    Button(IDELanguageRunText.t("在系统浏览器中打开", "Open in system browser"), systemImage: "safari") {
                        UIApplication.shared.open(url)
                    }
                }
                if center.taskHandoffsEnabled, !session.isUserControlling, center.deliverHandoff != nil {
                    Button(IDELanguageRunText.t("接管浏览器", "Take control"), systemImage: "hand.tap") { center.takeControl() }
                        .accessibilityIdentifier("browser.takeControl")
                }
            }
            Section {
                Button(IDELanguageRunText.t("浏览器设置", "Browser settings"), systemImage: "gearshape") { showSettings() }
                Button("portforward.title", systemImage: "network", action: showPorts)
            }
            Section {
                Button(IDELanguageRunText.t("标签页概览", "Tab overview"), systemImage: "square.on.square", action: showTabs)
                ForEach(session.tabs) { tab in
                    Button(tabTitle(tab)) {
                        session.registerUserInput(reason: "You switched tabs")
                        session.activate(tab.id)
                    }
                }
                Button("browser.new_tab", systemImage: "plus") {
                    session.registerUserInput(reason: "You opened a tab")
                    _ = session.createTab()
                }
                    .accessibilityIdentifier("browser.menu.newTab")
                if let active = session.activeTabID, !session.tabs.isEmpty {
                    Button("browser.close_tab", systemImage: "xmark", role: .destructive) {
                        session.registerUserInput(reason: "You closed a tab")
                        session.close(active)
                    }
                        .accessibilityIdentifier("browser.menu.closeTab")
                }
            }
        } label: { Image(systemName: "ellipsis.circle").frame(width: 44, height: 44) }
        .accessibilityLabel(IDELanguageRunText.t("浏览器菜单", "Browser menu"))
        .accessibilityIdentifier("browser.menu")
    }

    private func tabTitle(_ tab: BrowserTaskSession.Tab) -> String {
        let value = tab.webView.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? IDELanguageRunText.t("新标签页", "New tab") : value
    }

    private func button(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).frame(width: 44, height: 44).contentShape(Rectangle()) }
            .accessibilityLabel(Text(label))
    }
}

private struct BrowserDownloadBanner: View {
    @ObservedObject var service: BrowserDownloadService

    var body: some View {
        if let record = service.active.first {
            HStack(spacing: 10) {
                ProgressView(value: record.progress)
                    .frame(width: 120)
                VStack(alignment: .leading, spacing: 1) {
                    Text(record.displayName).font(.caption).lineLimit(1)
                    Text(record.state == .finishing
                        ? IDELanguageRunText.t("正在保存", "Saving")
                        : IDELanguageRunText.t("正在下载", "Downloading"))
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Button(IDELanguageRunText.t("取消", "Cancel")) { service.cancel(record.id) }
                    .font(.caption)
                    .frame(minHeight: 44)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .padding(8)
        }
    }
}

private struct BrowserWebContainer: UIViewRepresentable {
    let tab: BrowserTaskSession.Tab?
    let presentationID: UUID
    let priority: Int
    let active: Bool
    let onUserInteraction: () -> Void

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onUserInteraction: () -> Void
        init(onUserInteraction: @escaping () -> Void) { self.onUserInteraction = onUserInteraction }

        @objc func began(_ recognizer: UIGestureRecognizer) {
            guard let mount = recognizer.view as? BrowserPageMount, mount.ownsPage else { return }
            switch recognizer.state {
            case .began, .recognized, .ended: onUserInteraction()
            default: break
            }
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool { true }
    }

    func makeCoordinator() -> Coordinator { Coordinator(onUserInteraction: onUserInteraction) }

    func makeUIView(context: Context) -> BrowserPageMount {
        let container = BrowserPageMount()
        container.backgroundColor = .systemBackground
        container.clipsToBounds = true
        // The first real human gesture registers user control before it can
        // act, without cancelling the WebView's own touch/scroll handling.
        // A zero-duration long press is the touch-down detector: it begins
        // before the web content can act on the tap, so the takeover is
        // registered first. Pan/pinch/tap cover the remaining real gestures.
        let touchDown = UILongPressGestureRecognizer(
            target: context.coordinator, action: #selector(Coordinator.began(_:)))
        touchDown.minimumPressDuration = 0
        touchDown.allowableMovement = .greatestFiniteMagnitude
        for recognizer: UIGestureRecognizer in [
            touchDown,
            UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.began(_:))),
            UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.began(_:))),
            UIPinchGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.began(_:)))
        ] {
            recognizer.cancelsTouchesInView = false
            recognizer.delegate = context.coordinator
            container.addGestureRecognizer(recognizer)
        }
        return container
    }

    func updateUIView(_ container: BrowserPageMount, context: Context) {
        context.coordinator.onUserInteraction = onUserInteraction
        container.configure(tab: tab, id: presentationID, readOnly: false, priority: priority, active: active)
    }

    static func dismantleUIView(_ container: BrowserPageMount, coordinator: Coordinator) {
        coordinator.onUserInteraction = {}
        container.detach()
    }
}
#endif
