// SPDX-License-Identifier: MPL-2.0
import Foundation

/// A locator, never a path or an authorization grant. Readers must resolve it
/// through the current conversation's persisted run/message receipts.
public struct ChatContentReference: Sendable, Hashable, Codable {
    public enum Kind: String, Sendable, Codable { case artifact, output, attachment }
    public let kind: Kind
    /// Run identity for artifacts/outputs; message identity for attachments.
    public let ownerID: UUID
    public let contentID: String

    public init?(kind: Kind, ownerID: UUID, contentID: String) {
        let normalized: String
        if kind == .output {
            guard contentID.utf8.count == 64,
                  contentID.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return nil }
            normalized = contentID
        } else {
            guard let id = UUID(uuidString: contentID) else { return nil }
            normalized = id.uuidString
        }
        self.kind = kind; self.ownerID = ownerID; self.contentID = normalized
    }
    public init?(_ uri: String) {
        guard uri.utf8.count <= 256, let value = URLComponents(string: uri),
              value.scheme == "floe-content", let host = value.host, value.percentEncodedHost == host, let kind = Kind(rawValue: host),
              value.user == nil, value.password == nil, value.port == nil,
              value.query == nil, value.fragment == nil,
              value.percentEncodedPath == value.path else { return nil }
        let path = value.path.split(separator: "/", omittingEmptySubsequences: false)
        guard path.count == 3, path[0].isEmpty, let owner = UUID(uuidString: String(path[1])) else { return nil }
        self.init(kind: kind, ownerID: owner, contentID: String(path[2]))
    }
    private enum CodingKeys: String, CodingKey { case kind, ownerID, contentID }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try values.decode(Kind.self, forKey: .kind)
        let owner = try values.decode(UUID.self, forKey: .ownerID)
        let id = try values.decode(String.self, forKey: .contentID)
        guard let checked = Self(kind: kind, ownerID: owner, contentID: id) else {
            throw DecodingError.dataCorruptedError(forKey: .contentID, in: values, debugDescription: "Invalid content reference")
        }
        self = checked
    }
    public var uri: String { "floe-content://\(kind.rawValue)/\(ownerID.uuidString)/\(contentID)" }
    public func markdown(title: String) -> String {
        let label = String(title.prefix(160)).map { character -> Character in
            if character == "[" || character == "]" || character == "\\" || character.isNewline { return " " }
            return character
        }
        let clean = String(label).trimmingCharacters(in: .whitespacesAndNewlines)
        return "![\(clean.isEmpty ? "Content" : clean)](\(uri))"
    }
    public static let modelInstructions = "To insert an existing native result between answer paragraphs, copy its inlineMarkdown verbatim on a complete standalone line, for example ![Title](floe-content://artifact/RUN_UUID/ARTIFACT_UUID). Do not put it in a code fence or invent IDs, file paths or URLs. The reference is resolved only from this task's saved receipts; it grants no permissions. Use chat.content.list to recover earlier results in this task; continue its nextCursor even after an empty page. Bounded native synthesized-audio previews require a user tap. Video, PDF, Office and 3D/CAD output references display file preview entries, not a new inline player, reader or model editor. Images keep ordinary Markdown syntax. Unsupported files use the existing file preview rather than a fabricated renderer."
}

public struct ChatContentDescriptor: Sendable, Codable, Hashable {
    public let reference: ChatContentReference
    public let mimeType: String
    public let title: String
    public var inlineMarkdown: String { reference.markdown(title: title) }
    public init(reference: ChatContentReference, mimeType: String, title: String) {
        self.reference = reference; self.mimeType = mimeType; self.title = title
    }
}
