#if canImport(UIKit)
import UIKit
import FloeCanvasCore
import FloeCanvasLayout
import FloeDiagramExchange

/// Native mixed-content rendering for board node cards (P1c).
///
/// Every content kind renders as real structured content on the SAME board —
/// never a heavyweight editor per node and never a flattened plain-text
/// projection pretending to be the content:
/// - rich text draws its attributed runs (styles preserved);
/// - tables draw a real bounded grid (header + rows, truncation indicator);
/// - code draws monospaced lines with a language chip;
/// - formulas render through the public DiagramKit renderer
///   (`DiagramNativeRenderer`, reuse — no parallel renderer);
/// - media / PDF / rendered-formula assets draw host-provided bounded
///   thumbnails resolved by `CanvasBoardPreviewDemandController`.
///
/// All drawing is synchronous CoreGraphics inside the board's draw pass;
/// expensive or IO-bound work stays behind the host preview gate.
@MainActor
final class CanvasBoardNodeContentRenderer {

    // MARK: Formula

    /// One shared renderer: it owns the MathUILabel cache, matching the
    /// focused formula editor's reuse policy.
    private let formulaRenderer = DiagramNativeRenderer()
    /// Rendered formula bitmaps keyed by appearance+source; bounded and
    /// regenerable, so the draw pass never re-typesets the same formula.
    private let formulaCache = NSCache<NSString, UIImage>()

    init() {
        formulaCache.countLimit = 64
    }

    func updateAppearance(_ appearance: DiagramAppearance) {
        formulaRenderer.appearance = appearance
    }

    /// Rendered formula image, or nil when the source is invalid/empty.
    /// Synchronous and cache-backed; the draw pass stays cheap.
    func formulaImage(source: String) -> UIImage? {
        guard !source.isEmpty else { return nil }
        let key = "\(formulaRenderer.appearance == .dark ? "d" : "l")|\(source)" as NSString
        if let cached = formulaCache.object(forKey: key) { return cached }
        guard formulaRenderer.formulaIsValid(source) else { return nil }
        let size = CGSize(width: 360, height: 96)
        let format = UIGraphicsImageRendererFormat()
        format.scale = UIScreen.main.scale
        format.opaque = false
        let image = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            formulaRenderer.drawFormula(
                source,
                rect: .init(x: 0, y: 0, width: size.width, height: size.height),
                context: ctx.cgContext)
        }
        formulaCache.setObject(image, forKey: key)
        return image
    }

    // MARK: Rich text

    /// Maps Core attributed runs to UIKit attributes. Pure attribute logic
    /// (fonts/colors) so tests can assert the mapping without a graphics
    /// context.
    func attributedString(for document: CanvasRichTextDocument) -> NSAttributedString {
        let base = UIFont.preferredFont(forTextStyle: .footnote)
        let result = NSMutableAttributedString()
        for run in document.runs {
            var traits: UIFontDescriptor.SymbolicTraits = []
            if run.bold { traits.insert(.traitBold) }
            if run.italic { traits.insert(.traitItalic) }
            let font: UIFont
            if traits.isEmpty {
                font = base
            } else {
                font = base.fontDescriptor.withSymbolicTraits(traits)
                    .map { UIFont(descriptor: $0, size: base.pointSize) } ?? base
            }
            var attributes: [NSAttributedString.Key: Any] = [
                .font: font,
            ]
            var color = UIColor.label
            if let link = run.link {
                color = .systemBlue
                attributes[.link] = link
            } else if let foreground = run.foregroundColor,
                      let resolved = ColorCompat.uiColor(foreground) {
                color = resolved
            }
            attributes[.foregroundColor] = color
            if run.underline || run.link != nil {
                attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
            }
            if run.strikethrough {
                attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            }
            result.append(NSAttributedString(string: run.text, attributes: attributes))
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        result.addAttribute(
            .paragraphStyle,
            value: paragraph,
            range: NSRange(location: 0, length: result.length))
        return result
    }

    func drawRichText(
        _ document: CanvasRichTextDocument,
        in rect: CGRect,
        context: CGContext
    ) {
        guard rect.width > 4, rect.height > 4 else { return }
        let attributed = attributedString(for: document)
        guard attributed.length > 0 else { return }
        context.saveGState()
        context.clip(to: rect)
        attributed.draw(
            with: rect,
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
            context: nil)
        context.restoreGState()
    }

    // MARK: Plain text (text / markdown / shape text)

    func drawPlainText(
        _ text: String,
        in rect: CGRect,
        context: CGContext,
        font: UIFont = UIFont.preferredFont(forTextStyle: .footnote),
        color: UIColor = .label
    ) {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty, rect.width > 4, rect.height > 4 else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
        ]
        context.saveGState()
        context.clip(to: rect)
        (body as NSString).draw(
            with: rect,
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
            attributes: attributes,
            context: nil)
        context.restoreGState()
    }

    // MARK: Table

    /// Bounded grid layout for a table card. Pure value so tests can assert
    /// truncation behaviour without CoreGraphics.
    struct TableLayout: Equatable {
        struct Cell: Equatable {
            var rect: CGRect
            var text: String
            var isHeader: Bool
        }
        var cells: [Cell]
        var columnCount: Int
        var truncatedRowCount: Int

        var showsMoreIndicator: Bool { truncatedRowCount > 0 }
    }

    func tableLayout(
        header: [String],
        rows: [[String]],
        in rect: CGRect
    ) -> TableLayout? {
        let columnCount = max(header.count, rows.map(\.count).max() ?? 0)
        guard columnCount > 0, rect.width > 8, rect.height > 8 else { return nil }
        let headerHeight: CGFloat = 20
        let rowHeight: CGFloat = 18
        let maxRows = max(0, Int((rect.height - headerHeight) / rowHeight))
        guard maxRows > 0 else { return nil }
        let visibleRows = rows.prefix(maxRows)
        let columnWidth = rect.width / CGFloat(columnCount)
        var cells: [TableLayout.Cell] = []
        for (index, text) in header.enumerated() {
            cells.append(.init(
                rect: CGRect(
                    x: rect.minX + CGFloat(index) * columnWidth,
                    y: rect.minY,
                    width: columnWidth,
                    height: headerHeight),
                text: String(text.prefix(48)),
                isHeader: true))
        }
        for (rowIndex, row) in visibleRows.enumerated() {
            for (columnIndex, text) in row.enumerated() {
                cells.append(.init(
                    rect: CGRect(
                        x: rect.minX + CGFloat(columnIndex) * columnWidth,
                        y: rect.minY + headerHeight + CGFloat(rowIndex) * rowHeight,
                        width: columnWidth,
                        height: rowHeight),
                    text: String(text.prefix(48)),
                    isHeader: false))
            }
        }
        return TableLayout(
            cells: cells,
            columnCount: columnCount,
            truncatedRowCount: rows.count - visibleRows.count)
    }

    func drawTable(
        header: [String],
        rows: [[String]],
        in rect: CGRect,
        context: CGContext,
        moreIndicator: String
    ) {
        guard let layout = tableLayout(header: header, rows: rows, in: rect) else { return }
        let headerFont = UIFont.boldSystemFont(ofSize: 12)
        let cellFont = UIFont.systemFont(ofSize: 12)
        context.saveGState()
        context.clip(to: rect)
        for cell in layout.cells {
            if cell.isHeader {
                context.setFillColor(UIColor.quaternaryLabel.withAlphaComponent(0.12).cgColor)
                context.fill(cell.rect)
            }
            let attributes: [NSAttributedString.Key: Any] = [
                .font: cell.isHeader ? headerFont : cellFont,
                .foregroundColor: cell.isHeader
                    ? UIColor.label : UIColor.secondaryLabel,
            ]
            let textRect = cell.rect.insetBy(dx: 4, dy: 3)
            (cell.text as NSString).draw(
                with: textRect,
                options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                attributes: attributes,
                context: nil)
        }
        // Grid lines.
        context.setStrokeColor(UIColor.separator.withAlphaComponent(0.6).cgColor)
        context.setLineWidth(0.5)
        let headerPath = CGMutablePath()
        headerPath.move(to: CGPoint(x: rect.minX, y: rect.minY + 20))
        headerPath.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + 20))
        context.addPath(headerPath)
        context.strokePath()
        if layout.showsMoreIndicator {
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 11),
                .foregroundColor: UIColor.tertiaryLabel,
            ]
            (moreIndicator as NSString).draw(
                at: CGPoint(x: rect.minX + 4, y: rect.maxY - 15),
                withAttributes: attributes)
        }
        context.restoreGState()
    }

    // MARK: Code

    /// Bounded code layout: how many monospaced lines fit, and how many are
    /// clipped. Pure value for tests.
    struct CodeLayout: Equatable {
        var visibleLineCount: Int
        var truncatedLineCount: Int
        var showsLanguageChip: Bool
    }

    func codeLayout(source: String, language: String?, in rect: CGRect) -> CodeLayout? {
        guard rect.width > 8, rect.height > 8 else { return nil }
        let chipHeight: CGFloat = (language?.isEmpty == false) ? 14 : 0
        let lineHeight: CGFloat = 15
        let available = rect.height - chipHeight - (chipHeight > 0 ? 4 : 0)
        guard available > lineHeight else {
            return CodeLayout(
                visibleLineCount: 0,
                truncatedLineCount: source.isEmpty ? 0 : 1,
                showsLanguageChip: chipHeight > 0)
        }
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
        let maxLines = Int(available / lineHeight)
        let visible = min(lines.count, maxLines)
        return CodeLayout(
            visibleLineCount: visible,
            truncatedLineCount: lines.count - visible,
            showsLanguageChip: chipHeight > 0)
    }

    func drawCode(
        source: String,
        language: String?,
        in rect: CGRect,
        context: CGContext
    ) {
        guard let layout = codeLayout(source: source, language: language, in: rect) else { return }
        let font = UIFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        context.saveGState()
        context.clip(to: rect)
        var y = rect.minY
        if layout.showsLanguageChip, let language {
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 10, weight: .medium),
                .foregroundColor: UIColor.secondaryLabel,
            ]
            (language as NSString).draw(
                at: CGPoint(x: rect.minX, y: y),
                withAttributes: attributes)
            y += 14 + 4
        }
        if layout.visibleLineCount > 0 {
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: UIColor.label,
            ]
            let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
                .prefix(layout.visibleLineCount)
            for line in lines {
                let text = line.count > 400 ? String(line.prefix(400)) + "…" : String(line)
                (text as NSString).draw(
                    with: CGRect(x: rect.minX, y: y, width: rect.width, height: 15),
                    options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                    attributes: attributes,
                    context: nil)
                y += 15
            }
        }
        context.restoreGState()
    }

    // MARK: Web

    func drawWebReference(
        url: URL,
        title: String?,
        in rect: CGRect,
        context: CGContext
    ) {
        guard rect.width > 4, rect.height > 4 else { return }
        let headline = title ?? url.absoluteString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.preferredFont(forTextStyle: .footnote),
            .foregroundColor: UIColor.label,
        ]
        context.saveGState()
        context.clip(to: rect)
        (headline as NSString).draw(
            with: CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: min(34, rect.height)),
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
            attributes: attributes,
            context: nil)
        if title != nil {
            let linkAttributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 11),
                .foregroundColor: UIColor.secondaryLabel,
            ]
            (url.absoluteString as NSString).draw(
                with: CGRect(
                    x: rect.minX,
                    y: rect.minY + min(34, rect.height) + 2,
                    width: rect.width,
                    height: max(0, rect.height - min(34, rect.height) - 2)),
                options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                attributes: linkAttributes,
                context: nil)
        }
        context.restoreGState()
    }

    // MARK: Editor reference chip

    func drawEditorReference(
        _ reference: CanvasEditorReference,
        openActionTitle: String?,
        in rect: CGRect,
        context: CGContext
    ) {
        guard rect.width > 4, rect.height > 4 else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.preferredFont(forTextStyle: .footnote),
            .foregroundColor: UIColor.label,
        ]
        (reference.editorKind as NSString).draw(
            with: CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: 18),
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
            attributes: attributes,
            context: nil)
        if let openActionTitle {
            let actionAttributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 11),
                .foregroundColor: UIColor.systemBlue,
            ]
            (openActionTitle as NSString).draw(
                at: CGPoint(x: rect.minX, y: rect.minY + 22),
                withAttributes: actionAttributes)
        }
    }

    // MARK: Preview image + resource placeholders

    /// Aspect-fit thumbnail inside the card content rect.
    func drawPreviewImage(_ image: UIImage, in rect: CGRect, context: CGContext) {
        let scale = min(rect.width / image.size.width, rect.height / image.size.height)
        guard scale.isFinite, scale > 0 else { return }
        let size = CGSize(
            width: image.size.width * scale,
            height: image.size.height * scale)
        let target = CGRect(
            x: rect.midX - size.width / 2,
            y: rect.midY - size.height / 2,
            width: size.width,
            height: size.height)
        context.saveGState()
        context.clip(to: rect)
        image.draw(in: target)
        context.restoreGState()
    }

    /// Lightweight neutral placeholder while a bounded request is in flight.
    /// Never sold as content: dashed frame + kind icon only.
    func drawResourcePending(
        in rect: CGRect,
        systemImage: String,
        context: CGContext
    ) {
        context.saveGState()
        context.setStrokeColor(UIColor.tertiaryLabel.withAlphaComponent(0.5).cgColor)
        context.setLineDash(phase: 0, lengths: [4, 3])
        context.setLineWidth(0.75)
        let dashed = UIBezierPath(roundedRect: rect.insetBy(dx: 2, dy: 2), cornerRadius: 6).cgPath
        context.addPath(dashed)
        context.strokePath()
        context.setLineDash(phase: 0, lengths: [])
        let icon = UIImage(systemName: systemImage)?
            .withTintColor(.tertiaryLabel, renderingMode: .alwaysOriginal)
        let iconSize = CGSize(width: 22, height: 22)
        icon?.draw(in: CGRect(
            x: rect.midX - iconSize.width / 2,
            y: rect.midY - iconSize.height / 2,
            width: iconSize.width,
            height: iconSize.height))
        context.restoreGState()
    }

    /// Actionable missing state (orange, labelled). Used only when the host
    /// genuinely cannot resolve the resource — never for in-flight work.
    func drawResourceMissing(
        in rect: CGRect,
        label: String,
        systemImage: String,
        context: CGContext
    ) {
        drawResourcePending(in: rect, systemImage: systemImage, context: context)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 11),
            .foregroundColor: UIColor.systemOrange,
        ]
        (label as NSString).draw(
            at: CGPoint(x: rect.minX + 6, y: rect.maxY - 16),
            withAttributes: attributes)
    }
}

// MARK: - Bounded preview demand

/// Board-side demand lifecycle for host-provided thumbnails.
///
/// The controller sits between the draw pass and the shared
/// `CanvasPreviewPipeline` (which stays the single cache/cancellation owner).
/// Guarantees (UI_BRIEF):
/// - visible-only: demand is registered exclusively for keys that were on
///   screen in the current draw pass;
/// - coalesced by key: one request per `contentHash+kind+maxPixel` identity;
/// - bounded: at most `maxConcurrent` in-flight and `maxQueued` queued; the
///   draw pass starts at most `maxConcurrent` new tasks per frame — never a
///   per-frame task flood;
/// - fenced: results arriving after a layout/page invalidate (generation
///   change) are discarded and never touch the board;
/// - cancelled: queued work for keys that scrolled away is dropped before it
///   starts; in-flight work is cancelled at layout/page boundaries;
/// - honest: provider-missing and failed keys are remembered as unavailable
///   (actionable missing state) instead of being re-requested every frame.
@MainActor
final class CanvasBoardPreviewDemandController {

    enum Status: Equatable {
        /// No preview provider configured — permanent missing state.
        case unavailableProvider
        /// The host tried and could not produce a preview.
        case failed
        /// Queued or in flight — neutral placeholder, NOT missing.
        case pending
        /// No demand registered yet (first visible frame).
        case idle
    }

    struct Demand: Hashable {
        var key: String
        var locator: CanvasAssetLocator
        var contentKind: String?
        var maxPixelSize: Int
    }

    static let maxConcurrent = 6
    static let maxQueued = 32

    private weak var pipeline: CanvasPreviewPipeline?
    private var onImageReady: (@MainActor () -> Void)?
    private var generation: UInt64 = 0
    private var queued: [Demand] = []
    private var queuedKeys: Set<String> = []
    private var inFlight: [String: Demand] = [:]
    private var failedKeys: Set<String> = []
    /// Keys whose resource rect was actually drawn in the current pass.
    private var passKeys: Set<String> = []
    /// Keys visible in the most recent completed draw pass.
    private var visibleKeys: Set<String> = []

    init(
        pipeline: CanvasPreviewPipeline?,
        onImageReady: (@MainActor () -> Void)? = nil
    ) {
        self.pipeline = pipeline
        self.onImageReady = onImageReady
    }

    func attach(
        pipeline: CanvasPreviewPipeline?,
        onImageReady: (@MainActor () -> Void)?
    ) {
        self.pipeline = pipeline
        self.onImageReady = onImageReady
        invalidateAll()
    }

    // MARK: Draw-pass API
    func beginDrawPass() { passKeys.removeAll(keepingCapacity: true) }

    /// Synchronous lookup used while drawing a card. Records the resource as
    /// visible for this draw pass, returns the cached image, or registers a
    /// bounded demand and returns nil.
    func image(
        locator: CanvasAssetLocator,
        contentKind: String?,
        maxPixelSize: Int = 256
    ) -> UIImage? {
        guard let pipeline else { return nil }
        passKeys.insert(pipeline.demandKey(for: locator, maxPixelSize: maxPixelSize))
        if let cached = pipeline.cachedImage(
            for: locator, contentKind: contentKind, maxPixelSize: maxPixelSize) {
            return cached
        }
        registerDemand(locator: locator, contentKind: contentKind, maxPixelSize: maxPixelSize)
        return nil
    }

    func status(
        locator: CanvasAssetLocator,
        contentKind: String?,
        maxPixelSize: Int = 256
    ) -> Status {
        guard let pipeline, pipeline.hasProvider else { return .unavailableProvider }
        if pipeline.cachedImage(
            for: locator, contentKind: contentKind, maxPixelSize: maxPixelSize) != nil {
            return .idle
        }
        let key = pipeline.demandKey(for: locator, maxPixelSize: maxPixelSize)
        if failedKeys.contains(key) { return .failed }
        if queuedKeys.contains(key) || inFlight[key] != nil { return .pending }
        return .idle
    }

    /// Reconcile demand with the resources that were actually drawn this
    /// pass: drop queued work that scrolled away before it started, then
    /// start queued work up to the concurrency budget. Called once at the
    /// end of each draw pass (never per node).
    func reconcileVisibleDemand() {
        visibleKeys = passKeys
        passKeys.removeAll(keepingCapacity: true)
        // Drop queued work whose node scrolled away before it started.
        if !queued.isEmpty {
            let kept = queued.filter { visibleKeys.contains($0.key) }
            if kept.count != queued.count {
                queued = kept
                queuedKeys = Set(kept.map(\.key))
            }
        }
        while inFlight.count < Self.maxConcurrent, !queued.isEmpty {
            let demand = queued.removeFirst()
            queuedKeys.remove(demand.key)
            guard visibleKeys.contains(demand.key), inFlight[demand.key] == nil else {
                continue
            }
            inFlight[demand.key] = demand
            start(demand)
        }
    }

    /// Layout / snapshot / page boundary: fence in-flight results, cancel
    /// pipeline requests and reset all demand state. The pipeline's image
    /// cache survives (re-entry after back-scroll stays instant).
    func invalidateAll() {
        generation &+= 1
        if let pipeline {
            for demand in inFlight.values {
                pipeline.cancelInFlight(
                    for: demand.locator, maxPixelSize: demand.maxPixelSize)
            }
        }
        queued.removeAll()
        queuedKeys.removeAll()
        inFlight.removeAll()
        failedKeys.removeAll()
        visibleKeys.removeAll()
        passKeys.removeAll()
    }

    // MARK: Internals

    private func registerDemand(
        locator: CanvasAssetLocator,
        contentKind: String?,
        maxPixelSize: Int
    ) {
        guard let pipeline else { return }
        let key = pipeline.demandKey(for: locator, maxPixelSize: maxPixelSize)
        guard !queuedKeys.contains(key),
              inFlight[key] == nil,
              !failedKeys.contains(key),
              queued.count < Self.maxQueued else { return }
        queued.append(Demand(
            key: key,
            locator: locator,
            contentKind: contentKind,
            maxPixelSize: maxPixelSize))
        queuedKeys.insert(key)
    }

    private func start(_ demand: Demand) {
        guard let pipeline else {
            inFlight.removeValue(forKey: demand.key)
            return
        }
        let requestGeneration = generation
        Task { @MainActor [weak self] in
            guard let self else { return }
            let entry = await pipeline.preview(
                for: demand.locator,
                contentKind: demand.contentKind,
                maxPixelSize: demand.maxPixelSize)
            // Fenced: a page/layout invalidation during the request discards
            // the result entirely (stale or cancelled work never draws).
            guard self.generation == requestGeneration else { return }
            self.inFlight.removeValue(forKey: demand.key)
            guard entry != nil else {
                // The host could not resolve this resource: remember so the
                // board shows the actionable missing state instead of
                // re-requesting every frame.
                self.failedKeys.insert(demand.key)
                self.onImageReady?()
                return
            }
            self.onImageReady?()
            // Fill freed slots from the most recent visible demand without
            // requiring an unrelated draw pass to wake the remaining queue.
            while self.inFlight.count < Self.maxConcurrent, !self.queued.isEmpty {
                let next = self.queued.removeFirst()
                self.queuedKeys.remove(next.key)
                guard self.visibleKeys.contains(next.key), self.inFlight[next.key] == nil else { continue }
                self.inFlight[next.key] = next
                self.start(next)
            }
        }
    }
}
#endif
