// FloeApp — scene-owned foldable display support (iPhone Duo class hardware).
//
// SPDX-License-Identifier: MPL-2.0
//
// Capability detection is scene/window-bound: the probe attaches to the app
// root (inside the active window) and relies on real iOS 27.1 signals only —
// a non-nil `DeviceHingeContext.hinge` from `onHingeChange` (whose handler
// receives the INITIAL hinge state on attach) and/or system division
// `ReservedRegion`s queried with `.includeInactive`. A nil hinge can merely
// mean the hierarchy does not provide updates: it can never downgrade
// already-proven capability during transient detached/background changes, and
// the FIRST attach-time answer is used as the mount decision (nil → mount
// the ordinary hierarchy). Marketing model strings, device idiom and width
// are never foldable evidence.
//
// The mount decision is made once, before any live editor or entry route is
// delivered, and is frozen afterwards: proven hardware keeps the stable
// NavigationSplitView shell and ONE custom Layout workbench parent for the
// scene; unproven hardware keeps the historical HStack/sheet branch. After
// resolution neither the root shell nor any workbench parent changes again —
// preferences, postures and transient nils only move rects inside the stable
// parent, so a fold can never remount editor/session identity (no
// sheet↔inline churn; a compact assistant is the same secondary overlaying
// the lower region).
//
// The heavy lifting (thresholds, hysteresis, band classification, tabletop/
// book axis, avoidance insets) is the pure `FoldableLayoutEngine` in
// FloeCore so the decisions stay unit-testable with synthetic regions.

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import UIKit
import FloeCore

/// Per-scene, lightweight detection state. Owned by the root view; published
/// snapshots flow through the environment (never a required EnvironmentObject,
/// so isolated qualification hosts keep the neutral default and hide the
/// foldable settings row without crashing).
@MainActor
final class FoldableDisplayState: ObservableObject {
    @Published private(set) var snapshot = FoldableDisplaySnapshot.neutral

    /// Bounded initial-decision wait. Attach on a real window delivers the
    /// first hinge update immediately on 27.1 hardware; the deadline exists
    /// so pre-27.1 systems and test hosts mount the ordinary root without a
    /// visible stall. The boot chrome shown meanwhile is the EXISTING
    /// persistence gate — no new spinner, no device-model fallback.
    static let mountResolutionDeadlineNanoseconds: UInt64 = 350_000_000

    private var deadlineTask: Task<Void, Never>?

    /// Called once when the root scene appears: guarantees the mount
    /// decision resolves even when no hinge API exists.
    func startMountResolutionDeadline() {
        guard !snapshot.isMountResolved, deadlineTask == nil else { return }
        deadlineTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.mountResolutionDeadlineNanoseconds)
            guard !Task.isCancelled else { return }
            self?.finishDeadline()
        }
    }

    /// Positive hinge evidence. If this arrives during the unresolved boot
    /// window it also LATCHES the foldable mount (shell + stable workbench
    /// parent) for this scene. A late raise after an ordinary latch updates
    /// capability only — settings display and leaf placements may react,
    /// but the mounted parent tree is untouched.
    func recordHinge(status: FoldableHingeStatus) {
        let latched = snapshot.latchedFoldableMount || !snapshot.isMountResolved
        deadlineTask?.cancel()
        deadlineTask = nil
        snapshot = FoldableDisplaySnapshot(capability: .foldable,
                                           hingeStatus: status,
                                           isMountResolved: true,
                                           latchedFoldableMount: latched)
    }

    /// A hinge update whose `hinge` is nil means the hierarchy does not
    /// provide hinge updates. The FIRST such answer (before anything was
    /// proven) resolves the mount as ORDINARY — it never claims permanent
    /// negative hardware, it declines to raise foldable evidence. Later nils
    /// are transient and keep proven capability while posture is unknown;
    /// the foldable mount latch keeps whatever tree is already mounted.
    func recordHingeUnavailable() {
        deadlineTask?.cancel()
        deadlineTask = nil
        if snapshot.capability == .foldable {
            snapshot = FoldableDisplaySnapshot(capability: .foldable,
                                               hingeStatus: .unknown,
                                               isMountResolved: true,
                                               latchedFoldableMount: snapshot.latchedFoldableMount)
            return
        }
        snapshot = FoldableDisplaySnapshot(capability: .unknown,
                                           hingeStatus: .unknown,
                                           isMountResolved: true,
                                           latchedFoldableMount: false)
    }

    /// System division regions are only provided by hinge hardware. Seeing
    /// one (active or inactive) is positive evidence and latches the
    /// foldable mount if resolution has not happened yet.
    func record(divisionRegions regions: [FoldableRegion]) {
        guard !regions.isEmpty else { return }
        let latched = snapshot.latchedFoldableMount || !snapshot.isMountResolved
        deadlineTask?.cancel()
        deadlineTask = nil
        snapshot = FoldableDisplaySnapshot(capability: .foldable,
                                           hingeStatus: snapshot.hingeStatus,
                                           isMountResolved: true,
                                           latchedFoldableMount: latched)
    }

    /// Explicit negative evidence (reserved for fixtures/diagnostics). It
    /// never overwrites proven foldable capability within the scene and does
    /// not by itself freeze the mount decision.
    func recordNonFoldable() {
        guard snapshot.capability != .foldable else { return }
        snapshot = FoldableDisplaySnapshot(capability: .nonFoldable,
                                           hingeStatus: snapshot.hingeStatus,
                                           isMountResolved: snapshot.isMountResolved,
                                           latchedFoldableMount: snapshot.latchedFoldableMount)
    }

    private func finishDeadline() {
        guard !snapshot.isMountResolved else { return }
        // Honest unknown: the hierarchy answered nothing in the window.
        // Mount the ordinary root; a later raise may still update
        // capability for display, but the latch (and therefore the mounted
        // shell/parent) never flips mid-scene.
        snapshot = FoldableDisplaySnapshot(capability: snapshot.capability,
                                           hingeStatus: snapshot.hingeStatus,
                                           isMountResolved: true,
                                           latchedFoldableMount: false)
    }
}

// MARK: - Regression identifiers (pinned for Main's combined UI verification)

/// Stable accessibility identifiers for foldable surfaces. UI regression
/// definitions reference these so a rename cannot silently break the suite.
enum FoldableLayoutIdentifiers {
    static let settingsToggle = "settings.general.foldable_adaptation"
    static let notesAssistantInlineColumn = "notes.assistant.inline.column"
    static let notesAssistantInlineBelow = "notes.assistant.inline.below"
    static let notesAssistantSheet = "notes.assistant.sheet"
}

// MARK: - Environment plumbing

private struct FoldableDisplayEnvironmentKey: EnvironmentKey {
    static let defaultValue = FoldableDisplaySnapshot.neutral
}

extension EnvironmentValues {
    /// The scene capability snapshot. Defaults to unknown/non-foldable and
    /// unresolved so every view works unchanged in isolated hosts and
    /// pre-27.1 systems.
    var foldableDisplay: FoldableDisplaySnapshot {
        get { self[FoldableDisplayEnvironmentKey.self] }
        set { self[FoldableDisplayEnvironmentKey.self] = newValue }
    }
}

// MARK: - Region bridge (UIKit/SwiftUI geometry → pure engine values)

extension FoldableRegion {
    /// Normalizes a system region rect into the container's 0...1 space.
    init(kind: FoldableRegionKind, frame: CGRect, containerSize: CGSize, isActive: Bool) {
        let width = containerSize.width > 0 ? containerSize.width : 1
        let height = containerSize.height > 0 ? containerSize.height : 1
        self.init(kind: kind,
                  x: Double(frame.minX / width),
                  y: Double(frame.minY / height),
                  width: Double(frame.width / width),
                  height: Double(frame.height / height),
                  isActive: isActive)
    }
}

/// Reads system reserved regions from a live `GeometryProxy`. Returns nothing
/// on systems without the 27.1 region API, so callers degrade to the ordinary
/// geometry/size-class layout.
enum FoldableRegionReader {
    static func regions(from proxy: GeometryProxy,
                        kind: FoldableRegionKind,
                        includeInactive: Bool = true) -> [FoldableRegion] {
        guard #available(iOS 27.1, *) else { return [] }
        let size = proxy.size
        let options: ReservedRegion.QueryOptions = includeInactive ? [.includeInactive] : []
        let systemKind: ReservedRegion.Kind
        switch kind {
        case .division: systemKind = .division
        case .occlusion: systemKind = .occlusion
        }
        return proxy.reservedRegions(kind: systemKind, options: options).map { region in
            FoldableRegion(kind: kind,
                           frame: region.frame,
                           containerSize: size,
                           isActive: region.isActive)
        }
    }

    static func containerSize(from proxy: GeometryProxy) -> FoldableSize {
        FoldableSize(width: Double(proxy.size.width), height: Double(proxy.size.height))
    }
}

// MARK: - Detection probe (window/scene-bound)

/// Attaches the hinge observer and the division-region probe to the app root.
/// `onHingeChange` fires with the initial hinge state on attach, which lets
/// the root make ONE frozen mount decision (foldable shell vs ordinary
/// hierarchy) before any live editor exists or any entry route is delivered;
/// routes stay queued behind the existing boot gate (no spinner, no model
/// fallback), and an unknown device keeps today's idiom/size-class selection.
struct FoldableCapabilityProbeModifier: ViewModifier {
    @ObservedObject var state: FoldableDisplayState

    func body(content: Content) -> some View {
        content
            .background(
                FoldableRegionProbe(state: state)
                    .allowsHitTesting(false)
            )
            .modifier(HingeChangeObserver(state: state))
    }
}

private struct HingeChangeObserver: ViewModifier {
    let state: FoldableDisplayState

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 27.1, *) {
            content.onHingeChange { _, newContext in
                let hinge = newContext.hinge
                let status: FoldableHingeStatus
                if let hinge {
                    if hinge.status == .closed {
                        status = .closed
                    } else if hinge.status == .partiallyOpen {
                        status = .partiallyOpen
                    } else if hinge.status == .fullyOpen {
                        status = .fullyOpen
                    } else {
                        status = .unknown
                    }
                } else {
                    status = .unknown
                }
                // The action is nonisolated; hop to the main actor to mutate
                // the scene state. Positive evidence only ever raises.
                Task { @MainActor in
                    if hinge == nil {
                        state.recordHingeUnavailable()
                    } else {
                        state.recordHinge(status: status)
                    }
                }
            }
        } else {
            content
        }
    }
}

private struct FoldableRegionProbe: View {
    @ObservedObject var state: FoldableDisplayState

    var body: some View {
        GeometryReader { proxy in
            Color.clear
                .onAppear { read(proxy) }
                .onChange(of: proxy.size) { _, _ in read(proxy) }
        }
    }

    private func read(_ proxy: GeometryProxy) {
        let regions = FoldableRegionReader.regions(from: proxy, kind: .division)
        guard !regions.isEmpty else { return }
        Task { @MainActor in
            state.record(divisionRegions: regions)
        }
    }
}

// MARK: - Identity-preserving workbench layout (foldable parent)

/// ONE stable custom `Layout` for proven foldable hardware. It always holds
/// exactly two children at the same structural positions — primary editor and
/// secondary assistant — and only the PLACED RECTS change with the pure
/// model's mode (hidden / side-by-side with the real hinge gap left empty /
/// tabletop content-above / compact overlay). No sheet↔inline reparent while
/// the assistant stays open, no Arrangement/AnyLayout parent swap, no
/// idiom/angle keying of identity. Ordinary devices never instantiate this
/// layout: they keep the historical HStack/sheet branch, chosen by the
/// scene-frozen `FoldableLayoutEngine.usesStableWorkbenchParent` gate before
/// any editor can mount.
struct FoldableWorkbenchLayout: Layout {
    let mode: FoldableWorkbenchMode
    let containerSize: FoldableSize

    /// Pure placement plan: the primary is ALWAYS placed, with or without a
    /// secondary subview. An assistant-less editor (closed assistant) still
    /// lays out the document at full primary bounds; opening the assistant
    /// appends the stable second slot without moving the primary's identity.
    static func placementPlan(mode: FoldableWorkbenchMode,
                              containerSize: FoldableSize,
                              subviewCount: Int) -> [FoldableRect] {
        let rects = FoldableLayoutEngine.rects(for: mode, containerSize: containerSize)
        if subviewCount >= 2 {
            return [rects.primary, rects.secondary]
        }
        return [rects.primary]
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        CGSize(width: containerSize.width, height: containerSize.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        guard !subviews.isEmpty else { return }
        let plan = Self.placementPlan(mode: mode,
                                      containerSize: containerSize,
                                      subviewCount: subviews.count)
        subviews[0].place(
            at: CGPoint(x: bounds.minX + plan[0].x, y: bounds.minY + plan[0].y),
            anchor: .topLeading,
            proposal: ProposedViewSize(width: plan[0].width, height: plan[0].height))
        guard subviews.count > 1, plan.count > 1 else { return }
        let secondary = plan[1]
        if secondary.width <= 0 || secondary.height <= 0 {
            // Hidden assistant: collapse to zero and do not disturb primary.
            subviews[1].place(at: CGPoint(x: bounds.maxX, y: bounds.maxY),
                              anchor: .topLeading,
                              proposal: .zero)
            return
        }
        subviews[1].place(
            at: CGPoint(x: bounds.minX + secondary.x, y: bounds.minY + secondary.y),
            anchor: .topLeading,
            proposal: ProposedViewSize(width: secondary.width, height: secondary.height))
    }
}

// MARK: - Editor decision helper

/// One call site → the complete workbench decision from real geometry
/// (including safe-area insets), proven capability, system regions and the
/// persisted preference. The parent choice is scene-frozen; the mode only
/// feeds rects into that same parent.
enum FoldablePresentationSupport {
    struct WorkbenchDecision: Equatable {
        /// Scene-frozen: use the stable foldable custom layout parent.
        var usesStableWorkbench: Bool
        /// Placement for the foldable parent (ignored on ordinary devices).
        var mode: FoldableWorkbenchMode
        /// Assistant reads as "below" (tabletop/overlay) rather than beside.
        var assistantBelow: Bool
        /// Hysteresis output for the next width change.
        var sideBySideActive: Bool
        /// The historical wide-iPad column rule for the ordinary branch.
        var ordinaryUsesColumn: Bool
    }

    @MainActor
    static func decideWorkbench(
        proxy: GeometryProxy,
        snapshot: FoldableDisplaySnapshot,
        adaptationEnabled: Bool,
        assistantVisible: Bool,
        previouslySideBySide: Bool
    ) -> WorkbenchDecision {
        let width = Double(proxy.size.width)
        let container = FoldableRegionReader.containerSize(from: proxy)
        let active = FoldableLayoutEngine.foldAdaptationActive(
            snapshot: snapshot, adaptationEnabled: adaptationEnabled)
        let regions: [FoldableRegion] = active
            ? FoldableRegionReader.regions(from: proxy, kind: .division)
                + FoldableRegionReader.regions(from: proxy, kind: .occlusion)
            : []
        let placement = FoldableLayoutEngine.workbenchPlacement(
            assistantVisible: assistantVisible,
            width: width,
            containerSize: container,
            snapshot: snapshot,
            adaptationEnabled: adaptationEnabled,
            previouslySideBySide: previouslySideBySide,
            regions: regions,
            bottomSafeInset: Double(proxy.safeAreaInsets.bottom))
        var mode = FoldableWorkbenchMode.hidden
        var assistantBelow = false
        var sideBySideActive = previouslySideBySide
        if case .foldable(let placedMode) = placement {
            mode = placedMode
            switch placedMode {
            case .hidden:
                break
            case .sideBySide:
                sideBySideActive = true
                assistantBelow = false
            case .contentAbove:
                sideBySideActive = true
                assistantBelow = true
            case .compactOverlay:
                sideBySideActive = false
                assistantBelow = true
            }
        }
        return WorkbenchDecision(
            usesStableWorkbench: placement != .ordinary
                && FoldableLayoutEngine.usesStableWorkbenchParent(snapshot: snapshot),
            mode: mode,
            assistantBelow: assistantBelow,
            sideBySideActive: sideBySideActive,
            ordinaryUsesColumn: FoldableLayoutEngine.ordinaryAssistantUsesColumn(
                isPadIdiom: UIDevice.current.userInterfaceIdiom == .pad, width: width))
    }
}
#endif
