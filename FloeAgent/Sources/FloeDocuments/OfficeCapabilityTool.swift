// FloeDocuments — dynamic, truthful per-format Office capability reporting.
//
// Tiers:
//   verified   — implemented in this module and covered by unit tests
//                (pure OOXML read/create/updateText/readSheet paths).
//   engine     — available through the packaged Collabora engine's UNO
//                command surface, but NOT yet qualified on a physical device;
//                callers must not advertise these as accepted.
//   unavailable— no faithful implementation exists (never faked).

import Foundation
import FloeCore
import FloeTools

public enum OfficeCapabilityTool {
    /// Stable capability matrix consumed by agents and the UI. Static on
    /// purpose: nothing here is inferred from unimplemented UI.
    public static func capabilitiesJSON(enginePresent: Bool) -> String {
        struct Op: Codable { var name: String; var tier: String; var detail: String }
        struct Format: Codable { var format: String; var read: Bool; var operations: [Op] }
        struct Root: Codable { var enginePresent: Bool; var qualification: String; var formats: [Format] }

        let verified = "verified", engine = "engine", unavailable = "unavailable"
        let formats: [Format] = [
            Format(format: "docx", read: true, operations: [
                Op(name: "inspect", tier: verified, detail: "document.office.inspect: paragraphs, headers/footers"),
                Op(name: "updateText", tier: verified, detail: "document.office.updateText with expectedSHA256 CAS"),
                Op(name: "createWord", tier: verified, detail: "document.createWord"),
                Op(name: "styles", tier: engine, detail: ".uno:StyleApply via engine UNO bridge (unqualified)"),
                Op(name: "lists", tier: engine, detail: ".uno:DefaultBullet/.uno:DefaultNumbering (unqualified)"),
                Op(name: "alignment", tier: engine, detail: ".uno:CommonAlignLeft/Center/Right/Justified (unqualified)"),
                Op(name: "images", tier: engine, detail: "native insertAttachmentFromFileURL at cursor (unqualified)"),
                Op(name: "tables", tier: engine, detail: ".uno:InsertTable dialog-driven (unqualified)"),
            ]),
            Format(format: "xlsx", read: true, operations: [
                Op(name: "inspect", tier: verified, detail: "cells via shared-string table"),
                Op(name: "readSheet", tier: verified, detail: "document.readSheet cached values"),
                Op(name: "updateText", tier: verified, detail: "cell values; '=' written as formulas"),
                Op(name: "createWorkbook", tier: verified, detail: "document.createWorkbook"),
                Op(name: "format", tier: engine, detail: ".uno:NumberFormat/.uno:FormatCellDialog (unqualified)"),
                Op(name: "rowsColumns", tier: engine, detail: "insert/delete/height/width UNO commands (unqualified)"),
                Op(name: "freeze", tier: engine, detail: ".uno:FreezePanes (unqualified)"),
                Op(name: "sortFilter", tier: engine, detail: ".uno:SortAscending/.uno:DataFilterAutoFilter (unqualified)"),
                Op(name: "formulaErrorLocation", tier: unavailable,
                   detail: "no faithful error-cell readout bridge exists; formulas evaluate but error cells are not yet locatable"),
            ]),
            Format(format: "pptx", read: true, operations: [
                Op(name: "inspect", tier: verified, detail: "slide + notes text"),
                Op(name: "createDeck", tier: verified, detail: "document.presentation.createDeck incl. charts/images"),
                Op(name: "present", tier: engine, detail: "native startPresentation (implemented; device-qualified flag pending)"),
                Op(name: "duplicateSlide", tier: engine, detail: ".uno:DuplicatePage (unqualified)"),
                Op(name: "reorder", tier: engine, detail: "slide-sorter moveSlide JS path (unqualified)"),
                Op(name: "align", tier: engine, detail: ".uno:Align*/.uno:ObjectAlign* (unqualified)"),
                Op(name: "imageReplace", tier: unavailable,
                   detail: "no .uno:ChangePicture in the pinned bundle; faithful replace needs delete+insert (not yet wired)"),
            ])
        ]
        let root = Root(enginePresent: enginePresent,
                        qualification: "engine-tier operations require device receipts (qualify_office_device_capabilities.py) before release claims",
                        formats: formats)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(data: (try? encoder.encode(root)) ?? Data("{}".utf8), encoding: .utf8) ?? "{}"
    }
}

public struct OfficeCapabilitiesTool: AgentTool {
    public struct Arguments: Decodable, Sendable { public var format: String? }
    public static let name = "document.office.capabilities"
    public static let toolDescription =
        "Dynamic per-format Office capability matrix. Tiers: verified (unit-tested in this build), engine (available through the packaged Collabora engine but not device-qualified yet), unavailable (no faithful implementation; never faked). Use discover → inspect → propose → confirm → apply → verify; never claim engine-tier ops as accepted."
    public static let parametersJSON = #"{"type":"object","properties":{"format":{"type":"string","enum":["docx","xlsx","pptx"],"description":"optional format filter"}},"required":[],"additionalProperties":false}"#
    public static let riskLabels: Set<RiskLabel> = []
    public static let isSideEffecting = false

    private let enginePresent: Bool
    public init(enginePresent: Bool = true) { self.enginePresent = enginePresent }

    public func validate(_ args: Arguments) throws {
        if let format = args.format {
            guard ["docx", "xlsx", "pptx"].contains(format.lowercased()) else {
                throw FloeError.validationFailed("format must be docx|xlsx|pptx")
            }
        }
    }

    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled()
        var json = OfficeCapabilityTool.capabilitiesJSON(enginePresent: enginePresent)
        if let format = args.format?.lowercased(),
           let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] {
            let filtered = (object["formats"] as? [[String: Any]] ?? []).filter {
                ($0["format"] as? String) == format
            }
            var copy = object
            copy["formats"] = filtered
            json = (try? JSONSerialization.data(withJSONObject: copy, options: [.sortedKeys]))
                .flatMap { String(data: $0, encoding: .utf8) } ?? json
        }
        return ToolExecutionOutput(digesting: "document.office capabilities: \(json)", exitStatus: 0)
    }
}
