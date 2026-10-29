// FloeApp — Native setup guide shell.
//
// SPDX-License-Identifier: MPL-2.0
//
// One guide, two native shapes: iPad gets the group navigation a wide window
// expects (section list plus detail), iPhone gets the same sections as a
// sequential stack. Every path — each preset and Custom — reaches all ten
// product sections in order and then the summary. Back, Later and the
// per-section Next are available everywhere; leaving the guide keeps the
// position and never needs a working provider.
//
// The guide reuses the app's real editors inside its own stack, so an
// advanced choice opens the SAME form the user would find in Settings and
// returns to the same section. It is deliberately not a list of ten Settings
// links, and not a copy of the Settings dump either.

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import FloeCore

struct OnboardingView: View {
    @StateObject private var guide: SetupGuideModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    init(center: ConversationCenter) {
        _guide = StateObject(wrappedValue: SetupGuideModel(center: center))
    }

    var body: some View {
        Group {
            if horizontalSizeClass == .regular {
                groupedShell
            } else {
                sequentialShell
            }
        }
        // Reused native editors resolve their own dependencies from the
        // environment, so the guide supplies them explicitly instead of
        // asking for a new app-root injection.
        .environmentObject(guide.center.environment)
        .environmentObject(guide.center.environment.ttsSettingsService)
        .environmentObject(guide.center.environment.speechService)
        .environmentObject(guide.center.environment.voiceInput)
        .task { await guide.load() }
        .onDisappear {
            // Unsubscribe only. Service-owned jobs keep running and are
            // visible again on return. A finished guide has nothing to resume,
            // so the teardown never writes a fresh progress record.
            guide.stopObserving()
            guide.exitAndKeepProgress()
        }
        .alert("setup.guide.save_failed", isPresented: Binding(
            get: { guide.saveMessage != nil },
            set: { if !$0 { guide.saveMessage = nil } }
        )) {
            Button("action.done", role: .cancel) { guide.saveMessage = nil }
        } message: {
            Text(guide.saveMessage ?? "")
        }
    }

    // MARK: - iPad: native group navigation

    private var groupedShell: some View {
        NavigationSplitView {
            List(selection: sectionSelection) {
                Section {
                    ForEach(SetupGuideSection.configurable) { section in
                        SetupGuideSectionRow(section: section, model: guide)
                            .tag(section)
                    }
                } header: {
                    Text("setup.guide.sections")
                }
                Section {
                    SetupGuideSectionRow(section: .summary, model: guide)
                        .tag(SetupGuideSection.summary)
                }
            }
            .navigationTitle("more.setup_guide")
            // Exiting is a single decision on the active section. The detail
            // column owns the only Exit control so the sidebar and detail
            // never present two identical dismiss buttons (and two identical
            // accessibility identifiers) at the same time.
        } detail: {
            detailColumn
        }
    }

    private var sectionSelection: Binding<SetupGuideSection?> {
        Binding(
            get: { guide.state.section },
            set: { if let value = $0 { guide.jump(to: value) } }
        )
    }

    private var detailColumn: some View {
        NavigationStack {
            VStack(spacing: 0) {
                SetupGuideProgressHead(model: guide)
                SetupGuideSectionView(section: guide.state.section, model: guide)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityIdentifier("setup.content.\(guide.state.section.rawValue)")
                Divider()
                SetupGuideActionBar(section: guide.state.section, model: guide, dismiss: dismiss)
            }
            .background(FloeTheme.groupedSurface)
            .navigationTitle(Text(LocalizedStringKey(guide.state.section.titleKey)))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    exitButton
                }
            }
        }
    }

    // MARK: - iPhone: sequential navigation

    private var sequentialShell: some View {
        NavigationStack {
            VStack(spacing: 0) {
                SetupGuideProgressHead(model: guide)
                SetupGuideSectionView(section: guide.state.section, model: guide)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityIdentifier("setup.content.\(guide.state.section.rawValue)")
                Divider()
                SetupGuideActionBar(section: guide.state.section, model: guide, dismiss: dismiss)
            }
            .background(FloeTheme.groupedSurface)
            .navigationTitle(Text(LocalizedStringKey(guide.state.section.titleKey)))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    exitButton
                }
            }
        }
    }

    /// Exiting is not failing: the position is already persisted, and the
    /// provider state is untouched.
    private var exitButton: some View {
        Button("setup.exit") {
            guide.exitAndKeepProgress()
            dismiss()
        }
        .accessibilityIdentifier("setup.skip")
    }
}

/// Section row with the honest status chip. A preparing resource never reads
/// as a problem, and an unvisited section never reads as complete.
struct SetupGuideSectionRow: View {
    let section: SetupGuideSection
    @ObservedObject var model: SetupGuideModel

    var body: some View {
        let status = displayedStatus
        HStack(spacing: 10) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(LocalizedStringKey(section.titleKey))
                    if status == .needsAttention {
                        Text("setup.section.attention.hint")
                            .font(FloeTheme.Typography.metadata)
                            .foregroundStyle(FloeTheme.pending)
                    }
                }
            } icon: {
                Image(systemName: section.systemImage)
                    .foregroundStyle(FloeTheme.primary)
            }
            Spacer(minLength: 8)
            SetupGuideStatusChip(status: status)
        }
        .frame(minHeight: FloeTheme.minimumTarget)
        .contentShape(Rectangle())
        // An explicit container keeps the row identity separate from the
        // status chip's identifier. Without containment the row identifier
        // replaces every child's identifier, so a deferred/defaulted status
        // could never be observed independently.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("setup.section.\(section.rawValue)")
    }

    /// The mirrored live job lifts the badge only while work is running;
    /// finishing the job never claims the user configured the section.
    private var displayedStatus: SetupSectionStatus {
        let stored = model.state.status(for: section)
        if section == .summary {
            return model.resources.isAnyPreparing ? .preparing : stored
        }
        return stored
    }
}

struct SetupGuideStatusChip: View {
    let status: SetupSectionStatus

    var body: some View {
        Text(titleKey)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.14), in: Capsule())
            .accessibilityIdentifier("setup.status.\(status.rawValue)")
    }

    private var titleKey: LocalizedStringKey {
        switch status {
        case .unset: "setup.status.unset"
        case .defaulted: "setup.status.defaulted"
        case .configured: "setup.status.configured"
        case .deferred: "setup.status.deferred"
        case .preparing: "setup.status.preparing"
        case .needsAttention: "setup.status.needs_attention"
        }
    }

    private var color: Color {
        switch status {
        case .configured: FloeTheme.success
        case .defaulted: FloeTheme.primary
        case .preparing: FloeTheme.pending
        case .needsAttention: FloeTheme.destructive
        case .deferred, .unset: Color.secondary
        }
    }
}

/// Compact position head. It never claims the guide is finished just because
/// a provider exists.
struct SetupGuideProgressHead: View {
    @ObservedObject var model: SetupGuideModel

    var body: some View {
        VStack(spacing: 6) {
            ProgressView(value: progress, total: 1)
                .tint(FloeTheme.primary)
            HStack {
                Text("setup.progress.position \(positionText)")
                    .font(FloeTheme.Typography.metadata)
                    .foregroundStyle(.secondary)
                Spacer()
                if let preset = model.state.preset {
                    Text(LocalizedStringKey(preset.titleKey))
                        .font(FloeTheme.Typography.metadata)
                        .foregroundStyle(FloeTheme.primary)
                        .accessibilityIdentifier("setup.preset.active")
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, 4)
        // Keep the head itself addressable without replacing the live
        // position and active-preset identifiers on its children.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("setup.progress")
    }

    private var progress: Double {
        let index = SetupGuideSection.allCases.firstIndex(of: model.state.section) ?? 0
        return Double(index + 1) / Double(SetupGuideSection.allCases.count)
    }

    private var positionText: String {
        let index = SetupGuideSection.allCases.firstIndex(of: model.state.section) ?? 0
        return "\(index + 1)/\(SetupGuideSection.allCases.count)"
    }
}

/// Back, Later and Next always coexist. The main action is never disabled by
/// a running download, a failed resource or a missing provider.
struct SetupGuideActionBar: View {
    let section: SetupGuideSection
    @ObservedObject var model: SetupGuideModel
    let dismiss: DismissAction
    @State private var isFinishing = false

    var body: some View {
        HStack(spacing: 12) {
            Button {
                model.back()
            } label: {
                Text("action.back")
            }
            .disabled(!canGoBack)
            .accessibilityIdentifier("setup.back")
            Spacer()
            if section != .summary {
                Button {
                    model.later()
                } label: {
                    Text("setup.later")
                }
                .accessibilityIdentifier("setup.later")
                Button {
                    model.next()
                } label: {
                    Text("setup.next")
                        .frame(minWidth: 72)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("setup.next")
            } else {
                Button {
                    finish()
                } label: {
                    if isFinishing {
                        ProgressView()
                    } else {
                        Text("setup.finish").frame(minWidth: 72)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isFinishing)
                .accessibilityIdentifier("setup.finish")
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(FloeTheme.chromeMaterial)
    }

    private var canGoBack: Bool { model.state.section.previous != nil }

    private func finish() {
        isFinishing = true
        Task {
            // Writing the guide outcome is all Finish waits for. Preparation
            // keeps running in its own services afterwards.
            await model.finish()
            isFinishing = false
            // A failed completion write stays actionable: the guide remains
            // open with the honest message instead of pretending it finished.
            if model.didFinish { dismiss() }
        }
    }
}
#endif
