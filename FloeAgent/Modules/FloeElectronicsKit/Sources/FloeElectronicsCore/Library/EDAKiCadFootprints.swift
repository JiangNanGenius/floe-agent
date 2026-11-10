// SPDX-License-Identifier: MPL-2.0
import Foundation

public struct EDAKiCadFootprintImport: Sendable {
    public let footprint: EDAFootprintDefinition?
    public let notices: [EDALibraryNotice]
    public let source: EDALibrarySource
}
public enum EDAKiCadFootprints {
    public static func read(_ data: Data, sourcePath: String, namespace: String,
                            cancelled: @Sendable () -> Bool = { false }) throws -> EDAKiCadFootprintImport {
        let node = try EDASExpression.parse(data, cancelled: cancelled)
        guard node.tag == "footprint", let name = node.value() else { throw EDAError.unsupported("expected a .kicad_mod footprint") }
        let source = EDALibrarySource(path: sourcePath, data: data)
        do {
            let result = try convert(node, name: name, namespace: namespace, hash: source.sha256, cancelled: cancelled)
            return .init(footprint: result.0, notices: result.1, source: source)
        } catch EDAError.cancelled { throw EDAError.cancelled }
        catch {
            return .init(footprint: nil, notices: [.init("footprint_not_imported", .blocking, path: sourcePath, detail: String(describing: error))], source: source)
        }
    }
    private static func convert(_ node: EDASExpression, name: String, namespace: String, hash: String,
                                cancelled: @Sendable () -> Bool) throws -> (EDAFootprintDefinition, [EDALibraryNotice]) {
        var pads: [EDAPad] = [], graphics: [EDAGraphic] = [], assignments: [EDAGraphicLayerAssignment?] = []
        var fields: [String: String] = [:], notices: [EDALibraryNotice] = []
        let allowed: Set<String> = ["version", "generator", "generator_version", "layer", "descr", "tags", "attr", "property", "fp_text", "fp_line", "fp_rect", "fp_circle", "fp_arc", "fp_poly", "point", "pad", "model", "embedded_fonts", "tedit", "tstamp", "uuid", "solder_mask_margin", "solder_paste_margin", "solder_paste_ratio", "clearance", "zone_connect", "thermal_width", "thermal_gap", "duplicate_pad_numbers_are_jumpers"]
        for (index, item) in node.items.dropFirst(2).enumerated() {
            if index.isMultiple(of: 64), cancelled() { throw EDAError.cancelled }
            guard let tag = item.tag else { continue }
            guard allowed.contains(tag) else { throw EDAError.unsupported("KiCad footprint item " + tag) }
            switch tag {
            case "pad":
                if item.child("layers")?.items.contains(.atom("*.Cu")) == true { fields["kicad.usesAllCopperLayers"] = "true" }
                let result = try pad(item, salt: hash + "/pad/" + String(index))
                pads.append(result.0); notices.append(contentsOf: result.1)
                if let property = item.child("property")?.value() {
                    fields["kicad.pad." + result.0.number + ".property"] = property
                }
            case "fp_line", "fp_rect", "fp_circle", "fp_arc", "fp_poly", "fp_text", "property", "point":
                if tag == "property", let key = item.value(), let value = item.value(2) { fields[key] = value }
                if item.items.contains(.atom("hide")) || item.child("hide")?.value() == "yes" { continue }
                guard let layer = item.child("layer")?.value() else { throw EDAError.invalid("footprint artwork layer missing") }
                let kind: EDALayerKind
                if layer.hasSuffix(".Cu") { kind = .copper }
                else if layer.hasSuffix(".SilkS") { kind = .silkscreen }
                else if layer.hasSuffix(".CrtYd") || layer.hasSuffix(".Courtyard") { kind = .courtyard }
                else if layer.hasSuffix(".Mask") { kind = .mask }
                else if layer.hasSuffix(".Paste") { kind = .paste }
                else if layer.hasSuffix(".Fab") { kind = .fabrication }
                else if ["Cmts.User", "Dwgs.User", "User.Drawings", "User.Comments"].contains(layer) { kind = .fabrication }
                else { throw EDAError.unsupported("footprint artwork layer " + layer) }
                let values = try EDAKiCadGraphics.read(item, footprint: true)
                graphics.append(contentsOf: values); assignments.append(contentsOf: values.map { _ in .init(layerID: layer, kind: kind) })
                if item.child("fill")?.value() == "solid" {
                    notices.append(.init("graphic_fill_retained", .warning, path: name + "/" + tag, detail: "Outline imported; graphical fill remains in the retained original."))
                }
            case "descr", "tags": fields[tag] = item.value() ?? ""
            case "duplicate_pad_numbers_are_jumpers":
                fields["kicad." + tag] = item.value() ?? ""
                guard item.value() == "no" else { throw EDAError.unsupported("duplicate pad jumper semantics") }
            case "solder_mask_margin", "solder_paste_margin", "solder_paste_ratio", "clearance", "zone_connect", "thermal_width", "thermal_gap":
                fields["kicad." + tag] = item.value() ?? ""
                notices.append(.init("footprint_setting_retained", .warning, path: name + "/" + tag,
                    detail: "This per-footprint setting is retained; native project rules remain authoritative."))
            default: break
            }
        }
        let models = node.children("model")
        if !models.isEmpty {
            notices.append(.init("model_reference_only", .information, path: name + "/model", detail: "3D source references are retained separately; a model file has not been downloaded or verified."))
        }
        fields["kicad.libraryIdentifier"] = namespace + ":" + name
        let footprint = EDAFootprintDefinition(id: EDALibraryDigest.identifier(hash + namespace + name), name: name,
            pads: pads, graphics: graphics, graphicLayers: assignments, fields: fields, modelReference: models.first?.value())
        var project = EDAProject(title: name); project.footprints = [footprint]; try EDAValidation.validate(project)
        return (footprint, notices)
    }
    private static func pad(_ node: EDASExpression, salt: String) throws -> (EDAPad, [EDALibraryNotice]) {
        guard let number = node.value(), let type = node.value(2), let shape = node.value(3),
              let at = node.child("at"), let size = node.child("size"), let layers = node.child("layers") else { throw EDAError.invalid("KiCad pad fields") }
        guard ["smd", "thru_hole", "np_thru_hole", "connect"].contains(type) else { throw EDAError.unsupported("KiCad pad type " + type) }
        var layerNames = layers.items.dropFirst().compactMap(\.atom)
        // All outside pads remain outside; wildcard copper requires a
        // through-hole so native multilayer mapping cannot be invented.
        if layerNames.contains("*.Cu") {
            guard type == "thru_hole" || type == "np_thru_hole" else { throw EDAError.unsupported("wildcard SMD copper") }
            layerNames.removeAll { $0 == "*.Cu" }; layerNames += ["F.Cu", "B.Cu"]
        }
        if layerNames.contains("*.Mask") { layerNames.removeAll { $0 == "*.Mask" }; layerNames += ["F.Mask", "B.Mask"] }
        guard !layerNames.contains(where: { $0.contains("*") }) else { throw EDAError.unsupported("wildcard pad layer") }
        var drill: Double?
        if let hole = node.child("drill") {
            guard hole.value() != "oval", hole.child("offset") == nil else { throw EDAError.unsupported("slotted or offset footprint drill") }
            drill = try hole.number()
        }
        let dimensions = try size.point()
        guard dimensions.x > 0, dimensions.y > 0 else { throw EDAError.invalid("pad size") }
        let angle = try at.items.count > 3 ? at.number(3) : 0
        var value = EDAPad(id: EDALibraryDigest.identifier(salt), number: number,
            position: try EDAKiCadGraphics.point(at, footprint: true), size: dimensions, angle: -angle,
            drill: drill, layers: Array(Set(layerNames)).sorted(), drillPlated: drill == nil ? nil : type != "np_thru_hole")
        var notices: [EDALibraryNotice] = []
        if layers.items.contains(.atom("*.Cu")) {
            notices.append(.init("through_hole_two_layer_scope", .warning, path: "pad/" + number,
                detail: "All-copper source layers are retained; native placement is supported on two-copper-layer boards. Multilayer placement is blocked until inner-layer mapping is supported."))
        }
        switch shape {
        case "circle":
            guard abs(dimensions.x - dimensions.y) < 1e-8 else { throw EDAError.invalid("non-circular circle pad") }; value.shape = .circle
        case "rect": value.shape = .rectangle
        case "oval": value.shape = .oval
        case "roundrect":
            guard let ratio = node.child("roundrect_rratio"), node.child("chamfer") == nil else { throw EDAError.unsupported("roundrect radius missing or chamfered pad") }
            let fraction = try ratio.number()
            guard (0...0.5).contains(fraction) else { throw EDAError.invalid("pad roundrect ratio") }
            if fraction == 0 { value.shape = .rectangle }
            else {
                value.shape = .roundRectangle; value.roundRectangleRadius = min(dimensions.x, dimensions.y) * fraction
                try EDARoundedPadGeometry.validate(value)
                notices.append(.init("rounded_pad_exact_radius", .information, path: "pad/" + number,
                    detail: "Exact source radius is stored. Polygon consumers use at most 0.001 mm boundary error; clearance checking uses the outward envelope."))
            }
        default: throw EDAError.unsupported("KiCad pad shape " + shape)
        }
        let allowed: Set<String> = ["at", "size", "drill", "layers", "roundrect_rratio", "net", "pinfunction", "pintype", "uuid", "tstamp", "remove_unused_layers", "keep_end_layers", "solder_mask_margin", "solder_paste_margin", "solder_paste_margin_ratio", "clearance", "zone_connect", "thermal_bridge_width", "thermal_gap", "property"]
        for field in node.items.dropFirst(4) {
            guard let tag = field.tag else { continue }
            guard allowed.contains(tag) else { throw EDAError.unsupported("KiCad pad field " + tag) }
            if tag == "property" {
                guard let property = field.value(), ["pad_prop_bga", "pad_prop_fiducial_glob", "pad_prop_fiducial_loc", "pad_prop_testpoint", "pad_prop_heatsink"].contains(property) else {
                    throw EDAError.unsupported("KiCad pad property " + (field.value() ?? "missing"))
                }
                notices.append(.init("pad_property_retained", .warning, path: "pad/" + number + "/property",
                    detail: "The source pad role is retained in footprint attributes. Native geometry and explicit pad mapping are used; this role does not create a separate manufacturing rule."))
            }
            if ["solder_mask_margin", "solder_paste_margin", "solder_paste_margin_ratio", "clearance", "zone_connect", "thermal_bridge_width", "thermal_gap"].contains(tag) {
                notices.append(.init("pad_setting_retained", .warning, path: "pad/" + number + "/" + tag,
                    detail: "Local manufacturing setting retained in original; project export rules are not overridden."))
            }
        }
        try EDAPolygonPadGeometry.validate(value)
        return (value, notices)
    }
}
