// FloeCore — pure layout/typography model for list surfaces.
//
// Persisted user choices for file/asset/layer list typography and the iPad
// sidebar width. Kept free of UIKit so the formatting rules are unit-testable
// and identical for every list surface.

import Foundation

public enum LayoutListKind: String, CaseIterable, Codable, Sendable {
    case files
    case assets
    case layers

    public var titleZH: String {
        switch self {
        case .files: "文件"
        case .assets: "素材"
        case .layers: "图层"
        }
    }

    public var titleEN: String {
        switch self {
        case .files: "Files"
        case .assets: "Assets"
        case .layers: "Layers"
        }
    }
}

public enum LayoutListFontSize: String, CaseIterable, Codable, Sendable {
    case small
    case normal
    case large

    /// Point size applied to list primary text. Independent of code/terminal
    /// and document fonts by design.
    public var pointSize: Double {
        switch self {
        case .small: 12
        case .normal: 14
        case .large: 17
        }
    }

    public var titleZH: String {
        switch self {
        case .small: "小"
        case .normal: "标准"
        case .large: "大"
        }
    }

    public var titleEN: String {
        switch self {
        case .small: "Small"
        case .normal: "Normal"
        case .large: "Large"
        }
    }
}

/// File-name display rules: 1 or 2 lines, the extension always visible, an
/// optional full path line, and middle truncation that keeps the extension.
public enum FileNameDisplay {
    public static let maximumLines = 2

    /// Returns 1...2 display lines. Line 0 is the (possibly middle-truncated)
    /// file name with its extension preserved; line 1 is the relative path when
    /// requested and available.
    public static func lines(fileName: String,
                             relativePath: String? = nil,
                             lineCount: Int,
                             showPath: Bool,
                             maximumLength: Int = 48) -> [String] {
        let clampedLines = min(max(lineCount, 1), maximumLines)
        let name = middleTruncated(fileName, limit: maximumLength)
        guard clampedLines == 2 else { return [name] }
        guard showPath,
              let path = relativePath,
              !path.isEmpty,
              path != fileName else {
            return [name]
        }
        // The path line keeps the file name or directory tail readable.
        let tail = path.split(separator: "/").suffix(3).joined(separator: "/")
        return [name, middleTruncated(tail, limit: maximumLength + 12)]
    }

    /// Truncates the middle, preserving both the start and the extension.
    public static func middleTruncated(_ value: String, limit: Int) -> String {
        guard limit > 4, value.count > limit else { return value }
        let ns = value as NSString
        let extensionPart = ns.pathExtension
        let suffix = extensionPart.isEmpty ? "" : ".\(extensionPart)"
        let headBudget = max(1, limit - suffix.count - 1)
        let head = ns.deletingPathExtension.prefix(headBudget)
        return "\(head)…\(suffix)"
    }

    /// True when two visible list entries share the same base name, so the UI
    /// can surface a same-name hint instead of appearing to duplicate a file.
    public static func hasSameNameConflict(_ name: String, among others: [String]) -> Bool {
        let base = (name as NSString).deletingPathExtension.lowercased()
        return others.contains { other in
            other != name
                && (other as NSString).deletingPathExtension.lowercased() == base
        }
    }
}

/// Persisted layout values with explicit bounds. Stored through UserDefaults by
/// the app layer; this value type owns the defaults and clamping rules.
public struct LayoutSettings: Sendable, Equatable {
    public static let sidebarMinimumWidth: Double = 260
    public static let sidebarMaximumWidth: Double = 460
    public static let sidebarDefaultWidth: Double = 320

    public var fontSizes: [LayoutListKind: LayoutListFontSize]
    public var fileNameLines: Int
    public var showFullPath: Bool
    public var showFileExtension: Bool
    public var sidebarWidth: Double
    /// Foldable adaptation opt-out (iPhone Duo class hardware). `true` unless
    /// the user explicitly turns it off; the flag is only ever written by the
    /// General settings toggle, never by fold/unfold events or relaunches.
    /// A missing stored preference means enabled.
    public var foldableAdaptationEnabled: Bool

    public init(fontSizes: [LayoutListKind: LayoutListFontSize] = [:],
                fileNameLines: Int = 1,
                showFullPath: Bool = false,
                showFileExtension: Bool = true,
                sidebarWidth: Double = LayoutSettings.sidebarDefaultWidth,
                foldableAdaptationEnabled: Bool = true) {
        self.fontSizes = fontSizes
        self.fileNameLines = min(max(fileNameLines, 1), FileNameDisplay.maximumLines)
        self.showFullPath = showFullPath
        self.showFileExtension = showFileExtension
        self.sidebarWidth = min(max(sidebarWidth,
                                    LayoutSettings.sidebarMinimumWidth),
                                LayoutSettings.sidebarMaximumWidth)
        self.foldableAdaptationEnabled = foldableAdaptationEnabled
    }

    public func fontSize(for kind: LayoutListKind) -> LayoutListFontSize {
        fontSizes[kind] ?? .normal
    }

    public mutating func setFontSize(_ size: LayoutListFontSize, for kind: LayoutListKind) {
        fontSizes[kind] = size
    }
}

// MARK: - Foldable display support (system-detected hinge hardware)
//
// Pure decision layer for iPhone Duo class foldable hardware. The app layer
// feeds real iOS 27.1 signals (`UIHingeInteraction`/`onHingeChange` hinge
// presence and `ReservedRegion` division/occlusion data) into these value
// types; everything here stays free of UIKit so the selections are unit
// testable with synthetic compact/expanded/book/tabletop regions. Capability
// is never guessed from marketing model strings, device idiom or width alone.

public enum FoldableDisplayCapability: String, Sendable, Equatable, CaseIterable {
    /// No positive hinge evidence yet. Behaves exactly like a non-foldable
    /// device: ordinary adaptive layout, no fold-specific arrangements.
    case unknown
    /// Reserved for explicit negative evidence; treated identically to
    /// `.unknown` by every decision (never shows foldable UI). Production
    /// detection does not fabricate this from a nil hinge, because nil can
    /// simply mean the hierarchy does not provide updates.
    case nonFoldable
    /// Positively proven hinge hardware (non-nil hinge context or division
    /// regions observed on the active window). Sticky for the scene's
    /// lifetime; transient nil updates never downgrade it.
    case foldable
}

public enum FoldableHingeStatus: Sendable, Equatable {
    case unknown
    case closed
    case partiallyOpen
    case fullyOpen
}

/// Scene-owned capability snapshot published through the environment. Its
/// default (`neutral`) is unknown/non-foldable, unresolved and ordinary-
/// latched, so isolated qualification hosts render the ordinary layout
/// without any provider object.
///
/// `isMountResolved` freezes the ONE initial layout-shell and container
/// decision: the root publishes the boot chrome (never a new spinner — the
/// existing persistence gate) until the first real probe answer arrives
/// (attach-time initial hinge update or division-region read) or the bounded
/// deadline elapses.
///
/// `latchedFoldableMount` is the SEPARATE one-way mount choice: true only if
/// positive hardware evidence existed AT the first resolution. Later raises
/// update `capability`/`hingeStatus` (settings display and leaf placements
/// may still react), but neither the root shell nor any workbench parent can
/// be replaced mid-scene — an ordinary-latched scene keeps its mounted tree
/// until the next scene mounts. A nil answer is never faked as a permanent
/// hardware negative: it only declines to raise foldable evidence.
public struct FoldableDisplaySnapshot: Sendable, Equatable {
    public var capability: FoldableDisplayCapability
    public var hingeStatus: FoldableHingeStatus
    public var isMountResolved: Bool
    public var latchedFoldableMount: Bool

    public init(capability: FoldableDisplayCapability = .unknown,
                hingeStatus: FoldableHingeStatus = .unknown,
                isMountResolved: Bool = false,
                latchedFoldableMount: Bool = false) {
        self.capability = capability
        self.hingeStatus = hingeStatus
        self.isMountResolved = isMountResolved
        self.latchedFoldableMount = latchedFoldableMount
    }

    public static let neutral = FoldableDisplaySnapshot()

    public var isPositivelyFoldable: Bool { capability == .foldable }
}

public enum FoldableRegionKind: Sendable, Equatable {
    case occlusion
    case division
}

/// A normalized reserved region (components in 0...1 of the container) so the
/// engine is resolution-independent and testable without a live window.
public struct FoldableRegion: Sendable, Equatable {
    public var kind: FoldableRegionKind
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public var isActive: Bool

    public init(kind: FoldableRegionKind,
                x: Double, y: Double, width: Double, height: Double,
                isActive: Bool = true) {
        self.kind = kind
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.isActive = isActive
    }

    public var centerY: Double { y + height / 2 }
    public var centerX: Double { x + width / 2 }
}

public struct FoldableRect: Sendable, Equatable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var maxX: Double { x + width }
    public var maxY: Double { y + height }

    public func contains(_ other: FoldableRect, tolerance: Double = 0.5) -> Bool {
        other.x >= x - tolerance
            && other.y >= y - tolerance
            && other.maxX <= maxX + tolerance
            && other.maxY <= maxY + tolerance
    }
}

/// One-side insets in points for avoiding a hinge band within a container.
public struct FoldableEdgeInsets: Sendable, Equatable {
    public var top: Double
    public var leading: Double
    public var bottom: Double
    public var trailing: Double

    public init(top: Double = 0, leading: Double = 0, bottom: Double = 0, trailing: Double = 0) {
        self.top = top
        self.leading = leading
        self.bottom = bottom
        self.trailing = trailing
    }

    public static let zero = FoldableEdgeInsets()

    public var isZero: Bool { top == 0 && leading == 0 && bottom == 0 && trailing == 0 }
}

/// The one stable parent's placement parameter for foldable hardware. All
/// four cases keep BOTH children mounted at the same structural position —
/// only rects change — so a fold, a posture change or a preference toggle
/// can never remount the primary editor or the secondary assistant session.
public enum FoldableWorkbenchMode: Sendable, Equatable {
    /// Assistant not open: secondary collapses to zero; NO assistant/session
    /// is created for an unopened assistant.
    case hidden
    /// Expanded or book pose: primary left, hinge gap empty, secondary right.
    case sideBySide(secondaryWidth: Double, gapWidth: Double)
    /// Tabletop pose: content above the hinge band, assistant below it.
    case contentAbove(secondaryHeight: Double, gapHeight: Double)
    /// Folded/compact with the assistant open: the SAME secondary overlays
    /// the lower region instead of a sheet, avoiding any sheet↔inline
    /// reparent while the assistant stays open.
    case compactOverlay(secondaryHeight: Double, bottomInset: Double)
}

public enum FoldableWorkbenchPlacement: Sendable, Equatable {
    /// Non-foldable device: the caller keeps the exact historical
    /// HStack-column/sheet implementation untouched.
    case ordinary
    /// Proven foldable hardware: the stable custom-layout branch, frozen for
    /// the scene by the initial mount decision.
    case foldable(mode: FoldableWorkbenchMode)
}

/// The two existing outermost navigation shells. Selection is frozen per
/// mount: nothing inside a scene changes it afterwards.
public enum FoldableRootShell: Sendable, Equatable {
    case splitView
    case phoneDrawer
}

/// The frozen initial mount decision. The root shows the EXISTING boot chrome (never
/// a new spinner) until the bounded window probe resolves, and entry/deeplink
/// routes are delivered only after the same resolution — so the ONE shell and
/// container choice freezes before any editor exists, without an unbounded
/// wait and without device-model fallbacks.
public enum FoldableMountGate {
    public static func showsBootChrome(persistenceReady: Bool, mountResolved: Bool) -> Bool {
        !persistenceReady || !mountResolved
    }

    public static func entryRoutesReady(persistenceReady: Bool, mountResolved: Bool) -> Bool {
        persistenceReady && mountResolved
    }
}

public enum FoldableLayoutEngine {
    /// Minimum container width (points) for the assistant to sit inline next
    /// to the document when foldable adaptation is active.
    public static let assistantInlineMinWidth: Double = 850
    /// The assistant leaves inline presentation only below this width,
    /// preventing column<->sheet churn while a physical fold animates across
    /// the threshold.
    public static let assistantInlineResumeMinWidth: Double = 810
    /// Below this canvas width the compact chrome (single control cluster) is
    /// used; above it the expanded workbench chrome. Same band idea.
    public static let canvasExpandedMinWidth: Double = 620
    public static let canvasExpandedResumeMinWidth: Double = 580
    /// A band thinner than this fraction of the cross axis is plausible
    /// occlusion/division hardware (a hinge strip), not a content split.
    public static let maximumBandThicknessFraction: Double = 0.25
    /// A band must span at least this fraction of the container to count.
    public static let minimumBandSpanFraction: Double = 0.6
    /// A band whose center sits this far from either edge divides the
    /// display into usable above/below (or left/right) regions.
    public static let bandCenterMarginFraction: Double = 0.2
    /// The secondary region must at least be this tall/wide for tabletop or
    /// side-by-side placement to remain usable; otherwise keep side-by-side.
    public static let minimumSecondaryExtent: Double = 140
    /// Side-by-side never lets the secondary eat more than this fraction of
    /// a foldable container, keeping the document primary usable.
    public static let maximumSecondaryWidthFraction: Double = 0.5

    /// True only for positively proven foldable hardware with the persisted
    /// opt-out still enabled. Unknown/nonFoldable capability and explicit off
    /// never enable fold-specific arrangements.
    public static func foldAdaptationActive(snapshot: FoldableDisplaySnapshot,
                                            adaptationEnabled: Bool) -> Bool {
        snapshot.isPositivelyFoldable && adaptationEnabled
    }

    /// The frozen workbench-parent choice. Derived ONLY from the one-way
    /// mount latch — not from live capability — so a late positive raise
    /// after an ordinary mount can never replace the parent tree under a
    /// live editor. Postures and preferences never enter this input at all;
    /// they only change rects inside the chosen parent.
    public static func usesStableWorkbenchParent(snapshot: FoldableDisplaySnapshot) -> Bool {
        snapshot.isMountResolved && snapshot.latchedFoldableMount
    }

    /// The stable root shell question: the FROZEN foldable mount latch keeps
    /// the NavigationSplitView shell across open/close regardless of the
    /// user opt-out (system collapse handles the compact side). A late
    /// capability raise on an ordinary-latched scene cannot swap the shell
    /// mid-scene; the next scene mount will observe the proven hardware.
    /// Ordinary non-foldable roots keep the existing selection.
    public static func retainsSplitShell(snapshot: FoldableDisplaySnapshot,
                                         forceCompactForUITest: Bool,
                                         mountResolved: Bool) -> Bool {
        mountResolved && snapshot.latchedFoldableMount && !forceCompactForUITest
    }

    /// The OUTERMOST navigation shell choice, intentionally decoupled from
    /// live width/size-class: rotation, stage manager resizing and a late
    /// foldable raise can therefore never replace the mounted outer tree.
    /// Device idiom selects only the ordinary navigation shell (iPad reuses
    /// the existing two-column NavigationSplitView and lets the system
    /// collapse it; iPhone uses the existing drawer shell) — it is never
    /// foldable detection and never drives settings visibility. All
    /// size-adaptive layout stays INSIDE these shells. UITest forcing
    /// overrides keep their exact coverage.
    public static func selectRootShell(snapshot: FoldableDisplaySnapshot,
                                       isPadIdiom: Bool,
                                       mountResolved: Bool,
                                       forceRegularForUITest: Bool,
                                       forceCompactForUITest: Bool) -> FoldableRootShell {
        if forceRegularForUITest { return .splitView }
        if forceCompactForUITest { return .phoneDrawer }
        if retainsSplitShell(snapshot: snapshot,
                             forceCompactForUITest: false,
                             mountResolved: mountResolved) { return .splitView }
        if isPadIdiom { return .splitView }
        return .phoneDrawer
    }

    /// The workbench placement for the ONE stable foldable parent. Derived
    /// only from proven capability, the persisted preference, real container
    /// geometry and system division/occlusion regions — never hinge angle,
    /// device model or idiom pretending capability. Proven foldable hardware
    /// ALWAYS answers `.foldable` (even with the preference off — off simply
    /// drops region-driven placement to proportional, still no remount);
    /// everything else answers `.ordinary` for the historical path.
    public static func workbenchPlacement(
        assistantVisible: Bool,
        width: Double,
        containerSize: FoldableSize,
        snapshot: FoldableDisplaySnapshot,
        adaptationEnabled: Bool,
        previouslySideBySide: Bool,
        regions: [FoldableRegion] = [],
        bottomSafeInset: Double = 0
    ) -> FoldableWorkbenchPlacement {
        guard snapshot.isPositivelyFoldable else { return .ordinary }
        guard assistantVisible else { return .foldable(mode: .hidden) }
        let sideBySide: Bool
        if previouslySideBySide {
            sideBySide = width >= assistantInlineResumeMinWidth
        } else {
            sideBySide = width >= assistantInlineMinWidth
        }
        if sideBySide {
            if adaptationEnabled {
                if let parts = tabletopRegions(regions: regions, containerSize: containerSize) {
                    let height = min(max(parts.below.height, minimumSecondaryExtent),
                                     max(minimumSecondaryExtent, containerSize.height * 0.6))
                    return .foldable(mode: .contentAbove(secondaryHeight: height,
                                                         gapHeight: parts.band.height))
                }
                if let book = bookSplit(regions: regions, containerSize: containerSize) {
                    let maxWidth = max(minimumSecondaryExtent, containerSize.width * maximumSecondaryWidthFraction)
                    let width = min(max(book.right.width, minimumSecondaryExtent), maxWidth)
                    return .foldable(mode: .sideBySide(secondaryWidth: width,
                                                      gapWidth: book.band.width))
                }
            }
            return .foldable(mode: .sideBySide(
                secondaryWidth: min(440, max(360, width * 0.36)),
                gapWidth: 0))
        }
        // Folded with the assistant open: overlay the lower region. Never a
        // sheet on foldable hardware — the assistant keeps its mount.
        let safeInset = max(0, bottomSafeInset)
        let overlayHeight = min(max(240, containerSize.height * 0.6),
                               max(180, containerSize.height - safeInset - 120))
        return .foldable(mode: .compactOverlay(secondaryHeight: overlayHeight,
                                               bottomInset: safeInset))
    }

    /// The two child rects for a mode inside a container. The custom Layout
    /// places exactly these; tests pin containment directly against the same
    /// function the runtime uses.
    public static func rects(for mode: FoldableWorkbenchMode,
                             containerSize: FoldableSize)
        -> (primary: FoldableRect, secondary: FoldableRect)
    {
        let full = FoldableRect(x: 0, y: 0,
                                width: max(0, containerSize.width),
                                height: max(0, containerSize.height))
        switch mode {
        case .hidden:
            return (full, FoldableRect(x: 0, y: 0, width: 0, height: 0))
        case .sideBySide(let secondaryWidth, let gapWidth):
            let width = min(max(0, secondaryWidth), max(0, containerSize.width * 0.6))
            let gap = min(max(0, gapWidth), max(0, containerSize.width - width - 120))
            let primary = FoldableRect(x: 0, y: 0,
                                       width: max(0, containerSize.width - width - gap),
                                       height: containerSize.height)
            let secondary = FoldableRect(x: containerSize.width - width, y: 0,
                                         width: width, height: containerSize.height)
            return (primary, secondary)
        case .contentAbove(let secondaryHeight, let gapHeight):
            let height = min(max(0, secondaryHeight), max(0, containerSize.height * 0.7))
            let gap = min(max(0, gapHeight), max(0, containerSize.height - height - 120))
            let primary = FoldableRect(x: 0, y: 0,
                                       width: containerSize.width,
                                       height: max(0, containerSize.height - height - gap))
            let secondary = FoldableRect(x: 0, y: containerSize.height - height,
                                         width: containerSize.width, height: height)
            return (primary, secondary)
        case .compactOverlay(let secondaryHeight, let bottomInset):
            let inset = min(max(0, bottomInset), max(0, containerSize.height - 180))
            let height = min(max(0, secondaryHeight), max(0, containerSize.height - inset))
            let secondary = FoldableRect(x: 0, y: containerSize.height - inset - height,
                                         width: containerSize.width, height: height)
            return (full, secondary)
        }
    }

    /// The non-foldable historical rule, kept as one honest function so the
    /// editor and its tests pin the exact preserved behavior.
    public static func ordinaryAssistantUsesColumn(isPadIdiom: Bool, width: Double) -> Bool {
        isPadIdiom && width >= assistantInlineMinWidth
    }

    /// Canvas chrome decision. Non-foldable/off keeps the historical
    /// `.phone || width < 620` exactly; proven foldable hardware with
    /// adaptation on decides from the actual available width only, so an
    /// unfolded phone reaches the expanded workbench chrome.
    public static func canvasUsesCompactChrome(snapshot: FoldableDisplaySnapshot,
                                               adaptationEnabled: Bool,
                                               width: Double,
                                               previouslyExpanded: Bool,
                                               isPhoneIdiom: Bool) -> Bool {
        guard foldAdaptationActive(snapshot: snapshot, adaptationEnabled: adaptationEnabled) else {
            return isPhoneIdiom || width < canvasExpandedMinWidth
        }
        if previouslyExpanded {
            return width < canvasExpandedResumeMinWidth
        }
        return width < canvasExpandedMinWidth
    }

    /// A horizontal band (full-width, thin) that splits the display into an
    /// above and below region — the tabletop pose.
    public static func tabletopRegions(regions: [FoldableRegion],
                                       containerSize: FoldableSize) -> (band: FoldableRect, above: FoldableRect, below: FoldableRect)? {
        guard containerSize.width > 0, containerSize.height > 0 else { return nil }
        for region in regions where region.isActive {
            let height = region.height
            let span = region.width
            guard span >= minimumBandSpanFraction,
                  height > 0,
                  height <= maximumBandThicknessFraction,
                  region.centerY >= bandCenterMarginFraction,
                  region.centerY <= 1 - bandCenterMarginFraction else { continue }
            let band = FoldableRect(x: region.x * containerSize.width,
                                    y: region.y * containerSize.height,
                                    width: span * containerSize.width,
                                    height: height * containerSize.height)
            let below = FoldableRect(x: 0, y: band.maxY,
                                     width: containerSize.width,
                                     height: max(0, containerSize.height - band.maxY))
            let above = FoldableRect(x: 0, y: 0,
                                     width: containerSize.width,
                                     height: band.y)
            // Tabletop puts content above and controls below: the lower
            // region must remain usable, and both regions together with the
            // band must cover the container (containment invariant).
            guard below.height >= minimumSecondaryExtent,
                  above.height >= minimumSecondaryExtent,
                  abs(above.height + band.height + below.height - containerSize.height) < 1 else { continue }
            return (band, above, below)
        }
        return nil
    }

    /// A vertical band (full-height, thin) that splits the display into left
    /// and right regions — the book pose.
    public static func bookSplit(regions: [FoldableRegion],
                                 containerSize: FoldableSize) -> (band: FoldableRect, left: FoldableRect, right: FoldableRect)? {
        guard containerSize.width > 0, containerSize.height > 0 else { return nil }
        for region in regions where region.isActive {
            let width = region.width
            let span = region.height
            guard span >= minimumBandSpanFraction,
                  width > 0,
                  width <= maximumBandThicknessFraction,
                  region.centerX >= bandCenterMarginFraction,
                  region.centerX <= 1 - bandCenterMarginFraction else { continue }
            let band = FoldableRect(x: region.x * containerSize.width,
                                    y: region.y * containerSize.height,
                                    width: width * containerSize.width,
                                    height: span * containerSize.height)
            let left = FoldableRect(x: 0, y: 0, width: band.x, height: containerSize.height)
            let right = FoldableRect(x: band.maxX, y: 0,
                                     width: max(0, containerSize.width - band.maxX),
                                     height: containerSize.height)
            guard left.width >= minimumSecondaryExtent,
                  right.width >= minimumSecondaryExtent,
                  abs(left.width + band.width + right.width - containerSize.width) < 1 else { continue }
            return (band, left, right)
        }
        return nil
    }

    /// Bottom padding that keeps primary content entirely inside the above
    /// region when a tabletop band is present (zero otherwise).
    public static func contentAvoidanceInsets(regions: [FoldableRegion],
                                              containerSize: FoldableSize) -> FoldableEdgeInsets {
        guard let parts = tabletopRegions(regions: regions, containerSize: containerSize) else {
            return .zero
        }
        let bottom = max(0, containerSize.height - parts.above.maxY)
        return FoldableEdgeInsets(bottom: bottom)
    }

    /// A reachable control frame for the tabletop lower region, honouring the
    /// keyboard/safe-area bottom inset: the returned rect is guaranteed to sit
    /// inside the below region above the keyboard line.
    public static func tabletopControlFrame(controlWidth: Double,
                                            controlHeight: Double,
                                            regions: [FoldableRegion],
                                            containerSize: FoldableSize,
                                            bottomSafeInset: Double) -> FoldableRect? {
        guard let parts = tabletopRegions(regions: regions, containerSize: containerSize) else {
            return nil
        }
        let usableTop = parts.below.y
        let usableBottom = max(usableTop, containerSize.height - max(0, bottomSafeInset))
        let height = min(controlHeight, max(0, usableBottom - usableTop))
        let width = min(controlWidth, containerSize.width)
        guard height > 0 else { return nil }
        let frame = FoldableRect(x: max(0, (containerSize.width - width) / 2),
                                 y: usableBottom - height,
                                 width: width,
                                 height: height)
        return parts.below.contains(frame) && frame.maxY <= usableBottom + 0.5 ? frame : nil
    }
}

public struct FoldableSize: Sendable, Equatable {
    public var width: Double
    public var height: Double
    public init(width: Double = 0, height: Double = 0) {
        self.width = width
        self.height = height
    }
    public static let zero = FoldableSize()
}
