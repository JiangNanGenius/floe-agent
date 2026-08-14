// FloeApp — Error event card.
//
// SPDX-License-Identifier: MPL-2.0
//
// An error is a terminal presentation: destructive color, the honest
// message, and an explicit retry entry point (closure supplied by the
// thread). Rendering an error card implies the loading state has ended
// — RunStateLocalizer.isLoading returns false as soon as any error
// event exists.

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI

/// One error event: destructive-tinted card with message + retry.
struct ErrorEventView: View {
    /// Honest, already-redacted error message.
    let message: String
    /// Retry entry point. Nil hides the button (e.g. non-retryable).
    var onRetry: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "xmark.octagon")
                .foregroundStyle(FloeTheme.destructive)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text("error.card.title")
                    .font(FloeTheme.Typography.metadata.weight(.semibold))
                    .foregroundStyle(FloeTheme.destructive)
                Text(message)
                    .font(FloeTheme.Typography.body)
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let onRetry {
                    Button {
                        onRetry()
                    } label: {
                        Label("action.retry", systemImage: "arrow.clockwise")
                            .font(FloeTheme.Typography.metadata.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                    .tint(FloeTheme.destructive)
                    .frame(minHeight: FloeTheme.minimumTarget)
                    .accessibilityLabel("action.retry")
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            FloeTheme.destructive.opacity(0.08),
            in: RoundedRectangle(cornerRadius: 10)
        )
        .accessibilityElement(children: .combine)
    }
}
#endif
