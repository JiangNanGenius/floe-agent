import Foundation

/// A small, deterministic parser for composer commands. It deliberately
/// recognizes only a leading slash on the current line, so ordinary URLs,
/// file paths and prose containing `/` are never intercepted.
public struct ComposerSlashQuery: Sendable, Hashable {
    public var command: String
    public var argument: String

    public init(command: String, argument: String) {
        self.command = command
        self.argument = argument
    }

    public static func parse(_ draft: String) -> ComposerSlashQuery? {
        guard draft.first == "/", !draft.contains(where: { $0.isNewline }) else { return nil }
        let body = draft.dropFirst()
        let components = body.split(
            maxSplits: 1,
            omittingEmptySubsequences: false,
            whereSeparator: { $0.isWhitespace }
        )
        let command = components.first.map(String.init) ?? ""
        let argument = components.count > 1
            ? String(components[1]).trimmingCharacters(in: .whitespaces)
            : ""
        return ComposerSlashQuery(
            command: command.lowercased(),
            argument: argument
        )
    }
}
