// FloeApp — stable adaptive workbench inside the existing phone root.
//
// SPDX-License-Identifier: MPL-2.0
//
// Exactly TWO identity-bearing children are mounted for the whole scene:
// slot 0 is the primary content column (the mounted chat/editor/navigation
// subtree) and slot 1 is the sidebar. Width and fold changes only move rects
// inside ONE custom `Layout`; they never replace either child, never create a
// second router and never change the outer iPhoneRoot/iPadRoot choice. The
// compact presentation keeps today's drawer exactly (scrim, edge swipe,
// scale/offset; native toolbar remains unclipped); the expanded presentation shows a persistent, readable
// sidebar beside the content and turns the same sidebar action into a
// collapse/expand toggle. No device-name heuristic and no live shell swap.

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import FloeCore

struct AdaptivePhoneShell<Primary: View, Sidebar: View>: View {
    @Binding private var isDrawerOpen: Bool
    private let preferredSidebarWidth: Double
    /// True while another overlay (the phone inspector) owns horizontal
    /// gestures; the drawer never opens under it and the expanded sidebar
    /// never collapses behind it.
    private let blocksDrawerGesture: Bool
    /// Existing edge-swipe dismissal for the phone inspector overlay.
    private let onDismissInspector: (() -> Void)?
    /// Observation hook for the exact-component qualification host (and any
    /// future diagnostics). It never feeds layout back into the component.
    private let onPlanChange: ((PhoneShellPlan) -> Void)?
    private let primary: Primary
    private let sidebar: Sidebar

    @State private var isExpanded = false
    @State private var expandedSidebarVisible = true
    @GestureState private var drawerTranslation: CGFloat = 0

    init(isDrawerOpen: Binding<Bool>,
         preferredSidebarWidth: Double,
         blocksDrawerGesture: Bool = false,
         onDismissInspector: (() -> Void)? = nil,
         onPlanChange: ((PhoneShellPlan) -> Void)? = nil,
         @ViewBuilder primary: () -> Primary,
         @ViewBuilder sidebar: () -> Sidebar) {
        self._isDrawerOpen = isDrawerOpen
        self.preferredSidebarWidth = preferredSidebarWidth
        self.blocksDrawerGesture = blocksDrawerGesture
        self.onDismissInspector = onDismissInspector
        self.onPlanChange = onPlanChange
        self.primary = primary()
        self.sidebar = sidebar()
    }

    var body: some View {
        GeometryReader { proxy in
            let width = max(1, proxy.size.width)
            let plan = PhoneShellLayoutEngine.plan(
                containerWidth: width,
                containerHeight: proxy.size.height,
                preferredSidebarWidth: preferredSidebarWidth,
                drawerOpen: isDrawerOpen,
                drawerTranslation: isExpanded ? 0 : Double(drawerTranslation),
                expandedSidebarVisible: expandedSidebarVisible,
                previouslyExpanded: isExpanded)

            AdaptivePhoneShellLayout(plan: plan) {
                primary
                    .environment(\.phoneSidebarAction, sidebarAction(for: plan.mode))
                    .environment(\.phoneSidebarIsVisible,
                                 plan.mode == .expandedSidebar && plan.sidebarIsVisible)
                    .accessibilityHidden(plan.showsScrim)
                    .scaleEffect(plan.primaryScale, anchor: .trailing)
                    .offset(x: plan.primaryOffsetX)
                    // Native Duo toolbar controls live outside the safe
                    // content frame. Clipping this NavigationStack hides them.
                    .overlay {
                        if plan.showsScrim {
                            Color.black.opacity(plan.scrimOpacity)
                                .ignoresSafeArea()
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    withAnimation(.snappy) { isDrawerOpen = false }
                                }
                                .accessibilityLabel("app.floe_agent_app.collapse_task_list")
                        }
                    }
                // The sidebar is above the primary's scrim and stays tappable.
                sidebarContainer(plan: plan)
            }
            .animation(.snappy, value: isDrawerOpen)
            // Let the native command rail receive hits outside safe content.
            .simultaneousGesture(shellGesture(plan: plan))
            .onChange(of: plan, initial: true) { _, newPlan in
                onPlanChange?(newPlan)
            }
            .onChange(of: plan.mode, initial: true) { _, mode in
                isExpanded = mode == .expandedSidebar
                if mode == .expandedSidebar, isDrawerOpen {
                    // The drawer scrim never survives entering the wide
                    // layout: the persistent column replaces it.
                    isDrawerOpen = false
                }
            }
            .accessibilityIdentifier("phone.shell")
            .accessibilityValue(plan.mode.rawValue)
        }
    }

    /// The sidebar action the whole phone shell publishes. Compact opens the
    /// existing drawer; expanded collapses/restores the persistent sidebar.
    /// Both are the same native control and neither creates a second router.
    private func sidebarAction(for mode: PhoneShellPresentationMode) -> PhoneSidebarAction {
        switch mode {
        case .compactDrawer:
            return { withAnimation(.snappy) { isDrawerOpen = true } }
        case .expandedSidebar:
            return { withAnimation(.snappy) { expandedSidebarVisible.toggle() } }
        }
    }

    @ViewBuilder
    private func sidebarContainer(plan: PhoneShellPlan) -> some View {
        NavigationStack {
            // The column is already placed inside the safe content bounds.
            // Do not subtract the window's command rail a second time here.
            sidebar.ignoresSafeArea(.container, edges: .horizontal)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(FloeTheme.groupedSurface.ignoresSafeArea())
        .clipShape(RoundedRectangle(cornerRadius: plan.sidebarCornerRadius, style: .continuous))
        .shadow(color: .black.opacity(plan.mode == .compactDrawer ? 0.18 * plan.drawerProgress : 0),
                radius: 24, x: 8)
        .overlay(alignment: .trailing) {
            if plan.mode == .expandedSidebar, plan.sidebarIsVisible {
                Rectangle()
                    .fill(FloeTheme.separator)
                    .frame(width: 0.5)
                    .ignoresSafeArea()
            }
        }
        .accessibilityHidden(!plan.sidebarIsVisible)
        .allowsHitTesting(plan.sidebarIsVisible)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(plan.mode == .compactDrawer
                                 ? "phone.sidebar.drawer"
                                 : "phone.sidebar.column")
    }

    /// The phone drawer gestures, unchanged in compact: edge swipe opens,
    /// deliberate horizontal swipe closes. In expanded a right swipe that
    /// starts on the persistent sidebar collapses it (the iPad split's
    /// existing collapse habit), so the two layouts share one control.
    private func shellGesture(plan: PhoneShellPlan) -> some Gesture {
        DragGesture(minimumDistance: 12, coordinateSpace: .global)
            .updating($drawerTranslation) { value, state, _ in
                guard plan.mode == .compactDrawer, !blocksDrawerGesture else { return }
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                if isDrawerOpen {
                    state = min(0, value.translation.width)
                } else if value.startLocation.x < 28 {
                    state = max(0, value.translation.width)
                }
            }
            .onEnded { value in
                let horizontal = value.translation.width
                let predicted = value.predictedEndTranslation.width
                switch plan.mode {
                case .compactDrawer:
                    guard abs(horizontal) > abs(value.translation.height) else { return }
                    let drawerWidth = max(1, plan.sidebarFrame.width)
                    let commit = drawerWidth * PhoneShellLayoutEngine.drawerCommitFraction
                    if !isDrawerOpen, !blocksDrawerGesture,
                       value.startLocation.x < 28,
                       max(horizontal, predicted) > commit {
                        withAnimation(.snappy) { isDrawerOpen = true }
                    } else if isDrawerOpen {
                        let closesLeft = min(horizontal, predicted) < -commit
                        let closesRight = max(horizontal, predicted) > commit
                        if closesLeft || closesRight {
                            withAnimation(.snappy) { isDrawerOpen = false }
                        }
                    } else if horizontal > 0, let onDismissInspector {
                        // Historical phone behaviour: a right drag while the
                        // inspector overlay is up dismisses it.
                        onDismissInspector()
                    }
                case .expandedSidebar:
                    guard !blocksDrawerGesture, expandedSidebarVisible,
                          abs(horizontal) > abs(value.translation.height),
                          value.startLocation.x < max(1, plan.sidebarFrame.width) else { return }
                    if max(horizontal, predicted) > FloeTheme.minimumTarget {
                        withAnimation(.snappy) { expandedSidebarVisible = false }
                    }
                }
            }
    }
}

/// One stable two-child parent. The same child indexes are placed in both
/// presentations; only the rects differ, so SwiftUI never sees a structural
/// change at the primary or the sidebar.
struct AdaptivePhoneShellLayout: Layout {
    let plan: PhoneShellPlan

    func sizeThatFits(proposal: ProposedViewSize,
                      subviews: Subviews,
                      cache: inout Void) -> CGSize {
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil }
            ?? plan.containerSize.width
        let height = proposal.height.flatMap { $0.isFinite ? $0 : nil }
            ?? plan.containerSize.height
        return CGSize(width: max(0, width), height: max(0, height))
    }

    func placeSubviews(in bounds: CGRect,
                       proposal: ProposedViewSize,
                       subviews: Subviews,
                       cache: inout Void) {
        guard subviews.count >= 2 else {
            if let only = subviews.first {
                only.place(at: bounds.origin,
                           anchor: .topLeading,
                           proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
            }
            return
        }
        // Slots are contract constants: 0 = primary, 1 = sidebar.
        place(subviews[0], frame: plan.primaryFrame, in: bounds)
        place(subviews[1], frame: plan.sidebarFrame, in: bounds)
    }

    private func place(_ subview: LayoutSubviews.Element,
                       frame: FoldableRect,
                       in bounds: CGRect) {
        subview.place(
            at: CGPoint(x: bounds.minX + frame.x, y: bounds.minY + frame.y),
            anchor: .topLeading,
            proposal: ProposedViewSize(width: max(0, frame.width),
                                       height: max(0, frame.height)))
    }
}
#endif
