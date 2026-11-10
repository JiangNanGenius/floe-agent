// FloeImages — SVGDocumentValidator contracts.
//
// SPDX-License-Identifier: MPL-2.0
//
// The validator is the security boundary for BOTH the chat preview
// and image.renderSVG, so every rejection is asserted by stable code,
// and the accepted static subset is asserted by the owner acceptance
// fixtures (byte-identical copies inlined below) plus the sizing
// contract they encode.

import Foundation
import Testing
import FloeCore
@testable import FloeImages

@Suite("FloeImages.SVGDocument")
struct SVGDocumentTests {

    // MARK: - Owner acceptance fixtures (byte-identical)

    static let alphaFixture = ##"<svg xmlns="http://www.w3.org/2000/svg" width="120" height="80" viewBox="0 0 120 80"><rect x="10" y="10" width="40" height="40" fill="#ff0000"/></svg>"## + "\n"
    static let viewboxFixture = ##"<svg xmlns="http://www.w3.org/2000/svg" viewBox="-10 -20 200 100"><rect x="-10" y="-20" width="100" height="100" fill="#0066ff"/><rect x="90" y="-20" width="100" height="100" fill="#00cc66"/></svg>"## + "\n"
    static let diagramFixture = ##"<svg xmlns="http://www.w3.org/2000/svg" width="640" height="360" viewBox="0 0 640 360"><defs><linearGradient id="gradient"><stop offset="0" stop-color="#2374ff"/><stop offset="1" stop-color="#64d6cc"/></linearGradient><clipPath id="clip"><rect x="20" y="20" width="600" height="320" rx="24"/></clipPath></defs><g clip-path="url(#clip)"><rect width="640" height="360" fill="url(#gradient)"/><path d="M60 270 C160 80 260 330 350 150 S500 60 580 120" fill="none" stroke="#ffffff" stroke-width="8"/><circle cx="350" cy="150" r="14" fill="#ffdc60"/><text x="60" y="80" font-family="sans-serif" font-size="32" fill="#ffffff">Floe SVG · 矢量图</text></g></svg>"## + "\n"

    @Test("alpha fixture validates with exact declared size")
    func alphaFixture() throws {
        let document = try SVGDocumentValidator.validate(Self.alphaFixture)
        let intrinsic = try #require(document.metrics.intrinsicSizePx)
        #expect(Int(intrinsic.width) == 120)
        #expect(Int(intrinsic.height) == 80)
        #expect(document.metrics.aspectRatio == 1.5)
        // Tool/preview sizing must reproduce EXPECTED.json pixels.
        let size = try #require(SVGRenderSize.resolve(metrics: document.metrics))
        #expect(size == (width: 120, height: 80))
    }

    @Test("viewBox-only fixture derives size and aspect")
    func viewboxFixture() throws {
        let document = try SVGDocumentValidator.validate(Self.viewboxFixture)
        #expect(document.metrics.viewBox?.width == 200)
        #expect(document.metrics.aspectRatio == 2.0)
        // EXPECTED.json: width-only 400 ⇒ 400×200.
        let size = try #require(SVGRenderSize.resolve(
            metrics: document.metrics, requestedWidth: 400))
        #expect(size == (width: 400, height: 200))
        let intrinsic = try #require(SVGRenderSize.resolve(metrics: document.metrics))
        #expect(intrinsic == (width: 200, height: 100))
    }

    @Test("gradient/clipPath/curve/CJK-text diagram is accepted static content")
    func diagramFixture() throws {
        let document = try SVGDocumentValidator.validate(Self.diagramFixture)
        #expect(document.elementCount >= 10)
        let size = try #require(SVGRenderSize.resolve(metrics: document.metrics))
        #expect(size == (width: 640, height: 360))
    }

    @Test("fixture digests match EXPECTED.json")
    func fixtureDigests() throws {
        #expect(try SVGDocumentValidator.validate(Self.alphaFixture).sourceDigest
                == "0e932b320c9000c08d683821dd6fa34ef00a9ac1c20bf6ac667655d46a60bf61")
        #expect(try SVGDocumentValidator.validate(Self.viewboxFixture).sourceDigest
                == "8af1fff3274a857a37019261d230a00ec3872b0bc324a07465292b45673d9e24")
        #expect(try SVGDocumentValidator.validate(Self.diagramFixture).sourceDigest
                == "0cd6c2925d49f4b1f31c9bd00606a46918ce4a463a2f6394cd5b6fcfb30d1f2c")
    }

    // MARK: - Actionable content rejection

    @Test("scripts, events and embedding are rejected by stable codes")
    func unsafeContent() {
        func rejectionCode(_ source: String) -> String? {
            do {
                _ = try SVGDocumentValidator.validate(source)
                return nil
            } catch let rejection as SVGDocumentRejection {
                return rejection.code
            } catch {
                return "unexpected"
            }
        }
        let prefix = #"<svg xmlns="http://www.w3.org/2000/svg" width="40" height="40" "#
        let suffix = #">"#
        let cases: [(String, String?)] = [
            (prefix + suffix + "<script>alert(1)</script></svg>", "unknown_element"),
            (prefix + suffix + #"<script href="x"/>"# + "</svg>", "unknown_element"),
            (prefix + suffix + "<foreignObject><body xmlns=\"http://www.w3.org/1999/xhtml\">hi</body></foreignObject></svg>", "unknown_element"),
            (prefix + "onload=\"alert(1)\"" + suffix + "<rect width=\"4\" height=\"4\"/></svg>", "event_attribute"),
            (prefix + suffix + "<animate attributeName=\"href\" values=\"#a\"/></svg>", "unknown_element"),
            ("<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"40\" height=\"40\"></svg><svg/>", "not_well_formed"),
            (#"<?xml version="1.0"?><svg xmlns="http://www.w3.org/2000/svg" width="4" height="4"/>"#, nil),
            (#"<?xml version="1.0"?><?xml-stylesheet type="text/css" href="evil.css"?><svg xmlns="http://www.w3.org/2000/svg" width="4" height="4"/>"#, "processing_instruction"),
            (#"<!DOCTYPE svg PUBLIC "-//W3C//DTD SVG 1.1//EN" "http://www.w3.org/Graphics/SVG/1.1/DTD/svg11.dtd"><svg xmlns="http://www.w3.org/2000/svg" width="4" height="4"/>"#, "dtd_or_entity"),
            (prefix + suffix + #"<image href="data:image/png;base64,AAAA"/>"# + "</svg>", "unknown_element"),
            ("<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"40\" height=\"40\"><rect x=\"0\" width=\"4\" height=\"4\"/><svg>", "not_well_formed"),
            (prefix + #"href="http://evil.example/x.svg""# + suffix + "<rect width=\"4\" height=\"4\"/></svg>", "unsafe_reference"),
            (prefix + #"xlink:href="file:///etc/passwd""# + suffix + "<rect width=\"4\" height=\"4\"/></svg>", "unsafe_reference"),
            (prefix + suffix + #"<use href="other.svg#id"/>"# + "</svg>", "unsafe_reference"),
            (prefix + #"style="fill:url(http://evil.example/x.png)""# + suffix + "<rect width=\"4\" height=\"4\"/></svg>", "unsafe_css"),
            (prefix + #"fill="url(#good)""# + suffix + "<rect width=\"4\" height=\"4\"/></svg>", nil),
            (prefix + #"clip-path="url(//evil.example/x)""# + suffix + "<rect width=\"4\" height=\"4\"/></svg>", "unsafe_reference"),
            (prefix + suffix + "<style>@import url(evil.css);</style><rect width=\"4\" height=\"4\"/></svg>", "unsafe_css"),
            (prefix + suffix + "<style>rect{fill:url(\"http://evil.example/a.png\")}</style></svg>", "unsafe_css"),
            // Comment-hidden scheme: url(/*x*/http://evil) must decode first.
            (prefix + suffix + "<style>rect{fill:url(/*x*/http://evil.example/a.png)}</style></svg>", "unsafe_css"),
            // Backslash-escaped 'r' in url: u\r( — decoded before checking.
            (prefix + suffix + "<style>rect{fill:u\\72 (http://evil.example/a.png)}</style></svg>", "unsafe_css"),
            (prefix + ##"fill="#f00" inkscape:label="Layer""## + suffix + "<rect width=\"4\" height=\"4\"/></svg>", "unknown_attribute"),
            // Qualified element names are explicitly rejected (raw-name
            // parsing): a documented, honest refusal instead of a
            // silently misrendered raster.
            (prefix + suffix + #"<svg:rect xmlns:svg="http://www.w3.org/2000/svg" width="4" height="4"/>"# + "</svg>", "unknown_element"),
            (prefix + suffix + "<rect width=\"4\" height=\"4\" unknownAttr=\"1\"/></svg>", "unknown_attribute"),
            (prefix + suffix + ##"<filter id="f"><feImage href="#f"/></filter>"## + "<rect width=\"4\" height=\"4\"/></svg>", "unknown_element"),
            (prefix + suffix + #"<textArea>hi</textArea>"# + "</svg>", "unknown_element"),
            ("<notsvg/>", "unknown_element"),
            ("   ", "empty")
        ]
        for (source, expected) in cases {
            let got = rejectionCode(source)
            #expect(got == expected, "case \(source.prefix(60)) → \(got ?? "accepted"), want \(expected ?? "accepted")")
        }
    }

    @Test("duplicate ids and reference cycles/expansion are rejected")
    func referenceGraph() {
        func rejectionCode(_ source: String) -> String? {
            do {
                _ = try SVGDocumentValidator.validate(source)
                return nil
            } catch let rejection as SVGDocumentRejection {
                return rejection.code
            } catch {
                return "unexpected"
            }
        }
        let head = #"<svg xmlns="http://www.w3.org/2000/svg" width="40" height="40">"#
        // Duplicate id.
        #expect(rejectionCode(head + "<rect id=\"a\" width=\"4\" height=\"4\"/><circle id=\"a\" r=\"1\"/></svg>") == "duplicate_id")
        // use → use → same use: cycle.
        let cycle = head + "<defs><g id=\"x\"><use href=\"#x\"/></g></defs><use href=\"#x\"/></svg>"
        #expect(rejectionCode(cycle) == "reference_graph")
        // Self-referencing gradient stop chain via mask.
        let selfMask = head + "<mask id=\"m\"><rect width=\"4\" height=\"4\" mask=\"url(#m)\"/></mask><rect width=\"4\" height=\"4\" mask=\"url(#m)\"/></svg>"
        #expect(rejectionCode(selfMask) == "reference_graph")
        // Exponential fan-out: 16 levels, each use references the previous twice.
        var chain = head + "<defs><g id=\"l0\"><rect width=\"1\" height=\"1\"/></g>"
        for level in 1...16 {
            chain += "<g id=\"l\(level)\"><use href=\"#l\(level - 1)\"/><use href=\"#l\(level - 1)\"/></g>"
        }
        chain += "</defs><use href=\"#l16\"/></svg>"
        #expect(rejectionCode(chain) == "reference_graph")
        // A modest chain resolves fine.
        let ok = head + "<defs><g id=\"a\"><rect width=\"4\" height=\"4\"/></g><g id=\"b\"><use href=\"#a\"/></g></defs><use href=\"#b\"/></svg>"
        #expect(rejectionCode(ok) == nil)
        // Unresolved internal reference is inert, not a rejection.
        let dangling = head + "<rect width=\"4\" height=\"4\" fill=\"url(#missing)\"/></svg>"
        #expect(rejectionCode(dangling) == nil)
    }

    @Test("element and depth ceilings reject with codes")
    func complexityCeilings() {
        func rejectionCode(_ source: String) -> String? {
            do {
                _ = try SVGDocumentValidator.validate(source)
                return nil
            } catch let rejection as SVGDocumentRejection {
                return rejection.code
            } catch { return "unexpected" }
        }
        let head = #"<svg xmlns="http://www.w3.org/2000/svg" width="40" height="40">"#
        let many = head + String(repeating: "<rect width=\"1\" height=\"1\"/>", count: SVGSafetyLimits.maxElements + 1) + "</svg>"
        #expect(rejectionCode(many) == "too_many_elements")
        var deep = head
        for _ in 0...(SVGSafetyLimits.maxDepth + 1) { deep += "<g>" }
        #expect(rejectionCode(deep) == "too_deep")
        let huge = head + String(repeating: "a", count: SVGSafetyLimits.maxSourceBytes + 64) + "</svg>"
        #expect(rejectionCode(huge) == "too_large")
    }

    @Test("dimension rules reject invalid roots and accept units")
    func dimensions() {
        func metrics(_ source: String) -> SVGDocumentMetrics? {
            try? SVGDocumentValidator.validate(source).metrics
        }
        func rejectionCode(_ source: String) -> String? {
            do { _ = try SVGDocumentValidator.validate(source); return nil }
            catch let r as SVGDocumentRejection { return r.code }
            catch { return "unexpected" }
        }
        #expect(metrics(#"<svg xmlns="http://www.w3.org/2000/svg" width="50%" height="50%"/>"#)?.intrinsicSizePx == nil)
        // 10cm ≈ 377.95 px, 3.75in = 360 px.
        let unit = metrics(#"<svg xmlns="http://www.w3.org/2000/svg" width="10cm" height="3.75in"/>"#)
        #expect(unit?.intrinsicSizePx?.width ?? 0 > 377)
        #expect(unit?.intrinsicSizePx?.height == 360)
        #expect(rejectionCode(#"<svg xmlns="http://www.w3.org/2000/svg" width="40" height="0"/>"#) == "invalid_dimensions")
        #expect(rejectionCode(#"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 0 10"/>"#) == "invalid_dimensions")
        #expect(rejectionCode(#"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 nine 10"/>"#) == "invalid_dimensions")
        #expect(rejectionCode(#"<svg xmlns="http://www.w3.org/2000/svg" width="1e9" height="10"/>"#) == "invalid_dimensions")
        #expect(rejectionCode(#"<svg xmlns="http://www.w3.org/2000/svg" width="40" height="40" viewBox="0 0 -5 10"/>"#) == "invalid_dimensions")
    }

    @Test("render size clamps to shared raster ceilings")
    func renderSizeClamps() throws {
        let metrics = SVGDocumentMetrics(
            declaredWidth: SVGLength(value: 4000, unit: .px),
            declaredHeight: SVGLength(value: 4000, unit: .px),
            viewBox: nil)
        let size = SVGRenderSize.resolve(metrics: metrics)
        #expect(size?.width == 4000 && size?.height == 4000) // within 40 MP
        let huge = SVGDocumentMetrics(
            declaredWidth: SVGLength(value: 9000, unit: .px),
            declaredHeight: SVGLength(value: 9000, unit: .px),
            viewBox: nil)
        let clamped = try #require(SVGRenderSize.resolve(metrics: huge))
        #expect(clamped.width <= SVGSafetyLimits.maxOutputEdge)
        #expect(clamped.width * clamped.height <= SVGSafetyLimits.maxOutputPixels)
    }

    @Test("style body arriving split across callbacks is validated whole")
    func splitStyleText() throws {
        // The evil token spans a <style> text boundary; validation runs
        // on the accumulated full text at element close.
        let source = #"<svg xmlns="http://www.w3.org/2000/svg" width="40" height="40"><style>rect{fill:ur<![CDATA[l(http://evil.example/a)]]>}</style><rect width="4" height="4"/></svg>"#
        do {
            _ = try SVGDocumentValidator.validate(source)
            Issue.record("external url() split across XML text and CDATA must be rejected")
        } catch let rejection as SVGDocumentRejection {
            #expect(rejection.code == "unsafe_css")
        }
        // CDATA-wrapped CSS gets the same conservative treatment.
        let cdata = #"<svg xmlns="http://www.w3.org/2000/svg" width="40" height="40"><style><![CDATA[rect{fill:url(http://evil.example/a)}]]></style></svg>"#
        do {
            _ = try SVGDocumentValidator.validate(cdata)
            Issue.record("CDATA CSS must be rejected")
        } catch let rejection as SVGDocumentRejection {
            #expect(rejection.code == "unsafe_css")
        }
    }

    @Test("processing-invisible rejection survives parser abort")
    func rejectionSurvivesAbort() throws {
        // Deep nesting aborts the XML walk; the REAL rejection code must
        // surface, not a generic not_well_formed.
        var source = #"<svg xmlns="http://www.w3.org/2000/svg" width="40" height="40">"#
        for _ in 0...SVGSafetyLimits.maxDepth { source += "<g>" }
        do {
            _ = try SVGDocumentValidator.validate(source)
            Issue.record("depth must reject")
        } catch let rejection as SVGDocumentRejection {
            #expect(rejection.code == "too_deep")
        }
    }
    // MARK: - Weighted expansion graph (containment + references)

    @Test("nested-id containment cycle is rejected")
    func nestedIDCycle() {
        let source = ##"<svg xmlns="http://www.w3.org/2000/svg" width="40" height="40"><g id="a"><g id="b"><use href="#a"/></g></g><use href="#b"/></svg>"##
        #expect(rejectionCode(source) == "reference_graph")
    }

    @Test("repeated large subtree expansion exceeds the aggregate budget")
    func repeatedLargeSubtree() {
        let big = "<g id=\"big\">" + String(repeating: "<rect width=\"1\" height=\"1\"/>", count: 200) + "</g>"
        let uses = String(repeating: "<use href=\"#big\"/>", count: 300)
        let source = #"<svg xmlns="http://www.w3.org/2000/svg" width="40" height="40"><defs>"# + big + "</defs>" + uses + "</svg>"
        #expect(rejectionCode(source) == "reference_graph")
    }

    @Test("root aggregate use expansion under budget is accepted")
    func rootAggregateUnderBudget() {
        let small = "<g id=\"s\"><rect width=\"1\" height=\"1\"/><rect width=\"1\" height=\"1\"/></g>"
        let uses = String(repeating: "<use href=\"#s\"/>", count: 100)
        let source = #"<svg xmlns="http://www.w3.org/2000/svg" width="40" height="40"><defs>"# + small + "</defs>" + uses + "</svg>"
        #expect(rejectionCode(source) == nil)
    }

    @Test("style url(#id) joins the reference graph, including cycles")
    func styleReferenceEdges() {
        let ok = ##"<svg xmlns="http://www.w3.org/2000/svg" width="40" height="40"><defs><linearGradient id="g"><stop offset="0" stop-color="#f00"/></linearGradient></defs><style>.c{fill:url(#g)}</style><rect class="c" width="4" height="4"/></svg>"##
        #expect(rejectionCode(ok) == nil)
        // A mask whose own style references the mask: cycle via style text.
        let cycle = #"<svg xmlns="http://www.w3.org/2000/svg" width="40" height="40"><mask id="m"><style>rect{mask:url(#m)}</style><rect width="4" height="4"/></mask><rect width="4" height="4" mask="url(#m)"/></svg>"#
        #expect(rejectionCode(cycle) == "reference_graph")
        // Inline style url(#id) also lands in the graph.
        let inline = #"<svg xmlns="http://www.w3.org/2000/svg" width="40" height="40"><mask id="m"><rect width="4" height="4" style="mask:url(#m)"/></mask><rect width="4" height="4"/></svg>"#
        #expect(rejectionCode(inline) == "reference_graph")
    }

    @Test("long reference chains are rejected before descent")
    func longReferenceChain() {
        var defs = "<g id=\"l0\"><rect width=\"1\" height=\"1\"/></g>"
        for level in 1...40 {
            defs += "<g id=\"l\(level)\"><use href=\"#l\(level - 1)\"/></g>"
        }
        let source = #"<svg xmlns="http://www.w3.org/2000/svg" width="40" height="40"><defs>"# + defs + "</defs><use href=\"#l40\"/></svg>"
        #expect(rejectionCode(source) == "reference_graph")
    }

    // MARK: - CSS decode regressions

    @Test("escaped and comment-split CSS tokens are decoded before checking")
    func cssDecodeRegressions() {
        let head = #"<svg xmlns="http://www.w3.org/2000/svg" width="40" height="40">"#
        // Escaped 'r': u\72 l(… must decode to url( and be rejected.
        let escaped = head + "<style>rect{fill:u\\72 l(http://evil.example/a.png)}</style></svg>"
        #expect(rejectionCode(escaped) == "unsafe_css")
        // Escaped 'j': \6a avascript: must decode and be rejected.
        let escapedJS = head + "<style>rect{fill:\\6a avascript:alert(1)}</style></svg>"
        #expect(rejectionCode(escapedJS) == "unsafe_css")
        // Comment-hidden scheme must be stripped then rejected.
        let commented = head + "<style>rect{fill:url(/*x*/http://evil.example/a.png)}</style></svg>"
        #expect(rejectionCode(commented) == "unsafe_css")
        // A comment between url( and an INTERNAL target still resolves.
        let internalCommented = head + "<defs><linearGradient id=\"g\"><stop offset=\"0\" stop-color=\"#f00\"/></linearGradient></defs><style>rect{fill:url(/*c*/#g)}</style><rect width=\"4\" height=\"4\"/></svg>"
        #expect(rejectionCode(internalCommented) == nil)
        // Invalid escape codepoint → conservative reject.
        #expect(SVGStaticPolicy.decodeCSS("\\110000") == nil)
        // Plain geometry never trips the decoder.
        #expect(SVGStaticPolicy.decodeCSS("fill:url(#g);stroke-width:2") == "fill:url(#g);stroke-width:2")
    }

    // MARK: - Aspect precedence and truthful intrinsic sizing

    @Test("absolute width+height win over viewBox aspect")
    func aspectPrecedence() throws {
        let metrics = try SVGDocumentValidator.validate(
            #"<svg xmlns="http://www.w3.org/2000/svg" width="200" height="100" viewBox="0 0 100 100"/>"#
        ).metrics
        #expect(metrics.aspectRatio == 2.0)
        let size = try #require(SVGRenderSize.resolve(metrics: metrics, requestedWidth: 400))
        #expect(size == (width: 400, height: 200))
    }

    @Test("single absolute dimension completes with CSS defaults")
    func singleDimensionDefaults() throws {
        let widthOnly = try SVGDocumentValidator.validate(
            #"<svg xmlns="http://www.w3.org/2000/svg" width="400"/>"#).metrics
        #expect(widthOnly.intrinsicSizePx?.width == 400)
        #expect(widthOnly.intrinsicSizePx?.height == 150)
        let heightOnly = try SVGDocumentValidator.validate(
            #"<svg xmlns="http://www.w3.org/2000/svg" height="200"/>"#).metrics
        #expect(heightOnly.intrinsicSizePx?.width == 300)
        let size = try #require(SVGRenderSize.resolve(metrics: heightOnly, requestedHeight: 100))
        #expect(size == (width: 300, height: 100))
        let none = try SVGDocumentValidator.validate(
            #"<svg xmlns="http://www.w3.org/2000/svg"/>"#).metrics
        #expect(none.intrinsicSizePx == nil)
        let fallback = try #require(SVGRenderSize.resolve(metrics: none))
        #expect(fallback == (width: 300, height: 150))
    }

    @Test("nested svg documents validate with drawable content tracked")
    func nestedSVGAndDrawableFlag() throws {
        let nested = try SVGDocumentValidator.validate(
            ##"<svg xmlns="http://www.w3.org/2000/svg" width="100" height="50" viewBox="0 0 100 50"><svg x="50" y="0" width="50" height="50" viewBox="0 0 10 10"><rect width="10" height="10" fill="#ff0000"/></svg></svg>"##)
        #expect(nested.hasDrawableContent)
        let textless = try SVGDocumentValidator.validate(
            #"<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10"><title>t</title><desc>d</desc></svg>"#)
        #expect(!textless.hasDrawableContent)
    }

    private func rejectionCode(_ source: String) -> String? {
        do {
            _ = try SVGDocumentValidator.validate(source)
            return nil
        } catch let rejection as SVGDocumentRejection {
            return rejection.code
        } catch {
            return "unexpected"
        }
    }
}
