// SPDX-License-Identifier: MPL-2.0

import Foundation

/// Pins the exact text that was submitted. Editing A to B and back to A
/// creates a newer draft even though its text matches the submitted text.
struct ComposerDraftTextRevisions {
    struct Token: Equatable, Sendable {
        fileprivate let conversationID: UUID
        fileprivate let revision: Int
    }

    private var revisions: [UUID: Int] = [:]

    func token(for conversationID: UUID) -> Token {
        Token(conversationID: conversationID, revision: revisions[conversationID, default: 0])
    }

    func matches(_ token: Token, for conversationID: UUID) -> Bool {
        token == self.token(for: conversationID)
    }

    mutating func advance(for conversationID: UUID) {
        revisions[conversationID, default: 0] &+= 1
    }
}
