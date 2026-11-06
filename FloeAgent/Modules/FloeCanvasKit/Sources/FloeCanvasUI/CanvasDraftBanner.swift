#if canImport(UIKit)
import SwiftUI

/// Recoverable-failure banner. Each draft stays tied to its exact
/// page/node/revision; switching pages or dismissing panels never discards
/// or mis-applies it (UI_BRIEF, ICH02/ICH11).
public struct CanvasDraftBanner: View {
    @ObservedObject var store: CanvasEditorStore

    public init(store: CanvasEditorStore) {
        self.store = store
    }

    private var strings: CanvasStrings { store.strings }

    public var body: some View {
        if !store.drafts.isEmpty {
            VStack(spacing: 8) {
                ForEach(store.drafts) { draft in
                    HStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        VStack(alignment: .leading) {
                            Text(strings[.alertSaveFailedTitle])
                                .font(.caption)
                                .bold()
                            Text(draft.summary)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(strings[.alertSaveFailedKeepEditing]) {
                            Task { await store.retryDraft(draft) }
                        }
                        .font(.caption)
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier(CanvasAccessibilityID.draftRetryButton.identifier)
                        if draft.didConflict {
                            Button("Rebase") {
                                Task { await store.rebaseDraft(draft) }
                            }
                            .font(.caption)
                            .buttonStyle(.bordered)
                            .accessibilityIdentifier(CanvasAccessibilityID.draftRebaseButton.identifier)
                        }
                        Button(strings[.alertSaveFailedDiscard]) {
                            store.discardDraft(draft)
                        }
                        .font(.caption)
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier(CanvasAccessibilityID.draftDiscardButton.identifier)
                    }
                    .padding(10)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 8)
            .accessibilityIdentifier(CanvasAccessibilityID.draftBanner.identifier)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

/// Alert construction keeps copy concise; diagnostics stay in details.
@MainActor
public enum CanvasAlertBuilder {
    public static func alert(
        for alert: CanvasUserAlert,
        store: CanvasEditorStore
    ) -> Alert {
        switch alert.kind {
        case .revisionConflict:
            return Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                primaryButton: .default(Text(alert.primaryActionTitle ?? store.strings[.alertReload])) {
                    Task { await store.load() }
                },
                secondaryButton: .cancel())
        case .saveFailed:
            return Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text("OK")) {
                    Task { @MainActor in store.dismissAlert() }
                })
        default:
            return Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text("OK")) {
                    Task { @MainActor in store.dismissAlert() }
                })
        }
    }
}
#endif
