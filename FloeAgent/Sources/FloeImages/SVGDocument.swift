// FloeImages — bounded validation of untrusted SVG documents.
//
// SPDX-License-Identifier: MPL-2.0
//
// Every model-authored or imported SVG is hostile input until proven
// static. This validator is the single shared contract for the chat
// preview and the image.renderSVG tool. Policy is POSITIVE and static:
// only a curated set of geometry/paint/text/filter elements, only
// known SVG/XLink/XML namespaces, only allowlisted attribute names,
// and only internal `#fragment` references are accepted. Scripts,
// events, animation/set elements, DTDs/entities, processing
// instructions, stylesheet hooks, remote or file or data loads,
// unsafe CSS (including escape/comment obfuscation) and reference
// graphs that could expand unboundedly are rejected before any
// renderer sees the bytes. CSP is defense in depth, not the evidence;
// this validator is the evidence. Validation is pure Foundation so it
// compiles and runs identically on every platform.

import Foundation
import FloeCore

// MARK: - Public value types

/// A resolved CSS-ish length on the SVG root: value in user units plus
/// the declared unit (percent carries no absolute pixels).
public struct SVGLength: Sendable, Hashable {
    public enum Unit: String, Sendable, Hashable {
        case px, percent, pt, mm, cm, in_
    }
    public var value: Double
    public var unit: Unit

    /// Pixels for absolute units; nil for percent (container-relative).
    public var pixels: Double? {
        switch unit {
        case .px: return value
        case .percent: return nil
        case .pt: return value * 96.0 / 72.0
        case .mm: return value * 96.0 / 25.4
        case .cm: return value * 960.0 / 25.4
        case .in_: return value * 96.0
        }
    }
}

/// The viewBox rectangle in user units.
public struct SVGViewBox: Sendable, Hashable {
    public var minX: Double
    public var minY: Double
    public var width: Double
    public var height: Double
}

/// Validated root geometry.
public struct SVGDocumentMetrics: Sendable, Hashable {
    public var declaredWidth: SVGLength?
    public var declaredHeight: SVGLength?
    public var viewBox: SVGViewBox?

    /// BOTH absolute root width/height describe the real viewport
    /// aspect and win (W3C SVG2 IntrinsicSizing); the viewBox aspect is
    /// the fallback for missing or percentage dimensions.
    public var aspectRatio: Double? {
        if let w = declaredWidth?.pixels, let h = declaredHeight?.pixels,
           h > 0, w > 0 {
            return w / h
        }
        if let viewBox, viewBox.width > 0, viewBox.height > 0 {
            return viewBox.width / viewBox.height
        }
        return nil
    }

    /// Truthful intrinsic size for canvas selection: both absolute
    /// dimensions first, then the viewBox, then the CSS replaced-
    /// element defaults (300×150) completed by the one absolute edge
    /// when present. Fully percentage/absent documents return nil.
    public var intrinsicSizePx: (width: Double, height: Double)? {
        let w = declaredWidth?.pixels
        let h = declaredHeight?.pixels
        if let w, let h, w > 0, h > 0 {
            return (w, h)
        }
        if let viewBox, viewBox.width > 0, viewBox.height > 0 {
            return (viewBox.width, viewBox.height)
        }
        if let w, w > 0 { return (w, 150) }
        if let h, h > 0 { return (300, h) }
        return nil
    }
}

/// Stable rejection identities. UI layers map these to concise
/// bilingual sentences; tool summaries embed the machine-readable
/// code so model callers can repair the source.
public enum SVGDocumentRejection: Error, Sendable, Hashable, LocalizedError {
    case empty
    case tooLarge(byteCount: Int, limit: Int)
    case missingRootSVG
    case notWellFormed(String)
    case doctypeOrEntityDeclaration
    case processingInstruction(String)
    case unknownNamespace(String)
    case unknownElement(String)
    case unknownAttribute(String)
    case unsafeReference(String)
    case unsafeCSS(String)
    case eventAttribute(String)
    case tooManyElements(count: Int, limit: Int)
    case tooDeep(depth: Int, limit: Int)
    case duplicateID(String)
    case referenceGraph(String)
    case invalidDimensions(String)

    public var errorDescription: String? {
        switch self {
        case .empty: return "SVG source is empty"
        case .tooLarge(let bytes, let limit): return "SVG exceeds the \(limit)-byte limit (got \(bytes))"
        case .missingRootSVG: return "SVG root element is missing"
        case .notWellFormed(let detail): return "SVG is not well-formed XML (\(detail))"
        case .doctypeOrEntityDeclaration: return "SVG declares a DTD or entities"
        case .processingInstruction(let detail): return "SVG carries a processing instruction: \(detail)"
        case .unknownNamespace(let uri): return "SVG uses an unsupported namespace: \(uri)"
        case .unknownElement(let name): return "SVG element is not in the static allowlist: \(name)"
        case .unknownAttribute(let name): return "SVG attribute is not in the static allowlist: \(name)"
        case .unsafeReference(let ref): return "SVG references an external resource: \(ref)"
        case .unsafeCSS(let detail): return "SVG CSS is not conservatively safe: \(detail)"
        case .eventAttribute(let name): return "SVG carries an event handler attribute: \(name)"
        case .tooManyElements(let count, let limit): return "SVG has \(count) elements (limit \(limit))"
        case .tooDeep(let depth, let limit): return "SVG nesting depth \(depth) exceeds limit \(limit)"
        case .duplicateID(let id): return "SVG declares duplicate id: \(id)"
        case .referenceGraph(let detail): return "SVG reference graph is unsafe: \(detail)"
        case .invalidDimensions(let detail): return "SVG root dimensions are invalid: \(detail)"
        }
    }

    /// Machine code embedded in tool error lines.
    public var code: String {
        switch self {
        case .empty: "empty"
        case .tooLarge: "too_large"
        case .missingRootSVG: "missing_root"
        case .notWellFormed: "not_well_formed"
        case .doctypeOrEntityDeclaration: "dtd_or_entity"
        case .processingInstruction: "processing_instruction"
        case .unknownNamespace: "unknown_namespace"
        case .unknownElement: "unknown_element"
        case .unknownAttribute: "unknown_attribute"
        case .unsafeReference: "unsafe_reference"
        case .unsafeCSS: "unsafe_css"
        case .eventAttribute: "event_attribute"
        case .tooManyElements: "too_many_elements"
        case .tooDeep: "too_deep"
        case .duplicateID: "duplicate_id"
        case .referenceGraph: "reference_graph"
        case .invalidDimensions: "invalid_dimensions"
        }
    }
}

/// A source string that passed every structural, safety and dimension
/// rule. The validated bytes are carried forward unchanged so the
/// renderer and the digest always see exactly what was checked.
public struct ValidatedSVGDocument: Sendable, Hashable {
    public let source: String
    public let metrics: SVGDocumentMetrics
    public let elementCount: Int
    /// True when at least one shape/text/use element exists: the
    /// renderer's blank-capture gate only fires for documents that
    /// SHOULD produce visible pixels.
    public let hasDrawableContent: Bool
    public var utf8ByteCount: Int { source.utf8.count }

    /// SHA-256 of the exact validated bytes (cache/share identity).
    public var sourceDigest: String { FloeDigest.sha256Hex(Data(source.utf8)) }
}

/// Shared fixed ceilings. The renderer and the tool both draw their
/// limits from here so chat preview and tool output cannot diverge.
public enum SVGSafetyLimits {
    public static let maxSourceBytes = 1_048_576           // 1 MiB of XML
    public static let maxElements = 20_000
    public static let maxDepth = 64
    public static let maxStyleBytes = 256 * 1_024
    public static let maxViewBoxExtent = 1_000_000.0
    public static let maxIntrinsicEdge = 100_000.0
    /// Aggregate internal-reference expansion budget: the total number
    /// of element instantiations a renderer could perform across the
    /// containment + reference graph (weighted, root-inclusive).
    public static let maxReferenceExpansion = 50_000
    /// Reference-hop chain depth (use/pattern/mask/filter links).
    public static let maxReferenceChainDepth = 32
    /// Raster ceilings for one rendered bitmap (tool + preview).
    public static let maxOutputEdge = 4_096
    public static let maxOutputPixels = 40_000_000
    public static let minOutputEdge = 16
}

// MARK: - Static allowlists

/// Positive element allowlist (local SVG names, case-exact per SVG).
/// Everything outside it — including ALL animation elements
/// (animate, animateTransform, animateMotion, animateColor, set),
/// scripts, foreignObject/iframe/embed/object/image/audio/video,
/// SVG Tiny handler/listener/discard, fonts and glyph machinery —
/// is rejected.
enum SVGStaticPolicy {
    static let allowedElements: Set<String> = [
        // structure
        "svg", "g", "defs", "symbol", "use", "switch", "marker", "view",
        "title", "desc", "metadata", "style",
        // shapes
        "rect", "circle", "ellipse", "line", "polyline", "polygon", "path",
        // text
        "text", "tspan", "textPath", "tref",
        // paint servers
        "linearGradient", "radialGradient", "stop", "pattern", "solidColor",
        // clipping / masking
        "clipPath", "mask",
        // filters (common static subset only)
        "filter", "feBlend", "feColorMatrix", "feComponentTransfer",
        "feComposite", "feFlood", "feGaussianBlur", "feOffset",
        "feTile", "feTurbulence", "feMorphology",
        "feDistantLight", "fePointLight", "feSpotLight",
        "feMerge", "feMergeNode", "feFuncR", "feFuncG", "feFuncB", "feFuncA"
    ]

    static let allowedNamespaces: Set<String> = [
        "http://www.w3.org/2000/svg",
        "http://www.w3.org/1999/xlink",
        "http://www.w3.org/XML/1998/namespace"
    ]

    /// Attributes accepted without a namespace prefix (exact SVG case).
    static let allowedAttributes: Set<String> = [
        // global / structure
        "id", "class", "style", "lang", "systemLanguage", "version",
        "baseProfile", "transform", "display", "overflow", "visibility",
        "clip", "clip-path", "clip-rule", "mask", "filter", "opacity",
        // geometry
        "x", "y", "x1", "x2", "y1", "y2", "cx", "cy", "r", "rx", "ry",
        "width", "height", "viewBox", "preserveAspectRatio", "points", "d",
        "path", "pathLength", "refX", "refY", "markerWidth", "markerHeight",
        "markerUnits", "orient", "patternUnits", "patternContentUnits",
        "patternTransform", "clipPathUnits", "maskUnits", "maskContentUnits",
        "filterUnits", "primitiveUnits", "offset",
        // paint
        "fill", "fill-rule", "fill-opacity", "stroke", "stroke-width",
        "marker", "marker-start", "marker-mid", "marker-end",
        "stroke-linecap", "stroke-linejoin", "stroke-miterlimit",
        "stroke-dasharray", "stroke-dashoffset", "stroke-opacity",
        "color", "color-interpolation", "color-interpolation-filters",
        "color-rendering", "shape-rendering", "text-rendering",
        "image-rendering", "vector-effect", "paint-order",
        "stop-color", "stop-opacity", "flood-color", "flood-opacity",
        "lighting-color",
        // gradients
        "gradientUnits", "gradientTransform", "spreadMethod", "fx", "fy",
        // text
        "font-family", "font-size", "font-size-adjust", "font-stretch",
        "font-style", "font-variant", "font-weight", "text-anchor",
        "text-decoration", "letter-spacing", "word-spacing", "writing-mode",
        "direction", "unicode-bidi", "baseline-shift", "dominant-baseline",
        "alignment-baseline", "dx", "dy", "startOffset", "textLength",
        "lengthAdjust", "space",
        // filters (subset)
        "in", "in2", "result", "mode", "type", "values", "operator",
        "k1", "k2", "k3", "k4", "stdDeviation", "azimuth", "elevation",
        "surfaceScale", "diffuseConstant", "specularConstant",
        "specularExponent", "limitingConeAngle", "baseFrequency",
        "numOctaves", "seed", "scale", "radius",
        // xlink (validated separately: internal-only)
        "href", "xlink:href", "xmlns", "xmlns:xlink"
    ]

    static let forbiddenValueAttributeNames: Set<String> = [
        "requiredExtensions", "requiredFeatures", "externalResourcesRequired",
        "target", "onload", "attributeName", "attributeType"
    ]

    static func isEventAttribute(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower.hasPrefix("on") && lower.count > 2
            && lower.allSatisfy { $0.isLetter || $0.isNumber }
    }

    // MARK: Conservative CSS validation

    /// Decodes CSS comment hiding and backslash escapes, then applies
    /// the full conservative rule set. `accumulated` is the COMPLETE
    /// style text (attribute value, or the whole <style> body after
    /// close) so token splits across parser callbacks cannot bypass.
    /// Returns the violated token, or nil when safe.
    static func cssViolation(in accumulated: String) -> String? {
        guard let decoded = decodeCSS(accumulated) else { return "invalid escape" }
        let lower = decoded.lowercased()
        if lower.contains("@") { return "@-rule" }
        if lower.contains("expression(") { return "expression(" }
        if lower.contains("javascript:") { return "javascript:" }
        if lower.contains("behavior:") { return "behavior:" }
        // Every url() must open an internal #fragment after decoding.
        var searchStart = lower.startIndex
        while let open = lower.range(of: "url(", range: searchStart..<lower.endIndex) {
            let after = open.upperBound
            guard let close = lower.range(of: ")", range: after..<lower.endIndex) else { return "url(unclosed" }
            let target = lower[after..<close.lowerBound]
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
            if !target.hasPrefix("#") { return "url(\(String(target.prefix(80))))" }
            searchStart = close.upperBound
        }
        for scheme in ["http://", "https://", "ftp://", "file://", "data:", "//"]
        where lower.contains(scheme) { return scheme }
        return nil
    }

    /// Unicode.Scalar has no isHexDigit/hexDigitValue/isWhitespace;
    /// these wrap the Character/CharacterSet APIs for scalars.
    static func scalarIsHexDigit(_ scalar: Unicode.Scalar) -> Bool {
        CharacterSet(charactersIn: "0123456789abcdefABCDEF").contains(scalar)
    }

    static func scalarHexValue(_ scalar: Unicode.Scalar) -> UInt32? {
        UInt32(String(scalar), radix: 16)
    }

    static func scalarIsWhitespace(_ scalar: Unicode.Scalar) -> Bool {
        CharacterSet.whitespacesAndNewlines.contains(scalar)
    }

    /// Single bounded linear pass: strips /* */ comments, then resolves
    /// \\hh… CSS escapes. Returns nil on an invalid escape codepoint so
    /// callers can reject conservatively instead of guessing. No
    /// fixed-point rescanning.
    static func decodeCSS(_ text: String) -> String? {
        let scalars = Array(text.unicodeScalars)
        // Pass 1 — strip comments (an unterminated comment consumes the
        // remainder, which is the conservative outcome).
        var stripped: [Unicode.Scalar] = []
        stripped.reserveCapacity(scalars.count)
        var index = 0
        while index < scalars.count {
            if scalars[index] == "/", index + 1 < scalars.count, scalars[index + 1] == "*" {
                index += 2
                while index < scalars.count {
                    if scalars[index] == "*", index + 1 < scalars.count, scalars[index + 1] == "/" {
                        index += 2
                        break
                    }
                    index += 1
                }
                continue
            }
            stripped.append(scalars[index])
            index += 1
        }
        // Pass 2 — resolve backslash escapes.
        var decoded: [Unicode.Scalar] = []
        decoded.reserveCapacity(stripped.count)
        index = 0
        while index < stripped.count {
            let scalar = stripped[index]
            guard scalar == "\\" else {
                decoded.append(scalar)
                index += 1
                continue
            }
            index += 1
            guard index < stripped.count else {
                decoded.append("\\")
                break
            }
            if scalarIsHexDigit(stripped[index]) {
                var value: UInt32 = 0
                var digits = 0
                while index < stripped.count, scalarIsHexDigit(stripped[index]), digits < 6 {
                    value = value * 16 + (scalarHexValue(stripped[index]) ?? 0)
                    index += 1
                    digits += 1
                }
                // One trailing whitespace terminates the escape.
                if index < stripped.count, scalarIsWhitespace(stripped[index]) {
                    index += 1
                }
                guard let decodedScalar = Unicode.Scalar(value), value != 0 else {
                    return nil // invalid or NUL escape → conservative reject
                }
                decoded.append(decodedScalar)
            } else {
                decoded.append(stripped[index])
                index += 1
            }
        }
        return String(String.UnicodeScalarView(decoded))
    }

    /// Every `url(...)` target in an ALREADY-DECODED value.
    static func urlTokens(in text: String) -> [String] {
        let lower = text.lowercased()
        var tokens: [String] = []
        var searchStart = lower.startIndex
        while let open = lower.range(of: "url(", range: searchStart..<lower.endIndex) {
            let after = open.upperBound
            guard let close = lower.range(of: ")", range: after..<lower.endIndex) else {
                tokens.append("url(unclosed")
                break
            }
            let lowerTarget = lower[after..<close.lowerBound]
            // Mirror the same range in the ORIGINAL text so the
            // fragment id keeps its exact case.
            let startOffset = lower.distance(from: lower.startIndex, to: after)
            let endOffset = lower.distance(from: lower.startIndex, to: close.lowerBound)
            let originalStart = text.index(text.startIndex, offsetBy: startOffset)
            let originalEnd = text.index(text.startIndex, offsetBy: endOffset)
            let target = String(text[originalStart..<originalEnd])
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            tokens.append(target)
            searchStart = close.upperBound
        }
        return tokens
    }
}

// MARK: - Validator

public enum SVGDocumentValidator {
    /// Full validation: byte cap → raw scan for parser-invisible
    /// hazards → namespace-aware XML walk with positive element and
    /// attribute rules, internal-reference and conservative CSS
    /// checks → weighted reference-graph expansion budget → root
    /// dimensions. Throws `SVGDocumentRejection`.
    public static func validate(_ source: String) throws -> ValidatedSVGDocument {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SVGDocumentRejection.empty }
        let bytes = source.utf8.count
        guard bytes <= SVGSafetyLimits.maxSourceBytes else {
            throw SVGDocumentRejection.tooLarge(byteCount: bytes, limit: SVGSafetyLimits.maxSourceBytes)
        }

        // Raw scan first: DTD/entity declarations and stylesheet PIs
        // never reach an element delegate.
        try rawScan(trimmed)

        let walker = SVGWalk()
        let parser = XMLParser(data: Data(source.utf8))
        parser.shouldResolveExternalEntities = false
        // Raw-name parsing (shouldProcessNamespaces stays false): the
        // element/attribute names keep their prefixes and xmlns
        // declarations stay visible as attributes, so unknown or
        // executable namespaces are rejected by the allowlists instead
        // of being silently normalized away.
        parser.shouldProcessNamespaces = false
        parser.delegate = walker
        if parser.parse() {
            if let rejection = walker.rejection { throw rejection }
        } else {
            // Preserve the real rejection first: abortParsing() would
            // otherwise surface as a generic parse error.
            if let rejection = walker.rejection { throw rejection }
            let detail = parser.parserError?.localizedDescription ?? "unknown"
            if detail.lowercased().contains("entity") {
                throw SVGDocumentRejection.doctypeOrEntityDeclaration
            }
            throw SVGDocumentRejection.notWellFormed(detail)
        }
        guard walker.sawRoot, walker.rootName == "svg" else {
            throw SVGDocumentRejection.missingRootSVG
        }
        if let rejection = walker.rejection { throw rejection }
        try walker.checkReferenceGraph()
        let metrics = try rootMetrics(attributes: walker.rootAttributes)
        return ValidatedSVGDocument(
            source: source, metrics: metrics, elementCount: walker.elementCount,
            hasDrawableContent: walker.drawableCount > 0)
    }

    // MARK: Raw scan

    private static func rawScan(_ source: String) throws {
        let scalars = Array(source.unicodeScalars)
        var index = 0
        while index < scalars.count {
            guard scalars[index] == "<", index + 1 < scalars.count else {
                index += 1
                continue
            }
            let next = scalars[index + 1]
            if next == "!" {
                let probe = String(String.UnicodeScalarView(
                    scalars[(index + 2)..<min(index + 10, scalars.count)])).lowercased()
                if probe.hasPrefix("--") || probe.hasPrefix("[cdata[") {
                    // Comments and CDATA sections are inert here; the
                    // walk validates any CDATA inside <style>.
                    index += 2
                    continue
                }
                throw SVGDocumentRejection.doctypeOrEntityDeclaration
            }
            if next == "?" {
                let probe = String(String.UnicodeScalarView(
                    scalars[(index + 2)..<min(index + 10, scalars.count)]))
                if probe.lowercased().hasPrefix("xml") && index == firstNonWhitespace(scalars) {
                    index += 2
                    continue
                }
                let name = probe.prefix(while: { $0 != "?" && !$0.isWhitespace })
                throw SVGDocumentRejection.processingInstruction(String(name.prefix(32)))
            }
            index += 1
        }
    }

    private static func firstNonWhitespace(_ scalars: [Unicode.Scalar]) -> Int {
        var i = 0
        while i < scalars.count, SVGStaticPolicy.scalarIsWhitespace(scalars[i]) { i += 1 }
        return i
    }

    // MARK: Element walk

    /// One parsed element: containment children and internal reference
    /// targets. Reference edges from `href`/`url(#…)`/style live on the
    /// element that DECLARES them; containment edges propagate cost to
    /// every enclosing id automatically in the graph check.
    struct Slot {
        var children: [Int] = []
        var refs: [String] = []
        var declaredID: String?
    }

    final class SVGWalk: NSObject, XMLParserDelegate {
        var sawRoot = false
        var rootName = ""
        var rootAttributes: [String: String] = [:]
        var elementCount = 0
        var depth = 0
        var rejection: SVGDocumentRejection?

        /// Elements that would paint something when rendered.
        static let drawableElements: Set<String> = [
            "rect", "circle", "ellipse", "line", "polyline", "polygon",
            "path", "text", "use"
        ]
        var drawableCount = 0

        /// id → declaring slot (duplicate ids are rejected).
        var ids: [String: Int] = [:]
        var slots: [Slot] = []
        /// Open-element stack of slot indices (containment parents).
        var openStack: [Int] = []

        /// <style> body accumulation with full-text validation at close.
        private var styleDepth = 0
        private var styleText = ""
        private var styleSlot = -1

        func reject(_ rejection: SVGDocumentRejection, _ parser: XMLParser) {
            if self.rejection == nil { self.rejection = rejection }
            parser.abortParsing()
        }

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?,
            attributes attributeDict: [String: String] = [:]
        ) {
            guard rejection == nil else { return }
            if !sawRoot {
                sawRoot = true
                rootName = elementName
                rootAttributes = attributeDict
            }
            guard SVGStaticPolicy.allowedElements.contains(elementName) else {
                reject(.unknownElement(elementName), parser)
                return
            }
            // With raw-name parsing the allowlist itself rejects any
            // qualified element name (svg:svg, evil:rect, …); a
            // namespaceURI would only appear with namespace processing,
            // which stays off — guard anyway for portability.
            if let uri = namespaceURI, uri != "http://www.w3.org/2000/svg" {
                reject(.unknownNamespace(uri), parser)
                return
            }
            elementCount += 1
            if SVGWalk.drawableElements.contains(elementName) { drawableCount += 1 }
            depth += 1
            if elementCount > SVGSafetyLimits.maxElements {
                reject(.tooManyElements(count: elementCount, limit: SVGSafetyLimits.maxElements), parser)
                return
            }
            if depth > SVGSafetyLimits.maxDepth {
                reject(.tooDeep(depth: depth, limit: SVGSafetyLimits.maxDepth), parser)
                return
            }

            // Open this element's slot and link containment.
            let slot = slots.count
            slots.append(Slot())
            if let parent = openStack.last {
                slots[parent].children.append(slot)
            }
            openStack.append(slot)
            if elementName == "style" {
                styleDepth += 1
                styleText = ""
                styleSlot = slot
            }

            // Pre-scan for this element's own id (duplicate check).
            for (name, value) in attributeDict {
                guard name == "id" else { continue }
                let id = value.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !id.isEmpty, id.count <= 255 else { continue }
                if ids[id] != nil {
                    reject(.duplicateID(id), parser)
                    return
                }
                ids[id] = slot
                slots[slot].declaredID = id
            }

            for (rawName, value) in attributeDict {
                let localName = rawName.contains(":")
                    ? String(rawName.split(separator: ":").last ?? Substring(rawName))
                    : rawName
                // Event handlers never survive.
                if SVGStaticPolicy.isEventAttribute(rawName) {
                    reject(.eventAttribute(rawName), parser)
                    return
                }
                // Explicitly rejected attribute names (never allowlisted).
                if SVGStaticPolicy.forbiddenValueAttributeNames.contains(rawName) {
                    reject(.unknownAttribute(rawName), parser)
                    return
                }
                // Namespace declarations: only xmlns/xmlns:xlink to
                // known URIs.
                if rawName == "xmlns" || rawName.hasPrefix("xmlns:") {
                    if rawName == "xmlns:xml" {
                        reject(.unknownNamespace(rawName), parser)
                        return
                    }
                    let declared = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !declared.isEmpty,
                       !SVGStaticPolicy.allowedNamespaces.contains(declared) {
                        reject(.unknownNamespace(declared), parser)
                        return
                    }
                    continue
                }
                // Only known prefixes may qualify an attribute.
                if let colon = rawName.firstIndex(of: ":") {
                    let prefix = String(rawName[..<colon])
                    guard prefix == "xlink" || prefix == "xml" || prefix == "svg" else {
                        reject(.unknownAttribute(rawName), parser)
                        return
                    }
                }
                if !SVGStaticPolicy.allowedAttributes.contains(rawName)
                    && !SVGStaticPolicy.allowedAttributes.contains(localName) {
                    reject(.unknownAttribute(rawName), parser)
                    return
                }
                // href / xlink:href must be internal fragments.
                if localName == "href" || rawName == "xlink:href" {
                    guard value.hasPrefix("#"), value.count > 1 else {
                        reject(.unsafeReference(
                            value.isEmpty ? "empty" : String(value.prefix(160))), parser)
                        return
                    }
                    slots[slot].refs.append(String(value.dropFirst()))
                    continue
                }
                // Any value that can carry url(...) — style attributes
                // and paint/clip/mask/filter presentation attributes —
                // is CSS-validated on its FULL value (decode first, so
                // comment/escape obfuscation cannot split a token) and
                // contributes internal reference edges.
                if rawName == "style" || ["fill", "stroke", "filter", "mask", "clip-path", "marker", "marker-start", "marker-mid", "marker-end"].contains(localName) {
                    if let violation = SVGStaticPolicy.cssViolation(in: value) {
                        reject(rawName == "style" ? .unsafeCSS(violation) : .unsafeReference(violation), parser)
                        return
                    }
                    if let decoded = SVGStaticPolicy.decodeCSS(value) {
                        for token in SVGStaticPolicy.urlTokens(in: decoded) {
                            guard token.hasPrefix("#"), token.count > 1 else {
                                reject(.unsafeReference(String(token.prefix(160))), parser)
                                return
                            }
                            slots[slot].refs.append(String(token.dropFirst()))
                        }
                    }
                }
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            guard rejection == nil, styleDepth > 0 else { return }
            styleText += string
            if styleText.utf8.count > SVGSafetyLimits.maxStyleBytes {
                reject(.tooLarge(byteCount: styleText.utf8.count,
                                 limit: SVGSafetyLimits.maxStyleBytes), parser)
            }
        }

        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            guard rejection == nil, styleDepth > 0,
                  let text = String(data: CDATABlock, encoding: .utf8) else { return }
            styleText += text
            if styleText.utf8.count > SVGSafetyLimits.maxStyleBytes {
                reject(.tooLarge(byteCount: styleText.utf8.count,
                                 limit: SVGSafetyLimits.maxStyleBytes), parser)
            }
        }

        func parser(
            _ parser: XMLParser,
            didEndElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?
        ) {
            depth -= 1
            if elementName == "style", styleDepth > 0 {
                styleDepth -= 1
                guard rejection == nil else { return }
                // Validate the COMPLETE accumulated style text once, so
                // a token split across foundCharacters callbacks cannot
                // hide. Violations reject; internal url(#id) targets
                // become reference edges of the style element's slot.
                if let violation = SVGStaticPolicy.cssViolation(in: styleText) {
                    reject(.unsafeCSS(violation), parser)
                    openStack.popLast()
                    return
                }
                if styleSlot >= 0, styleSlot < slots.count,
                   let decoded = SVGStaticPolicy.decodeCSS(styleText) {
                    for token in SVGStaticPolicy.urlTokens(in: decoded) {
                        guard token.hasPrefix("#"), token.count > 1 else {
                            reject(.unsafeReference(String(token.prefix(160))), parser)
                            break
                        }
                        slots[styleSlot].refs.append(String(token.dropFirst()))
                    }
                }
            }
            if !openStack.isEmpty { openStack.popLast() }
        }

        // MARK: Weighted reference-graph expansion

        /// Iterative post-order DFS over containment + reference edges
        /// from the root slot. Cost of a slot = 1 + Σ(children costs)
        /// + Σ(resolved reference costs): every `use`/pattern/mask
        /// reference re-instantiates the referenced subtree, so shared
        /// subtrees multiply honestly. Cycles, over-deep reference
        /// chains and aggregate expansion beyond the budget are
        /// rejected BEFORE any renderer sees the document. Recursion
        /// is avoided entirely (explicit stack), and every budget is
        /// checked before descent, so no stack overflow or unbounded
        /// walk is possible.
        func checkReferenceGraph() throws {
            if let rejection { throw rejection }
            guard !slots.isEmpty else { return }
            struct Frame {
                let slot: Int
                let pathReferences: Int
                var edge = 0
                var cost = 1
                var referenceHeight = 0
                var height = 1
            }
            let adjacency: [[(target: Int, references: Int)]] = slots.map { slot in
                slot.children.map { (target: $0, references: 0) }
                    + slot.refs.compactMap { id in ids[id].map { (target: $0, references: 1) } }
            }
            let count = slots.count
            var state = [UInt8](repeating: 0, count: count)
            var cost = [Int](repeating: 0, count: count)
            var referenceHeight = [Int](repeating: 0, count: count)
            var height = [Int](repeating: 0, count: count)
            let maximumHeight = SVGSafetyLimits.maxDepth + SVGSafetyLimits.maxReferenceChainDepth
            var stack = [Frame(slot: 0, pathReferences: 0)]
            state[0] = 1
            while !stack.isEmpty {
                let index = stack.count - 1
                let frame = stack[index]
                if frame.edge == adjacency[frame.slot].count {
                    state[frame.slot] = 2
                    cost[frame.slot] = frame.cost
                    referenceHeight[frame.slot] = frame.referenceHeight
                    height[frame.slot] = frame.height
                    stack.removeLast()
                    continue
                }
                let edge = adjacency[frame.slot][frame.edge]
                if state[edge.target] == 1 {
                    throw SVGDocumentRejection.referenceGraph("cycle at #\(slots[edge.target].declaredID ?? "?")")
                }
                if state[edge.target] == 0 {
                    let pathReferences = frame.pathReferences + edge.references
                    guard pathReferences <= SVGSafetyLimits.maxReferenceChainDepth,
                          stack.count < maximumHeight else {
                        throw SVGDocumentRejection.referenceGraph("expanded reference path exceeds its budget")
                    }
                    // Keep the parent on this edge until the child is complete.
                    // Both first visits and memoized visits must add its full cost.
                    state[edge.target] = 1
                    stack.append(Frame(slot: edge.target, pathReferences: pathReferences))
                    continue
                }
                let references = referenceHeight[edge.target] + edge.references
                let expandedHeight = height[edge.target] + 1
                guard references <= SVGSafetyLimits.maxReferenceChainDepth,
                      frame.pathReferences + references <= SVGSafetyLimits.maxReferenceChainDepth,
                      expandedHeight <= maximumHeight,
                      cost[edge.target] <= SVGSafetyLimits.maxReferenceExpansion - frame.cost else {
                    throw SVGDocumentRejection.referenceGraph("reference expansion exceeds its budget")
                }
                stack[index].cost += cost[edge.target]
                stack[index].referenceHeight = max(frame.referenceHeight, references)
                stack[index].height = max(frame.height, expandedHeight)
                stack[index].edge += 1
            }
        }
    }

    // MARK: Root dimensions

    static func rootMetrics(attributes: [String: String]) throws -> SVGDocumentMetrics {
        let width = try parseLength(attributes["width"], name: "width")
        let height = try parseLength(attributes["height"], name: "height")
        var viewBox: SVGViewBox?
        // Raw-name parsing keeps SVG's exact attribute case: the
        // canonical key is "viewBox".
        if let raw = attributes["viewBox"],
           !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let parts = raw
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .split(whereSeparator: { $0 == "," || $0.isWhitespace })
                .map(String.init)
            guard parts.count == 4 else {
                throw SVGDocumentRejection.invalidDimensions("viewBox needs 4 numbers")
            }
            let values = try parts.map { part -> Double in
                guard let value = Double(part), value.isFinite else {
                    throw SVGDocumentRejection.invalidDimensions("viewBox number \(part.prefix(24))")
                }
                return value
            }
            let box = SVGViewBox(minX: values[0], minY: values[1], width: values[2], height: values[3])
            guard box.width > 0, box.height > 0,
                  abs(box.minX) <= SVGSafetyLimits.maxViewBoxExtent,
                  abs(box.minY) <= SVGSafetyLimits.maxViewBoxExtent,
                  box.width <= SVGSafetyLimits.maxViewBoxExtent,
                  box.height <= SVGSafetyLimits.maxViewBoxExtent else {
                throw SVGDocumentRejection.invalidDimensions("viewBox out of supported range")
            }
            viewBox = box
        }
        for (value, name) in [(width, "width"), (height, "height")] {
            if let pixels = value?.pixels,
               (pixels <= 0 || pixels > SVGSafetyLimits.maxIntrinsicEdge) {
                throw SVGDocumentRejection.invalidDimensions("\(name) \(pixels)")
            }
        }
        return SVGDocumentMetrics(declaredWidth: width, declaredHeight: height, viewBox: viewBox)
    }

    static func parseLength(_ raw: String?, name: String) throws -> SVGLength? {
        guard let raw else { return nil }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let lower = text.lowercased()
        let unitTable: [(suffix: String, unit: SVGLength.Unit)] = [
            ("px", .px), ("%", .percent), ("pt", .pt),
            ("mm", .mm), ("cm", .cm), ("in", .in_)
        ]
        var numberPart = text
        var unit: SVGLength.Unit = .px
        for (suffix, candidate) in unitTable where lower.hasSuffix(suffix) {
            numberPart = String(text.dropLast(suffix.count))
            unit = candidate
            break
        }
        guard let value = Double(numberPart.trimmingCharacters(in: .whitespaces)),
              value.isFinite else {
            throw SVGDocumentRejection.invalidDimensions("\(name) \(text.prefix(24))")
        }
        return SVGLength(value: value, unit: unit)
    }
}

/// Shared target-size resolution for the chat preview and the tool.
/// Explicit edges win; a single explicit edge follows the document
/// aspect (CSS replaced-element defaults complete the missing edge
/// when no aspect exists); neither falls back to intrinsic size, then
/// the 300×150 default, scaled into the caps.
public enum SVGRenderSize {
    public static func resolve(
        metrics: SVGDocumentMetrics,
        requestedWidth: Int? = nil,
        requestedHeight: Int? = nil,
        maxEdge: Int = SVGSafetyLimits.maxOutputEdge
    ) -> (width: Int, height: Int)? {
        let aspect = metrics.aspectRatio
        var w: Double?
        var h: Double?
        if let requestedWidth { w = Double(requestedWidth) }
        if let requestedHeight { h = Double(requestedHeight) }
        switch (w, h) {
        case (let w?, let h?):
            return clamp(width: w, height: h)
        case (let w?, nil):
            return clamp(width: w, height: aspect.map { w / $0 } ?? 150)
        case (nil, let h?):
            return clamp(width: aspect.map { h * $0 } ?? 300, height: h)
        case (nil, nil):
            if let intrinsic = metrics.intrinsicSizePx {
                let scale = min(1.0, Double(maxEdge) / max(intrinsic.width, intrinsic.height))
                return clamp(width: intrinsic.width * scale, height: intrinsic.height * scale)
            }
            return clamp(width: 300, height: 150)
        }
    }

    private static func clamp(width: Double, height: Double) -> (width: Int, height: Int)? {
        var w = max(1, width.rounded())
        var h = max(1, height.rounded())
        guard w.isFinite, h.isFinite else { return nil }
        // Preserve aspect while fitting the edge/pixel ceilings.
        let scale = min(
            Double(SVGSafetyLimits.maxOutputEdge) / max(w, h),
            sqrt(Double(SVGSafetyLimits.maxOutputPixels) / max(1, w * h))
        )
        if scale < 1 {
            w = max(1, (w * scale).rounded())
            h = max(1, (h * scale).rounded())
        }
        w = min(w, Double(SVGSafetyLimits.maxOutputEdge))
        h = min(h, Double(SVGSafetyLimits.maxOutputEdge))
        return (Int(w), Int(h))
    }
}
