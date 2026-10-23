// SPDX-License-Identifier: MPL-2.0
// FloeDocumentsTests — pure physical print layout for generated Word/PPT PDFs
// plus the plan-level support matrix. These are package checks: the real
// engine PDF output (measured paper boxes and retained text on produced
// DOCX/PPTX files) is qualified by the App acceptance/host tests, not here.
import Foundation
import CoreGraphics
import Testing
@testable import FloeDocuments

@Suite("FloeDocuments.OfficePDFPaginatedLayout")
struct OfficePDFPaginatedLayoutTests {
    // MARK: - Geometry

    @Test("paper points are portrait-first and exact")
    func paperSizes() {
        let a4 = OfficePDFPaginatedLayout.portraitSize(for: .a4)
        #expect(abs(a4.width - 595.2756) < 0.01)
        #expect(abs(a4.height - 841.8898) < 0.01)
        let a3 = OfficePDFPaginatedLayout.portraitSize(for: .a3)
        #expect(abs(a3.width - 841.8898) < 0.01)
        #expect(abs(a3.height - 1190.5512) < 0.01)
        #expect(OfficePDFPaginatedLayout.portraitSize(for: .letter)
                == CGSize(width: 612, height: 792))
        #expect(OfficePDFPaginatedLayout.portraitSize(for: .legal)
                == CGSize(width: 612, height: 1008))
    }

    @Test("target size honors orientation override and follows page aspect otherwise")
    func targetSelection() {
        let portrait = CGSize(width: 595, height: 842)
        let landscape = CGSize(width: 842, height: 595)
        let a4 = OfficePDFPaginatedLayout.portraitSize(for: .a4)
        let forcedLandscape = OfficePDFPaginatedLayout(paper: .a4, orientation: .landscape)
            .targetSize(forSourceDisplaySize: portrait)
        #expect(abs(forcedLandscape.width - a4.height) < 0.01)
        #expect(abs(forcedLandscape.height - a4.width) < 0.01)
        // Paper only: portrait page -> portrait paper, landscape page -> landscape paper.
        let paperOnly = OfficePDFPaginatedLayout(paper: .a4)
        let keptPortrait = paperOnly.targetSize(forSourceDisplaySize: portrait)
        #expect(abs(keptPortrait.width - a4.width) < 0.01)
        let keptLandscape = paperOnly.targetSize(forSourceDisplaySize: landscape)
        #expect(abs(keptLandscape.width - a4.height) < 0.01)
    }

    @Test("orientation-only swaps a differing page aspect and leaves a matching one")
    func orientationOnly() {
        let toLandscape = OfficePDFPaginatedLayout(orientation: .landscape)
            .targetSize(forSourceDisplaySize: CGSize(width: 595, height: 842))
        #expect(toLandscape == CGSize(width: 842, height: 595))
        let alreadyLandscape = OfficePDFPaginatedLayout(orientation: .landscape)
            .targetSize(forSourceDisplaySize: CGSize(width: 842, height: 595))
        #expect(alreadyLandscape == CGSize(width: 842, height: 595))
    }

    @Test("whole-page fit never enlarges and never clips")
    func fitIsSafe() {
        // Tall portrait source into a wide small target: the width-only trap
        // the coordinator called out. Fitting the whole page keeps content.
        let placement = OfficePDFPaginatedLayout(paper: .letter, orientation: .landscape)
            .placement(forSourceDisplaySize: CGSize(width: 612, height: 1584))
        #expect(placement.scaleFactor <= 1.0)
        #expect(placement.contentSize.width <= placement.targetSize.width + 0.01)
        #expect(placement.contentSize.height <= placement.targetSize.height + 0.01)
        #expect(placement.contentOrigin.x >= -0.01)
        #expect(placement.contentOrigin.y >= -0.01)
        #expect(!placement.contentExceedsPaper)
        // A small page on big paper must not enlarge either.
        let grown = OfficePDFPaginatedLayout(paper: .a3)
            .placement(forSourceDisplaySize: CGSize(width: 200, height: 300))
        #expect(grown.scaleFactor == 1.0)
        #expect(!grown.contentExceedsPaper)
    }

    @Test("nil scaling on a paper/orientation change resolves to whole-page fit")
    func defaultScaleIsSafe() {
        let layout = OfficePDFPaginatedLayout(paper: .a4, orientation: .landscape)
        #expect(layout.scale == nil)
        #expect(layout.resolvedScale == .fitWholePage)
        let placement = layout.placement(forSourceDisplaySize: CGSize(width: 595, height: 842))
        #expect(placement.scaleFactor <= 1.0)
        #expect(!placement.contentExceedsPaper)
    }

    @Test("explicit percent/actual-size overflow is measured, not hidden")
    func explicitExceed() {
        let half = OfficePDFPaginatedLayout(paper: .a4, scale: .percent(50))
            .placement(forSourceDisplaySize: CGSize(width: 595, height: 842))
        #expect(abs(half.scaleFactor - 0.5) < 0.001)
        #expect(!half.contentExceedsPaper)
        let doubled = OfficePDFPaginatedLayout(paper: .a4, scale: .percent(200))
            .placement(forSourceDisplaySize: CGSize(width: 595, height: 842))
        #expect(doubled.contentExceedsPaper)
        let actual = OfficePDFPaginatedLayout(paper: .letter, scale: .actualSize)
            .placement(forSourceDisplaySize: CGSize(width: 595.28, height: 841.89))
        #expect(abs(actual.scaleFactor - 1.0) < 0.0001)
        #expect(actual.contentExceedsPaper, "A4 841.89pt height exceeds Letter 792pt at 100%")
    }

    // MARK: - Bounds + Codable

    @Test("percent reuses the shared scale range")
    func bounds() throws {
        #expect(throws: OfficePDFPlanError.scalePercentOutOfRange(
            requested: 5, minimum: OfficePDFScale.minimumPercent,
            maximum: OfficePDFScale.maximumPercent)) {
            try OfficePDFPaginatedLayout(scale: .percent(5)).validated()
        }
        #expect(throws: Never.self) {
            try OfficePDFPaginatedLayout(scale: .percent(10)).validated()
            try OfficePDFPaginatedLayout(scale: .percent(400)).validated()
        }
    }

    @Test("layout round-trips and defaults to document settings")
    func codable() throws {
        let layout = OfficePDFPaginatedLayout(paper: .a4, orientation: .landscape,
                                              scale: .percent(150))
        let data = try JSONEncoder().encode(layout)
        #expect(try JSONDecoder().decode(OfficePDFPaginatedLayout.self, from: data) == layout)
        #expect(OfficePDFPaginatedLayout.documentSettings.isDocumentSettings)
        #expect(!OfficePDFPaginatedLayout(paper: .a3).isDocumentSettings)
    }

    // MARK: - Support matrix

    @Test("physical layout is only supported for the paginated saved route")
    func supportFlags() {
        #expect(OfficePDFFormatSupport.resolve(forExtension: "docx")?
                .supportsPhysicalPageLayout == true)
        #expect(OfficePDFFormatSupport.resolve(forExtension: "pptx")?
                .supportsPhysicalPageLayout == true)
        #expect(OfficePDFFormatSupport.resolve(forExtension: "xlsx")?
                .supportsPhysicalPageLayout == false)
        for legacy in ["xls", "ods", "doc", "odt", "rtf", "ppt", "odp"] {
            #expect(OfficePDFFormatSupport.resolve(forExtension: legacy)?
                    .supportsPhysicalPageLayout == false, "legacy .\(legacy) stays document-settings only")
        }
        // The workbook OOXML page-setup flag is unchanged by this feature.
        #expect(OfficePDFFormatSupport.resolve(forExtension: "docx")?
                .supportsCustomPageSetup == false)
        #expect(OfficePDFFormatSupport.resolve(forExtension: "xlsx")?
                .supportsCustomPageSetup == true)
    }

    // MARK: - Plan-level validate()

    private func layout(_ paper: OfficePDFPaper) -> OfficePDFPaginatedLayout {
        OfficePDFPaginatedLayout(paper: paper, orientation: .landscape)
    }

    @Test("paginated formats accept a physical layout; others refuse it")
    func planValidate() throws {
        let plan = OfficePDFPrintPlan(paginatedLayout: layout(.a4))
        #expect(throws: Never.self) { try plan.validate(forExtension: "docx") }
        #expect(throws: Never.self) { try plan.validate(forExtension: "pptx") }
        #expect(throws: OfficePDFPlanError.unsupportedPhysicalLayout(format: "xlsx")) {
            try plan.validate(forExtension: "xlsx")
        }
        #expect(throws: OfficePDFPlanError.unsupportedPhysicalLayout(format: "ods")) {
            try plan.validate(forExtension: "ods")
        }
    }

    @Test("an out-of-range percent is refused before any export work")
    func planValidateRejectsBadPercent() {
        let plan = OfficePDFPrintPlan(paginatedLayout: OfficePDFPaginatedLayout(scale: .percent(900)))
        #expect(throws: OfficePDFPlanError.scalePercentOutOfRange(
            requested: 900, minimum: OfficePDFScale.minimumPercent,
            maximum: OfficePDFScale.maximumPercent)) {
            try plan.validate(forExtension: "docx")
        }
    }

    @Test("a document-settings layout on a workbook is not an override")
    func noOverrideStaysDocumentSettings() throws {
        let plan = OfficePDFPrintPlan(paginatedLayout: .documentSettings)
        #expect(throws: Never.self) { try plan.validate(forExtension: "xlsx") }
        #expect(plan.requiresPrintCopy == false)
    }

    @Test("a paginated layout does not by itself require a print copy")
    func layoutNeverNeedsPrintCopy() {
        // Word/PPT apply the layout to the generated PDF, never through an
        // XLSX print copy, so requiresPrintCopy stays scoped to the workbook.
        let plan = OfficePDFPrintPlan(scope: .documentSettings,
                                      paginatedLayout: layout(.letter))
        #expect(plan.requiresPrintCopy == false)
        #expect(plan.paginatedLayout?.hasOverrides == true)
    }
}
