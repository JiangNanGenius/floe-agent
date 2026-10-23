// SPDX-License-Identifier: MPL-2.0
// FloeDocuments — physical print layout for generated paginated (Word/PPT) PDFs.
//
// A `.docx`/`.pptx` export runs the existing guarded isolated engine export
// first; the pages it produces then get their PHYSICAL print layout here:
// the requested paper, orientation and one scaling choice, applied to the
// generated PDF's pages. This is the print contract, not a reflow of the
// source document: no Word layout engine is claimed, no slide authoring
// size is changed, and the source package bytes are never written.
//
// Honest scaling semantics (deliberately smaller than the workbook set —
// workbook fit-across-pages budgets and page-width fits mean nothing for a
// finished PDF, so they are NOT exposed here):
//  * `fitWholePage` — the safe default. Each page's complete rendered area
//    is uniformly scaled DOWN (never enlarged) so all of it fits on the
//    chosen paper, centred. A portrait page fitted to landscape paper
//    keeps every pixel of content; nothing is clipped silently.
//  * `actualSize` — an explicit choice to print each page at its own
//    rendered size on the chosen paper. If a page is larger than that
//    paper, its content extends beyond the paper box; the caller reports
//    how many pages exceed (never a silent re-fit).
//  * `percent` — an explicit 10–400% of the page's rendered size, the same
//    bound `OfficePDFScale` defines for a declared worksheet scale. Same
//    exceeds-paper reporting; the result is exactly what the regenerated
//    preview shows because preview and print share this one computation.
//
// Target paper selection per page:
//  * paper chosen, orientation chosen → the paper's box in that orientation.
//  * paper chosen, no orientation → the paper follows each source page's
//    own aspect, so a Word document's portrait sections and landscape
//    pages (or a deck's mixed slide sizes) keep their intent.
//  * orientation only, no paper → the source page's own box swapped when
//    the requested orientation differs from the page's aspect.
//  * neither → the source box (an explicit `percent`/`actualSize` then
//    scales the content on the document's own page size).
//
// All geometry is in PDF points, portrait-first, ISO 216 at 72/25.4.

import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// The one scaling control a paginated physical layout request may carry.
public enum OfficePDFPaginatedScale: Codable, Sendable, Equatable {
    /// Scale each page down if needed so its complete rendered area fits
    /// the target paper, centred. Never enlarges. The default whenever a
    /// layout changes paper or orientation without naming a scale.
    case fitWholePage
    /// Print each page at 100% of its rendered size (explicit choice).
    case actualSize
    /// Print each page at exactly this percentage of its rendered size,
    /// `OfficePDFScale.minimumPercent`…`maximumPercent` (explicit choice).
    case percent(Int)
}

/// One physical print layout request for the pages of a generated
/// paginated-format PDF. Every `nil` keeps the source page's own value;
/// a struct with all members nil IS document settings (no override).
public struct OfficePDFPaginatedLayout: Codable, Sendable, Equatable {
    public var paper: OfficePDFPaper?
    public var orientation: OfficePDFOrientation?
    public var scale: OfficePDFPaginatedScale?

    public init(paper: OfficePDFPaper? = nil,
                orientation: OfficePDFOrientation? = nil,
                scale: OfficePDFPaginatedScale? = nil) {
        self.paper = paper
        self.orientation = orientation
        self.scale = scale
    }

    /// Keep every page exactly as the engine rendered it.
    public static let documentSettings = OfficePDFPaginatedLayout()

    /// True when this layout asks for no physical change at all: the
    /// export must behave byte-for-byte like the existing route.
    public var isDocumentSettings: Bool {
        paper == nil && orientation == nil && scale == nil
    }

    /// True when at least one physical member must be applied.
    public var hasOverrides: Bool { !isDocumentSettings }

    /// nil scaling on a requested layout resolves to the safe whole-page
    /// fit, so a paper/orientation-only change can never clip content.
    public var resolvedScale: OfficePDFPaginatedScale { scale ?? .fitWholePage }

    /// Validate the bounded members. Percent bounds reuse the single
    /// `OfficePDFScale` range the shared plan already enforces.
    public func validated() throws {
        if case .percent(let value)? = scale {
            guard (OfficePDFScale.minimumPercent...OfficePDFScale.maximumPercent)
                    .contains(value) else {
                throw OfficePDFPlanError.scalePercentOutOfRange(
                    requested: value,
                    minimum: OfficePDFScale.minimumPercent,
                    maximum: OfficePDFScale.maximumPercent)
            }
        }
    }

    // MARK: - Paper geometry (PDF points)

    /// Portrait-first physical size. ISO pages use 1 mm = 72/25.4 pt;
    /// Letter/Legal are exact.
    public static func portraitSize(for paper: OfficePDFPaper) -> CGSize {
        let mm: CGFloat = 72.0 / 25.4
        switch paper {
        case .a4: return CGSize(width: 210 * mm, height: 297 * mm)
        case .a3: return CGSize(width: 297 * mm, height: 420 * mm)
        case .letter: return CGSize(width: 612, height: 792)
        case .legal: return CGSize(width: 612, height: 1008)
        }
    }

    /// The target paper box for one source page's DISPLAY size (the size
    /// after the source page's own rotation, upright).
    public func targetSize(forSourceDisplaySize source: CGSize) -> CGSize {
        let sourceLandscape = source.width >= source.height
        if let paper {
            let portrait = Self.portraitSize(for: paper)
            let wantLandscape = orientation.map { $0 == .landscape } ?? sourceLandscape
            return wantLandscape
                ? CGSize(width: portrait.height, height: portrait.width)
                : portrait
        }
        guard let orientation else { return source }
        switch orientation {
        case .portrait:
            return sourceLandscape
                ? CGSize(width: source.height, height: source.width)
                : source
        case .landscape:
            return sourceLandscape
                ? source
                : CGSize(width: source.height, height: source.width)
        }
    }

    /// The uniform scale for one source page. `fitWholePage` is capped at
    /// 100%: fitting never enlarges the document's rendered text.
    public func scaleFactor(forSourceDisplaySize source: CGSize,
                           target: CGSize) -> CGFloat {
        switch resolvedScale {
        case .fitWholePage:
            guard source.width > 0, source.height > 0 else { return 1 }
            let fit = min(target.width / source.width, target.height / source.height)
            return min(1, max(fit, 0))
        case .actualSize:
            return 1
        case .percent(let value):
            return CGFloat(value) / 100
        }
    }

    /// One fully resolved physical placement for one source page — the
    /// single computation the renderer, the preview and the measured
    /// result report all share.
    public struct Placement: Sendable, Equatable {
        /// The new page box, origin zero.
        public var targetSize: CGSize
        /// The scaled page's bottom-left point inside the box (centred;
        /// may be negative when an explicit scale exceeds the paper).
        public var contentOrigin: CGPoint
        public var contentSize: CGSize
        public var scaleFactor: CGFloat
        /// True when the explicitly scaled page is larger than the paper
        /// in either axis — the part beyond the page box is what a
        /// physical printer trims. A `fitWholePage` request is never
        /// exceeding by construction.
        public var contentExceedsPaper: Bool
    }

    public func placement(forSourceDisplaySize source: CGSize) -> Placement {
        let target = targetSize(forSourceDisplaySize: source)
        let factor = scaleFactor(forSourceDisplaySize: source, target: target)
        let content = CGSize(width: source.width * factor,
                             height: source.height * factor)
        let origin = CGPoint(x: (target.width - content.width) / 2,
                             y: (target.height - content.height) / 2)
        let exceeds = content.width > target.width + 0.01
            || content.height > target.height + 0.01
        return Placement(targetSize: target, contentOrigin: origin,
                         contentSize: content, scaleFactor: factor,
                         contentExceedsPaper: exceeds)
    }
}
