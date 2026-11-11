// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import FloeToolboxWorkbenches

struct ToolboxTimerPage: View {
    var body: some View {
        let center = ToolboxTimerReminders.shared
        ToolboxTimerView(reminders: .init(authorize: { try await center.authorize() },
            synchronize: { try await center.synchronize($0) },
            cancel: { try await center.cancel(timerID: $0) },
            prune: { try await center.prune(keeping: $0) }, updates: { center.updates() }))
    }
}
#endif
