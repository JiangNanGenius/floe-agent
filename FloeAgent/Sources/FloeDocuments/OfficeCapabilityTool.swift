// FloeDocuments — dynamic, truthful per-format Office capability reporting.
//
// Tiers:
//   verified   — implemented in this module and covered by unit tests
//                (pure OOXML read/create/updateText, saved-package verification
//                and same-format image replacement).
//   engine     — implemented as validated UNO dispatches through the live
//                pinned engine (encodings re-checked against the pinned bundle),
//                but NOT yet qualified with physical-device receipts; callers
//                must not advertise these as device-accepted.
//   unavailable— no faithful implementation exists (never faked).
//
// The engine-tier list is derived from `OfficeEngineCommandCatalog`, so a
// command cannot be advertised unless the same catalog can dispatch and verify
// it.

import Foundation
import FloeCore
import FloeTools

public enum OfficeCapabilityTool {
    /// Stable capability matrix consumed by agents and the UI.
    public static func capabilitiesJSON(enginePresent: Bool) -> String {
        struct Op: Codable { var name: String; var tier: String; var path: String; var detail: String }
        struct Format: Codable { var format: String; var read: Bool; var operations: [Op] }
        struct Root: Codable { var enginePresent: Bool; var qualification: String; var formats: [Format] }

        let verified = "verified", engine = "engine", unavailable = "unavailable"

        func engineOps(_ format: OfficeDocumentFormat) -> [Op] {
            OfficeEngineCommandCatalog.engineCommands(format).map { command in
                let dispatch = command.plan.steps.map { step -> String in
                    switch step {
                    case .uno(let name, _): return name
                    case .socket(let payload): return payload
                    case .selectPart(let index): return "setPart(\(index))"
                    }
                }.joined(separator: " + ")
                return Op(name: command.id,
                          tier: enginePresent ? engine : unavailable,
                          path: "engine-uno",
                          detail: "\(dispatch); saved-package verified after flush"
                              + (enginePresent ? "" : " (engine not present in this build)"))
            }
        }

        let docx: [Op] = [
            Op(name: "inspect", tier: verified, path: "ooxml", detail: "document.office.inspect: paragraphs, headers/footers"),
            Op(name: "updateText", tier: verified, path: "ooxml", detail: "paragraph find/replace via document.office.updateText with expectedSHA256 CAS"),
            Op(name: "createWord", tier: verified, path: "ooxml", detail: "document.createWord"),
            Op(name: "replaceImage", tier: verified, path: "package", detail: "same-format picture bytes replaced in place, atomic reopen-verified"),
            Op(name: "images", tier: enginePresent ? engine : unavailable, path: "native-host",
               detail: "native insertAttachment(fromFileURL:) at the cursor; live-editor only"),
        ] + engineOps(.docx)
        let xlsx: [Op] = [
            Op(name: "inspect", tier: verified, path: "ooxml", detail: "cells via shared-string table"),
            Op(name: "readSheet", tier: verified, path: "ooxml", detail: "document.readSheet cached values"),
            Op(name: "updateText", tier: verified, path: "ooxml", detail: "cell values and formulas via expectedSHA256 CAS"),
            Op(name: "createWorkbook", tier: verified, path: "ooxml", detail: "document.createWorkbook"),
            Op(name: "formulaErrorLocation", tier: verified, path: "ooxml",
               detail: "document.office.edit action=errors reads t=\"e\" cells with codes from the saved package"),
            Op(name: "replaceImage", tier: verified, path: "package", detail: "same-format picture bytes replaced in place, atomic reopen-verified"),
        ] + engineOps(.xlsx)
        let pptx: [Op] = [
            Op(name: "inspect", tier: verified, path: "ooxml", detail: "slide + notes text"),
            Op(name: "createDeck", tier: verified, path: "ooxml", detail: "document.presentation.createDeck incl. charts/images"),
            Op(name: "updateText", tier: verified, path: "ooxml", detail: "slide text fields via expectedSHA256 CAS"),
            Op(name: "replaceImage", tier: verified, path: "package", detail: "same-format picture bytes replaced in place, atomic reopen-verified"),
            Op(name: "present", tier: enginePresent ? engine : unavailable, path: "native-host",
               detail: "native startPresentation; live-editor only"),
            Op(name: "imageReplaceEngine", tier: unavailable, path: "engine-uno",
               detail: "no .uno:ChangePicture in the pinned bundle; use action=replaceImage (package path) instead"),
        ] + engineOps(.pptx)
        let formats: [Format] = [
            Format(format: "docx", read: true, operations: docx),
            Format(format: "xlsx", read: true, operations: xlsx),
            Format(format: "pptx", read: true, operations: pptx),
        ]
        let root = Root(enginePresent: enginePresent,
                        qualification: "engine commands are pinned-bundle-encoded and locally structural-tested; physical-device qualification receipts (qualify_office_device_capabilities.py) are still required before release claims",
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
