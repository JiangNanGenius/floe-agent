//
//  CADDrawingSheetTemplate.swift
//  FloeCADKit
//
//  Reusable, editable drawing-sheet templates (E18). A template owns the
//  sheet frame, title block, revision rows, projection method, display units,
//  precision and line/text style. Applying one to several pages is a single
//  drawing-set transaction; every applied page stores an independent snapshot
//  so deleting the library record can never change an old drawing's layout.
//
//  The existing `CADDrawingSet.standardSheet` / `multiViewSheet` generators
//  remain the fixed quick-create paths. They are not reimplemented here.
//
//  SPDX-License-Identifier: MPL-2.0
//

import Foundation
import simd

// MARK: - Projection / units / style

public nonisolated enum CADDrawingProjectionMethod: String, Codable, Sendable, CaseIterable {
    case firstAngle
    case thirdAngle

    public var title: String {
        switch self {
        case .firstAngle: return "First angle"
        case .thirdAngle: return "Third angle"
        }
    }

    public var draftingLabel: String {
        switch self {
        case .firstAngle: return "FIRST ANGLE"
        case .thirdAngle: return "THIRD ANGLE"
        }
    }
}

/// Display/document unit. Geometry and stored dimensions remain millimetres;
/// this only controls annotation, tolerance and title-block text. Applying a
/// template never rescales exact geometry.
public nonisolated enum CADDrawingUnit: String, Codable, Sendable, CaseIterable {
    case millimetre
    case centimetre
    case inch

    public var title: String {
        switch self {
        case .millimetre: return "Millimetres"
        case .centimetre: return "Centimetres"
        case .inch: return "Inches"
        }
    }

    public var symbol: String {
        switch self {
        case .millimetre: return "mm"
        case .centimetre: return "cm"
        case .inch: return "in"
        }
    }

    public var millimetresPerUnit: Double {
        switch self {
        case .millimetre: return 1
        case .centimetre: return 10
        case .inch: return 25.4
        }
    }

    public func displayValue(millimetres: Double) -> Double {
        millimetres / millimetresPerUnit
    }
}

public nonisolated struct CADDrawingSheetStyle: Codable, Sendable, Equatable {
    /// Clear margin from the paper edge to the frame (mm).
    public var marginMM: Double
    /// Title-block width (mm), clamped to the frame by the renderer.
    public var titleBlockWidthMM: Double
    /// Base title-block height (mm). The renderer grows it when revision rows
    /// need more room.
    public var titleBlockHeightMM: Double
    /// Exported line width (mm). PDF/SVG/DXF use this exact value.
    public var lineWidthMM: Double
    /// Base text height (mm).
    public var textHeightMM: Double
    /// Optional zone grid in the frame margin.
    public var showZoneGrid: Bool

    public init(marginMM: Double = 8,
                titleBlockWidthMM: Double = 120,
                titleBlockHeightMM: Double = 22,
                lineWidthMM: Double = 0.25,
                textHeightMM: Double = 3.5,
                showZoneGrid: Bool = false) {
        self.marginMM = marginMM
        self.titleBlockWidthMM = titleBlockWidthMM
        self.titleBlockHeightMM = titleBlockHeightMM
        self.lineWidthMM = lineWidthMM
        self.textHeightMM = textHeightMM
        self.showZoneGrid = showZoneGrid
    }

    private enum CodingKeys: String, CodingKey {
        case marginMM, titleBlockWidthMM, titleBlockHeightMM
        case lineWidthMM, textHeightMM, showZoneGrid
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        marginMM = try c.decodeIfPresent(Double.self, forKey: .marginMM) ?? 8
        titleBlockWidthMM = try c.decodeIfPresent(Double.self, forKey: .titleBlockWidthMM) ?? 120
        titleBlockHeightMM = try c.decodeIfPresent(Double.self, forKey: .titleBlockHeightMM) ?? 22
        lineWidthMM = try c.decodeIfPresent(Double.self, forKey: .lineWidthMM) ?? 0.25
        textHeightMM = try c.decodeIfPresent(Double.self, forKey: .textHeightMM) ?? 3.5
        showZoneGrid = try c.decodeIfPresent(Bool.self, forKey: .showZoneGrid) ?? false
    }
}

// MARK: - Title block / revision rows

public nonisolated struct CADDrawingRevisionRow: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    /// Revision mark, e.g. "A".
    public var revision: String
    /// Free-form display date; never parsed or reordered.
    public var date: String
    public var description: String
    public var approvedBy: String?

    public init(id: UUID = UUID(), revision: String, date: String = "",
                description: String, approvedBy: String? = nil) {
        self.id = id
        self.revision = revision
        self.date = date
        self.description = description
        self.approvedBy = approvedBy
    }

    private enum CodingKeys: String, CodingKey {
        case id, revision, date, description, approvedBy
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        revision = try c.decodeIfPresent(String.self, forKey: .revision) ?? ""
        date = try c.decodeIfPresent(String.self, forKey: .date) ?? ""
        description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        approvedBy = try c.decodeIfPresent(String.self, forKey: .approvedBy)
    }
}

public nonisolated struct CADDrawingTitleBlock: Codable, Sendable, Equatable {
    public var company: String
    /// Template default drawing number. A page-level override is stored on the
    /// page so applying the template to many sheets keeps one drawing identity
    /// per sheet.
    public var drawingNumber: String

    public init(company: String = "", drawingNumber: String = "") {
        self.company = company
        self.drawingNumber = drawingNumber
    }

    private enum CodingKeys: String, CodingKey {
        case company, drawingNumber
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        company = try c.decodeIfPresent(String.self, forKey: .company) ?? ""
        drawingNumber = try c.decodeIfPresent(String.self, forKey: .drawingNumber) ?? ""
    }
}

// MARK: - Template and per-page snapshot binding

public nonisolated struct CADDrawingSheetTemplate: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public var paper: CADPaperSize
    public var customWidthMM: Double?
    public var customHeightMM: Double?
    public var projection: CADDrawingProjectionMethod
    public var units: CADDrawingUnit
    /// Decimal places used for dimension/tolerance text (0…4).
    public var precision: Int
    public var style: CADDrawingSheetStyle
    public var titleBlock: CADDrawingTitleBlock
    public var revisionRows: [CADDrawingRevisionRow]
    /// Built-in presets are offered by `listTemplates` but are never written
    /// into the mutable collection; edit/copy creates an editable copy.
    public var builtIn: Bool

    public init(id: UUID = UUID(), name: String,
                paper: CADPaperSize = .a3,
                customWidthMM: Double? = nil,
                customHeightMM: Double? = nil,
                projection: CADDrawingProjectionMethod = .thirdAngle,
                units: CADDrawingUnit = .millimetre,
                precision: Int = 2,
                style: CADDrawingSheetStyle = CADDrawingSheetStyle(),
                titleBlock: CADDrawingTitleBlock = CADDrawingTitleBlock(),
                revisionRows: [CADDrawingRevisionRow] = [],
                builtIn: Bool = false) {
        self.id = id
        self.name = name
        self.paper = paper
        self.customWidthMM = customWidthMM
        self.customHeightMM = customHeightMM
        self.projection = projection
        self.units = units
        self.precision = precision
        self.style = style
        self.titleBlock = titleBlock
        self.revisionRows = revisionRows
        self.builtIn = builtIn
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, paper, customWidthMM, customHeightMM
        case projection, units, precision, style, titleBlock
        case revisionRows, builtIn
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Template"
        paper = try c.decodeIfPresent(CADPaperSize.self, forKey: .paper) ?? .a3
        customWidthMM = try c.decodeIfPresent(Double.self, forKey: .customWidthMM)
        customHeightMM = try c.decodeIfPresent(Double.self, forKey: .customHeightMM)
        projection = try c.decodeIfPresent(CADDrawingProjectionMethod.self,
                                            forKey: .projection) ?? .thirdAngle
        units = try c.decodeIfPresent(CADDrawingUnit.self, forKey: .units) ?? .millimetre
        precision = try c.decodeIfPresent(Int.self, forKey: .precision) ?? 2
        style = try c.decodeIfPresent(CADDrawingSheetStyle.self, forKey: .style)
            ?? CADDrawingSheetStyle()
        titleBlock = try c.decodeIfPresent(CADDrawingTitleBlock.self, forKey: .titleBlock)
            ?? CADDrawingTitleBlock()
        revisionRows = try c.decodeIfPresent([CADDrawingRevisionRow].self,
                                              forKey: .revisionRows) ?? []
        builtIn = try c.decodeIfPresent(Bool.self, forKey: .builtIn) ?? false
    }
}

/// Stored on the PAGE. The snapshot is authoritative for that page's frame and
/// title block forever, even after the source template is edited or deleted.
public nonisolated struct CADDrawingSheetTemplateBinding: Codable, Sendable, Equatable {
    public var templateID: UUID
    public var snapshot: CADDrawingSheetTemplate
    /// Template name at apply time, for a clear but non-authoritative label.
    public var appliedName: String

    public init(templateID: UUID, snapshot: CADDrawingSheetTemplate,
                appliedName: String? = nil) {
        self.templateID = templateID
        self.snapshot = snapshot
        self.appliedName = appliedName ?? snapshot.name
    }

    private enum CodingKeys: String, CodingKey {
        case templateID, snapshot, appliedName
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        templateID = try c.decode(UUID.self, forKey: .templateID)
        snapshot = try c.decode(CADDrawingSheetTemplate.self, forKey: .snapshot)
        appliedName = try c.decodeIfPresent(String.self, forKey: .appliedName)
            ?? snapshot.name
    }
}

// MARK: - Validation and application

public nonisolated enum CADDrawingTemplateError: Error, LocalizedError, Equatable, Sendable {
    case invalid(String)

    public var errorDescription: String? {
        switch self {
        case .invalid(let message): return message
        }
    }
}

public nonisolated enum CADDrawingTemplateRules {

    public static let maximumRevisionRows = 6

    /// Strict numeric draft parsing for the native sheet editor. Empty,
    /// partial and non-finite text returns nil; callers must surface an error
    /// or keep the field unchanged instead of substituting zero or the old
    /// value. The value is parsed only when Save is pressed, so typing "8."
    /// or "0.25" never resets the draft or its caret.
    public static func parseNumberDraft(_ raw: String) -> Double? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let value = Double(trimmed),
              value.isFinite else { return nil }
        return value
    }

    public static func validate(_ template: CADDrawingSheetTemplate) -> [String] {
        var issues: [String] = []
        let name = template.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty || name.count > 80 {
            issues.append("The template name must be 1…80 characters.")
        }
        if !(0...4).contains(template.precision) {
            issues.append("precision must be between 0 and 4.")
        }
        let size = paperSize(template)
        if size.width < 40 || size.height < 40 || size.width > 5000 || size.height > 5000 {
            issues.append("The paper size must be between 40 and 5000 mm on each side.")
        }
        let style = template.style
        if !style.marginMM.isFinite || !(3...30).contains(style.marginMM) {
            issues.append("marginMM must be in [3, 30].")
        }
        let safeMargin = style.marginMM.isFinite ? max(3, style.marginMM) : 8
        let maximumBlockWidth = max(40, min(400, size.width - 2 * safeMargin))
        let maximumBlockHeight = max(12, min(160, size.height - 2 * safeMargin))
        if !style.titleBlockWidthMM.isFinite
            || !(40...maximumBlockWidth).contains(style.titleBlockWidthMM) {
            issues.append("titleBlockWidthMM is outside the frame.")
        }
        if !style.titleBlockHeightMM.isFinite
            || !(12...maximumBlockHeight).contains(style.titleBlockHeightMM) {
            issues.append("titleBlockHeightMM is outside the frame.")
        }
        if !style.lineWidthMM.isFinite || !(0.05...1.0).contains(style.lineWidthMM) {
            issues.append("lineWidthMM must be in [0.05, 1.0].")
        }
        if !style.textHeightMM.isFinite || !(1.0...20).contains(style.textHeightMM) {
            issues.append("textHeightMM must be in [1, 20].")
        }
        if template.titleBlock.company.count > 80 {
            issues.append("The company name must be at most 80 characters.")
        }
        if template.titleBlock.drawingNumber.count > 60 {
            issues.append("The drawing number must be at most 60 characters.")
        }
        if template.revisionRows.count > maximumRevisionRows {
            issues.append("A template supports at most \(maximumRevisionRows) revision rows.")
        }
        for row in template.revisionRows {
            if row.revision.count > 16 || row.date.count > 24
                || row.description.count > 80
                || (row.approvedBy?.count ?? 0) > 40 {
                issues.append("A revision row field is longer than its bound.")
            }
            if row.revision.trimmingCharacters(in: .whitespaces).isEmpty
                && row.description.trimmingCharacters(in: .whitespaces).isEmpty {
                issues.append("A revision row needs a revision or a description.")
            }
        }
        return issues
    }

    public static func paperSize(_ template: CADDrawingSheetTemplate) -> (width: Double, height: Double) {
        if template.paper == .custom {
            return (template.customWidthMM ?? 297, template.customHeightMM ?? 420)
        }
        return template.paper.millimetres
    }

    /// Apply a validated template to a page. Everything except the sheet
    /// presentation and display settings is preserved: page ID, views, source
    /// binding, dimensions, annotations and balloons.
    public static func apply(_ template: CADDrawingSheetTemplate,
                             to page: inout CADDrawingPage) throws {
        let issues = validate(template)
        guard issues.isEmpty else {
            throw CADDrawingTemplateError.invalid(issues.joined(separator: " "))
        }
        let previousProjection = page.sheetTemplate?.snapshot.projection ?? .thirdAngle
        if previousProjection != template.projection, let views = page.sheetViews {
            page.sheetViews = views.map { view in
                var updated = view
                switch view.kind {
                case .top where view.alignment.placement == .above:
                    updated.alignment.placement = .below
                case .top where view.alignment.placement == .below:
                    updated.alignment.placement = .above
                case .side where view.alignment.placement == .left:
                    updated.alignment.placement = .right
                case .side where view.alignment.placement == .right:
                    updated.alignment.placement = .left
                default:
                    break
                }
                return updated
            }
        }
        page.paper = template.paper
        if template.paper == .custom {
            page.customWidthMM = template.customWidthMM
            page.customHeightMM = template.customHeightMM
        } else {
            page.customWidthMM = nil
            page.customHeightMM = nil
        }
        page.revisionRows = template.revisionRows
        page.units = template.units
        page.precision = template.precision
        page.titleBlock = template.titleBlock
        var snapshot = template
        let size = paperSize(template)
        snapshot.style = normalized(template.style,
                                    paperWidth: size.width,
                                    paperHeight: size.height,
                                    revisionCount: template.revisionRows.count)
        page.sheetTemplate = CADDrawingSheetTemplateBinding(templateID: template.id,
                                                            snapshot: snapshot)
    }

    /// Defensive render-time style: malformed decoded values are clamped, never
    /// allowed to produce a negative frame or an off-sheet title block.
    public static func normalized(_ style: CADDrawingSheetStyle,
                                  paperWidth: Double,
                                  paperHeight: Double,
                                  revisionCount: Int) -> CADDrawingSheetStyle {
        let width = max(paperWidth, 40)
        let height = max(paperHeight, 40)
        let margin = min(max(style.marginMM.isFinite ? style.marginMM : 8, 3),
                         min(30, min(width, height) / 4))
        let maximumWidth = max(41, min(400, width - 2 * margin - 1))
        let blockWidth = min(max(style.titleBlockWidthMM.isFinite ? style.titleBlockWidthMM : 120,
                                 40), maximumWidth)
        // The revision table lives inside the title block. Reserve its rows
        // plus a real title/company area so a three-row revision table never
        // crushes the sheet identity into a one-line strip.
        let revisionRoom = 21 + 6.2 * Double(min(max(revisionCount, 0), 6))
        let requestedHeight = max(style.titleBlockHeightMM.isFinite ? style.titleBlockHeightMM : 22,
                                  revisionCount > 0 ? revisionRoom : 12)
        let blockHeight = min(max(requestedHeight, 12),
                              min(160, height - 2 * margin - 1))
        return CADDrawingSheetStyle(
            marginMM: margin,
            titleBlockWidthMM: blockWidth,
            titleBlockHeightMM: blockHeight,
            lineWidthMM: min(max(style.lineWidthMM.isFinite ? style.lineWidthMM : 0.25, 0.05), 1),
            textHeightMM: min(max(style.textHeightMM.isFinite ? style.textHeightMM : 3.5, 1), 20),
            showZoneGrid: style.showZoneGrid)
    }
}

// MARK: - Built-in presets

public nonisolated enum CADDrawingSheetTemplateLibrary {

    /// Stable IDs so a persisted page snapshot can name its origin across
    /// launches without a lookup table. These are not mutable collection rows.
    private static let thirdAngleA3ID = UUID(uuidString: "F10E0000-0000-4000-8000-000000000001")!
    private static let firstAngleA3ID = UUID(uuidString: "F10E0000-0000-4000-8000-000000000002")!
    private static let thirdAngleA4ID = UUID(uuidString: "F10E0000-0000-4000-8000-000000000003")!

    public static let builtIns: [CADDrawingSheetTemplate] = [
        CADDrawingSheetTemplate(
            id: thirdAngleA3ID, name: "A3 Third Angle",
            paper: .a3, projection: .thirdAngle, units: .millimetre, precision: 2,
            style: CADDrawingSheetStyle(marginMM: 8, titleBlockWidthMM: 120,
                                        titleBlockHeightMM: 26, lineWidthMM: 0.25,
                                        textHeightMM: 3.5),
            titleBlock: CADDrawingTitleBlock(company: "", drawingNumber: ""),
            revisionRows: [CADDrawingRevisionRow(revision: "A", date: "",
                                                  description: "Initial release")],
            builtIn: true),
        CADDrawingSheetTemplate(
            id: firstAngleA3ID, name: "A3 First Angle",
            paper: .a3, projection: .firstAngle, units: .millimetre, precision: 2,
            style: CADDrawingSheetStyle(marginMM: 8, titleBlockWidthMM: 120,
                                        titleBlockHeightMM: 26, lineWidthMM: 0.25,
                                        textHeightMM: 3.5),
            titleBlock: CADDrawingTitleBlock(company: "", drawingNumber: ""),
            revisionRows: [CADDrawingRevisionRow(revision: "A", date: "",
                                                  description: "Initial release")],
            builtIn: true),
        CADDrawingSheetTemplate(
            id: thirdAngleA4ID, name: "A4 Third Angle",
            paper: .a4, projection: .thirdAngle, units: .millimetre, precision: 2,
            style: CADDrawingSheetStyle(marginMM: 7, titleBlockWidthMM: 110,
                                        titleBlockHeightMM: 24, lineWidthMM: 0.25,
                                        textHeightMM: 3.2),
            titleBlock: CADDrawingTitleBlock(company: "", drawingNumber: ""),
            revisionRows: [CADDrawingRevisionRow(revision: "A", date: "",
                                                  description: "Initial release")],
            builtIn: true),
    ]

    public static func preset(id: UUID) -> CADDrawingSheetTemplate? {
        builtIns.first { $0.id == id }
    }

    public static func isBuiltIn(id: UUID) -> Bool {
        builtIns.contains { $0.id == id }
    }
}
