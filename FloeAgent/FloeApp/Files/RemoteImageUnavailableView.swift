// FloeApp — Honest unsupported state for remote image operations.
//
// SPDX-License-Identifier: MPL-2.0
//
// Shown when the selected provider's committed ImageProviderAdapter cannot
// perform a requested operation. Never emulates success.

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI

/// An explicit "unsupported by this provider" state for remote image ops.
struct RemoteImageUnavailableView: View {
    let operationName: String
    let providerName: String

    var body: some View {
        ContentUnavailableView {
            Label("image.unsupported", systemImage: "exclamationmark.triangle")
        } description: {
            Text("image.unsupported.hint")
        } actions: {
            Text(operationName + " · " + providerName)
                .font(FloeTheme.Typography.metadata)
                .foregroundStyle(.secondary)
        }
    }
}
#endif
