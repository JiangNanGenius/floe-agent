// SPDX-License-Identifier: MPL-2.0

import Foundation

public struct ComposerDraftEntry: Codable, Equatable, Sendable {
    public var text: String
    public var attachments: [AttachmentRef]
    public var revision: Int
    public var updatedAt: Date
    public var selectionLocation: Int?
    public var selectionLength: Int?

    public init(text: String, attachments: [AttachmentRef], revision: Int, updatedAt: Date,
                selectionLocation: Int? = nil, selectionLength: Int? = nil) {
        self.text = text
        self.attachments = attachments
        self.revision = revision
        self.updatedAt = updatedAt
        self.selectionLocation = selectionLocation
        self.selectionLength = selectionLength
    }

    public var selection: NSRange? {
        guard let selectionLocation else { return nil }
        return NSRange(location: selectionLocation, length: selectionLength ?? 0)
    }
}

/// Local composer storage shared by Floe on Apple platforms. Platforms that
/// do not issue import receipts can still retain the ledgers when rewriting.
public struct ComposerDraftDocument<Handoff: Codable, LandingProof: Codable>: Codable {
    public static var homeDraftID: UUID { UUID(uuidString: "8F4D0A6E-3B1C-4E2A-9D55-2C8F1A77E010")! }

    public var drafts: [String: ComposerDraftEntry]
    public var handoffs: [String: Handoff]
    public var landingProofs: [String: LandingProof]?

    public init(drafts: [String: ComposerDraftEntry], handoffs: [String: Handoff],
                landingProofs: [String: LandingProof]? = nil) {
        self.drafts = drafts
        self.handoffs = handoffs
        self.landingProofs = landingProofs
    }
}

extension ComposerDraftDocument: Sendable where Handoff: Sendable, LandingProof: Sendable {}
