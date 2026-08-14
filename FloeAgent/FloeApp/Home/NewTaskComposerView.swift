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
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .bottom, spacing: 8) {
                TextField(text: $draft, axis: .vertical) {
                    Text("home.new_task.placeholder")
                }
                .lineLimit(1...4)
                .textFieldStyle(.plain)
                .disabled(!providerConfigured)
                .accessibilityLabel("home.new_task.placeholder")

                Button {
                    onSend()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                        .foregroundStyle(canSend ? FloeTheme.primary : Color.secondary)
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .frame(minWidth: FloeTheme.minimumTarget, minHeight: FloeTheme.minimumTarget)
                .accessibilityLabel("thread.send")
            }

            HStack(spacing: 10) {
                // Model indicator (read-only; model editing lives in Providers).
                if let modelName {
                    Label(modelName, systemImage: "cpu")
                        .font(FloeTheme.Typography.metadata)
                        .foregroundStyle(.secondary)
                } else {
                    Label("composer.no_model", systemImage: "cpu")
                        .font(FloeTheme.Typography.metadata)
                        .foregroundStyle(FloeTheme.pending)
                }
                Spacer()
                // Attachment affordance (wired in T05; present but inert now).
                Button {
                    // Attachments land in T05.
                } label: {
                    Image(systemName: "paperclip")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .frame(minWidth: FloeTheme.minimumTarget, minHeight: FloeTheme.minimumTarget)
                .accessibilityLabel("composer.attach")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(FloeTheme.chromeMaterial)
    }
}
#endif
