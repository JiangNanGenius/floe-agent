// SPDX-License-Identifier: MPL-2.0
import SwiftUI
import FloeGameDeveloperCore
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Compact, native development menu. It presents only the typed service; it
/// owns no player, file, Git or environment service. The host decides whether
/// to show it as a sheet, popover or narrow iPad side panel.
@MainActor
public struct GameDeveloperMenuView: View {
    @ObservedObject private var session: GameDeveloperSession
    @StateObject private var model: GameDeveloperMenuModel
    private let strings: GameDeveloperStrings

    public init(session: GameDeveloperSession,
                locale: GameDeveloperLocale = .automatic) {
        self.session = session
        self.strings = GameDeveloperStrings(locale: locale)
        _model = StateObject(wrappedValue: GameDeveloperMenuModel(session: session, locale: locale))
    }

    public var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                header
                if let error = model.errorText {
                    errorBanner(error)
                }
                if let success = model.successText {
                    successBanner(success)
                }
                if session.phase.isReady {
                    quickControls
                    searchField
                }
                stateSection
                actionsSection
                checkpointsSection
                historySection
                diagnosticsSection
                planSection
            }
            .padding(16)
        }
        .background(Color.floeDeveloperPanel)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("developer.menu")
        .task {
            if session.canAttach { try? await session.attach() }
            while !Task.isCancelled {
                if session.phase.isReady { await session.refresh() }
                try? await Task.sleep(for: .seconds(1))
            }
        }
        .confirmationDialog(
            strings.confirmAction,
            isPresented: Binding(
                get: { model.pendingConfirmation != nil },
                set: { if !$0 { model.cancelPendingAction() } }),
            titleVisibility: .visible
        ) {
            Button(strings.confirm, role: .destructive) { model.confirmPendingAction() }
                .accessibilityIdentifier("developer.menu.confirm")
            Button(strings.cancel, role: .cancel) { model.cancelPendingAction() }
                .accessibilityIdentifier("developer.menu.cancel")
        } message: {
            if let pending = model.pendingConfirmation {
                Text(strings.detail(pending.action) ?? strings.destructive)
            }
        }
        .confirmationDialog(
            strings.resetTitle,
            isPresented: $model.showResetConfirmation,
            titleVisibility: .visible
        ) {
            Button(strings.resetBaseline) { model.reset(scope: .baseline) }
                .accessibilityIdentifier("developer.menu.reset.baseline")
            Button(strings.resetRestart, role: .destructive) { model.reset(scope: .restart) }
                .accessibilityIdentifier("developer.menu.reset.restart")
            Button(strings.cancel, role: .cancel) {}
                .accessibilityIdentifier("developer.menu.reset.cancel")
        } message: {
            Text(strings.resetMessage)
        }
        .sheet(item: $model.actionSheet) { action in
            GameDeveloperActionSheet(model: model, action: action, strings: strings)
        }
        .sheet(isPresented: Binding(
            get: { model.screenshot != nil },
            set: { if !$0 { model.screenshot = nil } })) {
            GameDeveloperScreenshotSheet(data: model.screenshot ?? Data(), strings: strings)
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(strings.title)
                        .font(.title3.weight(.semibold))
                    Text(strings.engineName(session.descriptor))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                GameDeveloperStatusBadge(phase: session.phase, strings: strings)
            }
            HStack(spacing: 8) {
                Text(session.attachment?.runtime ?? session.capabilities?.runtime ?? session.descriptor.route.rawValue)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if session.canAttach {
                    Button(strings.attach) { model.connect() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("developer.menu.connect")
                }
            }
            if let limitation = session.snapshotLimitation {
                Label(limitation, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func errorBanner(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(text)
                .font(.caption)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(strings.clearError) { model.dismissError() }
                .font(.caption)
                .buttonStyle(.borderless)
                .frame(minHeight: 44)
        }
        .padding(12)
        .background(Color.floeDeveloperWarning, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("developer.menu.error")
    }

    private func successBanner(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Text(text)
                .font(.caption)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(strings.close) { model.dismissStatus() }
                .font(.caption)
                .buttonStyle(.borderless)
                .frame(minHeight: 44)
        }
        .padding(12)
        .background(Color.floeDeveloperSuccess, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("developer.menu.status")
    }

    // MARK: - Quick controls

    private var quickControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            GameDeveloperSectionHeader(title: strings.quickControls, symbol: "bolt.fill")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    if let pause = model.quickAction("engine.pause"), session.supports?.pause != false {
                        GameDeveloperQuickButton(
                            title: strings.paused, symbol: "pause.fill",
                            identifier: "developer.menu.quick.pause",
                            disabled: model.isBusy) { model.perform(pause) }
                    }
                    if let resume = model.quickAction("engine.resume"), session.supports?.resume != false {
                        GameDeveloperQuickButton(
                            title: strings.resume, symbol: "play.fill",
                            identifier: "developer.menu.quick.resume",
                            disabled: model.isBusy) { model.perform(resume) }
                    }
                    if let speed = model.speedField {
                        Menu {
                            ForEach([0.25, 0.5, 1.0, 2.0, 4.0], id: \.self) { value in
                                Button(String(format: "%.2g×", value)) { model.setSpeed(value) }
                            }
                        } label: {
                            GameDeveloperQuickLabel(title: strings.speed, symbol: "gauge.with.dots.needle.67percent")
                        }
                        .frame(minHeight: 44)
                        .disabled(model.isBusy)
                        .accessibilityIdentifier("developer.menu.quick.speed")
                        .accessibilityValue(model.currentValue(speed)?.displayText ?? "")
                    }
                    if session.supports?.snapshot == true ||
                        session.fields.contains(where: { !$0.isReadOnly && !$0.kind.isReadOnly }) {
                        GameDeveloperQuickButton(
                            title: strings.checkpoint, symbol: "bookmark.fill",
                            identifier: "developer.menu.quick.checkpoint",
                            disabled: model.isBusy) { model.createCheckpoint() }
                    }
                    if session.supports?.screenshot != false {
                        GameDeveloperQuickButton(
                            title: strings.screenshot, symbol: "camera.fill",
                            identifier: "developer.menu.quick.screenshot",
                            disabled: model.isBusy) { model.takeScreenshot() }
                    }
                    if let resetSupport = session.supports?.reset, resetSupport != .none {
                        GameDeveloperQuickButton(
                            title: strings.reset, symbol: "arrow.counterclockwise",
                            identifier: "developer.menu.quick.reset",
                            disabled: model.isBusy, role: .destructive) {
                                model.showResetConfirmation = true
                            }
                    }
                }
                .padding(.vertical, 2)
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("developer.menu.quick")
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(strings.search, text: $model.searchText)
                .textFieldStyle(.plain)
                .accessibilityIdentifier("developer.menu.search")
            if !model.searchText.isEmpty {
                Button {
                    model.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 44)
        .background(Color.floeDeveloperRow, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: - State

    private var stateSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            GameDeveloperSectionHeader(
                title: strings.state,
                symbol: "slider.horizontal.3",
                count: model.filteredFields.count)
            if !session.phase.isReady {
                Text(strings.attachHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if model.filteredFields.isEmpty {
                Text(model.searchText.isEmpty ? strings.noFields : strings.noSearchResults)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.fieldGroups(model.filteredFields), id: \.name) { group in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(group.name)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)
                        ForEach(group.fields) { field in
                            GameDeveloperFieldRow(model: model, field: field, strings: strings)
                        }
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("developer.menu.fields")
    }

    // MARK: - Actions

    private var actionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            GameDeveloperSectionHeader(
                title: strings.actions,
                symbol: "wrench.and.screwdriver.fill",
                count: model.filteredActions.count)
            if !session.phase.isReady {
                EmptyView()
            } else if model.filteredActions.isEmpty {
                Text(model.searchText.isEmpty ? strings.noActions : strings.noSearchResults)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.actionGroups(model.filteredActions), id: \.name) { group in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(group.name)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)
                        ForEach(group.actions) { action in
                            GameDeveloperActionRow(model: model, action: action, strings: strings)
                        }
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("developer.menu.actions")
    }

    // MARK: - Checkpoints

    private var checkpointsSection: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 6) {
                if session.checkpoints.isEmpty {
                    Text(strings.noCheckpoints)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(session.checkpoints.reversed())) { checkpoint in
                        GameDeveloperCheckpointRow(model: model, checkpoint: checkpoint, strings: strings)
                    }
                }
                Text(strings.checkpointsInMemory)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.top, 6)
        } label: {
            GameDeveloperSectionHeader(
                title: strings.checkpoints,
                symbol: "bookmark",
                count: session.checkpoints.count)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("developer.menu.checkpoints")
    }

    // MARK: - History

    private var historySection: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 6) {
                if session.history.isEmpty {
                    Text(strings.noHistory)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(session.history) { entry in
                        GameDeveloperHistoryRow(entry: entry, strings: strings)
                    }
                }
            }
            .padding(.top, 6)
        } label: {
            GameDeveloperSectionHeader(
                title: strings.history, symbol: "clock.arrow.circlepath",
                count: session.history.count)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("developer.menu.history")
    }

    // MARK: - Diagnostics

    private var diagnosticsSection: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 6) {
                let diagnostics = session.diagnostics
                GameDeveloperDiagnosticRow(label: strings.fps, value: diagnostics.fps.map { String(format: "%.1f", $0) } ?? "—")
                GameDeveloperDiagnosticRow(label: strings.frames, value: diagnostics.frames.map(String.init) ?? "—")
                GameDeveloperDiagnosticRow(label: strings.viewport, value: diagnostics.viewportWidth.flatMap { width in
                    diagnostics.viewportHeight.map { "\(width) × \($0)" }
                } ?? "—")
                GameDeveloperDiagnosticRow(label: strings.canvases, value: diagnostics.canvases.map(String.init) ?? "—")
                GameDeveloperDiagnosticRow(label: strings.webAssembly, value: diagnostics.webAssembly.map { $0 ? "yes" : "no" } ?? "—")
                ForEach(model.diagnosticFields.filter {
                    ["page.title", "page.visibility", "page.readyState", "runtime.uptime"].contains($0.id)
                }) { field in
                    GameDeveloperDiagnosticRow(label: strings.fieldLabel(field),
                                               value: model.currentValue(field)?.displayText ?? "—")
                }
                if !diagnostics.details.isEmpty {
                    ForEach(diagnostics.details.keys.sorted(), id: \.self) { key in
                        GameDeveloperDiagnosticRow(label: key, value: diagnostics.details[key] ?? "")
                    }
                }
                if !session.logs.isEmpty {
                    Divider()
                    Text(strings.logs).font(.caption.weight(.semibold))
                    ForEach(Array(session.logs.suffix(20).enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    }
                }
            }
            .padding(.top, 6)
        } label: {
            GameDeveloperSectionHeader(title: strings.diagnostics, symbol: "stethoscope")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("developer.menu.diagnostics")
    }

    // MARK: - Instrumentation plan

    private var planSection: some View {
        DisclosureGroup {
            let plan = session.descriptor.instrumentation
            VStack(alignment: .leading, spacing: 8) {
                Text(strings.planSummary(plan))
                    .font(.caption)
                if !plan.files.isEmpty {
                    Text(strings.details)
                        .font(.caption.weight(.semibold))
                    ForEach(plan.files) { file in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(file.path).font(.caption2.monospaced())
                            Text(strings.locale.isChinese ? file.purposeZhHans : file.purpose)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                if !plan.steps.isEmpty {
                    Text(strings.details)
                        .font(.caption.weight(.semibold))
                    ForEach(Array(strings.planSteps(plan).enumerated()), id: \.offset) { index, step in
                        Text("\(index + 1). \(step)")
                            .font(.caption2)
                    }
                }
                Text(strings.planLimitations(plan))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if !plan.officialDocumentation.isEmpty {
                    ForEach(plan.officialDocumentation, id: \.self) { link in
                        Text(link)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.tertiary)
                            .textSelection(.enabled)
                    }
                }
            }
            .padding(.top, 6)
        } label: {
            GameDeveloperSectionHeader(title: strings.instrumentation, symbol: "doc.text.magnifyingglass")
        }
    }
}

// MARK: - Panel

@MainActor
public struct GameDeveloperMenuPanel: View {
    @ObservedObject private var session: GameDeveloperSession
    private let locale: GameDeveloperLocale

    public init(session: GameDeveloperSession,
                locale: GameDeveloperLocale = .automatic) {
        self.session = session
        self.locale = locale
    }

    public var body: some View {
        GameDeveloperMenuView(session: session, locale: locale)
            .frame(minWidth: 300, idealWidth: 380)
    }
}

// MARK: - Small components

private struct GameDeveloperStatusBadge: View {
    let phase: GameDeveloperSessionPhase
    let strings: GameDeveloperStrings

    var body: some View {
        Text(strings.phase(phase))
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.16), in: Capsule())
            .foregroundStyle(color)
            .lineLimit(1)
    }

    private var color: Color {
        switch phase {
        case .ready: return .green
        case .attaching, .reloading: return .orange
        case .failed: return .red
        case .idle, .detached: return .secondary
        }
    }
}

private struct GameDeveloperSectionHeader: View {
    let title: String
    let symbol: String
    var count: Int? = nil

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.subheadline.weight(.semibold))
            if let count {
                Text(String(count))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.floeDeveloperRow, in: Capsule())
            }
            Spacer(minLength: 0)
        }
    }
}

private struct GameDeveloperQuickLabel: View {
    let title: String
    let symbol: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
            Text(title).lineLimit(1)
        }
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 12)
        .frame(minHeight: 44)
        .background(Color.floeDeveloperRow, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct GameDeveloperQuickButton: View {
    let title: String
    let symbol: String
    var identifier: String? = nil
    var disabled = false
    var role: ButtonRole? = nil
    let action: () -> Void

    var body: some View {
        Button(role: role) {
            action()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                Text(title).lineLimit(1)
            }
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 12)
            .frame(minHeight: 44)
            .background(Color.floeDeveloperRow, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .foregroundStyle(role == .destructive ? Color.red : Color.primary)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .accessibilityIdentifier(identifier ?? "developer.menu.quick.unknown")
    }
}

private struct GameDeveloperFieldRow: View {
    @ObservedObject var model: GameDeveloperMenuModel
    let field: GameDeveloperFieldDescriptor
    let strings: GameDeveloperStrings

    @State private var draft = ""
    @State private var localError: String?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let symbol = field.symbol {
                    Image(systemName: symbol)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 16)
                }
                Text(strings.fieldLabel(field))
                    .font(.callout)
                    .lineLimit(2)
                Spacer(minLength: 6)
                editor
            }
            if let localError {
                Text(localError)
                    .font(.caption2)
                    .foregroundStyle(.red)
            } else if let detail = strings.detail(field) {
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(minHeight: 44)
        .background(Color.floeDeveloperRow, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("developer.field.\(field.id)")
        .onAppear { draft = valueText }
        .onChange(of: sessionRevision) { _, _ in
            if !focused { draft = valueText }
        }
    }

    private var sessionRevision: Int {
        model.session.state?.revision ?? -1
    }

    @ViewBuilder
    private var editor: some View {
        if field.isReadOnly || field.kind.isReadOnly {
            Text(valueText)
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .textSelection(.enabled)
                .accessibilityValue(valueText)
        } else {
            switch field.kind {
            case .boolean:
                Toggle("", isOn: Binding(
                    get: { model.currentValue(field)?.booleanValue ?? false },
                    set: { model.write(field: field, value: .boolean($0)) }))
                    .labelsHidden()
                    .frame(minWidth: 44, minHeight: 44)
                    .disabled(model.isBusy)
            case .choice:
                Menu {
                    ForEach(field.options) { option in
                        Button(strings.optionLabel(option)) {
                            model.write(field: field, value: .text(option.value))
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(currentChoiceLabel)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption2)
                    }
                    .font(.callout)
                    .frame(minHeight: 44)
                }
                .disabled(model.isBusy)
            case .integer, .number, .text:
                HStack(spacing: 6) {
                    TextField(valuePlaceholder, text: $draft)
                        .textFieldStyle(.roundedBorder)
                        .focused($focused)
                        .accessibilityIdentifier("developer.field.\(field.id).input")
                        .onSubmit { commit() }
                        .floeNumericKeyboard(field.kind == .integer || field.kind == .number)
                        .frame(minWidth: 84)
                        .disabled(model.isBusy)
                    if draft != valueText, !draft.isEmpty {
                        Button {
                            commit()
                        } label: {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.tint)
                                .frame(width: 44, height: 44)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(strings.apply)
                        .accessibilityIdentifier("developer.field.\(field.id).apply")
                    }
                }
                .onChange(of: focused) { _, isFocused in
                    if !isFocused, !model.isBusy, draft != valueText { commit() }
                }
            default:
                Text(valueText).font(.callout.monospacedDigit())
            }
        }
    }

    private var valueText: String {
        guard let value = model.currentValue(field) else { return "—" }
        guard (try? GameDeveloperWire.validate(value: value, against: field,
                                               limits: model.session.limits)) != nil else {
            return "—"
        }
        if field.kind == .number || field.kind == .readOnlyNumber {
            return String(format: "%.6g", value.numberValue ?? 0)
        }
        return value.displayText
    }

    private var valuePlaceholder: String {
        switch field.kind {
        case .integer: return "0"
        case .number: return "0"
        default: return field.label
        }
    }

    private var currentChoiceLabel: String {
        guard let value = model.currentValue(field)?.textValue,
              let option = field.options.first(where: { $0.value == value }) else {
            return valueText
        }
        return strings.optionLabel(option)
    }

    private func commit() {
        guard !model.isBusy else { return }
        guard let value = model.parse(draft, field: field) else {
            localError = strings.invalidValue
            return
        }
        localError = nil
        model.write(field: field, value: value)
    }
}

private struct GameDeveloperActionRow: View {
    @ObservedObject var model: GameDeveloperMenuModel
    let action: GameDeveloperActionDescriptor
    let strings: GameDeveloperStrings

    var body: some View {
        Button {
            model.perform(action)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: action.symbol ?? symbol)
                    .font(.callout)
                    .foregroundStyle(tint)
                    .frame(width: 22, height: 22)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(strings.actionLabel(action))
                            .font(.callout.weight(.medium))
                            .foregroundStyle(.primary)
                        if !action.parameters.isEmpty {
                            Text(String(action.parameters.count))
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 5)
                                .background(Color.floeDeveloperPanel, in: Capsule())
                        }
                        if action.confirmation == .required {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        }
                    }
                    if let detail = strings.detail(action) {
                        Text(detail)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(10)
            .frame(minHeight: 44)
            .background(Color.floeDeveloperRow, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(model.isBusy)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("developer.action.\(action.id)")
    }

    private var tint: Color {
        switch action.role {
        case .destructive: return .red
        case .jump: return .blue
        case .safe: return .accentColor
        }
    }

    private var symbol: String {
        switch action.role {
        case .destructive: return "exclamationmark.octagon"
        case .jump: return "arrow.right.to.line"
        case .safe: return "play.circle"
        }
    }
}

private struct GameDeveloperActionSheet: View {
    @ObservedObject var model: GameDeveloperMenuModel
    let action: GameDeveloperActionDescriptor
    let strings: GameDeveloperStrings
    @Environment(\.dismiss) private var dismiss

    @State private var values: [String: GameDeveloperValue]
    @State private var text: [String: String] = [:]
    @State private var errorText: String?

    init(model: GameDeveloperMenuModel,
         action: GameDeveloperActionDescriptor,
         strings: GameDeveloperStrings) {
        self.model = model
        self.action = action
        self.strings = strings
        var initial: [String: GameDeveloperValue] = [:]
        for parameter in action.parameters {
            if let value = parameter.defaultValue { initial[parameter.id] = value }
        }
        _values = State(initialValue: initial)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let detail = strings.detail(action) {
                        Text(detail).font(.callout).foregroundStyle(.secondary)
                    }
                    if action.confirmation == .required {
                        Label(strings.destructive, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    ForEach(action.parameters) { parameter in
                        GameDeveloperParameterRow(parameter: parameter,
                                                  value: binding(for: parameter),
                                                  strings: strings)
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("developer.action.\(action.id).parameter.\(parameter.id)")
                    }
                    if let errorText {
                        Text(errorText).font(.caption).foregroundStyle(.red)
                    }
                }
                .padding(16)
            }
            .navigationTitle(strings.parameters)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(strings.cancel) { dismiss() }
                        .accessibilityIdentifier("developer.action.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(strings.apply) {
                        submit()
                    }
                    .disabled(!isComplete)
                    .accessibilityIdentifier("developer.action.apply")
                }
            }
        }
    }

    private var isComplete: Bool {
        action.parameters.allSatisfy { parameter in
            !parameter.isRequired || values[parameter.id] != nil
        }
    }

    private func binding(for parameter: GameDeveloperActionParameterDescriptor) -> Binding<GameDeveloperValue?> {
        Binding(
            get: { values[parameter.id] },
            set: { newValue in
                values[parameter.id] = newValue
                errorText = nil
            })
    }

    private func submit() {
        guard !model.isBusy else { return }
        for parameter in action.parameters where parameter.isRequired {
            guard values[parameter.id] != nil else {
                errorText = strings.required + " · " + strings.parameterLabel(parameter)
                return
            }
        }
        model.submit(action: action, arguments: values)
        dismiss()
    }
}

private struct GameDeveloperParameterRow: View {
    let parameter: GameDeveloperActionParameterDescriptor
    @Binding var value: GameDeveloperValue?
    let strings: GameDeveloperStrings
    @State private var draft: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(strings.parameterLabel(parameter))
                    .font(.callout.weight(.medium))
                if parameter.isRequired {
                    Text(strings.required)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            switch parameter.kind {
            case .boolean:
                Toggle("", isOn: Binding(
                    get: { value?.booleanValue ?? false },
                    set: { value = .boolean($0) }))
                    .labelsHidden()
                    .frame(minWidth: 44, minHeight: 44)
            case .choice:
                Menu {
                    ForEach(parameter.options) { option in
                        Button(strings.optionLabel(option)) { value = .text(option.value) }
                    }
                } label: {
                    HStack {
                        Text(currentChoice)
                        Spacer()
                        Image(systemName: "chevron.up.chevron.down")
                    }
                    .frame(minHeight: 44)
                }
            case .integer, .number, .text:
                TextField(placeholder, text: Binding(
                    get: { draft },
                    set: { draft = $0; parse($0) }))
                    .textFieldStyle(.roundedBorder)
                    .frame(minHeight: 44)
                    .floeNumericKeyboard(parameter.kind == .integer || parameter.kind == .number)
                    .onAppear { draft = initialText }
            default:
                EmptyView()
            }
            if let detail = strings.detail(parameter) {
                Text(detail).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(Color.floeDeveloperRow, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var initialText: String {
        value?.displayText ?? ""
    }

    private var placeholder: String {
        switch parameter.kind {
        case .integer, .number: return "0"
        default: return parameter.label
        }
    }

    private var currentChoice: String {
        guard let text = value?.textValue,
              let option = parameter.options.first(where: { $0.value == text }) else {
            return value?.displayText ?? parameter.label
        }
        return strings.optionLabel(option)
    }

    private func parse(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let parsed: GameDeveloperValue
            switch parameter.kind {
            case .integer:
                guard let number = Int(trimmed) else { value = nil; return }
                parsed = .integer(number)
            case .number:
                guard let number = Double(trimmed), number.isFinite else { value = nil; return }
                parsed = .number(number)
            default:
                parsed = .text(trimmed)
            }
            try GameDeveloperWire.validate(value: parsed, against: parameter,
                                           limits: .default)
            value = parsed
        } catch {
            value = nil
        }
    }
}

private struct GameDeveloperCheckpointRow: View {
    @ObservedObject var model: GameDeveloperMenuModel
    let checkpoint: GameDeveloperCheckpoint
    let strings: GameDeveloperStrings

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: checkpoint.isComplete ? "bookmark.fill" : "bookmark")
                .foregroundStyle(checkpoint.kind == .baseline ? .blue : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.locale.isChinese ? checkpoint.labelZhHans : checkpoint.label)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                Text(checkpoint.createdAt, style: .time)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                Text(checkpoint.isComplete ? strings.completeSnapshot : strings.fieldsOnly)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Button(strings.revert) { model.revert(to: checkpoint) }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .frame(minHeight: 44)
                .disabled(model.isBusy)
                .accessibilityIdentifier("developer.checkpoint.\(checkpoint.id.uuidString).revert")
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("developer.checkpoint.\(checkpoint.id.uuidString)")
    }
}

private struct GameDeveloperHistoryRow: View {
    let entry: GameDeveloperHistoryEntry
    let strings: GameDeveloperStrings

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(color)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(strings.locale.isChinese ? entry.labelZhHans : entry.label)
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(entry.at, style: .time)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                Text(strings.locale.isChinese ? entry.messageZhHans : entry.message)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }

    private var icon: String {
        switch entry.status {
        case .applied: return "checkmark.circle.fill"
        case .rejected: return "xmark.octagon.fill"
        case .unsupported: return "minus.circle"
        case .reloading: return "arrow.clockwise.circle"
        }
    }

    private var color: Color {
        switch entry.status {
        case .applied: return .green
        case .rejected: return .red
        case .unsupported: return .secondary
        case .reloading: return .orange
        }
    }
}

private struct GameDeveloperDiagnosticRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(value)
                .font(.caption.monospacedDigit())
                .lineLimit(2)
                .multilineTextAlignment(.trailing)
        }
    }
}

private struct GameDeveloperScreenshotSheet: View {
    let data: Data
    let strings: GameDeveloperStrings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack {
                if let image = platformImage {
                    image
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ContentUnavailableView(strings.screenshotTitle,
                                           systemImage: "camera")
                }
            }
            .padding(16)
            .navigationTitle(strings.screenshotTitle)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(strings.close) { dismiss() }
                }
            }
        }
    }

    private var platformImage: Image? {
        #if os(iOS)
        if let image = UIImage(data: data) { return Image(uiImage: image) }
        #elseif os(macOS)
        if let image = NSImage(data: data) { return Image(nsImage: image) }
        #endif
        return nil
    }
}

private extension Bool? {
    var isFalse: Bool { self == false }
}

private extension View {
    @ViewBuilder
    func floeNumericKeyboard(_ numeric: Bool) -> some View {
        #if os(iOS)
        if numeric {
            keyboardType(.numbersAndPunctuation)
        } else {
            self
        }
        #else
        self
        #endif
    }
}

private extension Color {
    static var floeDeveloperPanel: Color {
        #if os(iOS)
        Color(uiColor: .systemGroupedBackground)
        #else
        Color(nsColor: .windowBackgroundColor)
        #endif
    }

    static var floeDeveloperRow: Color {
        #if os(iOS)
        Color(uiColor: .secondarySystemGroupedBackground)
        #else
        Color(nsColor: .controlBackgroundColor)
        #endif
    }

    static var floeDeveloperWarning: Color {
        #if os(iOS)
        Color(uiColor: .systemOrange).opacity(0.12)
        #else
        Color.orange.opacity(0.12)
        #endif
    }

    static var floeDeveloperSuccess: Color {
        #if os(iOS)
        Color(uiColor: .systemGreen).opacity(0.12)
        #else
        Color.green.opacity(0.12)
        #endif
    }
}
