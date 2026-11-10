// FloeApp — hosted chat-surface tests for the fenced-SVG preview.
//
// SPDX-License-Identifier: MPL-2.0
//
// These are the canonical App-run contracts for the fenced ```svg
// chat surface, exercised through the REAL MarkdownRendererView →
// CodeBlockView → SVGCodeBlockView route on a hosted UIWindow.
// Observation goes through the accessibility tree (SwiftUI bridges
// .accessibilityIdentifier onto the hosting layer), so the tests do
// NOT assume UIImageView/UIControl descendants. Every wait/assert is
// required — a missing render is a real failure here, never a silent
// skip. Real pixel colour proof belongs to the component WebKit tests
// and to upstream screenshot acceptance; App presentation remains
// with the owner's canonical Simulator run.

import XCTest
import SwiftUI
import UIKit
import ImageIO
import FloeImages
import FloeMarkdown
@testable import FloeApp

@MainActor
final class SVGChatRenderingTests: XCTestCase {

    private static let alphaSVG = ##"<svg xmlns="http://www.w3.org/2000/svg" width="120" height="80" viewBox="0 0 120 80"><rect x="10" y="10" width="40" height="40" fill="#ff0000"/></svg>"##

    // MARK: - Hosting + accessibility observation helpers

    private func host<V: View>(_ view: V) throws -> (UIWindow, UIView) {
        let host = UIHostingController(rootView: view)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 900, height: 1400)
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
        host.view.layoutIfNeeded()
        return (window, host.view!)
    }

    private struct AccessibilityNode {
        let object: NSObject
        let depth: Int
        let edge: String
        let dynamicCount: Int
    }

    /// Public UIKit container APIs also apply to UIAccessibilityElement
    /// containers. SwiftUI can vend dynamic children without populating
    /// UIView.accessibilityElements, so neither channel can stand alone.
    private func accessibilityNodes(in root: UIView) -> [AccessibilityNode] {
        var pending: [(NSObject, Int, String)] = [(root, 0, "root")]
        var visited = Set<ObjectIdentifier>()
        var nodes: [AccessibilityNode] = []
        while let (element, depth, edge) = pending.popLast(), nodes.count < 4_096 {
            guard depth <= 64, visited.insert(ObjectIdentifier(element)).inserted else { continue }
            let count = element.accessibilityElementCount()
            nodes.append(.init(object: element, depth: depth, edge: edge, dynamicCount: count))
            var children: [(NSObject, Int, String)] = []
            if let view = element as? UIView {
                children += view.subviews.map { ($0, depth + 1, "subview") }
            }
            children += (element.accessibilityElements ?? []).compactMap {
                ($0 as? NSObject).map { ($0, depth + 1, "elements") }
            }
            children += (element.automationElements ?? []).compactMap {
                ($0 as? NSObject).map { ($0, depth + 1, "automation") }
            }
            // NSObject's default may report NSNotFound. Never iterate that
            // sentinel, and keep a malformed/lazy container bounded.
            if count > 0, count != NSNotFound {
                for index in 0..<min(count, 1_024) {
                    if let child = element.accessibilityElement(at: index) as? NSObject {
                        children.append((child, depth + 1, "dynamic[\(index)]"))
                    }
                }
            }
            pending.append(contentsOf: children.reversed())
        }
        return nodes
    }

    private func contains(identifier: String, in root: UIView) -> Bool {
        findAccessibility(identifier: identifier, in: root) != nil
    }

    @discardableResult
    private func waitUntil(
        identifier: String,
        in root: UIView,
        timeout: TimeInterval = 30
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            root.window?.layoutIfNeeded()
            root.layoutIfNeeded()
            if contains(identifier: identifier, in: root) { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return contains(identifier: identifier, in: root)
    }

    private func findAccessibility(identifier: String, in root: UIView) -> NSObject? {
        accessibilityNodes(in: root).first {
            ($0.object as? any UIAccessibilityIdentification)?.accessibilityIdentifier == identifier
        }?.object
    }

    /// Always called before the synthetic host is dismantled, including
    /// assertion failures and thrown XCTUnwrap. No user labels, source text,
    /// unrelated windows or arbitrary identifiers enter the diagnostic tree.
    @discardableResult
    private func captureHostEvidence(_ name: String, window: UIWindow, root: UIView) -> (image: UIImage, drawSucceeded: Bool) {
        window.layoutIfNeeded()
        root.layoutIfNeeded()
        var drawSucceeded = false
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let rendered = UIGraphicsImageRenderer(bounds: root.bounds, format: format).image { _ in
            drawSucceeded = root.drawHierarchy(in: root.bounds, afterScreenUpdates: true)
        }
        let picture = XCTAttachment(image: rendered)
        picture.name = "\(name) — hosted fixture (drawSucceeded=\(drawSucceeded))"
        picture.lifetime = .keepAlways
        add(picture)

        let nodes = accessibilityNodes(in: root)
        let tree: [[String: Any]] = nodes.map { node in
            let identifier = (node.object as? any UIAccessibilityIdentification)?.accessibilityIdentifier
            var row: [String: Any] = [
                "class": String(describing: type(of: node.object)),
                "depth": node.depth,
                "edge": node.edge,
                "dynamicCount": node.dynamicCount == NSNotFound ? "NSNotFound" : String(node.dynamicCount),
                "isAccessibilityElement": node.object.isAccessibilityElement
            ]
            if let identifier, identifier.hasPrefix("chat.svg") { row["identifier"] = identifier }
            if let view = node.object as? UIView {
                row["frame"] = NSCoder.string(for: view.frame)
                row["hidden"] = view.isHidden
            }
            return row
        }
        let report: [String: Any] = [
            "fixture": name,
            "drawSucceeded": drawSucceeded,
            "windowHidden": window.isHidden,
            "windowKey": window.isKeyWindow,
            "sceneActivation": window.windowScene?.activationState.rawValue ?? -1,
            "rootAttached": root.window === window,
            "rootBounds": NSCoder.string(for: root.bounds),
            "nodeCount": nodes.count,
            "traversalLimits": "4096 nodes / 64 depth / 1024 children per container",
            "nodes": tree
        ]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]),
           let text = String(data: data, encoding: .utf8) {
            let attachment = XCTAttachment(string: text)
            attachment.name = "\(name) — public accessibility containers (redacted)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        return (rendered, drawSucceeded)
    }

    private static func redPixelCount(in image: UIImage) throws -> Int {
        let source = try XCTUnwrap(image.cgImage, "the hosted screenshot must decode")
        let width = source.width, height = source.height
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        let bytes = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        var count = 0
        for y in 0..<height {
            for x in 0..<width {
                let offset = y * context.bytesPerRow + x * 4
                if bytes[offset] > 200, bytes[offset + 1] < 80,
                   bytes[offset + 2] < 80, bytes[offset + 3] > 200 { count += 1 }
            }
        }
        return count
    }

    private final class DynamicAccessibilityContainer: UIAccessibilityElement {
        var children: [NSObject] = []
        override func accessibilityElementCount() -> Int { children.count }
        override func accessibilityElement(at index: Int) -> Any? {
            children.indices.contains(index) ? children[index] : nil
        }
    }

    func testDynamicAccessibilityContainersAreTraversed() throws {
        let root = UIView()
        let outer = DynamicAccessibilityContainer(accessibilityContainer: root)
        let inner = DynamicAccessibilityContainer(accessibilityContainer: outer)
        let leaf = UIAccessibilityElement(accessibilityContainer: inner)
        leaf.accessibilityIdentifier = "chat.svg.testLeaf"
        root.accessibilityElements = [outer]
        outer.children = [inner]
        inner.children = [outer, leaf] // A real cycle must not hide the sibling.
        XCTAssertTrue(contains(identifier: "chat.svg.testLeaf", in: root))
        XCTAssertTrue(findAccessibility(identifier: "chat.svg.testLeaf", in: root) === leaf)
        XCTAssertLessThan(accessibilityNodes(in: root).count, 10)
    }


    // MARK: - Fenced routing through the real markdown surface

    func testFencedSVGRoutesToSharedPreviewSurface() async throws {
        let source = "Diagram:\n\n```svg\n" + Self.alphaSVG + "\n```\n"
        let (window, root) = try host(MarkdownRendererView(source: source))
        defer {
            captureHostEvidence(#function, window: window, root: root)
            window.isHidden = true
            window.rootViewController = nil
        }
        _ = await waitUntil(identifier: "chat.svgBlock", in: root)
        XCTAssertTrue(
            contains(identifier: "chat.svgBlock", in: root),
            "fenced svg must render through SVGCodeBlockView")
        let visible1 = await waitUntil(identifier: "chat.svgPreview.image", in: root, timeout: 60)
        XCTAssertTrue(visible1,
            "the shared renderer must produce a preview element in the App host")
        let capture = captureHostEvidence("SVG preview pixel check", window: window, root: root)
        XCTAssertTrue(capture.drawSucceeded, "the actual hosted fixture must be captured")
        XCTAssertGreaterThanOrEqual(try Self.redPixelCount(in: capture.image), 64,
            "the hosted SVG picture must contain the fixture's red rectangle")

    }

    func testNonSVGCodeFencesKeepThePlainSurface() async throws {
        let source = "```swift\nlet value = 1\n```\n"
        let (window, root) = try host(MarkdownRendererView(source: source))
        defer {
            captureHostEvidence(#function, window: window, root: root)
            window.isHidden = true
            window.rootViewController = nil
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertFalse(
            contains(identifier: "chat.svgBlock", in: root),
            "non-svg fences must not hit the SVG surface")
    }

    // MARK: - Rendered size truth + copy surface

    func testRenderedPreviewReportsRealPixelSizeAndKeepsCopy() async throws {
        let source = "```svg\n" + Self.alphaSVG + "\n```\n"
        let (window, root) = try host(MarkdownRendererView(source: source))
        defer {
            captureHostEvidence(#function, window: window, root: root)
            window.isHidden = true
            window.rootViewController = nil
        }
        let visible2 = await waitUntil(identifier: "chat.svgPreview.image", in: root, timeout: 60)
        XCTAssertTrue(visible2,
            "a valid fence must reach the preview phase")
        let visible3 = await waitUntil(identifier: "chat.svgPreview.size", in: root, timeout: 5)
        XCTAssertTrue(visible3)
        let sizeElement = try XCTUnwrap(
            findAccessibility(identifier: "chat.svgPreview.size", in: root),
            "the preview must state the real pixel size")
        XCTAssertEqual(sizeElement.accessibilityLabel, "120×80")
        let visible4 = await waitUntil(identifier: "chat.svgPreview.copy", in: root, timeout: 5)
        XCTAssertTrue(visible4,
            "the copy action must stay on the SVG surface")
    }

    // MARK: - Source toggle reversibility

    func testSourceToggleIsReversibleWithoutLosingPreview() async throws {
        let source = "```svg\n" + Self.alphaSVG + "\n```\n"
        let (window, root) = try host(MarkdownRendererView(source: source))
        defer {
            captureHostEvidence(#function, window: window, root: root)
            window.isHidden = true
            window.rootViewController = nil
        }
        let visible5 = await waitUntil(identifier: "chat.svgPreview.image", in: root, timeout: 60)
        XCTAssertTrue(visible5)
        let toggle = try XCTUnwrap(
            findAccessibility(identifier: "chat.svgPreview.sourceToggle", in: root),
            "the preview must expose a source toggle")
        // Expand source… (the toggle itself stays visible in both states)
        XCTAssertTrue(
            Self.activateViaProtocol(toggle),
            "AX activation of the toggle must report success")
        let visible6 = await waitUntil(identifier: "chat.svgPreview.sourceText", in: root, timeout: 5)
        XCTAssertTrue(visible6,
            "expanded source must be visible")
        captureHostEvidence("SVG source expanded checkpoint", window: window, root: root)
        // …and collapse back: preview is restored from RAM, not re-rendered.
        let secondToggle = try XCTUnwrap(
            findAccessibility(identifier: "chat.svgPreview.sourceToggle", in: root))
        XCTAssertTrue(Self.activateViaProtocol(secondToggle))
        let visible7 = await waitUntil(identifier: "chat.svgPreview.image", in: root, timeout: 5)
        XCTAssertTrue(visible7,
            "hiding source must not discard or re-render the preview")
        let stillThere = try XCTUnwrap(
            findAccessibility(identifier: "chat.svgPreview.size", in: root))
        XCTAssertEqual(stillThere.accessibilityLabel, "120×80")
    }

    private static func activateViaProtocol(_ object: NSObject) -> Bool {
        object.accessibilityActivate()
    }

    // MARK: - Fallbacks

    func testUnsafeFenceFallsBackToSourceWithReason() async throws {
        let evil = #"<svg xmlns="http://www.w3.org/2000/svg" width="40" height="40" onload="alert(1)"><rect width="4" height="4"/></svg>"#
        let source = "```svg\n" + evil + "\n```\n"
        let (window, root) = try host(MarkdownRendererView(source: source))
        defer {
            captureHostEvidence(#function, window: window, root: root)
            window.isHidden = true
            window.rootViewController = nil
        }
        let visible8 = await waitUntil(identifier: "chat.svgPreview.fallback", in: root)
        XCTAssertTrue(visible8,
            "actionable SVG must show the concise bilingual fallback")
        XCTAssertFalse(contains(identifier: "chat.svgPreview.image", in: root))
    }

    func testIncompleteStreamingFenceStaysOnSourceSilently() async throws {
        // Mid-stream tail: no closing fence yet → plain source, NO error line.
        let partial = "```svg\n<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"40\" height=\"40\"><rect"
        let (window, root) = try host(MarkdownRendererView(source: partial, isStreaming: true))
        defer {
            captureHostEvidence(#function, window: window, root: root)
            window.isHidden = true
            window.rootViewController = nil
        }
        // Give the streaming path a settle window, then require the
        // silent source state explicitly.
        try await Task.sleep(nanoseconds: 500_000_000)
        let visible9 = await waitUntil(identifier: "chat.svgPreview.sourceText", in: root, timeout: 5)
        XCTAssertTrue(visible9,
            "partial fences must show the source surface")
        XCTAssertFalse(
            contains(identifier: "chat.svgPreview.fallback", in: root),
            "partial fences are expected mid-stream and must not show errors")
    }

    func testOversizedFenceFallsBackWithoutRendering() async throws {
        let huge = "```svg\n<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"40\" height=\"40\">"
            + String(repeating: "<rect width=\"1\" height=\"1\"/>", count: 100)
            + String(repeating: "x", count: SVGSafetyLimits.maxSourceBytes)
            + "</svg>\n```\n"
        let (window, root) = try host(MarkdownRendererView(source: huge))
        defer {
            captureHostEvidence(#function, window: window, root: root)
            window.isHidden = true
            window.rootViewController = nil
        }
        let visible10 = await waitUntil(identifier: "chat.svgPreview.fallback", in: root)
        XCTAssertTrue(visible10,
            "an oversized fence must fall back to source")
        XCTAssertFalse(contains(identifier: "chat.svgPreview.image", in: root))
    }
}
