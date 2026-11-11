import SwiftUI
import Foundation

// The exact value/environment contract from ChatInlineContentResolver.swift.
// The full resolver also defines an AppEnvironment-dependent discovery tool;
// its owner/receipt resolution remains a full-App check. This isolated host
// supplies an explicitly synthetic conversation to the real native card.
struct ChatInlineContentScope: Sendable, Hashable {
    let conversationID: UUID
    let isTemporary: Bool
}
private struct ChatInlineContentScopeKey: EnvironmentKey {
    static let defaultValue: ChatInlineContentScope? = nil
}
extension EnvironmentValues {
    var chatInlineContentScope: ChatInlineContentScope? {
        get { self[ChatInlineContentScopeKey.self] }
        set { self[ChatInlineContentScopeKey.self] = newValue }
    }
}
