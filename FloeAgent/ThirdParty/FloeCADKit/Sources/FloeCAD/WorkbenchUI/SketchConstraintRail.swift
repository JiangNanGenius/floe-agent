import SwiftUI

/// Common sketch relationships stay visible independently of drawing tools.
/// Compact windows retain the same actions in a single reachable menu.
struct SketchConstraintRail: View {
    @Bindable var viewModel: EditorViewModel
    @Environment(\.horizontalSizeClass) private var sizeClass

    private struct Action: Identifiable {
        var title: String
        var kind: SketchConstraintKind
        var prerequisite: String
        var id: String { kind.rawValue }
    }
    private var common: [Action] { [
        .init(title: FloeCADStrings.text("cad.ui.constraint.coincident", "Coincident"), kind: .coincident, prerequisite: FloeCADStrings.text("cad.ui.constraint.hint.pointsOrMeetingLines", "Select two points, a point and line, or meeting lines")),
        .init(title: FloeCADStrings.text("cad.ui.constraint.horizontal", "Horizontal"), kind: .horizontal, prerequisite: FloeCADStrings.text("cad.ui.constraint.hint.linesOrPoints", "Select lines or two points")),
        .init(title: FloeCADStrings.text("cad.ui.constraint.vertical", "Vertical"), kind: .vertical, prerequisite: FloeCADStrings.text("cad.ui.constraint.hint.linesOrPoints", "Select lines or two points")),
        .init(title: FloeCADStrings.text("cad.ui.constraint.parallel", "Parallel"), kind: .parallel, prerequisite: FloeCADStrings.text("cad.ui.constraint.hint.twoOrMoreLines", "Select two or more lines")),
        .init(title: FloeCADStrings.text("cad.ui.constraint.perpendicular", "Perpendicular"), kind: .perpendicular, prerequisite: FloeCADStrings.text("cad.ui.constraint.hint.twoLines", "Select two lines")),
        .init(title: FloeCADStrings.text("cad.ui.constraint.tangent", "Tangent"), kind: .tangent, prerequisite: FloeCADStrings.text("cad.ui.constraint.hint.lineAndCircleOrTwoCircles", "Select a line and circle/arc, or two circles")),
        .init(title: FloeCADStrings.text("cad.ui.constraint.lock", "Lock"), kind: .fixed, prerequisite: FloeCADStrings.text("cad.ui.constraint.hint.geometryOrPoint", "Select geometry or a point"))
    ] }
    private var more: [Action] { [
        .init(title: FloeCADStrings.text("cad.ui.constraint.equalLength", "Equal Length"), kind: .equalLength, prerequisite: FloeCADStrings.text("cad.ui.constraint.hint.twoLines", "Select two lines")),
        .init(title: FloeCADStrings.text("cad.ui.constraint.equalRadius", "Equal Radius"), kind: .equalRadius, prerequisite: FloeCADStrings.text("cad.ui.constraint.hint.twoCircularEntities", "Select two circular entities")),
        .init(title: FloeCADStrings.text("cad.ui.constraint.concentric", "Concentric"), kind: .concentric, prerequisite: FloeCADStrings.text("cad.ui.constraint.hint.twoCircularEntities", "Select two circular entities")),
        .init(title: FloeCADStrings.text("cad.ui.constraint.midpoint", "Midpoint"), kind: .midpoint, prerequisite: FloeCADStrings.text("cad.ui.constraint.hint.pointAndLine", "Select one point and one line")),
        .init(title: FloeCADStrings.text("cad.ui.constraint.symmetric", "Symmetric"), kind: .symmetric, prerequisite: FloeCADStrings.text("cad.ui.constraint.hint.symmetric", "Select two lines or circles, or two points and an axis line")),
        .init(title: FloeCADStrings.text("cad.ui.constraint.colinear", "Collinear"), kind: .colinear, prerequisite: FloeCADStrings.text("cad.ui.constraint.hint.twoLines", "Select two lines"))
    ] }

    var body: some View {
        if sizeClass == .compact {
            compactMenu
        } else {
            ViewThatFits(in: .vertical) {
                expandedRail
                compactMenu
            }
        }
    }

    private var expandedRail: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(FloeCADStrings.text("cad.ui.items.constraints", "Constraints")).font(.caption.weight(.semibold))
                Spacer()
                Button { viewModel.showConstraintSettings = true } label: {
                    Image(systemName: "gearshape").frame(width: 44, height: 44)
                }
                .accessibilityLabel(FloeCADStrings.text("cad.ui.constraint.settings", "Constraint Settings"))
                .accessibilityIdentifier("ConstraintRailSettings")
            }
            ForEach(common) { action in
                Button { perform(action) } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title(action)).font(.caption.weight(.semibold))
                        if !viewModel.canApplyConstraint(action.kind) {
                            Text(action.prerequisite).font(.caption2).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
                    .padding(.vertical, 7)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!viewModel.canApplyConstraint(action.kind))
                .accessibilityIdentifier("ConstraintRail-" + action.id)
                .accessibilityHint(action.prerequisite)
                .help(action.prerequisite)
            }
            Button(FloeCADStrings.text("cad.ui.constraint.disconnect", "Disconnect")) { viewModel.disconnectSketchSelection() }
                .font(.caption.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .disabled(!viewModel.canDisconnectSketchSelection)
                .accessibilityIdentifier("ConstraintRailDisconnect")
            Divider()
            Menu {
                ForEach(more) { menuAction($0) }
            } label: {
                Label(FloeCADStrings.text("cad.ui.common.more", "More"), systemImage: "ellipsis").frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            }
            .accessibilityIdentifier("ConstraintRailMore")
        }
        .padding(10)
        .frame(width: 156)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private var compactMenu: some View {
        Menu {
            ForEach(common + more) { menuAction($0) }
            Button(FloeCADStrings.text("cad.ui.constraint.disconnect", "Disconnect")) { viewModel.disconnectSketchSelection() }
                .disabled(!viewModel.canDisconnectSketchSelection)
                .accessibilityIdentifier("ConstraintRailDisconnect")
            Divider()
            Button(FloeCADStrings.text("cad.ui.constraint.settings", "Constraint Settings")) { viewModel.showConstraintSettings = true }
        } label: {
            Label(FloeCADStrings.text("cad.ui.items.constraints", "Constraints"), systemImage: "link")
                .labelStyle(.iconOnly).frame(width: 44, height: 44)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        }
        .accessibilityIdentifier("ConstraintRailMenu")
    }

    private func title(_ action: Action) -> String {
        action.kind == .fixed && viewModel.canUnlockSketchSelection ? FloeCADStrings.text("cad.input.unlock", "Unlock") : action.title
    }

    private func perform(_ action: Action) {
        if action.kind == .fixed { viewModel.toggleSketchSelectionLock() }
        else { viewModel.applyConstraint(action.kind) }
    }

    private func menuAction(_ action: Action) -> some View {
        Button(title(action)) { perform(action) }
            .disabled(!viewModel.canApplyConstraint(action.kind))
            .accessibilityHint(action.prerequisite)
    }
}
