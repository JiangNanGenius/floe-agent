// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI

/// Real inline composer editing sources in the currently mounted subtree.
/// A source disappears with its view; no process-wide focus or keyboard state.
struct NativeComposerEditingSourcesKey: PreferenceKey {
    static let defaultValue: Set<UUID> = []
    static func reduce(value: inout Set<UUID>, nextValue: () -> Set<UUID>) {
        value.formUnion(nextValue())
    }
}
#endif
