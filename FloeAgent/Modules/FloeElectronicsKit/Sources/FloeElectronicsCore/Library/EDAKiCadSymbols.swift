// SPDX-License-Identifier: MPL-2.0
import Foundation

public struct EDAKiCadSymbolImport: Sendable {
    public let symbols: [EDASymbolDefinition]
    public let notices: [String: [EDALibraryNotice]]
    public let source: EDALibrarySource
}

/// Source-only KiCad 6+ / 10 symbol import. Inherited definitions are resolved
/// from the explicitly supplied library files, without network or filesystem
/// lookup. Unknown graphics block that symbol and retain the original bytes.
public enum EDAKiCadSymbols {
    public static func read(_ data: Data, sourcePath: String, namespace: String,
                            dependencies: [String: Data] = [:],
                            cancelled: @Sendable () -> Bool = { false }) throws -> EDAKiCadSymbolImport {
        let root = try EDASExpression.parse(data, cancelled: cancelled)
        guard root.tag == "kicad_symbol_lib" else { throw EDAError.unsupported("expected a .kicad_sym library") }
        let source = EDALibrarySource(path: sourcePath, data: data)
        var definitions: [String: EDASExpression] = [:]
        var hashes = [source.sha256]
        func collect(_ node: EDASExpression) throws {
            guard node.tag == "kicad_symbol_lib" else { throw EDAError.unsupported("symbol dependency format") }
            for symbol in node.children("symbol") {
                guard let name = symbol.value(), !name.isEmpty else { throw EDAError.invalid("symbol name") }
                if let previous = definitions[name], previous != symbol { throw EDAError.duplicate("KiCad symbol " + name) }
                definitions[name] = symbol
            }
        }
        try collect(root)
        guard dependencies.count <= 128 else { throw EDAError.invalid("symbol dependency count") }
        for key in dependencies.keys.sorted() {
            guard let bytes = dependencies[key] else { continue }
            try collect(EDASExpression.parse(bytes, cancelled: cancelled)); hashes.append(EDALibraryDigest.sha256(bytes))
        }
        let salt = hashes.sorted().joined(separator: "/")
        var symbols: [EDASymbolDefinition] = [], reports: [String: [EDALibraryNotice]] = [:]
        for node in root.children("symbol") {
            if cancelled() { throw EDAError.cancelled }
            guard let name = node.value() else { continue }
            do {
                let resolved = try resolve(node, definitions: definitions, stack: [])
                let result = try convert(resolved, name: name, namespace: namespace, salt: salt)
                symbols.append(result.0); reports[name] = result.1
            } catch EDAError.cancelled { throw EDAError.cancelled }
            catch {
                reports[name] = [.init("symbol_not_imported", .blocking, path: sourcePath + ":" + name, detail: String(describing: error))]
            }
        }
        return .init(symbols: symbols, notices: reports, source: source)
    }
    private static func resolve(_ node: EDASExpression, definitions: [String: EDASExpression], stack: [String]) throws -> EDASExpression {
        guard let name = node.value(), !stack.contains(name), stack.count < 32 else { throw EDAError.invalid("cyclic/deep symbol inheritance") }
        guard let base = node.child("extends")?.value() else { return node }
        guard let parent = definitions[base] else { throw EDAError.missing("KiCad symbol dependency " + base) }
        guard node.children("symbol").isEmpty, node.children("pin").isEmpty else { throw EDAError.unsupported("derived symbol changes geometry") }
        let resolved = try resolve(parent, definitions: definitions, stack: stack + [name])
        let overrides = Set(node.children("property").compactMap { $0.value() })
        let inherited = resolved.items.dropFirst(2).filter { item in
            if item.tag == "property", let key = item.value(), overrides.contains(key) { return false }
            return item.tag != "extends"
        }
        let own = node.items.dropFirst(2).filter { $0.tag != "extends" }
        return .list([.atom("symbol"), .atom(name)] + inherited + own)
    }
    private static func convert(_ node: EDASExpression, name: String, namespace: String, salt: String) throws -> (EDASymbolDefinition, [EDALibraryNotice]) {
        var fields: [String: String] = [:]
        for field in node.children("property") {
            if let key = field.value(), let value = field.value(2) { fields[key] = value }
        }
        var pins: [EDAPin] = [], graphics: [EDAGraphic] = [], units: [Int] = [], notices: [EDALibraryNotice] = []
        let prefix = namespace + ":" + name
        func append(_ graphic: EDAGraphic, unit: Int) { graphics.append(graphic); units.append(unit) }
        var layers = [(node, 0)]
        for child in node.children("symbol") {
            guard let id = child.value() else { throw EDAError.invalid("symbol unit identifier") }
            let pieces = id.split(separator: "_")
            guard pieces.count >= 3, let unit = Int(pieces[pieces.count - 2]), let style = Int(pieces[pieces.count - 1]),
                  (0...1_000).contains(unit), (0...2).contains(style) else { throw EDAError.unsupported("symbol unit/body identifier " + id) }
            if style == 2 {
                notices.append(.init("alternate_body_retained", .information, path: prefix + ":" + id, detail: "Alternate body remains in the original; the normal body is used."))
            } else { layers.append((child, unit)) }
        }
        let allowed: Set<String> = ["symbol", "extends", "property", "pin_numbers", "pin_names", "exclude_from_sim", "in_bom", "on_board", "in_pos_files", "duplicate_pin_numbers_are_jumpers", "unit_name", "power", "embedded_fonts", "description", "keywords", "footprint_filters", "units_locked", "body_styles", "pin", "polyline", "rectangle", "circle", "arc", "text"]
        for (layer, unit) in layers {
            for item in layer.items.dropFirst(2) {
                guard let tag = item.tag else { continue }
                guard allowed.contains(tag) else { throw EDAError.unsupported("KiCad symbol item " + tag) }
                switch tag {
                case "pin":
                    guard let at = item.child("at"), let number = item.child("number")?.value(),
                          let length = item.child("length"), let typeText = item.value(), let style = item.value(2) else { throw EDAError.invalid("symbol pin fields") }
                    let type: EDAPinType
                    switch typeText {
                    case "input": type = .input
                    case "output": type = .output
                    case "bidirectional": type = .bidirectional
                    case "tri_state": type = .triState
                    case "passive": type = .passive
                    case "power_in": type = .powerInput
                    case "power_out": type = .powerOutput
                    case "open_collector": type = .openCollector
                    case "open_emitter": type = .openEmitter
                    case "no_connect": type = .noConnect
                    case "unspecified", "free": type = .unspecified
                    default: throw EDAError.unsupported("pin electrical type " + typeText)
                    }
                    let position = try at.point(), angle = try at.number(3), distance = try length.number()
                    guard [0.0, 90, 180, 270].contains(angle), distance >= 0 else { throw EDAError.invalid("pin geometry") }
                    let pinName = item.child("name")?.value() ?? ""
                    pins.append(.init(id: EDALibraryDigest.identifier(salt + prefix + "/pin/\(unit)/" + number), number: number,
                        name: pinName, position: position, type: type, unit: unit))
                    let radians = angle * .pi / 180
                    let end = position + .init(cos(radians) * distance, sin(radians) * distance)
                    append(.line(position, end, width: 0.15), unit: unit)
                    if style != "line" {
                        if ["inverted", "inverted_clock"].contains(style) { append(.circle(center: end, radius: 0.35, width: 0.12), unit: unit) }
                        notices.append(.init("pin_graphic_style_retained", .warning, path: prefix + "/pin/" + number,
                            detail: "Electrical pin, name and connection point are exact; specialised '" + style + "' artwork remains in the source."))
                    }
                    if !pinName.isEmpty, pinName != "~", node.child("pin_names")?.child("hide")?.value() != "yes" {
                        append(.text(pinName, position: end + .init(0.5, 0.5), height: 0.9, angle: 0), unit: unit)
                    }
                case "polyline", "rectangle", "circle", "arc", "text":
                    for graphic in try EDAKiCadGraphics.read(item, footprint: false) { append(graphic, unit: unit) }
                    if let fill = item.child("fill")?.child("type")?.value(), fill != "none" {
                        notices.append(.init("graphic_fill_retained", .warning, path: prefix + "/" + tag, detail: "The exact outline is imported; fill styling remains in the retained original."))
                    }
                default: break
                }
            }
        }
        guard !pins.isEmpty || !graphics.isEmpty else { throw EDAError.invalid("empty KiCad symbol") }
        fields["kicad.libraryIdentifier"] = prefix
        let prefixText = fields["Reference"] ?? "U"
        let definition = EDASymbolDefinition(id: EDALibraryDigest.identifier(salt + prefix), name: name,
            referencePrefix: prefixText.isEmpty ? "U" : prefixText, pins: pins, graphics: graphics, fields: fields,
            graphicUnits: Set(pins.map(\.unit)).filter { $0 > 0 }.count > 1 ? units : nil)
        var project = EDAProject(title: name); project.symbols = [definition]; try EDAValidation.validate(project)
        return (definition, notices)
    }
}
