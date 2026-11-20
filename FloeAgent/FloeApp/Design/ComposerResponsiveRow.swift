// SPDX-License-Identifier: MPL-2.0

import SwiftUI

/// Row composition for the composer: keep the natural controls beside the
/// field while the text keeps a usable column, otherwise give the field the
/// row's full width and reflow the controls into a second row.
///
/// The shipped New Task screenshots showed the failure this rule prevents:
/// five 44pt controls in one row left only a sliver (~65pt on the canonical
/// iPad in portrait) for the editable text, so even a modest mixed draft
/// broke into a ragged staircase of tiny lines and an unbroken URL could
/// never read as a URL. The rule is pure geometry at the row's real width:
/// - `minimumInlineTextWidth` is the practical minimum width of the editable
///   column while the controls stay beside it;
/// - the same draft measured at the flanked width and at the full row width
///   tells whether the text wraps only because the controls took its space;
/// - the host's overflow verdict (the field scrolls at its current width)
///   means the draft is multiline at its widest available slot as well.
///
/// The decision is placement-independent: it is computed from the row width,
/// the controls' measured widths and the draft's heights at both widths,
/// never from the layout it produced, so re-evaluating it after a flip cannot
/// oscillate. Stacking only ever widens the field (so its measured block can
/// never grow), and a verdict recorded at the narrower flanked width is
/// re-derived at the wider laid-out width by the field's own report.
enum ComposerResponsiveLayoutPolicy {
    /// Practical minimum width for the editable text column while the
    /// controls stay beside it. Below this the field owns the whole row.
    static let minimumInlineTextWidth: CGFloat = 200

    /// Slack when comparing the same draft measured at two widths. Different
    /// line counts differ by whole line heights; only TextKit sub-pixel
    /// rounding is tolerated here.
    static let multilineHeightTolerance: CGFloat = 1

    /// Width the field keeps when `controlsCount` controls share its row,
    /// with `spacing` between every adjacent pair.
    static func inlineTextWidth(
        rowWidth: CGFloat,
        controlsWidth: CGFloat,
        controlsCount: Int,
        spacing: CGFloat
    ) -> CGFloat {
        guard controlsCount > 0 else { return max(rowWidth, 0) }
        return max(0, rowWidth - controlsWidth - spacing * CGFloat(controlsCount))
    }

    /// True when the field must own the full row and the controls reflow into
    /// the row below it.
    static func stacks(
        rowWidth: CGFloat,
        controlsWidth: CGFloat,
        controlsCount: Int,
        spacing: CGFloat,
        fieldHeightAtInlineWidth: CGFloat,
        fieldHeightAtFullWidth: CGFloat,
        isFieldOverflowing: Bool
    ) -> Bool {
        let inlineWidth = inlineTextWidth(
            rowWidth: rowWidth,
            controlsWidth: controlsWidth,
            controlsCount: controlsCount,
            spacing: spacing
        )
        // Narrow host: the field would get less than a usable reading column.
        if inlineWidth < minimumInlineTextWidth { return true }
        // The draft only wraps because the controls took its width.
        if fieldHeightAtInlineWidth > fieldHeightAtFullWidth + multilineHeightTolerance {
            return true
        }
        // Multiline at the widest available slot (the host reports the field
        // scrolls there), so the text still deserves the whole row.
        return isFieldOverflowing || fieldHeightAtFullWidth > 44 + multilineHeightTolerance
    }
}

// MARK: - Responsive composer row (field + natural controls)

/// Marks the one editable field slot inside `ComposerResponsiveRowLayout`.
/// The layout finds the field by this value rather than by declaration
/// index, so optional controls (attachment menu, Expand, Stop) never shift
/// which subview is measured as the text column.
struct ComposerResponsiveFieldSlotKey: LayoutValueKey {
    static let defaultValue = false
}

/// Marks a control that keeps the leading edge when the row reflows. The
/// attachment menu does; every action control (Expand, dictation, continuous
/// voice, Stop, Send) trails on the right, exactly as it does in one row.
struct ComposerResponsiveLeadingControlKey: LayoutValueKey {
    static let defaultValue = false
}

extension View {
    /// Declares this subview as the row's editable text field.
    func composerResponsiveFieldSlot() -> some View {
        layoutValue(key: ComposerResponsiveFieldSlotKey.self, value: true)
    }

    /// Declares this subview as one of the row's leading-edge controls.
    func composerResponsiveLeadingControl() -> some View {
        layoutValue(key: ComposerResponsiveLeadingControlKey.self, value: true)
    }
}

/// One composer input row: the live field and its natural controls, placed
/// side by side while the text keeps a usable column, or field above a
/// controls row when it does not (see `ComposerResponsiveLayoutPolicy`).
///
/// The reflow is pure placement inside ONE `Layout`: the `ComposerReturnField`
/// subview — and therefore its `HardwareReturnTextView`, coordinator, first
/// responder, caret, marked text and undo association — is never re-created,
/// so a Chinese-IME composition or an active keyboard session survives the
/// flip untouched. That is why this row uses neither `ViewThatFits` nor two
/// conditional branches: both would remount the editing surface mid-IME, and
/// choosing per keystroke from a remounting branch would drop focus.
struct ComposerResponsiveRowLayout: Layout {
    /// Gap between adjacent items on one row.
    var spacing: CGFloat = 8
    /// Gap between the field row and the control row when stacked.
    var stackedSpacing: CGFloat = 6
    /// The host's live overflow verdict for the field (it scrolls at its
    /// current width). Stacks the row: the draft is multiline at its widest
    /// available slot too, so the text deserves the whole width.
    var isFieldOverflowing = false

    private struct Plan {
        var isStacked = false
        var width: CGFloat = 0
        var height: CGFloat = 0
        var fieldIndex = 0
        var fieldSize: CGSize = .zero
        var controlIndices: [Int] = []
        var controlSizes: [CGSize] = []
        var maxControlHeight: CGFloat = 0
    }

    private func plan(subviews: Subviews, proposal: ProposedViewSize) -> Plan {
        var plan = Plan()
        guard !subviews.isEmpty else { return plan }
        plan.fieldIndex = subviews.indices.first {
            subviews[$0][ComposerResponsiveFieldSlotKey.self]
        } ?? 0
        plan.controlIndices = subviews.indices.filter { $0 != plan.fieldIndex }
        plan.controlSizes = plan.controlIndices.map { subviews[$0].sizeThatFits(.unspecified) }
        let controlsWidth = plan.controlSizes.reduce(0) { $0 + $1.width }
        plan.maxControlHeight = plan.controlSizes.map(\.height).max() ?? 0
        if let proposedWidth = proposal.width, proposedWidth.isFinite {
            // A zero/one-point proposal is a collapsed host: report an empty
            // row instead of measuring a meaningless 1pt text column.
            guard proposedWidth > 1 else { return plan }
            plan.width = proposedWidth
        } else {
            // Unbounded sizing probe: ask for the natural row (the field's
            // own ideal width plus the controls) rather than a guess. Only
            // this branch pays for the extra ideal-width measurement, so a
            // bounded pass never remeasures the draft a third time.
            let idealField = subviews[plan.fieldIndex].sizeThatFits(.unspecified)
            plan.width = idealField.width + controlsWidth
                + spacing * CGFloat(plan.controlIndices.count)
        }
        let inlineWidth = ComposerResponsiveLayoutPolicy.inlineTextWidth(
            rowWidth: plan.width,
            controlsWidth: controlsWidth,
            controlsCount: plan.controlIndices.count,
            spacing: spacing
        )
        let inlineField = subviews[plan.fieldIndex].sizeThatFits(
            ProposedViewSize(width: inlineWidth, height: nil)
        )
        let fullField = subviews[plan.fieldIndex].sizeThatFits(
            ProposedViewSize(width: plan.width, height: nil)
        )
        plan.isStacked = ComposerResponsiveLayoutPolicy.stacks(
            rowWidth: plan.width,
            controlsWidth: controlsWidth,
            controlsCount: plan.controlIndices.count,
            spacing: spacing,
            fieldHeightAtInlineWidth: inlineField.height,
            fieldHeightAtFullWidth: fullField.height,
            isFieldOverflowing: isFieldOverflowing
        )
        plan.fieldSize = plan.isStacked
            ? CGSize(width: plan.width, height: fullField.height)
            : CGSize(width: inlineWidth, height: inlineField.height)
        plan.height = plan.isStacked
            ? plan.fieldSize.height + stackedSpacing + plan.maxControlHeight
            : max(plan.fieldSize.height, plan.maxControlHeight)
        return plan
    }

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Void
    ) -> CGSize {
        guard !subviews.isEmpty else { return .zero }
        let plan = plan(subviews: subviews, proposal: proposal)
        return CGSize(width: plan.width, height: plan.height)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Void
    ) {
        guard !subviews.isEmpty else { return }
        // Re-plan from the space actually granted (a parent may clamp the
        // proposal) so placement can never use a different mode than sizing.
        let plan = plan(
            subviews: subviews,
            proposal: ProposedViewSize(width: bounds.width, height: bounds.height)
        )
        guard plan.width > 1 else {
            for index in subviews.indices {
                subviews[index].place(
                    at: CGPoint(x: bounds.minX, y: bounds.minY),
                    anchor: .topLeading,
                    proposal: .zero
                )
            }
            return
        }
        if plan.isStacked {
            placeStacked(plan, in: bounds, subviews: subviews)
        } else {
            placeInline(plan, in: bounds, subviews: subviews)
        }
    }

    /// One compact row, bottom-aligned like the historical composer HStack:
    /// attachment, the field taking the remaining width, then the actions.
    private func placeInline(_ plan: Plan, in bounds: CGRect, subviews: Subviews) {
        var x = bounds.minX
        var controlPosition = 0
        for index in subviews.indices {
            let size: CGSize
            if index == plan.fieldIndex {
                size = plan.fieldSize
            } else {
                size = plan.controlSizes[controlPosition]
                controlPosition += 1
            }
            subviews[index].place(
                at: CGPoint(x: x, y: bounds.maxY - size.height),
                anchor: .topLeading,
                proposal: ProposedViewSize(size)
            )
            x += size.width + spacing
        }
    }

    /// Field across the full row, then its controls directly below: leading
    /// group (the attachment menu) on the left edge, every action control
    /// right-aligned in declaration order.
    private func placeStacked(_ plan: Plan, in bounds: CGRect, subviews: Subviews) {
        subviews[plan.fieldIndex].place(
            at: CGPoint(x: bounds.minX, y: bounds.minY),
            anchor: .topLeading,
            proposal: ProposedViewSize(plan.fieldSize)
        )
        let rowTop = bounds.minY + plan.fieldSize.height + stackedSpacing
        // Bottom-align every control inside the control row, so a control
        // that reports a taller accessible frame (Dynamic Type, larger hit
        // target) still shares one visual baseline.
        func place(_ index: Int, size: CGSize, atX x: CGFloat) {
            subviews[index].place(
                at: CGPoint(x: x, y: rowTop + plan.maxControlHeight - size.height),
                anchor: .topLeading,
                proposal: ProposedViewSize(size)
            )
        }
        var leading: [(index: Int, size: CGSize)] = []
        var trailing: [(index: Int, size: CGSize)] = []
        for (position, index) in plan.controlIndices.enumerated() {
            let size = plan.controlSizes[position]
            if subviews[index][ComposerResponsiveLeadingControlKey.self] {
                leading.append((index, size))
            } else {
                trailing.append((index, size))
            }
        }
        var x = bounds.minX
        for control in leading {
            place(control.index, size: control.size, atX: x)
            x += control.size.width + spacing
        }
        var trailingWidth = trailing.reduce(0) { $0 + $1.size.width }
        if trailing.count > 1 { trailingWidth += spacing * CGFloat(trailing.count - 1) }
        x = bounds.maxX - trailingWidth
        for control in trailing {
            place(control.index, size: control.size, atX: x)
            x += control.size.width + spacing
        }
    }
}

/// Host-facing wrapper for `ComposerResponsiveRowLayout`: pass the row's
/// natural controls and exactly one `.composerResponsiveFieldSlot()` field.
struct ComposerResponsiveRow<Content: View>: View {
    var spacing: CGFloat = 8
    var stackedSpacing: CGFloat = 6
    var isFieldOverflowing = false
    var content: Content

    init(
        spacing: CGFloat = 8,
        stackedSpacing: CGFloat = 6,
        isFieldOverflowing: Bool = false,
        @ViewBuilder content: () -> Content
    ) {
        self.spacing = spacing
        self.stackedSpacing = stackedSpacing
        self.isFieldOverflowing = isFieldOverflowing
        self.content = content()
    }

    var body: some View {
        // A custom `Layout` is used as the container itself (its
        // `callAsFunction` builder), which is what gives the subviews stable
        // identities across reflow: the same field subview is re-placed, not
        // re-created, so an active editing session survives.
        ComposerResponsiveRowLayout(
            spacing: spacing,
            stackedSpacing: stackedSpacing,
            isFieldOverflowing: isFieldOverflowing
        ) {
            content
        }
    }
}
