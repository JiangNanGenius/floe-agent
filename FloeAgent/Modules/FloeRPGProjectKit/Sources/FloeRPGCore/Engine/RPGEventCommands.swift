// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeGameCore
import FloeGameEditingCore

/// A typed event command in an RPG Maker event list. Binary projects carry
/// Ruby values; MV/MZ carry JSON values. Unknown commands round-trip with
/// their original payloads untouched.
public struct RPGEventCommand: Equatable, Sendable {
    public var code: Int
    public var indent: Int
    /// Binary projects: Ruby scalar/structural parameters.
    public var parameters: [RPGCommandParameter]
    /// MV/MZ projects: raw JSON parameters (order preserved).
    public var jsonParameters: [JSONValue]

    public init(code: Int, indent: Int, parameters: [RPGCommandParameter] = [],
                jsonParameters: [JSONValue] = []) {
        self.code = code; self.indent = indent
        self.parameters = parameters; self.jsonParameters = jsonParameters
    }
}

/// A scalar command parameter for binary engines.
public enum RPGCommandParameter: Sendable {
    case `nil`
    case bool(Bool)
    case integer(Int64)
    case float(Double)
    case string(String)
    case binary(Data)

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var intValue: Int64? {
        if case .integer(let value) = self { return value }
        return nil
    }
}

extension RPGCommandParameter: Equatable {
    public static func == (lhs: RPGCommandParameter, rhs: RPGCommandParameter) -> Bool {
        switch (lhs, rhs) {
        case (.`nil`, .`nil`): return true
        case (.bool(let a), .bool(let b)): return a == b
        case (.integer(let a), .integer(let b)): return a == b
        case (.float(let a), .float(let b)): return a == b
        case (.string(let a), .string(let b)): return a == b
        case (.binary(let a), .binary(let b)): return a == b
        default: return false
        }
    }
}

/// Declarative knowledge about one event command code for one engine.
/// Unknown codes are preserved, never dropped.
public struct RPGCommandSpec: Sendable {
    public let code: Int
    /// Stable identifier shared with the editing bridge.
    public let id: String
    /// Parameter names for the leading simple parameters (best effort; the
    /// full original parameter list is always preserved alongside).
    public let fieldNames: [String]
}

public extension RPGCommandSpec {
    /// Common XP/VX/VX Ace command specs (codes shared across the three
    /// engines except where noted). Field names cover the editable subset.
    static let binaryCommon: [RPGCommandSpec] = [
        RPGCommandSpec(code: 101, id: "showText", fieldNames: ["faceName", "faceIndex", "background", "position"]),
        RPGCommandSpec(code: 401, id: "showTextLine", fieldNames: ["text"]),
        RPGCommandSpec(code: 102, id: "showChoices", fieldNames: ["choices", "cancelType"]),
        RPGCommandSpec(code: 402, id: "choiceBranch", fieldNames: ["index", "text"]),
        RPGCommandSpec(code: 403, id: "choiceCancel", fieldNames: []),
        RPGCommandSpec(code: 103, id: "numberInput", fieldNames: ["variableId", "digits"]),
        RPGCommandSpec(code: 104, id: "itemChoice", fieldNames: ["variableId", "itemType"]),
        RPGCommandSpec(code: 108, id: "comment", fieldNames: ["text"]),
        RPGCommandSpec(code: 408, id: "commentLine", fieldNames: ["text"]),
        RPGCommandSpec(code: 111, id: "conditionalBranch", fieldNames: ["condition"]),
        RPGCommandSpec(code: 411, id: "elseBranch", fieldNames: []),
        RPGCommandSpec(code: 412, id: "branchEnd", fieldNames: []),
        RPGCommandSpec(code: 112, id: "loop", fieldNames: []),
        RPGCommandSpec(code: 113, id: "breakLoop", fieldNames: []),
        RPGCommandSpec(code: 413, id: "loopEnd", fieldNames: []),
        RPGCommandSpec(code: 115, id: "exitEventProcessing", fieldNames: []),
        RPGCommandSpec(code: 117, id: "callCommonEvent", fieldNames: ["commonEventId"]),
        RPGCommandSpec(code: 118, id: "label", fieldNames: ["name"]),
        RPGCommandSpec(code: 119, id: "jumpToLabel", fieldNames: ["name"]),
        RPGCommandSpec(code: 121, id: "controlSwitches", fieldNames: ["startId", "endId", "operation"]),
        RPGCommandSpec(code: 122, id: "controlVariables", fieldNames: ["startId", "endId", "operation", "operand"]),
        RPGCommandSpec(code: 124, id: "changeTimer", fieldNames: ["operation", "seconds"]),
        RPGCommandSpec(code: 125, id: "changeGold", fieldNames: ["operation", "operand"]),
        RPGCommandSpec(code: 303, id: "changeName", fieldNames: ["actorId", "name"]),
        RPGCommandSpec(code: 320, id: "changeActorGraphic", fieldNames: ["actorId", "characterName", "characterIndex", "faceName", "faceIndex"]),
        RPGCommandSpec(code: 355, id: "script", fieldNames: ["line"]),
        RPGCommandSpec(code: 655, id: "scriptLine", fieldNames: ["line"]),
        RPGCommandSpec(code: 0, id: "endOfList", fieldNames: []),
    ]

    /// MV/MZ command specs: same semantics with recoded numbers where noted.
    static let jsonCommon: [RPGCommandSpec] = [
        RPGCommandSpec(code: 101, id: "showText", fieldNames: ["faceName", "faceIndex", "background", "position"]),
        RPGCommandSpec(code: 401, id: "showTextLine", fieldNames: ["text"]),
        RPGCommandSpec(code: 102, id: "showChoices", fieldNames: ["choices", "cancelType", "defaultType", "position"]),
        RPGCommandSpec(code: 402, id: "choiceBranch", fieldNames: ["index", "text"]),
        RPGCommandSpec(code: 403, id: "choiceCancel", fieldNames: []),
        RPGCommandSpec(code: 103, id: "numberInput", fieldNames: ["variableId", "digits"]),
        RPGCommandSpec(code: 104, id: "itemChoice", fieldNames: ["variableId", "itemType"]),
        RPGCommandSpec(code: 108, id: "comment", fieldNames: ["text"]),
        RPGCommandSpec(code: 408, id: "commentLine", fieldNames: ["text"]),
        RPGCommandSpec(code: 111, id: "conditionalBranch", fieldNames: ["condition"]),
        RPGCommandSpec(code: 411, id: "elseBranch", fieldNames: []),
        RPGCommandSpec(code: 412, id: "branchEnd", fieldNames: []),
        RPGCommandSpec(code: 112, id: "loop", fieldNames: []),
        RPGCommandSpec(code: 113, id: "breakLoop", fieldNames: []),
        RPGCommandSpec(code: 413, id: "loopEnd", fieldNames: []),
        RPGCommandSpec(code: 115, id: "exitEventProcessing", fieldNames: []),
        RPGCommandSpec(code: 117, id: "callCommonEvent", fieldNames: ["commonEventId"]),
        RPGCommandSpec(code: 118, id: "label", fieldNames: ["name"]),
        RPGCommandSpec(code: 119, id: "jumpToLabel", fieldNames: ["name"]),
        RPGCommandSpec(code: 121, id: "controlSwitches", fieldNames: ["startId", "endId", "operation"]),
        RPGCommandSpec(code: 122, id: "controlVariables", fieldNames: ["startId", "endId", "operation", "operand"]),
        RPGCommandSpec(code: 124, id: "changeTimer", fieldNames: ["operation", "seconds"]),
        RPGCommandSpec(code: 125, id: "changeGold", fieldNames: ["operation", "operand"]),
        RPGCommandSpec(code: 303, id: "changeName", fieldNames: ["actorId", "name"]),
        RPGCommandSpec(code: 322, id: "changeActorGraphic", fieldNames: ["actorId", "characterName", "characterIndex", "faceName", "faceIndex"]),
        RPGCommandSpec(code: 355, id: "script", fieldNames: ["line"]),
        RPGCommandSpec(code: 655, id: "scriptLine", fieldNames: ["line"]),
        RPGCommandSpec(code: 0, id: "endOfList", fieldNames: []),
    ]

    static func spec(for code: Int, json: Bool) -> RPGCommandSpec? {
        let table = json ? jsonCommon : binaryCommon
        return table.first(where: { $0.code == code })
    }
}
