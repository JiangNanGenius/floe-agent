// FloeApp — Compact new-task composer (Home).
//
// SPDX-License-Identifier: MPL-2.0
//
// A compact composer pinned to the top of the workbench: text field, model
// label, attachment affordance and send. Glass/material is allowed here and
// only here (reading surfaces stay opaque). Disabled honestly when no
// provider is configured.

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI

/// The compact composer. `onSend` returns the new conversation ID so the
/// caller can navigate to the Chat thread.
struct NewTaskComposerView: View {
    @Binding var draft: String
    let modelName: String?
    let canSend: Bool
    let providerConfigured: Bool
    let onSend: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("home.composer.title", systemImage: "sparkles")
                    .font(.headline)
                Spacer()
                if let modelName {
                    Text(modelName)
                        .font(FloeTheme.Typography.metadata)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            HStack(alignment: .bottom, spacing: 8) {
                TextField(text: $draft, axis: .vertical) {
                    Text("home.new_task.placeholder")
                }
                .lineLimit(1...4)
                .textFieldStyle(.plain)
                .padding(.vertical, 6)
                .disabled(!providerConfigured)
                .accessibilityLabel("home.new_task.placeholder")

                Button {
                    onSend()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 29, weight: .semibold))
                        .foregroundStyle(canSend ? AnyShapeStyle(FloeTheme.brandGradient) : AnyShapeStyle(Color.secondary))
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .frame(minWidth: FloeTheme.minimumTarget, minHeight: FloeTheme.minimumTarget)
                .accessibilityLabel("thread.send")
            }

            HStack(spacing: 10) {
                if modelName == nil {
                    Label("composer.no_model", systemImage: "cpu")
                        .font(FloeTheme.Typography.metadata)
                        .foregroundStyle(FloeTheme.pending)
                } else {
                    Label("home.composer.ready", systemImage: "checkmark.circle.fill")
                        .font(FloeTheme.Typography.metadata)
                        .foregroundStyle(FloeTheme.success)
                }
                Spacer()
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
        .overlay {
            RoundedRectangle(cornerRadius: 20)
                .stroke(Color.primary.opacity(0.07), lineWidth: 1)
        }
        .shadow(color: Color.black.opacity(0.05), radius: 14, y: 7)
    }
}
#endif
