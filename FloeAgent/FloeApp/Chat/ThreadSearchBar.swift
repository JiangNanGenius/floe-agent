// FloeApp — native in-chat find bar.
//
// SPDX-License-Identifier: MPL-2.0
//
// A single pinned row: query field, match position, previous/next and Done.
// It occupies the same top slot as the linked-schedule capsule (the thread
// shows exactly one of them, never both stacked). The composer draft, its
// selection and the conversation are never touched here.

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import FloeCore

struct ThreadSearchBar: View {
    @ObservedObject var model: ThreadSearchModel
    @FocusState private var fieldFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField(ThreadSearchCopy.placeholder, text: $model.query)
                .textFieldStyle(.plain)
                .font(.subheadline)
                .submitLabel(.search)
                .focused($fieldFocused)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .onSubmit { Task { await model.next() } }
                .accessibilityIdentifier("thread.find.field")
            if model.isSearching {
                ProgressView().controlSize(.small)
            } else if model.errorText != nil {
                Image(systemName: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(Text(model.errorText ?? ""))
                    .accessibilityIdentifier("thread.find.error")
            } else {
                Text(model.countLabel)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 38, alignment: .trailing)
                    .accessibilityIdentifier("thread.find.count")
                    .accessibilityLabel(Text(model.countLabel))
            }
            Button {
                Task { await model.previous() }
            } label: {
                Image(systemName: "chevron.up")
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.borderless)
            .disabled(model.isSearching || model.hits.count < 2)
            .accessibilityLabel(ThreadSearchCopy.previous)
            .accessibilityIdentifier("thread.find.previous")
            Button {
                Task { await model.next() }
            } label: {
                Image(systemName: "chevron.down")
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.borderless)
            .disabled(model.isSearching || model.hits.count < 2)
            .accessibilityLabel(ThreadSearchCopy.next)
            .accessibilityIdentifier("thread.find.next")
            Button(ThreadSearchCopy.done) {
                model.end()
            }
            .buttonStyle(.borderless)
            .font(.subheadline.weight(.medium))
            .frame(minHeight: FloeTheme.minimumTarget)
            .accessibilityIdentifier("thread.find.done")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
        .accessibilityIdentifier("thread.find.bar")
        .task {
            // Focus without stealing focus permanently: Done dismisses find.
            fieldFocused = true
        }
    }
}
#endif
