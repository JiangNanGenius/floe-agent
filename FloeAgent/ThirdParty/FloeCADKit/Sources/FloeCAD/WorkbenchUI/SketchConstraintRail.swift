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
    private let common: [Action] = [
        .init(title: "Coincident", kind: .coincident, prerequisite: "Select two points, a point and line, or meeting lines"),
        .init(title: "Horizontal", kind: .horizontal, prerequisite: "Select lines or two points"),
        .init(title: "Vertical", kind: .vertical, prerequisite: "Select lines or two points"),
        .init(title: "Parallel", kind: .parallel, prerequisite: "Select two or more lines"),
        .init(title: "Perpendicular", kind: .perpendicular, prerequisite: "Select two lines"),
        .init(title: "Tangent", kind: .tangent, prerequisite: "Select a line and circle/arc, or two circles"),
        .init(title: "Lock", kind: .fixed, prerequisite: "Select geometry or a point")
    ]
    private let more: [Action] = [
        .init(title: "Equal Length", kind: .equalLength, prerequisite: "Select two lines"),
        .init(title: "Equal Radius", kind: .equalRadius, prerequisite: "Select two circular entities"),
        .init(title: "Concentric", kind: .concentric, prerequisite: "Select two circular entities"),
        .init(title: "Midpoint", kind: .midpoint, prerequisite: "Select one point and one line"),
        .init(title: "Symmetric", kind: .symmetric, prerequisite: "Select two lines or circles, or two points and an axis line"),
        .init(title: "Collinear", kind: .colinear, prerequisite: "Select two lines")
    ]

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
                Text("Constraints").font(.caption.weight(.semibold))
                Spacer()
                Button { viewModel.showConstraintSettings = true } label: {
                    Image(systemName: "gearshape").frame(width: 44, height: 44)
                }
                .accessibilityLabel("Constraint Settings")
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
            Button("Disconnect") { viewModel.disconnectSketchSelection() }
                .font(.caption.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .disabled(!viewModel.canDisconnectSketchSelection)
                .accessibilityIdentifier("ConstraintRailDisconnect")
            Divider()
            Menu {
                ForEach(more) { menuAction($0) }
            } label: {
                Label("More", systemImage: "ellipsis").frame(maxWidth: .infinity, alignment: .leading)
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
            Button("Disconnect") { viewModel.disconnectSketchSelection() }
                .disabled(!viewModel.canDisconnectSketchSelection)
                .accessibilityIdentifier("ConstraintRailDisconnect")
            Divider()
            Button("Constraint Settings") { viewModel.showConstraintSettings = true }
        } label: {
            Label("Constraints", systemImage: "link")
                .labelStyle(.iconOnly).frame(width: 44, height: 44)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        }
        .accessibilityIdentifier("ConstraintRailMenu")
    }

    private func title(_ action: Action) -> String {
        action.kind == .fixed && viewModel.canUnlockSketchSelection ? "Unlock" : action.title
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
