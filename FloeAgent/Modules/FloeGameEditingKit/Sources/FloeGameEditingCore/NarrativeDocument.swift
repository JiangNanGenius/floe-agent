// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeGameCore

/// Editor-owned narrative/event DTO with explicit branch structure. Engine
/// adapters translate to/from native event formats; unsupported command codes
/// are surfaced read-only and their original payloads are preserved verbatim.
public struct NarrativeDocument: Codable, Hashable, Sendable {
    public static let stagingFormatName = "floe-editing-narrative"
    public static let stagingFormatVersion = 1

    /// A named anchor that branch commands link to.
    public struct Label: Codable, Hashable, Sendable, Identifiable {
        public var id: UUID
        public var name: String
        public init(id: UUID = UUID(), name: String) { self.id = id; self.name = name }
    }

    public enum BranchRole: String, Codable, Sendable {
        case none
        /// Opens a block linked to a label; a matching `.close` must follow.
        case open
        /// Closes the most recent still-open block.
        case close
    }

    public struct Command: Codable, Hashable, Sendable, Identifiable {
        public var id: UUID
        public var code: String
        public var parameters: [String: JSONValue]
        public var branchRole: BranchRole
        /// Label this command links to (`.open` blocks and jump-style codes).
        public var labelID: UUID?
        /// True when the originating adapter did not recognize the code; the
        /// row is read-only and `originalPayload` round-trips untouched.
        public var isSupported: Bool
        public var originalPayload: JSONValue?
        public init(id: UUID = UUID(), code: String, parameters: [String: JSONValue] = [:],
                    branchRole: BranchRole = .none, labelID: UUID? = nil,
                    isSupported: Bool = true, originalPayload: JSONValue? = nil) {
            self.id = id; self.code = code; self.parameters = parameters
            self.branchRole = branchRole; self.labelID = labelID
            self.isSupported = isSupported; self.originalPayload = originalPayload
        }
    }

    public struct ValidationIssue: Hashable, Sendable, Identifiable {
        public enum Kind: String, Sendable {
            case danglingBranchLink
            case unbalancedOpen
            case unbalancedClose
            case duplicateLabelName
            case unsupportedCommandPresent
        }
        public var id: UUID
        public var kind: Kind
        public var commandID: UUID?
        public var message: GameEditCopy
    }

    public var format: String
    public var formatVersion: Int
    public var title: String
    public var labels: [Label]
    public var commands: [Command]

    public init(title: String, labels: [Label] = [], commands: [Command] = []) {
        self.format = Self.stagingFormatName
        self.formatVersion = Self.stagingFormatVersion
        self.title = title
        self.labels = labels
        self.commands = commands
    }

    // MARK: - Editing operations (pure)

    public func inserting(_ command: Command, at index: Int) -> NarrativeDocument {
        var copy = self
        let clamped = min(max(0, index), commands.count)
        copy.commands.insert(command, at: clamped)
        return copy
    }

    public func removing(id: UUID) -> NarrativeDocument {
        var copy = self
        copy.commands.removeAll { $0.id == id }
        return copy
    }

    public func moving(id: UUID, toIndex destination: Int) -> NarrativeDocument {
        guard let source = commands.firstIndex(where: { $0.id == id }) else { return self }
        let clamped = min(max(0, destination), commands.count - 1)
        var copy = self
        let command = copy.commands.remove(at: source)
        copy.commands.insert(command, at: clamped)
        return copy
    }

    public func updating(id: UUID, _ transform: (inout Command) -> Void) -> NarrativeDocument {
        var copy = self
        guard let index = copy.commands.firstIndex(where: { $0.id == id }) else { return self }
        transform(&copy.commands[index])
        return copy
    }

    public func addingLabel(name: String) -> NarrativeDocument {
        var copy = self
        copy.labels.append(Label(name: name))
        return copy
    }

    public func removingLabel(id: UUID) -> NarrativeDocument {
        var copy = self
        copy.labels.removeAll { $0.id == id }
        // Links to the removed label become dangling; validation reports them
        // and serialization keeps the null link instead of inventing targets.
        for index in copy.commands.indices where copy.commands[index].labelID == id {
            copy.commands[index].labelID = nil
        }
        return copy
    }

    public func label(id: UUID?) -> Label? {
        guard let id else { return nil }
        return labels.first(where: { $0.id == id })
    }

    // MARK: - Validation

    public func validationIssues(knownCodes: Set<String>? = nil) -> [ValidationIssue] {
        var issues: [ValidationIssue] = []
        var openStack: [UUID] = []
        var seenNames: Set<String> = []
        let labelIDs = Set(labels.map(\.id))
        for command in commands {
            if let labelID = command.labelID, !labelIDs.contains(labelID) {
                issues.append(.init(id: UUID(), kind: .danglingBranchLink, commandID: command.id,
                    message: GameEditCopy("Branch link points to a missing label.", "分支链接指向不存在的标签。")))
            }
            switch command.branchRole {
            case .open: openStack.append(command.id)
            case .close:
                if openStack.isEmpty {
                    issues.append(.init(id: UUID(), kind: .unbalancedClose, commandID: command.id,
                        message: GameEditCopy("Branch end without a matching open.", "分支结束缺少对应的开头。")))
                } else {
                    openStack.removeLast()
                }
            case .none: break
            }
            if !command.isSupported {
                issues.append(.init(id: UUID(), kind: .unsupportedCommandPresent, commandID: command.id,
                    message: GameEditCopy("Unsupported command shown read-only; original preserved.",
                                          "不支持的命令只读展示；原始内容已保留。")))
            } else if let knownCodes, !knownCodes.contains(command.code) {
                issues.append(.init(id: UUID(), kind: .unsupportedCommandPresent, commandID: command.id,
                    message: GameEditCopy("Command not listed by the adapter; shown read-only.",
                                          "命令未在适配器中登记；只读展示。")))
            }
        }
        for openID in openStack {
            issues.append(.init(id: UUID(), kind: .unbalancedOpen, commandID: openID,
                message: GameEditCopy("Branch open without a matching end.", "分支开头缺少对应的结束。")))
        }
        for label in labels where !seenNames.insert(label.name).inserted {
            issues.append(.init(id: UUID(), kind: .duplicateLabelName,
                message: GameEditCopy("Duplicate label name \"\(label.name)\".", "标签名“\(label.name)”重复。")))
        }
        return issues
    }

    // MARK: - Serialization

    public static func decode(_ bytes: Data) throws -> NarrativeDocument {
        guard let root = try? JSONValue.parse(bytes),
              root["format"]?.stringValue == stagingFormatName,
              root["formatVersion"]?.intValue == stagingFormatVersion else {
            throw GameProjectError.invalidManifest("narrative.format")
        }
        let data = try root.serialized()
        guard let document = try? JSONDecoder().decode(NarrativeDocument.self, from: data) else {
            throw GameProjectError.invalidManifest("narrative.decode")
        }
        return document
    }

    public func encode() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self) else { throw GameProjectError.invalidEdit }
        _ = try NarrativeDocument.decode(data)
        return data
    }
}
