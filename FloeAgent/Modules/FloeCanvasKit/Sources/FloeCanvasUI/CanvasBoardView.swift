#if canImport(UIKit)
import UIKit
import Combine
import FloeCanvasCore
import FloeCanvasLayout
import FloeDiagramCore
import FloeDiagramLayout

/// Interaction state owned by the board while a gesture is in flight.
/// Nothing here commits; gesture end translates to exactly one command.
public enum CanvasBoardGestureState: Equatable {
    case idle
    case movingNodes(initialCenters: [UUID: CanvasGeometry.Point], currentDelta: CanvasGeometry.Point)
    case marquee(start: CanvasGeometry.Point, current: CanvasGeometry.Point)
    case panning
    case pinching
    case resizing(nodeID: UUID, currentSize: CanvasGeometry.Size)
    case connectingFlowPorts(
        sourceNodeID: UUID, sourcePortID: UUID,
        current: CanvasGeometry.Point,
        target: (nodeID: UUID, portID: UUID)?)

    public static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.panning, .panning), (.pinching, .pinching): return true
        case let (.movingNodes(a, b), .movingNodes(c, d)): return a == c && b == d
        case let (.marquee(a, b), .marquee(c, d)): return a == c && b == d
        case let (.resizing(a, b), .resizing(c, d)): return a == c && b == d
        case let (.connectingFlowPorts(a, b, c, d), .connectingFlowPorts(e, f, g, h)):
            return a == e && b == f && c == g && d?.nodeID == h?.nodeID && d?.portID == h?.portID
        default: return false
        }
    }
}

/// UIKit board: one native canvas surface. Renders regions, ordinary
/// relations, flow edges and node cards with world↔view transforms from the
/// Layout module. Pan/zoom never rebuilds the layout index — the prepared
/// index is consumed as-is (per LAYOUT_CONTRACT).
public final class CanvasBoardView: UIView {
    // MARK: Inputs

    weak var store: CanvasEditorStore?
    private var cancellables = Set<AnyCancellable>()

    // MARK: Mixed-content rendering (P1c)

    /// Structured native rendering for text-like content kinds and formula.
    let contentRenderer = CanvasBoardNodeContentRenderer()
    /// Bounded, visible-only thumbnail demand backed by the shared
    /// `CanvasPreviewPipeline` (store-owned, same one the inspector uses).
    let previewDemand = CanvasBoardPreviewDemandController(pipeline: nil)

    // MARK: Gesture state

    var gestureState: CanvasBoardGestureState = .idle {
        didSet { setNeedsDisplay() }
    }
    /// World-rect query for visible content during the current frame.
    private var lastVisibleWorldRect = DiagramRect(x: 0, y: 0, width: 1, height: 1)

    private var resizeStartSize: CanvasGeometry.Size?

    // MARK: Subviews

    let inkOverlay = CanvasInkOverlayView()

    // MARK: Init

    public override init(frame: CGRect) {
        super.init(frame: frame)
        commonInit()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        backgroundColor = .systemBackground
        isOpaque = true
        contentMode = .redraw
        accessibilityIdentifier = CanvasAccessibilityID.board.identifier
        let interaction = UIContextMenuInteraction(delegate: self)
        addInteraction(interaction)

        addSubview(inkOverlay)
        inkOverlay.board = self

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tap.delegate = self
        addGestureRecognizer(tap)

        let doubleTap = UITapGestureRecognizer(
            target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)
        tap.require(toFail: doubleTap)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.delegate = self
        pan.maximumNumberOfTouches = 1
        addGestureRecognizer(pan)

        let panTwo = UIPanGestureRecognizer(
            target: self, action: #selector(handlePanTwo(_:)))
        panTwo.delegate = self
        panTwo.minimumNumberOfTouches = 2
        addGestureRecognizer(panTwo)

        let pinch = UIPinchGestureRecognizer(
            target: self, action: #selector(handlePinch(_:)))
        pinch.delegate = self
        addGestureRecognizer(pinch)
    }

    // MARK: Store binding

    func bind(to store: CanvasEditorStore) {
        self.store = store
        cancellables.removeAll()
        contentRenderer.updateAppearance(
            traitCollection.userInterfaceStyle == .dark ? .dark : .light)
        previewDemand.attach(
            pipeline: store.previews,
            onImageReady: { [weak self] in self?.setNeedsDisplay() })
        store.$viewport
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.onViewportChanged() }
            }
            .store(in: &cancellables)
        store.$layoutIndex
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    // Snapshot/layout boundary: fence in-flight preview work
                    // and drop stale demand before drawing the new state.
                    self?.previewDemand.invalidateAll()
                    self?.inkOverlay.syncTransform()
                    self?.setNeedsDisplay()
                }
            }
            .store(in: &cancellables)
        store.$selection
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.setNeedsDisplay() }
            }
            .store(in: &cancellables)
        store.$relationEdges
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.setNeedsDisplay() }
            }
            .store(in: &cancellables)
        store.$flowEdges
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.setNeedsDisplay() }
            }
            .store(in: &cancellables)
        store.$tool
            .receive(on: DispatchQueue.main)
            .sink { [weak self] tool in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.inkOverlay.isUserInteractionEnabled = tool == .pencil || tool == .eraser || tool == .lasso
                    self.inkOverlay.editingTool = tool
                }
            }
            .store(in: &cancellables)
        onViewportChanged()
    }

    private func onViewportChanged() {
        inkOverlay.syncTransform()
        setNeedsDisplay()
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        inkOverlay.frame = bounds
        if let store, abs(store.viewport.viewSize.width - bounds.width) > 0.5
            || abs(store.viewport.viewSize.height - bounds.height) > 0.5 {
            if let resized = try? CanvasViewportTransform(
                center: store.viewport.center,
                scale: store.viewport.scale,
                viewSize: .init(width: bounds.width, height: bounds.height)) {
                store.setViewport(resized)
            }
        }
    }

    public override func didMoveToWindow() {
        super.didMoveToWindow()
        contentRenderer.updateAppearance(
            traitCollection.userInterfaceStyle == .dark ? .dark : .light)
    }

    public override func removeFromSuperview() {
        // The board leaves the hierarchy: stop owning demand. The shared
        // pipeline cache survives for the next bind.
        previewDemand.invalidateAll()
        super.removeFromSuperview()
    }

    public override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        contentRenderer.updateAppearance(
            traitCollection.userInterfaceStyle == .dark ? .dark : .light)
        setNeedsDisplay()
    }

    // MARK: Accessibility (bounded, visible-only elements)

    public override var isAccessibilityElement: Bool {
        get { false }
        set { /* The board exposes its visible children instead. */ }
    }

    public override var accessibilityElements: [Any]? {
        get {
            guard let store else { return nil }
            return CanvasBoardAccessibilityBuilder.elements(store: store, board: self)
        }
        set { /* Elements are derived from the current visible index. */ }
    }

    // MARK: Coordinates

    func viewPoint(for world: CanvasGeometry.Point) -> CGPoint {
        guard let store else { return .zero }
        let p = store.viewport.worldToView(.init(x: world.x, y: world.y))
        return CGPoint(x: p.x, y: p.y)
    }

    func worldPoint(for view: CGPoint) -> CanvasGeometry.Point {
        guard let store else { return .zero }
        let p = store.viewport.viewToWorld(.init(x: view.x, y: view.y))
        return CanvasGeometry.Point(x: p.x, y: p.y)
    }

    // MARK: Drawing

    public override func draw(_ rect: CGRect) {
        previewDemand.beginDrawPass()
        guard let store, let context = UIGraphicsGetCurrentContext() else { return }
        let viewport = store.viewport
        lastVisibleWorldRect = viewport.visibleWorldRect(overscan: 128)
        drawBackground(context: context, viewport: viewport)
        guard store.layoutIndex.pageID == store.selectedPageID else { return }
        drawRegions(context: context, store: store)
        drawRelationEdges(context: context, store: store)
        drawFlowEdges(context: context, store: store)
        drawNodes(context: context, store: store)
        drawGestureOverlays(context: context, store: store)
    }

    private func drawBackground(
        context: CGContext,
        viewport: CanvasViewportTransform
    ) {
        let bounds = self.bounds
        context.setFillColor(UIColor.systemBackground.cgColor)
        context.fill(bounds)
        let style = store?.page.background ?? .grid
        let spacing = 28.0 * viewport.scale
        guard spacing > 6 else { return }
        context.setStrokeColor(UIColor.separator.withAlphaComponent(0.18).cgColor)
        context.setLineWidth(0.5)
        let offsetX = (bounds.width / 2 - viewport.center.x * viewport.scale).truncatingRemainder(dividingBy: spacing)
        let offsetY = (bounds.height / 2 - viewport.center.y * viewport.scale).truncatingRemainder(dividingBy: spacing)
        var path = CGMutablePath()
        switch style {
        case .blank:
            return
        case .grid:
            var x = offsetX
            while x < bounds.width {
                path.move(to: .init(x: x, y: 0))
                path.addLine(to: .init(x: x, y: bounds.height))
                x += spacing
            }
            var y = offsetY
            while y < bounds.height {
                path.move(to: .init(x: 0, y: y))
                path.addLine(to: .init(x: bounds.width, y: y))
                y += spacing
            }
        case .dots:
            var x = offsetX
            while x < bounds.width {
                var y = offsetY
                while y < bounds.height {
                    path.addEllipse(in: .init(
                        x: x - 0.75, y: y - 0.75, width: 1.5, height: 1.5))
                    y += spacing
                }
                x += spacing
            }
        }
        context.addPath(path)
        context.strokePath()
    }

    private func drawRegions(
        context: CGContext,
        store: CanvasEditorStore
    ) {
        for region in store.layoutIndex.visibleRegions(
            in: lastVisibleWorldRect, overscan: 0
        ) {
            let rect = viewRect(forWorldRect: region.frame)
            let path = UIBezierPath(roundedRect: rect, cornerRadius: 12).cgPath
            if region.isCollapsed {
                context.setFillColor(UIColor.secondarySystemBackground.cgColor)
                context.addPath(path)
                context.fillPath()
                context.setStrokeColor(UIColor.tertiaryLabel.cgColor)
            } else {
                context.setStrokeColor(
                    UIColor.tertiaryLabel.withAlphaComponent(0.6).cgColor)
            }
            context.setLineWidth(1)
            context.addPath(path)
            context.strokePath()
            let name = region.name as NSString
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.preferredFont(forTextStyle: .caption1),
                .foregroundColor: UIColor.secondaryLabel,
            ]
            name.draw(at: .init(x: rect.minX + 8, y: rect.minY + 4), withAttributes: attributes)
        }
    }

    private func drawRelationEdges(
        context: CGContext,
        store: CanvasEditorStore
    ) {
        let visible = store.visibleRelationEdges(in: lastVisibleWorldRect)
        context.setStrokeColor(UIColor.label.withAlphaComponent(0.75).cgColor)
        context.setLineWidth(1.5)
        for edge in visible {
            strokeGeometry(context: context, geometry: edge.geometry, viewport: store.viewport)
            if edge.kind == .arrow {
                drawArrowHead(
                    context: context,
                    geometry: edge.geometry,
                    viewport: store.viewport,
                    color: UIColor.label.withAlphaComponent(0.75))
            }
            if let label = edge.label, !label.isEmpty {
                drawEdgeLabel(label, geometry: edge.geometry, viewport: store.viewport)
            }
        }
    }

    private func drawFlowEdges(
        context: CGContext,
        store: CanvasEditorStore
    ) {
        // Flow execution edges are visually distinct: accent dashed line
        // with filled port dots (UI_BRIEF: typed ports vs ordinary
        // relations must never be confusable).
        let viewport = store.viewport
        let visible = store.visibleFlowEdges(in: lastVisibleWorldRect)
        context.setStrokeColor(UIColor.systemBlue.cgColor)
        context.setLineWidth(2)
        context.setLineDash(phase: 0, lengths: [6, 4])
        for edge in visible {
            strokeGeometry(context: context, geometry: edge.geometry, viewport: viewport)
        }
        context.setLineDash(phase: 0, lengths: [])
        var drawnPorts = Set<UUID>()
        if CanvasLODPolicy.level(forZoom: viewport.scale) >= .standard {
            for anchor in store.visibleFlowPortAnchors(in: lastVisibleWorldRect) {
                guard drawnPorts.insert(anchor.id).inserted,
                      lastVisibleWorldRect.insetBy(-64).contains(anchor.position) else { continue }
                let center = viewPoint(forWorld: .init(x: anchor.position.x, y: anchor.position.y))
                let radius = max(3.5, 8 * viewport.scale / max(viewport.scale, 1))
                let rect = CGRect(x: center.x - radius, y: center.y - radius,
                                  width: radius * 2, height: radius * 2)
                context.setFillColor(UIColor.systemBackground.cgColor)
                context.fillEllipse(in: rect)
                context.setStrokeColor(UIColor.systemBlue.cgColor)
                context.setLineWidth(1.5)
                context.strokeEllipse(in: rect)
            }
        }
        // Pending connection drag line.
        if case .connectingFlowPorts(let sourceNodeID, let sourcePortID, let current, let target) = gestureState {
            context.setStrokeColor(
                (target == nil ? UIColor.systemOrange : UIColor.systemGreen).cgColor)
            context.setLineWidth(2)
            var path = CGMutablePath()
            let anchor = store.layoutIndex.flowPortAnchor(
                nodeID: sourceNodeID, portID: sourcePortID)
            let from = viewPoint(forWorld: .init(
                x: anchor?.position.x ?? 0, y: anchor?.position.y ?? 0))
            path.move(to: from)
            path.addLine(to: viewPoint(for: current))
            context.addPath(path)
            context.strokePath()
        }
    }

    private func drawNodes(
        context: CGContext,
        store: CanvasEditorStore
    ) {
        let viewport = store.viewport
        let visible = store.layoutIndex.visibleNodes(in: lastVisibleWorldRect, overscan: 64)
        let lod = CanvasLODPolicy.level(forZoom: viewport.scale)
        let nodes: [CanvasPreparedNode]
        if lod == .overview {
            let demand = CanvasLODPolicy.demand(for: visible, zoom: viewport.scale)
            let representatives = Set(demand.representativeNodeIDs).union(store.selection)
            nodes = visible.filter { representatives.contains($0.id) }
        } else {
            nodes = visible
        }
        for prepared in nodes {
            let nodeID = prepared.id
            guard let node = store.node(id: nodeID) else {
                continue
            }
            let frame = viewRect(forWorldRect: CanvasLayoutGeometry.rect(from: node.frame))
            guard frame.intersects(self.bounds.insetBy(dx: -80, dy: -80)) else { continue }
            let isSelected = store.selection.contains(nodeID)
            let path = nodeBodyPath(node: node, frame: frame)
            let isShape: Bool
            let isOpenShape: Bool
            if case .shape(let kind, _) = node.content {
                isShape = true
                isOpenShape = kind == .line || kind == .arrow
            } else { isShape = false; isOpenShape = false }

            context.setFillColor(cardColor(for: node).cgColor)
            if !isOpenShape {
                context.addPath(path)
                context.fillPath()
            }
            context.setStrokeColor(
                isSelected ? UIColor.systemBlue.cgColor
                    : UIColor.separator.cgColor)
            context.setLineWidth(isSelected ? 2.5 : 1)
            context.addPath(path)
            context.strokePath()

            // Heavyweight content renders a lightweight placeholder at low
            // zoom and a bounded preview demand marker (LAYOUT_CONTRACT §8).
            if lod == .overview { continue }
            context.saveGState()
            context.addPath(path)
            context.clip()
            if lod == .preview {
                // At overview zoom a readable, clipped label is more
                // useful than full-size text squeezed into a thumbnail.
                let paragraph = NSMutableParagraphStyle()
                paragraph.lineBreakMode = .byTruncatingTail
                let label = compactLabel(for: node)
                let textFrame = CGRect(x: frame.minX + 8, y: frame.minY + 6,
                    width: max(0, frame.width - 16),
                    height: max(0, min(frame.height - 12, UIFont.preferredFont(forTextStyle: .caption2).lineHeight)))
                (label as NSString).draw(in: textFrame, withAttributes: [
                    .font: UIFont.preferredFont(forTextStyle: .caption2),
                    .foregroundColor: UIColor.label, .paragraphStyle: paragraph])
                context.restoreGState()
                continue
            }
            // Draw document content in document coordinates. Previously
            // card bounds shrank with zoom while fonts and insets did not.
            context.translateBy(x: frame.minX, y: frame.minY)
            context.scaleBy(x: viewport.scale, y: viewport.scale)
            let contentFrame = CGRect(origin: .zero,
                size: CGSize(width: node.frame.size.width, height: node.frame.size.height))
            let heavyweight = prepared.isHeavyweight
            let allowsHeavy = CanvasLODLevel(forZoom: viewport.scale).allowsHeavyweightContent
            if heavyweight && !allowsHeavy {
                drawPlaceholder(in: contentFrame, label: node.title ?? "Preview", context: context)
            } else {
                if isShape {
                    drawShapeText(node: node, frame: contentFrame)
                } else {
                    drawNodeContent(node, in: contentFrame, lod: lod, context: context, store: store)
                }
            }

            // Vector shapes keep their label inside their own geometry.
            if !isShape, let title = node.title, !title.isEmpty {
                drawTitleBar(title, in: contentFrame, context: context)
            }
            context.restoreGState()

            // Lock badge.
            if node.isLocked {
                drawBadge(
                    symbol: "lock.fill", in: frame, alignment: .topTrailing,
                    context: context)
            }
            // Flow step badge.
            if CanvasFlowCardBinding(metadata: node.metadata) != nil {
                drawBadge(
                    symbol: "arrow.triangle.branch",
                    in: frame, alignment: .bottomTrailing, context: context,
                    tint: .systemBlue)
            }
            // Run-output badge: cards placed from a completed run are
            // visibly distinct from ordinary content.
            if CanvasRunOutputStateBadge(metadata: node.metadata) != nil {
                drawBadge(
                    symbol: "tray.and.arrow.down.fill",
                    in: frame, alignment: .bottomLeading, context: context,
                    tint: .systemGreen)
            }
        }

        // Resize handle for single selection.
        if let single = store.singleSelectedNode, !single.isLocked,
           case .idle = gestureState {
            let frame = viewRect(forWorldRect: CanvasLayoutGeometry.rect(from: single.frame))
            let handle = CGRect(
                x: frame.maxX - 5, y: frame.maxY - 5, width: 10, height: 10)
            context.setFillColor(UIColor.systemBlue.cgColor)
            context.fillEllipse(in: handle)
        }

        // Reconcile preview demand with the resources actually drawn this
        // pass: drop queued work that scrolled away, start bounded new work.
        // Runs once per draw pass, never per node.
        previewDemand.reconcileVisibleDemand()
    }

    private func nodeBodyPath(node: CanvasNodeSnapshot, frame: CGRect) -> CGPath {
        guard case .shape(let kind, _) = node.content else {
            return UIBezierPath(roundedRect: frame, cornerRadius: min(12, frame.height / 6)).cgPath
        }
        switch kind {
        case .rectangle: return UIBezierPath(rect: frame).cgPath
        case .roundedRectangle: return UIBezierPath(roundedRect: frame, cornerRadius: min(16, frame.height / 5)).cgPath
        case .ellipse: return UIBezierPath(ovalIn: frame).cgPath
        case .diamond:
            let path = CGMutablePath()
            path.move(to: CGPoint(x: frame.midX, y: frame.minY))
            path.addLine(to: CGPoint(x: frame.maxX, y: frame.midY))
            path.addLine(to: CGPoint(x: frame.midX, y: frame.maxY))
            path.addLine(to: CGPoint(x: frame.minX, y: frame.midY))
            path.closeSubpath()
            return path
        case .line, .arrow:
            let path = CGMutablePath()
            path.move(to: CGPoint(x: frame.minX, y: frame.midY))
            path.addLine(to: CGPoint(x: frame.maxX, y: frame.midY))
            if kind == .arrow {
                let head = min(16, frame.width / 5, frame.height / 2)
                path.move(to: CGPoint(x: frame.maxX - head, y: frame.midY - head))
                path.addLine(to: CGPoint(x: frame.maxX, y: frame.midY))
                path.addLine(to: CGPoint(x: frame.maxX - head, y: frame.midY + head))
            }
            return path
        }
    }

    private func compactLabel(for node: CanvasNodeSnapshot) -> String {
        if let title = node.title, !title.isEmpty { return title }
        let text: String
        switch node.content {
        case .text(let value), .shape(_, let value): text = value
        case .markdown(let document, let preview): text = preview ?? document
        case .richText(let document): text = document.plainText
        case .formula(let source, _), .code(_, let source): text = source
        case .table(let header, _): text = header.joined(separator: " · ")
        case .web(let url, let title): text = title ?? url.host ?? url.absoluteString
        default: text = store?.strings[.canvasTitleUntitled] ?? "Untitled"
        }
        return String(text.prefix(120)).replacingOccurrences(of: "\n", with: " ")
    }

    private func drawShapeText(node: CanvasNodeSnapshot, frame: CGRect) {
        guard case .shape(let kind, let text) = node.content, !text.isEmpty else { return }
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.preferredFont(forTextStyle: .subheadline),
            .foregroundColor: UIColor.label, .paragraphStyle: paragraph]
        let width = frame.width * (kind == .diamond ? 0.55 : 0.8)
        let measured = (text as NSString).boundingRect(
            with: CGSize(width: width, height: frame.height * 0.7),
            options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attributes, context: nil)
        let y = kind == .line || kind == .arrow
            ? frame.midY - measured.height - 5 : frame.midY - measured.height / 2
        (text as NSString).draw(in: CGRect(x: frame.midX - width / 2, y: y,
            width: width, height: measured.height), withAttributes: attributes)
    }

    /// Real mixed-content rendering for one card. Resource-backed kinds
    /// (media / PDF / rendered formula) draw host-provided bounded thumbnails
    /// through the shared preview pipeline; text-like kinds render natively.
    /// Missing resources are honest and actionable; valid resources never
    /// show a missing state.
    private func drawNodeContent(
        _ node: CanvasNodeSnapshot,
        in frame: CGRect,
        lod: CanvasLODLevel,
        context: CGContext,
        store: CanvasEditorStore
    ) {
        let headerHeight: CGFloat = node.title?.isEmpty == false ? cardTitleHeight : 0
        let contentRect = CGRect(x: frame.minX + 12, y: frame.minY + headerHeight + 12,
            width: frame.width - 24, height: frame.height - headerHeight - 24)
        guard contentRect.height > 12, contentRect.width > 8 else { return }
        let strings = store.strings
        switch node.content {
        case .text(let text):
            contentRenderer.drawPlainText(text, in: contentRect, context: context)
        case .markdown(let document, _):
            contentRenderer.drawPlainText(document, in: contentRect, context: context)
        case .richText(let document):
            contentRenderer.drawRichText(document, in: contentRect, context: context)
        case .shape(_, let text):
            contentRenderer.drawPlainText(
                text,
                in: contentRect,
                context: context,
                color: .secondaryLabel)
        case .code(let language, let source):
            contentRenderer.drawCode(
                source: source, language: language, in: contentRect, context: context)
        case .formula(let source, let renderedAssetID):
            drawFormulaContent(
                source: source,
                renderedAssetID: renderedAssetID,
                in: contentRect,
                context: context)
        case .table(let header, let rows):
            contentRenderer.drawTable(
                header: header,
                rows: rows,
                in: contentRect,
                context: context,
                moreIndicator: strings[.contentTruncated])
        case .media(let locator):
            drawMediaContent(locator: locator, in: contentRect, context: context, strings: strings)
        case .pdf(let documentAssetID, let pageRange):
            drawPDFContent(
                documentAssetID: documentAssetID,
                pageRange: pageRange,
                in: contentRect,
                context: context,
                strings: strings)
        case .web(let url, let title):
            contentRenderer.drawWebReference(
                url: url, title: title, in: contentRect, context: context)
        case .editor(let reference):
            contentRenderer.drawEditorReference(
                reference,
                openActionTitle: store.services.editorGateway == nil
                    ? nil : strings[.mediaOpenEditor],
                in: contentRect,
                context: context)
        case .unknown(let kind, _):
            contentRenderer.drawPlainText(
                kind,
                in: contentRect,
                context: context,
                color: .secondaryLabel)
        }
    }

    // MARK: Resource-backed content (media / PDF / rendered formula)

    private func drawMediaContent(
        locator: CanvasAssetLocator,
        in rect: CGRect,
        context: CGContext,
        strings: CanvasStrings
    ) {
        let icon = mediaIcon(for: locator.mimeType)
        if let image = previewDemand.image(
            locator: locator, contentKind: locator.mimeType) {
            contentRenderer.drawPreviewImage(image, in: rect, context: context)
            // Non-visual media keep a kind badge on top of the artwork.
            if locator.mimeType.map(isNonVisualMedia) == true {
                drawKindBadge(symbol: icon, in: rect, context: context)
            }
            return
        }
        let status = previewDemand.status(locator: locator, contentKind: locator.mimeType)
        switch status {
        case .unavailableProvider, .failed:
            // Actionable missing state: the inspector exposes re-linking.
            contentRenderer.drawResourceMissing(
                in: rect,
                label: strings[.mediaTapToResolve],
                systemImage: icon,
                context: context)
        case .pending, .idle:
            // In flight (or about to be requested): neutral placeholder,
            // never presented as content and never as "missing".
            contentRenderer.drawResourcePending(in: rect, systemImage: icon, context: context)
        }
    }

    private func drawPDFContent(
        documentAssetID: UUID?,
        pageRange: ClosedRange<Int>?,
        in rect: CGRect,
        context: CGContext,
        strings: CanvasStrings
    ) {
        let caption = pdfCaption(pageRange: pageRange, strings: strings)
        guard let documentAssetID else {
            // No document reference at all: honest, actionable missing state.
            contentRenderer.drawResourceMissing(
                in: rect,
                label: caption ?? strings[.pdfMissingDocument],
                systemImage: "doc.text",
                context: context)
            return
        }
        // The host's preview service is the PDF gate (UI_BRIEF): the kit
        // asks it for bounded thumbnail bytes and never renders PDF pages
        // itself.
        let locator = CanvasAssetLocator(
            id: documentAssetID,
            mimeType: "application/pdf")
        if let image = previewDemand.image(locator: locator, contentKind: "pdf") {
            contentRenderer.drawPreviewImage(image, in: rect, context: context)
            if let caption {
                drawResourceCaption(caption, in: rect, context: context)
            }
            return
        }
        let status = previewDemand.status(locator: locator, contentKind: "pdf")
        switch status {
        case .unavailableProvider, .failed:
            contentRenderer.drawResourceMissing(
                in: rect,
                label: caption ?? strings[.pdfMissingDocument],
                systemImage: "doc.text",
                context: context)
        case .pending, .idle:
            contentRenderer.drawResourcePending(in: rect, systemImage: "doc.text", context: context)
            if let caption {
                drawResourceCaption(caption, in: rect, context: context)
            }
        }
    }

    private func drawFormulaContent(
        source: String,
        renderedAssetID: UUID?,
        in rect: CGRect,
        context: CGContext
    ) {
        // Prefer the pre-rendered asset when the document carries one;
        // otherwise typeset live through the public DiagramKit renderer.
        if let renderedAssetID {
            let locator = CanvasAssetLocator(id: renderedAssetID)
            if let image = previewDemand.image(locator: locator, contentKind: "image") {
                contentRenderer.drawPreviewImage(image, in: rect, context: context)
                return
            }
            let status = previewDemand.status(locator: locator, contentKind: "image")
            if status == .pending || status == .idle {
                contentRenderer.drawResourcePending(
                    in: rect, systemImage: "function", context: context)
                return
            }
            // Fall through to the live render when the asset is missing.
        }
        if let image = contentRenderer.formulaImage(source: source) {
            contentRenderer.drawPreviewImage(image, in: rect, context: context)
        } else {
            // Invalid/empty source: show the raw source honestly (the
            // focused formula editor flags validity and offers fixes).
            let base = UIFont.preferredFont(forTextStyle: .footnote)
            let italic = base.fontDescriptor.withSymbolicTraits(.traitItalic)
                .map { UIFont(descriptor: $0, size: base.pointSize) } ?? base
            contentRenderer.drawPlainText(
                source,
                in: rect,
                context: context,
                font: italic,
                color: .secondaryLabel)
        }
    }

    // MARK: Resource drawing helpers

    private func mediaIcon(for mimeType: String?) -> String {
        guard let mimeType else { return "photo" }
        if mimeType.hasPrefix("audio/") { return "waveform" }
        if mimeType.hasPrefix("video/") { return "film" }
        if mimeType.hasPrefix("model/") { return "cube" }
        return "photo"
    }

    private func isNonVisualMedia(_ mimeType: String) -> Bool {
        mimeType.hasPrefix("audio/") || mimeType.hasPrefix("video/")
            || mimeType.hasPrefix("model/")
    }

    private func pdfCaption(pageRange: ClosedRange<Int>?, strings: CanvasStrings) -> String? {
        guard let pageRange else { return nil }
        return strings.formatted(.pdfPageRangeCaption, pageRange.lowerBound, pageRange.upperBound)
    }

    private func drawKindBadge(
        symbol: String,
        in rect: CGRect,
        context: CGContext
    ) {
        let size = CGSize(width: 18, height: 18)
        let origin = CGPoint(x: rect.minX + 4, y: rect.minY + 4)
        let bubble = CGRect(origin: origin, size: size).insetBy(dx: -3, dy: -3)
        context.saveGState()
        context.setFillColor(UIColor.systemBackground.withAlphaComponent(0.75).cgColor)
        context.fillEllipse(in: bubble)
        context.restoreGState()
        let image = UIImage(systemName: symbol)?
            .withTintColor(.label, renderingMode: .alwaysOriginal)
        image?.draw(in: CGRect(origin: origin, size: size))
    }

    private func drawResourceCaption(
        _ caption: String,
        in rect: CGRect,
        context: CGContext
    ) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 10),
            .foregroundColor: UIColor.secondaryLabel,
        ]
        (caption as NSString).draw(
            at: CGPoint(x: rect.minX + 6, y: rect.maxY - 15),
            withAttributes: attributes)
    }

    private func drawPlaceholder(
        in frame: CGRect,
        label: String,
        context: CGContext
    ) {
        context.setStrokeColor(UIColor.tertiaryLabel.cgColor)
        context.setLineDash(phase: 0, lengths: [4, 3])
        let dashed = UIBezierPath(
            roundedRect: frame.insetBy(dx: 4, dy: 4),
            cornerRadius: 10).cgPath
        context.addPath(dashed)
        context.strokePath()
        context.setLineDash(phase: 0, lengths: [])
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.preferredFont(forTextStyle: .caption2),
            .foregroundColor: UIColor.tertiaryLabel,
        ]
        (label as NSString).draw(
            in: frame.insetBy(dx: 10, dy: 10), withAttributes: attributes)
    }

    private func drawTitleBar(
        _ title: String,
        in frame: CGRect,
        context: CGContext
    ) {
        let bar = CGRect(
            x: frame.minX, y: frame.minY,
            width: frame.width, height: cardTitleHeight)
        context.setFillColor(UIColor.tertiarySystemBackground.cgColor)
        context.fill(bar)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.preferredFont(forTextStyle: .subheadline),
            .foregroundColor: UIColor.label,
        ]
        (title as NSString).draw(
            in: bar.insetBy(dx: 12, dy: 6), withAttributes: attributes)
    }

    private var cardTitleHeight: CGFloat {
        ceil(UIFont.preferredFont(forTextStyle: .subheadline).lineHeight) + 12
    }

    private enum BadgeAlignment {
        case topTrailing, bottomTrailing, bottomLeading
    }

    private func drawBadge(
        symbol: String,
        in frame: CGRect,
        alignment: BadgeAlignment,
        context: CGContext,
        tint: UIColor = .secondaryLabel
    ) {
        let image = UIImage(
            systemName: symbol,
            withConfiguration: UIImage.SymbolConfiguration(scale: .small))
        let size = CGSize(width: 14, height: 14)
        let origin: CGPoint
        switch alignment {
        case .topTrailing:
            origin = .init(x: frame.maxX - 18, y: frame.minY + 2)
        case .bottomTrailing:
            origin = .init(x: frame.maxX - 18, y: frame.maxY - 18)
        case .bottomLeading:
            origin = .init(x: frame.minX + 4, y: frame.maxY - 18)
        }
        tint.setFill()
        image?.withTintColor(tint).draw(in: .init(origin: origin, size: size))
    }

    private func drawGestureOverlays(
        context: CGContext,
        store: CanvasEditorStore
    ) {
        let viewport = store.viewport
        switch gestureState {
        case .marquee(let start, let current):
            let a = viewPoint(forWorld: .init(x: start.x, y: start.y))
            let b = viewPoint(forWorld: .init(x: current.x, y: current.y))
            let rect = CGRect(
                x: min(a.x, b.x), y: min(a.y, b.y),
                width: abs(a.x - b.x), height: abs(a.y - b.y))
            context.setStrokeColor(UIColor.systemBlue.cgColor)
            context.setFillColor(UIColor.systemBlue.withAlphaComponent(0.08).cgColor)
            context.setLineWidth(1)
            context.fill(rect)
            context.stroke(rect)
        case .movingNodes(_, let delta):
            for nodeID in store.selection {
                guard let node = store.page.nodes.first(where: { $0.id == nodeID }) else {
                    continue
                }
                let frame = CanvasLayoutGeometry.rect(from: node.frame)
                    .offsetBy(dx: delta.x, dy: delta.y)
                let rect = viewRect(forWorldRect: frame)
                context.setStrokeColor(UIColor.systemBlue.withAlphaComponent(0.7).cgColor)
                context.setLineWidth(1.5)
                context.stroke(rect)
            }
        case .resizing(_, let size):
            guard let single = store.singleSelectedNode else { break }
            let worldFrame = CanvasLayoutGeometry.rect(from: single.frame)
            let frame = DiagramRect(
                x: worldFrame.center.x - size.width / 2,
                y: worldFrame.center.y - size.height / 2,
                width: size.width,
                height: size.height)
            context.setStrokeColor(UIColor.systemBlue.withAlphaComponent(0.7).cgColor)
            context.setLineWidth(1.5)
            context.stroke(viewRect(forWorldRect: frame))
        default:
            break
        }
    }

    // MARK: Geometry helpers

    func worldToViewAffine(_ viewport: CanvasViewportTransform) -> CGAffineTransform {
        CGAffineTransform(
            a: viewport.scale, b: 0,
            c: 0, d: viewport.scale,
            tx: viewport.viewSize.width / 2 - viewport.center.x * viewport.scale,
            ty: viewport.viewSize.height / 2 - viewport.center.y * viewport.scale)
    }


    func viewRect(forWorldRect rect: DiagramRect) -> CGRect {
        CGRect(
            x: rect.x, y: rect.y,
            width: rect.width, height: rect.height)
            .applying(worldToViewAffine(store?.viewport
                ?? CanvasViewportTransform.fallback))
    }
    func viewPoint(forWorld world: DiagramPoint) -> CGPoint {
        guard let store else { return .zero }
        let p = store.viewport.worldToView(world)
        return CGPoint(x: p.x, y: p.y)
    }

    private func strokeGeometry(
        context: CGContext,
        geometry: DiagramEdgeGeometry,
        viewport: CanvasViewportTransform
    ) {
        var path = CGMutablePath()
        path.move(to: viewPoint(forWorld: .init(
            x: geometry.start.x, y: geometry.start.y)))
        for segment in geometry.segments {
            switch segment {
            case .line(let end):
                path.addLine(to: viewPoint(forWorld: .init(x: end.x, y: end.y)))
            case .cubic(let c1, let c2, let end):
                path.addCurve(
                    to: viewPoint(forWorld: .init(x: end.x, y: end.y)),
                    control1: viewPoint(forWorld: .init(x: c1.x, y: c1.y)),
                    control2: viewPoint(forWorld: .init(x: c2.x, y: c2.y)))
            }
        }
        context.addPath(path)
        context.strokePath()
    }

    private func drawArrowHead(
        context: CGContext,
        geometry: DiagramEdgeGeometry,
        viewport: CanvasViewportTransform,
        color: UIColor
    ) {
        guard let segment = geometry.segments.last else { return }
        let end = viewPoint(forWorld: .init(
            x: geometry.end.x, y: geometry.end.y))
        let beforeEnd: CGPoint
        switch segment {
        case .line(let point):
            beforeEnd = viewPoint(forWorld: .init(x: point.x, y: point.y))
        case .cubic(_, let c2, _):
            beforeEnd = viewPoint(forWorld: .init(x: c2.x, y: c2.y))
        }
        let angle = atan2(end.y - beforeEnd.y, end.x - beforeEnd.x)
        let length: CGFloat = 10
        var path = CGMutablePath()
        for sign in [-1, 1] {
            let theta = angle + CGFloat(sign) * .pi * 0.82
            let tip = CGPoint(
                x: end.x + length * cos(theta),
                y: end.y + length * sin(theta))
            path.move(to: end)
            path.addLine(to: tip)
        }
        context.setStrokeColor(color.cgColor)
        context.setLineWidth(1.5)
        context.addPath(path)
        context.strokePath()
    }

    private func drawEdgeLabel(
        _ label: String,
        geometry: DiagramEdgeGeometry,
        viewport: CanvasViewportTransform
    ) {
        guard viewport.scale >= 0.65 else { return }
        let mid = viewPoint(forWorld: .init(
            x: (geometry.start.x + geometry.end.x) / 2,
            y: (geometry.start.y + geometry.end.y) / 2))
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.preferredFont(forTextStyle: .caption2),
            .foregroundColor: UIColor.secondaryLabel,
        ]
        (label as NSString).draw(
            at: .init(x: mid.x + 4, y: mid.y - 14),
            withAttributes: attributes)
    }

    private func cardColor(for node: CanvasNodeSnapshot) -> UIColor {
        if let style = CanvasVisualStyle(metadata: node.metadata),
           let fill = style.fillColor {
            return ColorCompat.uiColor(fill) ?? .secondarySystemBackground
        }
        return .secondarySystemBackground
    }
}

// MARK: - Gestures

extension CanvasBoardView: UIGestureRecognizerDelegate {
    public override func gestureRecognizerShouldBegin(
        _ gestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        guard let store else { return false }
        if gestureRecognizer is UIPinchGestureRecognizer { return true }
        if let pan = gestureRecognizer as? UIPanGestureRecognizer {
            if pan.minimumNumberOfTouches == 2 { return true }
            // One-finger pan: hand tool pans; select tool drags nodes or
            // marquees — decided in handlePan using the hit test.
            return store.tool == .select || store.tool == .hand
                || store.tool == .connector
        }
        return store.tool == .select
    }

    @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
        guard let store else { return }
        let location = recognizer.location(in: self)
        let world = worldPoint(for: location)
        if store.tool == .connector {
            beginOrCompletePortConnection(at: world, extending: false)
            return
        }
        if let target = store.layoutIndex.hitTest(
            .init(x: world.x, y: world.y),
            zoom: store.viewport.scale,
            screenTolerance: 12) {
            switch target {
            case .node(let node):
                store.select(node.id)
            case .region:
                store.clearSelection()
            }
        } else {
            store.clearSelection()
        }
    }

    @objc private func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
        guard let store else { return }
        let world = worldPoint(for: recognizer.location(in: self))
        if let target = store.layoutIndex.hitTest(
            .init(x: world.x, y: world.y),
            zoom: store.viewport.scale,
            screenTolerance: 12),
           case .node(let node) = target {
            store.select(node.id)
            store.showsInspector = true
        }
    }

    @objc private func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
        guard let store else { return }
        switch recognizer.state {
        case .began, .changed:
            gestureState = .pinching
            let anchor = recognizer.location(in: self)
            if let next = try? store.viewport.zoomed(
                byFactor: recognizer.scale,
                anchorViewPoint: .init(x: anchor.x, y: anchor.y)) {
                store.setViewport(next)
            }
            recognizer.scale = 1
        case .ended, .cancelled, .failed:
            gestureState = .idle
        default: break
        }
    }

    @objc private func handlePanTwo(_ recognizer: UIPanGestureRecognizer) {
        guard let store else { return }
        switch recognizer.state {
        case .began:
            gestureState = .panning
        case .changed:
            let delta = recognizer.translation(in: self)
            recognizer.setTranslation(.zero, in: self)
            store.setViewport(store.viewport.panned(byViewDelta: .init(
                x: delta.x, y: delta.y)))
        case .ended, .cancelled:
            gestureState = .idle
        default:
            break
        }
    }

    @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
        guard let store else { return }
        let location = recognizer.location(in: self)
        let world = worldPoint(for: location)
        switch store.tool {
        case .hand:
            handlePanTwo(recognizer)
        case .connector:
            updatePortConnectionDrag(at: world, recognizer: recognizer)
        case .select:
            switch recognizer.state {
            case .began:
                let worldPoint = DiagramPoint(x: world.x, y: world.y)
                if let anchor = CanvasFlowEdgeLayout.hitTestPort(
                    store.visibleFlowPortAnchors(in: lastVisibleWorldRect),
                    point: worldPoint,
                    zoom: store.viewport.scale) {
                    gestureState = .connectingFlowPorts(
                        sourceNodeID: anchor.nodeID,
                        sourcePortID: anchor.id,
                        current: world,
                        target: nil)
                } else if let node = store.singleSelectedNode,
                          resizeHandleFrame(for: node).contains(location),
                          !node.isLocked {
                    gestureState = .resizing(
                        nodeID: node.id,
                        currentSize: node.frame.size)
                } else if let target = store.layoutIndex.hitTest(
                    worldPoint,
                    zoom: store.viewport.scale,
                    screenTolerance: 12),
                    case .node(let node) = target,
                    store.selection.contains(node.id) {
                    let centers = Dictionary(uniqueKeysWithValues:
                        store.selection.compactMap { id in
                            store.page.nodes.first(where: { $0.id == id })
                        }.map { ($0.id, $0.frame.center) })
                    gestureState = .movingNodes(
                        initialCenters: centers, currentDelta: .zero)
                } else if let target = store.layoutIndex.hitTest(
                    worldPoint, zoom: store.viewport.scale,
                    screenTolerance: 12),
                    case .node(let node) = target {
                    store.select(node.id)
                    let centers = [node.id: CanvasGeometry.Point(x: node.frame.center.x, y: node.frame.center.y)]
                    gestureState = .movingNodes(
                        initialCenters: centers, currentDelta: .zero)
                } else {
                    gestureState = .marquee(start: world, current: world)
                }
            case .changed:
                applyPanChange(at: world, translation: recognizer.translation(in: self))
            case .ended, .cancelled:
                finishPan(at: world)
            default:
                break
            }
        case .pencil, .lasso, .eraser:
            // Ink gestures are owned by CanvasInkOverlayView.
            break
        }
    }

    private func applyPanChange(
        at world: CanvasGeometry.Point,
        translation: CGPoint
    ) {
        guard let store else { return }
        let worldDelta = CanvasGeometry.Point(
            x: translation.x / store.viewport.scale,
            y: translation.y / store.viewport.scale)
        switch gestureState {
        case .movingNodes(let initial, _):
            gestureState = .movingNodes(
                initialCenters: initial, currentDelta: worldDelta)
        case .marquee(let start, _):
            gestureState = .marquee(start: start, current: world)
        case .resizing(let nodeID, _):
            guard let node = store.page.nodes.first(where: { $0.id == nodeID }) else { break }
            let initial = resizeStartSize ?? node.frame.size
            resizeStartSize = initial
            let newSize = CanvasGeometry.Size(
                width: max(40, initial.width + worldDelta.x),
                height: max(32, initial.height + worldDelta.y))
            gestureState = .resizing(nodeID: nodeID, currentSize: newSize)
        case .connectingFlowPorts(let sourceNode, let sourcePort, _, _):
            updatePortConnectionDrag(at: world, recognizer: nil)
        default:
            break
        }
    }


    private func finishPan(at world: CanvasGeometry.Point) {
        guard let store else { return }
        switch gestureState {
        case .movingNodes(let initial, let delta):
            let moves: [(UUID, CanvasGeometry.Point)] = initial.map { id, center in
                (id, .init(x: center.x + delta.x, y: center.y + delta.y))
            }
            if !moves.isEmpty {
                Task { await store.apply(.moveNodes(moves)) }
            }
        case .marquee(let start, let current):
            let rect = DiagramRect(
                x: min(start.x, current.x), y: min(start.y, current.y),
                width: abs(current.x - start.x), height: abs(current.y - start.y))
            let picked = store.layoutIndex.lasso(rect).map(\.id)
            store.select(Set(picked))
        case .resizing(let nodeID, let size):
            resizeStartSize = nil
            Task { await store.apply(.resizeNode(nodeID, size)) }
        case .connectingFlowPorts(let sourceNode, let sourcePort, _, let target):
            if let target {
                Task {
                    await store.apply(.connectFlowPorts(
                        sourceNodeID: sourceNode, sourcePortID: sourcePort,
                        destinationNodeID: target.nodeID,
                        destinationPortID: target.portID))
                }
            }
        default:
            break
        }
        gestureState = .idle
    }

    // MARK: Flow port connection

    private func beginOrCompletePortConnection(
        at world: CanvasGeometry.Point,
        extending: Bool
    ) {
        guard let store else { return }
        let point = DiagramPoint(x: world.x, y: world.y)
        let anchors = store.visibleFlowPortAnchors(in: lastVisibleWorldRect)
        if case .connectingFlowPorts(let sourceNode, let sourcePort, _, _) = gestureState {
            if let target = CanvasFlowEdgeLayout.hitTestPort(
                anchors, point: point, zoom: store.viewport.scale),
               target.nodeID != sourceNode || target.id != sourcePort {
                Task {
                    await store.apply(.connectFlowPorts(
                        sourceNodeID: sourceNode, sourcePortID: sourcePort,
                        destinationNodeID: target.nodeID,
                        destinationPortID: target.id))
                }
            }
            gestureState = .idle
            return
        }
        if let anchor = CanvasFlowEdgeLayout.hitTestPort(
            anchors, point: point, zoom: store.viewport.scale) {
            gestureState = .connectingFlowPorts(
                sourceNodeID: anchor.nodeID,
                sourcePortID: anchor.id,
                current: world,
                target: nil)
        }
    }

    private func updatePortConnectionDrag(
        at world: CanvasGeometry.Point,
        recognizer: UIPanGestureRecognizer?
    ) {
        guard let store,
              case .connectingFlowPorts(let sourceNode, let sourcePort, _, _) = gestureState else {
            return
        }
        let point = DiagramPoint(x: world.x, y: world.y)
        let anchors = store.visibleFlowPortAnchors(in: lastVisibleWorldRect)
        var target: (UUID, UUID)? = nil
        if let hit = CanvasFlowEdgeLayout.hitTestPort(
            anchors, point: point, zoom: store.viewport.scale),
           hit.nodeID != sourceNode || hit.id != sourcePort {
            // Validate before highlighting acceptance.
            if let graph = store.activeFlowGraph,
               let sourceFlowNode = graph.nodes.first(where: { $0.id == sourceNode }),
               let destinationFlowNode = graph.nodes.first(where: { $0.id == hit.nodeID }),
               let sourcePortModel = sourceFlowNode.ports.first(where: { $0.id == sourcePort }),
               let destinationPortModel = destinationFlowNode.ports.first(where: { $0.id == hit.id }),
               case .valid = CanvasFlowPortValidator.validate(
                   source: sourcePortModel, destination: destinationPortModel) {
                target = (hit.nodeID, hit.id)
            }
        }
        gestureState = .connectingFlowPorts(
            sourceNodeID: sourceNode,
            sourcePortID: sourcePort,
            current: world,
            target: target)
        if let recognizer, recognizer.state == .ended || recognizer.state == .cancelled {
            if let target {
                Task {
                    await store.apply(.connectFlowPorts(
                        sourceNodeID: sourceNode, sourcePortID: sourcePort,
                        destinationNodeID: target.0, destinationPortID: target.1))
                }
            }
            gestureState = .idle
        }
    }

    // MARK: Hit helpers

    private func resizeHandleFrame(for node: CanvasNodeSnapshot) -> CGRect {
        guard let store else { return .zero }
        let frame = viewRect(forWorldRect: CanvasLayoutGeometry.rect(from: node.frame))
        return CGRect(x: frame.maxX - 12, y: frame.maxY - 12, width: 24, height: 24)
    }
}

extension CanvasBoardView: UIContextMenuInteractionDelegate {
    public func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        configurationForMenuAtLocation location: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard let store else { return nil }
        let world = worldPoint(for: location)
        let point = DiagramPoint(x: world.x, y: world.y)
        guard let target = store.layoutIndex.hitTest(
            point, zoom: store.viewport.scale, screenTolerance: 12) else {
            return nil
        }
        switch target {
        case .node(let node):
            return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) {
                [weak self] _ in
                self?.nodeMenu(for: node.id, store: store) ?? UIMenu()
            }
        case .region(let region):
            return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in
                UIMenu(children: [
                    UIAction(title: region.isCollapsed
                        ? store.strings[.toolbarExpandRegion]
                        : store.strings[.toolbarCollapseRegion]) { _ in
                        Task {
                            await store.apply(.setRegionCollapsed(
                                region.id, !region.isCollapsed))
                        }
                    },
                ])
            }
        }
    }

    private func nodeMenu(for nodeID: UUID, store: CanvasEditorStore) -> UIMenu {
        store.select(nodeID)
        let strings = store.strings
        var children: [UIMenuElement] = [
            UIAction(title: strings[.toolbarDuplicate]) { _ in
                Task { await store.apply(.duplicateFlowCard(nodeID)) }
            },
            UIAction(title: strings[.toolbarDelete]) { _ in
                Task { await store.apply(.deleteSelection) }
            },
            UIAction(title: strings[.toolbarGroup]) { _ in
                Task { await store.apply(.groupSelection) }
            },
        ]
        if let node = store.page.nodes.first(where: { $0.id == nodeID }) {
            // Resource actions stay reachable from the board itself, not
            // only from the inspector (ICH04/editor gateway injection).
            if node.source != nil, store.services.sourceOpening != nil {
                children.append(UIAction(
                    title: strings[.inspectorOpenOriginal],
                    image: UIImage(systemName: "arrow.up.forward.app")) { _ in
                    Task { await store.openOriginalSource(nodeID: nodeID) }
                })
            }
            if case .editor = node.content {
                children.append(UIAction(
                    title: strings[.inspectorOpenEditor],
                    image: UIImage(systemName: "pencil.and.outline")) { _ in
                    Task { await store.openEditorForSelectedNode() }
                })
            }
        }
        return UIMenu(children: children)
    }
}

// MARK: - Small helpers

enum ColorCompat {
    /// Resolves the Core visual vocabulary (`#RGB/#RRGGBB/#RRGGBBAA` or
    /// lower-case names) to UIColor without inventing new spellings.
    static func uiColor(_ value: String) -> UIColor? {
        var text = value.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        if text.hasPrefix("#") {
            text.removeFirst()
            var channel: UInt64 = 0
            switch text.count {
            case 3:
                guard Scanner(string: text).scanHexInt64(&channel) else { return nil }
                let r = CGFloat((channel >> 8) & 0xF) / 15
                let g = CGFloat((channel >> 4) & 0xF) / 15
                let b = CGFloat(channel & 0xF) / 15
                return UIColor(red: r, green: g, blue: b, alpha: 1)
            case 6, 8:
                guard Scanner(string: text).scanHexInt64(&channel) else { return nil }
                let r = CGFloat((channel >> 16) & 0xFF) / 255
                let g = CGFloat((channel >> 8) & 0xFF) / 255
                let b = CGFloat(channel & 0xFF) / 255
                let a = text.count == 8
                    ? CGFloat((channel >> 24) & 0xFF) / 255
                    : 1
                return UIColor(red: r, green: g, blue: b, alpha: a)
            default:
                return nil
            }
        }
        switch text {
        case "red": return .systemRed
        case "orange": return .systemOrange
        case "yellow": return .systemYellow
        case "green": return .systemGreen
        case "blue": return .systemBlue
        case "purple": return .systemPurple
        case "gray", "grey": return .systemGray
        case "black": return .black
        case "white": return .white
        case "clear": return .clear
        default: return nil
        }
    }
}

extension CanvasViewportTransform {
    /// Guaranteed-valid emergency value; production paths always inject a
    /// real transform from the store.
    static var fallback: CanvasViewportTransform {
        try! CanvasViewportTransform(
            center: .zero, scale: 1,
            viewSize: .init(width: 1, height: 1))
    }
}

extension CanvasLODLevel {
    init(forZoom zoom: Double) { self = CanvasLODPolicy.level(forZoom: zoom) }
}

private extension UITapGestureRecognizer {
    var modifierFlagsShift: Bool {
        modifierFlags.contains(.shift)
    }
}

private extension DiagramRect {
    func offsetBy(dx: Double, dy: Double) -> DiagramRect {
        .init(x: x + dx, y: y + dy, width: width, height: height)
    }
}
#endif
