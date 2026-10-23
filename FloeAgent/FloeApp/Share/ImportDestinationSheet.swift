// SPDX-License-Identifier: MPL-2.0
//
// FloeApp — compact inbound destination chooser.
//
// Three equal native destination rows (Notes / Task / Canvas), file names
// and count only — no technical explanations. The sheet never navigates by
// itself and is presented OVER whatever surface the user is already on.
// Task and Canvas each open a compact picker: New Task / New Canvas plus
// ALL existing persisted targets, searchable and paged in the picker (the
// lists are never clipped upstream). A failed load shows one concise retry,
// never a misleading empty list. Cancelling a picker returns to the rows
// and commits nothing; no task, canvas, note or navigation exists before an
// explicit target confirmation.

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import FloeCore

@MainActor
struct ImportDestinationSheet: View {
    let request: ImportDestinationRequest
    @ObservedObject var center: ImportDestinationCenter
    var onNotes: () -> Void
    var onTask: (TaskDestinationTarget) -> Void
    var onCanvas: (CanvasDestinationTarget) -> Void
    var onCancel: () -> Void
    var onPresented: () -> Void

    private enum ActivePicker { case canvas, task }
    private static let pageSize = 40

    @State private var activePicker: ActivePicker?
    @State private var canvasRows: [CanvasImportTarget] = []
    @State private var taskRows: [TaskImportTarget] = []
    @State private var canvasQuery = ""
    @State private var taskQuery = ""
    @State private var canvasVisible = ImportDestinationSheet.pageSize
    @State private var taskVisible = ImportDestinationSheet.pageSize
    @State private var canvasLoadState = PickerLoadState.idle
    @State private var taskLoadState = PickerLoadState.idle

    private enum PickerLoadState: Equatable {
        case idle, loading, loaded, failed
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch activePicker {
            case nil: choiceRows
            case .canvas: canvasPicker
            case .task: taskPicker
            }
            cancelButton
            statusLine
        }
        .padding(20)
        .frame(maxWidth: 520)
        .interactiveDismissDisabled(center.isResolving)
        .onAppear(perform: onPresented)
    }

    // MARK: Destination rows

    private var fileSummary: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(request.fileNames.prefix(3).enumerated()), id: \.offset) { _, name in
                Text(verbatim: name)
                    .font(.body)
                    .lineLimit(1)
            }
            if request.includesText {
                Text("import.destination.text_row")
                    .font(.body)
                    .lineLimit(1)
            }
            Text(FloeL10n.plural("share.intake.pending_count", count: request.itemCount))
                .font(FloeTheme.Typography.metadata)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("import.destination.files")
    }

    private var choiceRows: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("import.destination.title")
                .font(.headline)
            fileSummary
            VStack(spacing: 10) {
                destinationRow(
                    symbol: "note.text",
                    titleKey: "import.destination.notes",
                    identifier: "import.destination.notes",
                    action: onNotes
                )
                destinationRow(
                    symbol: "square.and.pencil",
                    titleKey: "import.destination.task",
                    identifier: "import.destination.task"
                ) {
                    activePicker = .task
                    loadTasks()
                }
                destinationRow(
                    symbol: "rectangle.3.group",
                    titleKey: "import.destination.canvas",
                    identifier: "import.destination.canvas"
                ) {
                    activePicker = .canvas
                    loadCanvases()
                }
            }
        }
    }

    private var cancelButton: some View {
        Button(action: onCancel) {
            Text("share.intake.cancel")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .disabled(center.isResolving)
        .frame(minHeight: FloeTheme.minimumTarget)
        .accessibilityIdentifier("import.destination.cancel")
    }

    @ViewBuilder
    private var statusLine: some View {
        if center.isResolving {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("share.intake.working")
                    .font(FloeTheme.Typography.metadata)
                    .foregroundStyle(.secondary)
            }
        } else if let message = center.lastActionMessage {
            Text(message)
                .font(FloeTheme.Typography.metadata)
                .foregroundStyle(FloeTheme.pending)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("import.destination.status")
        }
    }

    private func destinationRow(
        symbol: String,
        titleKey: String,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        destinationRowContent(
            symbol: symbol,
            // Explicit LocalizedStringKey: the dynamic String overload is
            // verbatim and would expose the key; real names stay verbatim.
            title: Text(LocalizedStringKey(titleKey)),
            identifier: identifier,
            action: action
        )
    }

    private func destinationRow(
        symbol: String,
        title: String,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        destinationRowContent(
            symbol: symbol,
            title: Text(verbatim: title),
            identifier: identifier,
            action: action
        )
    }

    private func destinationRowContent(
        symbol: String,
        title: Text,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.title3)
                    .foregroundStyle(FloeTheme.primary)
                    .frame(width: 28)
                    .accessibilityHidden(true)
                title
                    .font(.body)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
            .background(FloeTheme.readingSurface, in: RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(FloeTheme.primary.opacity(0.16))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(center.isResolving)
        .frame(minHeight: FloeTheme.minimumTarget)
        .accessibilityIdentifier(identifier)
    }

    // MARK: Task picker

    private var taskPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            pickerHeader(
                titleKey: "import.destination.task_title",
                backIdentifier: "import.destination.task.back"
            )
            destinationRow(
                symbol: "plus.square",
                titleKey: "import.destination.task_new",
                identifier: "import.destination.task.new"
            ) {
                onTask(.newTask)
            }
            TextField("import.destination.search", text: $taskQuery)
                .textFieldStyle(.roundedBorder)
                .frame(minHeight: 40)
                .accessibilityIdentifier("import.destination.task.search")

            pickerList(content: {
                let filtered = filteredTasks
                ForEach(Array(filtered.prefix(taskVisible).enumerated()), id: \.element.id) { _, target in
                    destinationRow(
                        symbol: "text.bubble",
                        title: taskTitle(target),
                        identifier: "import.destination.task.item"
                    ) {
                        onTask(.existing(conversationID: target.id))
                    }
                }
                if filtered.count > taskVisible {
                    Button("import.destination.load_more") {
                        taskVisible += Self.pageSize
                    }
                    .buttonStyle(.borderless)
                    .frame(maxWidth: .infinity, minHeight: FloeTheme.minimumTarget)
                    .accessibilityIdentifier("import.destination.task.more")
                }
            }, state: taskLoadState, isEmpty: filteredTasks.isEmpty, retry: loadTasks)
        }
    }

    private var filteredTasks: [TaskImportTarget] {
        let query = taskQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return taskRows }
        return taskRows.filter {
            taskTitle($0).range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }

    private func taskTitle(_ target: TaskImportTarget) -> String {
        let title = target.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? FloeL10n.l("chat.untitled") : title
    }

    private func loadTasks() {
        guard taskLoadState != .loading else { return }
        taskLoadState = .loading
        Task {
            do {
                taskRows = try await center.loadTaskImportTargets()
                taskVisible = Self.pageSize
                taskLoadState = .loaded
            } catch {
                taskLoadState = .failed
            }
        }
    }

    // MARK: Canvas picker

    private var canvasPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            pickerHeader(
                titleKey: "import.destination.canvas_title",
                backIdentifier: "import.destination.canvas.back"
            )
            destinationRow(
                symbol: "plus.rectangle.on.rectangle",
                titleKey: "import.destination.canvas_new",
                identifier: "import.destination.canvas.new"
            ) {
                onCanvas(.newCanvas)
            }
            TextField("import.destination.search", text: $canvasQuery)
                .textFieldStyle(.roundedBorder)
                .frame(minHeight: 40)
                .accessibilityIdentifier("import.destination.canvas.search")

            pickerList(content: {
                let filtered = filteredCanvases
                ForEach(filtered.prefix(canvasVisible)) { target in
                    destinationRow(
                        symbol: "rectangle.3.group",
                        title: target.name,
                        identifier: "import.destination.canvas.item"
                    ) {
                        onCanvas(.existing(canvasID: target.id))
                    }
                }
                if filtered.count > canvasVisible {
                    Button("import.destination.load_more") {
                        canvasVisible += Self.pageSize
                    }
                    .buttonStyle(.borderless)
                    .frame(maxWidth: .infinity, minHeight: FloeTheme.minimumTarget)
                    .accessibilityIdentifier("import.destination.canvas.more")
                }
            }, state: canvasLoadState, isEmpty: filteredCanvases.isEmpty, retry: loadCanvases)
        }
    }

    private var filteredCanvases: [CanvasImportTarget] {
        let query = canvasQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return canvasRows }
        return canvasRows.filter {
            $0.name.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }

    private func loadCanvases() {
        guard canvasLoadState != .loading else { return }
        canvasLoadState = .loading
        Task {
            do {
                canvasRows = try center.loadCanvasImportTargets()
                canvasVisible = Self.pageSize
                canvasLoadState = .loaded
            } catch {
                canvasLoadState = .failed
            }
        }
    }

    // MARK: Shared picker chrome

    private func pickerHeader(titleKey: String, backIdentifier: String) -> some View {
        HStack(spacing: 8) {
            Button {
                activePicker = nil
            } label: {
                Image(systemName: "chevron.left")
                    .frame(minWidth: 44, minHeight: 44)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(backIdentifier)

            Text(LocalizedStringKey(titleKey))
                .font(.headline)
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func pickerList<Content: View>(
        @ViewBuilder content: () -> Content,
        state: PickerLoadState,
        isEmpty: Bool,
        retry: @escaping () -> Void
    ) -> some View {
        ScrollView {
            VStack(spacing: 8) {
                content()
                if state == .loading {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("share.intake.working")
                            .font(FloeTheme.Typography.metadata)
                            .foregroundStyle(.secondary)
                    }
                } else if state == .failed {
                    VStack(spacing: 6) {
                        Text("import.destination.load_failed")
                            .font(FloeTheme.Typography.metadata)
                            .foregroundStyle(FloeTheme.pending)
                        Button("action.retry", action: retry)
                            .buttonStyle(.borderless)
                            .frame(minHeight: FloeTheme.minimumTarget)
                            .accessibilityIdentifier("import.destination.retry")
                    }
                } else if state == .loaded && isEmpty {
                    Text("import.destination.empty")
                        .font(FloeTheme.Typography.metadata)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxHeight: 300)
    }
}
#endif
