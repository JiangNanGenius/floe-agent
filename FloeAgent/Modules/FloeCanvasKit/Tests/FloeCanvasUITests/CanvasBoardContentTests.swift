#if canImport(UIKit)
import XCTest
@testable import FloeCanvasUI
import FloeCanvasCore
import FloeCanvasIntegration
import FloeCanvasLayout
import UIKit

/// P1c board mixed-content regression tests: structured rendering mappings
/// and the bounded preview demand lifecycle. Source-only evidence (the
/// coordinator runs the native compile/host acceptance).
@MainActor
final class CanvasBoardContentTests: XCTestCase {
    func testZoomedCardLabelsStayInsideTheirActualGeometry() async throws {
        let node = CanvasNodeSnapshot(content: .shape(kind: .diamond,
            text: String(repeating: "Long label 中文 ", count: 20)),
            frame: .init(center: .zero, size: .init(width: 160, height: 100)))
        var snapshot = CanvasTestStubs.snapshot(nodes: [node])
        snapshot.pages[0].background = .blank
        let store = CanvasEditorStore(canvasID: snapshot.id,
            services: CanvasEditorServices(documentStore: InMemoryCanvasRepository(snapshot: snapshot)))
        await store.load()
        let board = CanvasBoardView(frame: CGRect(x: 0, y: 0, width: 600, height: 400))
        board.overrideUserInterfaceStyle = .light
        board.bind(to: store)
        board.layoutIfNeeded()
        for scale in [0.22, 0.5, 1.0] {
            store.setViewport(try CanvasViewportTransform(center: .zero, scale: scale,
                viewSize: .init(width: 600, height: 400)))
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            format.opaque = true
            let image = UIGraphicsImageRenderer(size: board.bounds.size, format: format).image { _ in
                board.draw(board.bounds)
            }
            let cgImage = try XCTUnwrap(image.cgImage)
            var pixels = [UInt8](repeating: 255, count: 600 * 400 * 4)
            try pixels.withUnsafeMutableBytes { bytes in
                let context = try XCTUnwrap(CGContext(data: bytes.baseAddress, width: 600, height: 400,
                    bitsPerComponent: 8, bytesPerRow: 600 * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue))
                context.draw(cgImage, in: board.bounds)
            }
            let expected = CGRect(x: 300 - 80 * scale, y: 200 - 50 * scale,
                width: 160 * scale, height: 100 * scale).insetBy(dx: -2, dy: -2)
            var outside = 0
            var inside = 0
            for y in 0..<400 {
                for x in 0..<600 {
                    let offset = (y * 600 + x) * 4
                    if pixels[offset..<offset + 3].min()! < 230 {
                        if expected.contains(CGPoint(x: x, y: y)) { inside += 1 }
                        else { outside += 1 }
                    }
                }
            }
            XCTAssertGreaterThan(inside, 10, "the actual card is rendered at zoom \(scale)")
            XCTAssertEqual(outside, 0, "long labels must not paint over neighboring cards at zoom \(scale)")
        }
    }

    // MARK: Rich text mapping

    func testRichTextAttributedStringMapsRunStyles() {
        let renderer = CanvasBoardNodeContentRenderer()
        let document = CanvasRichTextDocument(runs: [
            CanvasRichTextRun(text: "bold ", bold: true),
            CanvasRichTextRun(text: "italic", italic: true),
            CanvasRichTextRun(text: "under", underline: true),
            CanvasRichTextRun(text: "struck", strikethrough: true),
            CanvasRichTextRun(text: "red", foregroundColor: "#FF0000"),
            CanvasRichTextRun(text: "link", link: URL(string: "https://example.com")),
        ])
        let attributed = renderer.attributedString(for: document)
        XCTAssertEqual(attributed.length, document.plainText.utf16.count)

        func traits(at substring: String) -> UIFontDescriptor.SymbolicTraits {
            let range = (document.plainText as NSString).range(of: substring)
            guard range.location != NSNotFound,
                  let font = attributed.attribute(.font, at: range.location, effectiveRange: nil) as? UIFont else {
                return []
            }
            return font.fontDescriptor.symbolicTraits
        }
        XCTAssertTrue(traits(at: "bold").contains(.traitBold))
        XCTAssertTrue(traits(at: "italic").contains(.traitItalic))
        XCTAssertFalse(traits(at: "bold").contains(.traitItalic))

        func numberAttribute(_ key: NSAttributedString.Key, at substring: String) -> Int? {
            let range = (document.plainText as NSString).range(of: substring)
            guard range.location != NSNotFound else { return nil }
            return attributed.attribute(key, at: range.location, effectiveRange: nil) as? Int
        }
        XCTAssertEqual(numberAttribute(.underlineStyle, at: "under"), NSUnderlineStyle.single.rawValue)
        XCTAssertEqual(numberAttribute(.strikethroughStyle, at: "struck"), NSUnderlineStyle.single.rawValue)
        // A link is underlined and tinted blue like the focused editor.
        XCTAssertEqual(numberAttribute(.underlineStyle, at: "link"), NSUnderlineStyle.single.rawValue)

        func color(at substring: String) -> UIColor? {
            let range = (document.plainText as NSString).range(of: substring)
            guard range.location != NSNotFound else { return nil }
            return attributed.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? UIColor
        }
        var redValue: CGFloat = 0
        color(at: "red")?.getRed(&redValue, green: nil, blue: nil, alpha: nil)
        XCTAssertEqual(redValue, 1, accuracy: 0.01, "canonical hex color maps to UIColor")
        XCTAssertEqual(color(at: "link"), .systemBlue)

        let range = (document.plainText as NSString).range(of: "link")
        let link = attributed.attribute(.link, at: range.location, effectiveRange: nil) as? URL
        XCTAssertEqual(link, URL(string: "https://example.com"))

        // Truncating paragraph style so long cards clip instead of overflow.
        let paragraph = attributed.attribute(
            .paragraphStyle,
            at: 0,
            effectiveRange: nil) as? NSParagraphStyle
        XCTAssertEqual(paragraph?.lineBreakMode, .byTruncatingTail)
    }

    // MARK: Table layout

    func testTableLayoutTruncatesRowsAndKeepsHeader() {
        let renderer = CanvasBoardNodeContentRenderer()
        let header = ["Name", "Value"]
        let rows = (1...8).map { ["row\($0)", "\($0)"] }
        // 20pt header + 18pt rows: 100pt height fits header + 4 rows.
        let rect = CGRect(x: 0, y: 0, width: 200, height: 100)
        let layout = renderer.tableLayout(header: header, rows: rows, in: rect)
        XCTAssertEqual(layout?.columnCount, 2)
        XCTAssertEqual(layout?.truncatedRowCount, 4)
        XCTAssertEqual(layout?.showsMoreIndicator, true)
        XCTAssertEqual(layout?.cells.filter(\.isHeader).count, 2)
        // Header sits at the top, first body row right below it.
        XCTAssertEqual(layout?.cells.first?.rect.minY, 0)
        let firstBody = layout?.cells.first(where: { !$0.isHeader })
        XCTAssertEqual(firstBody?.rect.minY, 20)
        XCTAssertEqual(firstBody?.rect.height, 18)
    }

    func testTableLayoutNilForEmptyOrTinyContent() {
        let renderer = CanvasBoardNodeContentRenderer()
        XCTAssertNil(renderer.tableLayout(header: [], rows: [], in: .init(x: 0, y: 0, width: 100, height: 100)))
        XCTAssertNil(renderer.tableLayout(header: ["a"], rows: [], in: .init(x: 0, y: 0, width: 100, height: 6)))
        // Height too small for even one row under the header.
        XCTAssertNil(renderer.tableLayout(header: ["a"], rows: [], in: .init(x: 0, y: 0, width: 100, height: 30)))
    }

    // MARK: Code layout

    func testCodeLayoutCountsVisibleLinesAndClipping() {
        let renderer = CanvasBoardNodeContentRenderer()
        let source = "one\ntwo\nthree\nfour"
        // chip 14 + 4 gap, line height 15: 60pt height fits 2 lines.
        let layout = renderer.codeLayout(
            source: source, language: "swift", in: .init(x: 0, y: 0, width: 200, height: 60))
        XCTAssertEqual(layout?.showsLanguageChip, true)
        XCTAssertEqual(layout?.visibleLineCount, 2)
        XCTAssertEqual(layout?.truncatedLineCount, 2)
    }

    func testCodeLayoutWithoutLanguageUsesFullHeight() {
        let renderer = CanvasBoardNodeContentRenderer()
        let layout = renderer.codeLayout(
            source: "a\nb", language: nil, in: .init(x: 0, y: 0, width: 200, height: 40))
        XCTAssertEqual(layout?.showsLanguageChip, false)
        XCTAssertEqual(layout?.visibleLineCount, 2)
        XCTAssertEqual(layout?.truncatedLineCount, 0)
    }

    // MARK: Formula

    func testFormulaImageRendersValidSource() {
        let renderer = CanvasBoardNodeContentRenderer()
        let image = renderer.formulaImage(source: "E = mc^2")
        XCTAssertNotNil(image, "valid LaTeX renders through the public DiagramKit renderer")
        XCTAssertGreaterThan(image?.size.width ?? 0, 0)
    }

    func testFormulaImageNilForInvalidSource() {
        let renderer = CanvasBoardNodeContentRenderer()
        XCTAssertNil(renderer.formulaImage(source: ""))
        // Unbalanced brace groups are refused by the shared renderer.
        XCTAssertNil(renderer.formulaImage(source: "\\frac{{{broken"))
    }

    // MARK: Demand lifecycle

    @MainActor
    final class FakePreviewProvider: CanvasPreviewProviding {
        struct Call: Hashable {
            var assetID: UUID
            var maxPixelSize: Int
        }
        var calls: [Call] = []
        var results: [UUID: CanvasPreviewResult] = [:]
        var delays: [UUID: UInt64] = [:]
        /// Continuations held until released, for fence/cancel tests. One
        /// entry per gated call so same-key replacement pairs can be
        /// released independently of bookkeeping order.
        var gates: [UUID: [CheckedContinuation<CanvasPreviewResult, Error>]] = [:]
        var gateAssets: Set<UUID> = []
        var observedConcurrent = 0
        var maxObservedConcurrent = 0

        func preview(
            _ request: CanvasPreviewRequest,
            cancellation token: CanvasCancellationToken?
        ) async throws -> CanvasPreviewResult {
            calls.append(.init(assetID: request.locator.id, maxPixelSize: request.maxPixelSize))
            observedConcurrent += 1
            maxObservedConcurrent = max(maxObservedConcurrent, observedConcurrent)
            defer { observedConcurrent -= 1 }
            if let delay = delays[request.locator.id] {
                try? await Task.sleep(nanoseconds: delay)
            }
            if gateAssets.contains(request.locator.id) {
                return try await withCheckedThrowingContinuation { continuation in
                    gates[request.locator.id, default: []].append(continuation)
                }
            }
            if token?.isCancelled == true { throw CanvasKitError.cancelled }
            if let result = results[request.locator.id] { return result }
            throw CanvasKitError.io("no preview available")
        }

        func releaseGate(_ assetID: UUID, with result: CanvasPreviewResult?) {
            guard let stack = gates[assetID] else { return }
            gates[assetID] = nil
            for gate in stack {
                if let result {
                    gate.resume(returning: result)
                } else {
                    gate.resume(throwing: CanvasKitError.cancelled)
                }
            }
        }

        /// Resumes only the oldest gated call for the asset; the rest stay
        /// gated (deterministic same-key replacement lifecycles).
        func releaseOldestGate(_ assetID: UUID, with result: CanvasPreviewResult?) {
            guard var stack = gates[assetID], let gate = stack.first else { return }
            stack.removeFirst()
            gates[assetID] = stack.isEmpty ? nil : stack
            if let result {
                gate.resume(returning: result)
            } else {
                gate.resume(throwing: CanvasKitError.cancelled)
            }
        }
    }

    private func tinyPNGResult() -> CanvasPreviewResult {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { ctx in
            UIColor.red.setFill()
            ctx.fill(.init(origin: .zero, size: .init(width: 4, height: 4)))
        }
        return CanvasPreviewResult(
            data: image.pngData() ?? Data(),
            mimeType: "image/png",
            pixelWidth: 4,
            pixelHeight: 4,
            isPlaceholder: false,
            sourceByteCount: 16,
            cacheKey: "test")
    }

    func testDemandCoalescesDuplicateKeysAndCachesResult() async {
        let provider = FakePreviewProvider()
        let pipeline = CanvasPreviewPipeline(provider: provider)
        var readyCount = 0
        let demand = CanvasBoardPreviewDemandController(pipeline: pipeline) { readyCount += 1 }
        let locator = CanvasAssetLocator(id: UUID(), contentHash: "h1", mimeType: "image/png")
        provider.results[locator.id] = tinyPNGResult()

        // Same key drawn twice in one pass: one provider call.
        _ = demand.image(locator: locator, contentKind: "image/png")
        _ = demand.image(locator: locator, contentKind: "image/png")
        demand.reconcileVisibleDemand()
        await waitFor { provider.calls.count == 1 }

        // Let the request complete, then reconcile the redraw.
        await waitFor { !provider.calls.isEmpty }
        await waitFor { pipeline.cachedImage(for: locator, contentKind: "image/png", maxPixelSize: 256) != nil }
        _ = demand.image(locator: locator, contentKind: "image/png")
        demand.reconcileVisibleDemand()
        XCTAssertEqual(provider.calls.count, 1, "cached result served without a second request")
        XCTAssertEqual(readyCount, 1)
    }

    func testQueuedOffscreenDemandDroppedBeforeStart() async {
        let provider = FakePreviewProvider()
        let pipeline = CanvasPreviewPipeline(provider: provider)
        let demand = CanvasBoardPreviewDemandController(pipeline: pipeline)
        let onScreen = CanvasAssetLocator(id: UUID(), mimeType: "image/png")
        let scrolledAway = CanvasAssetLocator(id: UUID(), mimeType: "image/png")

        _ = demand.image(locator: onScreen, contentKind: "image/png")
        _ = demand.image(locator: scrolledAway, contentKind: "image/png")
        // Pass 2 draws only the first resource: the second must be dropped
        // from the queue before any work starts.
        demand.beginDrawPass()
        _ = demand.image(locator: onScreen, contentKind: "image/png")
        demand.reconcileVisibleDemand()
        await waitFor { provider.calls.count == 1 }
        XCTAssertEqual(provider.calls.map(\.assetID), [onScreen.id],
                       "offscreen queued demand is cancelled before it starts")
    }

    func testFailedResourceIsHonestMissingAndNotRetriedEveryFrame() async {
        let provider = FakePreviewProvider()
        let pipeline = CanvasPreviewPipeline(provider: provider)
        let demand = CanvasBoardPreviewDemandController(pipeline: pipeline)
        let locator = CanvasAssetLocator(id: UUID(), mimeType: "image/png")

        _ = demand.image(locator: locator, contentKind: "image/png")
        demand.reconcileVisibleDemand()
        await waitFor { provider.calls.count == 1 }
        await waitFor { demand.status(locator: locator, contentKind: "image/png") == .failed }

        // Later frames: still failed (actionable missing state), no retry.
        _ = demand.image(locator: locator, contentKind: "image/png")
        demand.reconcileVisibleDemand()
        _ = demand.image(locator: locator, contentKind: "image/png")
        demand.reconcileVisibleDemand()
        XCTAssertEqual(provider.calls.count, 1, "failed keys are not re-requested per frame")
        XCTAssertEqual(demand.status(locator: locator, contentKind: "image/png"), .failed)
    }

    func testInvalidateFencesStaleResults() async {
        let provider = FakePreviewProvider()
        let pipeline = CanvasPreviewPipeline(provider: provider)
        let ready = CanvasAssetLocator(id: UUID(), mimeType: "image/png")
        provider.gateAssets = [ready.id]
        var readyCount = 0
        let demand = CanvasBoardPreviewDemandController(pipeline: pipeline) { readyCount += 1 }

        _ = demand.image(locator: ready, contentKind: "image/png")
        demand.reconcileVisibleDemand()
        await waitFor { provider.gates[ready.id] != nil }
        // Page/layout boundary while the request is in flight.
        demand.invalidateAll()
        provider.releaseGate(ready.id, with: tinyPNGResult())
        await waitFor { provider.observedConcurrent == 0 }
        await Task.yield()
        // Result is fenced: never cached, and the demand state was reset.
        XCTAssertNil(pipeline.cachedImage(for: ready, contentKind: "image/png"),
                     "stale result discarded after invalidate")
        XCTAssertEqual(demand.status(locator: ready, contentKind: "image/png"), .idle)
    }

    /// Gated-provider lifecycle: request A for a key is cancelled by its
    /// same-key replacement B; when A's late callback runs, it must NOT
    /// evict B's cancellation-token ownership, so `cancelAll()` afterwards
    /// still cancels B and the stale image never reaches the cache.
    func testLateCancelledRequestCannotEvictReplacementTokenBeforeCancelAll() async {
        let provider = FakePreviewProvider()
        let pipeline = CanvasPreviewPipeline(provider: provider)
        let locator = CanvasAssetLocator(id: UUID(), mimeType: "image/png")
        provider.gateAssets = [locator.id]

        let taskA = Task { await pipeline.preview(for: locator, contentKind: "image/png") == nil }
        await waitFor { (provider.gates[locator.id]?.count ?? 0) == 1 }
        // B replaces A for the same key: A's token is cancelled, B owns it.
        let taskB = Task { await pipeline.preview(for: locator, contentKind: "image/png") == nil }
        await waitFor { (provider.gates[locator.id]?.count ?? 0) == 2 }

        // A's late provider callback arrives while B is still gated.
        provider.releaseOldestGate(locator.id, with: tinyPNGResult())
        let a = await taskA.value
        XCTAssertTrue(a, "the cancelled first request returns nothing")

        // The late callback must not have cleared B's token: cancelAll
        // still reaches B, and B's still-gated provider call then returns
        // into a cancelled token.
        pipeline.cancelAll()
        provider.releaseOldestGate(locator.id, with: tinyPNGResult())
        let b = await taskB.value
        XCTAssertTrue(b, "cancelAll still cancels the replacement owner")
        XCTAssertNil(pipeline.cachedImage(for: locator, contentKind: "image/png"),
                     "a cancelled preview never lands in the cache")
    }

    func testConcurrencyBudgetRespected() async {
        let provider = FakePreviewProvider()
        let pipeline = CanvasPreviewPipeline(provider: provider)
        let demand = CanvasBoardPreviewDemandController(pipeline: pipeline)
        var locators: [CanvasAssetLocator] = []
        for _ in 0..<10 {
            let locator = CanvasAssetLocator(id: UUID(), mimeType: "image/png")
            locators.append(locator)
            provider.results[locator.id] = tinyPNGResult()
            provider.delays[locator.id] = 30_000_000
            _ = demand.image(locator: locator, contentKind: "image/png")
        }
        demand.reconcileVisibleDemand()
        await waitFor { provider.maxObservedConcurrent == CanvasBoardPreviewDemandController.maxConcurrent }
        XCTAssertLessThanOrEqual(provider.maxObservedConcurrent,
                                 CanvasBoardPreviewDemandController.maxConcurrent)
        await waitFor { provider.calls.count == 10 }
    }

    func testStatusWithoutProviderIsUnavailable() {
        let pipeline = CanvasPreviewPipeline(provider: nil)
        let demand = CanvasBoardPreviewDemandController(pipeline: pipeline)
        let locator = CanvasAssetLocator(id: UUID(), mimeType: "image/png")
        XCTAssertEqual(demand.status(locator: locator, contentKind: "image/png"), .unavailableProvider)
    }

    func testStoreOwnsSingleSharedPipeline() async {
        let snapshot = CanvasTestStubs.snapshot()
        let store = CanvasEditorStore(
            canvasID: snapshot.id,
            services: CanvasEditorServices(
                documentStore: InMemoryCanvasRepository(snapshot: snapshot)))
        await store.load()
        // The store exposes the single shared preview pipeline; the board
        // binds store.previews in bind(to:) and the inspector receives the
        // same instance from CanvasEditorView — one cache/cancel authority.
        XCTAssertNotNil(store.previews)
        let first = store.previews
        XCTAssertTrue(first === store.previews, "pipeline identity is stable per store")
    }

    // MARK: Strings

    func testNewBoardStringsLocalized() {
        let english = CanvasStrings(language: .english)
        XCTAssertEqual(english[.contentTruncated], "More…")
        XCTAssertEqual(english.formatted(.pdfPageRangeCaption, 2, 5), "Pages 2–5")
        let chinese = CanvasStrings(language: .simplifiedChinese)
        XCTAssertEqual(chinese[.contentTruncated], "更多…")
        XCTAssertEqual(chinese.formatted(.pdfPageRangeCaption, 2, 5), "第 2–5 页")
    }

    // MARK: Helpers

    private func waitFor(
        timeout: TimeInterval = 2,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: @escaping () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                XCTFail("waitFor timed out", file: file, line: line)
                return
            }
            await Task.yield()
        }
    }
}

#endif // canImport(UIKit)
