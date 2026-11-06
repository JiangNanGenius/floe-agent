#if canImport(UIKit)
import SwiftUI
import FloeCanvasCore

/// New scene/goal sheet: template choice + goal description. When no
/// assistant gateway is injected the description honestly falls back to
/// template content and the sheet says so (never fake AI output).
public struct CanvasNewSceneSheet: View {
    @ObservedObject var store: CanvasEditorStore
    @Environment(\.dismiss) private var dismiss
    @State private var name: String = ""
    @State private var goalDescription: String = ""
    @State private var template: CanvasSceneTemplate = .research
    @State private var isComposing = false
    @State private var composed: CanvasTemplateContent?

    private var strings: CanvasStrings { store.strings }

    public init(store: CanvasEditorStore) {
        self.store = store
    }

    private var hasAssistant: Bool {
        store.services.proposalGateway != nil
            || store.services.assistantGateway != nil
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section(strings[.newSceneTitle]) {
                    TextField(
                        strings[.newSceneNamePlaceholder],
                        text: $name)
                    .accessibilityIdentifier(CanvasAccessibilityID.newSceneNameField.identifier)
                }
                Section {
                    ForEach(CanvasSceneTemplate.allCases, id: \.self) { option in
                        Button {
                            template = option
                        } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(templateTitle(option))
                                        .foregroundStyle(.primary)
                                    Text(templateSubtitle(option))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if template == option {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.tint)
                                }
                            }
                        }
                        .accessibilityIdentifier(templateAccessibilityID(option))
                    }
                }
                Section(strings[.templateResearchSubtitle]) {
                    TextField(
                        goalPlaceholder,
                        text: $goalDescription,
                        axis: .vertical)
                    .lineLimit(2...5)
                    if !hasAssistant {
                        Label(
                            store.strings[.alertAssistantUnavailable],
                            systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
                if template == .lab {
                    Label(
                        strings[.templateLabSubtitle],
                        systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            .navigationTitle(strings[.newSceneTitle])
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(strings[.cancelButton]) { dismiss() }
                        .accessibilityIdentifier(CanvasAccessibilityID.newSceneCancelButton.identifier)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(strings[.createButton]) {
                        Task { await create() }
                    }
                    .accessibilityIdentifier(CanvasAccessibilityID.newSceneCreateButton.identifier)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .disabled(isComposing)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(CanvasAccessibilityID.newSceneSheet.identifier)
    }

    private var goalPlaceholder: String {
        hasAssistant ? "Describe the goal (optional)" : "Goal notes (assistant unavailable)"
    }

    private func create() async {
        isComposing = true
        defer { isComposing = false }
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        var content: CanvasTemplateContent
        if hasAssistant && !goalDescription.trimmingCharacters(in: .whitespaces).isEmpty {
            content = await CanvasSceneGoalComposer.compose(
                description: goalDescription,
                template: template,
                store: store)
            content.pageName = trimmedName
        } else {
            content = CanvasTemplateFactory.make(
                template, name: trimmedName, configuration: store.configuration)
        }
        await store.createScenePage(from: content)
        dismiss()
    }

    private func templateTitle(_ template: CanvasSceneTemplate) -> String {
        switch template {
        case .research: return strings[.templateResearch]
        case .compare: return strings[.templateCompare]
        case .blank: return strings[.templateBlank]
        case .lab: return strings[.templateLab]
        }
    }

    private func templateSubtitle(_ template: CanvasSceneTemplate) -> String {
        switch template {
        case .research: return strings[.templateResearchSubtitle]
        case .compare: return strings[.templateCompareSubtitle]
        case .blank: return strings[.templateBlankSubtitle]
        case .lab: return strings[.templateLabSubtitle]
        }
    }

    private func templateAccessibilityID(_ template: CanvasSceneTemplate) -> String {
        switch template {
        case .research: return CanvasAccessibilityID.newSceneTemplateResearch.identifier
        case .compare: return CanvasAccessibilityID.newSceneTemplateCompare.identifier
        case .blank: return CanvasAccessibilityID.newSceneTemplateBlank.identifier
        case .lab: return CanvasAccessibilityID.newSceneTemplateLab.identifier
        }
    }
}

/// Recognition decision sheet: explicit Convert vs Keep ink choice.
public struct CanvasInkRecognitionSheet: View {
    @ObservedObject var store: CanvasEditorStore
    let session: CanvasInkRecognitionSession
    @Environment(\.dismiss) private var dismiss
    private var strings: CanvasStrings { store.strings }

    public init(
        store: CanvasEditorStore,
        session: CanvasInkRecognitionSession
    ) {
        self.store = store
        self.session = session
    }

    public var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Image(systemName: "pencil.and.outline")
                    .font(.largeTitle)
                Text(summary)
                    .multilineTextAlignment(.center)
                HStack(spacing: 12) {
                    Button(strings[.keepInk]) {
                        Task {
                            await store.applyInkConversion(keepInk: true)
                            dismiss()
                        }
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier(CanvasAccessibilityID.inkKeepChoice.identifier)
                    Button(strings[.convertToObject]) {
                        Task {
                            await store.applyInkConversion(keepInk: false)
                            dismiss()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
                Button(strings[.cancelButton]) {
                    store.discardInkConversion()
                    dismiss()
                }
                .font(.caption)
            }
            .padding(20)
        }
    }

    private var summary: String {
        store.strings.formatted(
            .inkRecognizedShapes, session.results.count)
    }
}
#endif
