// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeGameCore

/// One typed value crossing the development bridge. The bridge deliberately
/// has no object/array/function value: only values that can be rendered,
/// validated and read back safely by the native menu.
public enum GameDeveloperValue: Equatable, Sendable, Codable {
    case boolean(Bool)
    case integer(Int)
    case number(Double)
    case text(String)

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Bool.self) {
            self = .boolean(value); return
        }
        if let value = try? container.decode(Int.self) {
            self = .integer(value); return
        }
        if let value = try? container.decode(Double.self) {
            self = .number(value); return
        }
        if let value = try? container.decode(String.self) {
            self = .text(value); return
        }
        throw DecodingError.dataCorruptedError(in: container,
            debugDescription: "A developer value must be a boolean, number or string")
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .boolean(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .text(let value): try container.encode(value)
        }
    }

    public var displayText: String {
        switch self {
        case .boolean(let value): return value ? "true" : "false"
        case .integer(let value): return String(value)
        case .number(let value):
            guard value.isFinite else { return "—" }
            if value.rounded() == value,
               value >= Double(Int.min), value <= Double(Int.max) {
                return String(Int(value))
            }
            return String(format: "%.6g", value)
        case .text(let value): return value
        }
    }

    public var booleanValue: Bool? { if case .boolean(let value) = self { return value }; return nil }
    public var integerValue: Int? { if case .integer(let value) = self { return value }; return nil }
    public var numberValue: Double? {
        switch self {
        case .integer(let value): return Double(value)
        case .number(let value): return value
        default: return nil
        }
    }
    public var textValue: String? { if case .text(let value) = self { return value }; return nil }
}

public enum GameDeveloperFieldKind: String, Codable, Sendable, CaseIterable {
    case boolean
    case integer
    case number
    case text
    case choice
    case readOnlyText
    case readOnlyNumber
    case readOnlyBoolean

    public var isReadOnly: Bool {
        switch self {
        case .readOnlyText, .readOnlyNumber, .readOnlyBoolean: return true
        default: return false
        }
    }
}

public struct GameDeveloperChoiceOption: Codable, Equatable, Sendable, Identifiable {
    public let value: String
    public let label: String
    public let labelZhHans: String

    public init(value: String, label: String, labelZhHans: String? = nil) {
        self.value = value
        self.label = label
        self.labelZhHans = labelZhHans ?? label
    }

    public var id: String { value }
}

public struct GameDeveloperFieldDescriptor: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let label: String
    public let labelZhHans: String
    public let group: String
    public let groupZhHans: String
    public let kind: GameDeveloperFieldKind
    public let symbol: String?
    public let detail: String?
    public let detailZhHans: String?
    public let minimum: Double?
    public let maximum: Double?
    public let step: Double?
    public let maximumLength: Int?
    public let options: [GameDeveloperChoiceOption]
    public let isReadOnly: Bool

    public init(id: String, label: String, labelZhHans: String? = nil,
                group: String, groupZhHans: String? = nil,
                kind: GameDeveloperFieldKind, symbol: String? = nil,
                detail: String? = nil, detailZhHans: String? = nil,
                minimum: Double? = nil, maximum: Double? = nil, step: Double? = nil,
                maximumLength: Int? = nil, options: [GameDeveloperChoiceOption] = [],
                isReadOnly: Bool? = nil) {
        self.id = id
        self.label = label
        self.labelZhHans = labelZhHans ?? label
        self.group = group
        self.groupZhHans = groupZhHans ?? group
        self.kind = kind
        self.symbol = symbol
        self.detail = detail
        self.detailZhHans = detailZhHans
        self.minimum = minimum
        self.maximum = maximum
        self.step = step
        self.maximumLength = maximumLength
        self.options = options
        self.isReadOnly = isReadOnly ?? kind.isReadOnly
    }
}

public enum GameDeveloperActionRole: String, Codable, Sendable, CaseIterable {
    case safe
    case destructive
    case jump
}

public enum GameDeveloperConfirmation: String, Codable, Sendable, CaseIterable {
    case none
    case required
}

public struct GameDeveloperActionParameterDescriptor: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let label: String
    public let labelZhHans: String
    public let kind: GameDeveloperFieldKind
    public let detail: String?
    public let detailZhHans: String?
    public let minimum: Double?
    public let maximum: Double?
    public let step: Double?
    public let maximumLength: Int?
    public let options: [GameDeveloperChoiceOption]
    public let isRequired: Bool
    public let defaultValue: GameDeveloperValue?

    public init(id: String, label: String, labelZhHans: String? = nil,
                kind: GameDeveloperFieldKind, detail: String? = nil,
                detailZhHans: String? = nil, minimum: Double? = nil,
                maximum: Double? = nil, step: Double? = nil,
                maximumLength: Int? = nil, options: [GameDeveloperChoiceOption] = [],
                isRequired: Bool = true, defaultValue: GameDeveloperValue? = nil) {
        self.id = id
        self.label = label
        self.labelZhHans = labelZhHans ?? label
        self.kind = kind
        self.detail = detail
        self.detailZhHans = detailZhHans
        self.minimum = minimum
        self.maximum = maximum
        self.step = step
        self.maximumLength = maximumLength
        self.options = options
        self.isRequired = isRequired
        self.defaultValue = defaultValue
    }

    private enum CodingKeys: String, CodingKey {
        case id, label, labelZhHans, kind, detail, detailZhHans, minimum, maximum,
             step, maximumLength, options, isRequired, defaultValue
    }
}

public struct GameDeveloperActionDescriptor: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let label: String
    public let labelZhHans: String
    public let group: String
    public let groupZhHans: String
    public let symbol: String?
    public let detail: String?
    public let detailZhHans: String?
    public let role: GameDeveloperActionRole
    public let confirmation: GameDeveloperConfirmation
    public let parameters: [GameDeveloperActionParameterDescriptor]
    public let isQuick: Bool

    public init(id: String, label: String, labelZhHans: String? = nil,
                group: String, groupZhHans: String? = nil,
                symbol: String? = nil, detail: String? = nil,
                detailZhHans: String? = nil, role: GameDeveloperActionRole = .safe,
                confirmation: GameDeveloperConfirmation = .none,
                parameters: [GameDeveloperActionParameterDescriptor] = [],
                isQuick: Bool = false) {
        self.id = id
        self.label = label
        self.labelZhHans = labelZhHans ?? label
        self.group = group
        self.groupZhHans = groupZhHans ?? group
        self.symbol = symbol
        self.detail = detail
        self.detailZhHans = detailZhHans
        self.role = role
        self.confirmation = confirmation
        self.parameters = parameters
        self.isQuick = isQuick
    }
}

public enum GameDeveloperResetMode: String, Codable, Sendable, CaseIterable {
    case hook
    case reload
    case none
}

public struct GameDeveloperSupports: Codable, Equatable, Sendable {
    public let liveState: Bool
    public let snapshot: Bool
    public let restore: Bool
    public let pause: Bool
    public let resume: Bool
    public let speed: Bool
    public let reset: GameDeveloperResetMode
    public let screenshot: Bool
    public let fields: Bool
    public let actions: Bool
    public let projectRegistration: Bool

    public init(liveState: Bool, snapshot: Bool, restore: Bool,
                pause: Bool, resume: Bool, speed: Bool,
                reset: GameDeveloperResetMode, screenshot: Bool,
                fields: Bool, actions: Bool, projectRegistration: Bool) {
        self.liveState = liveState
        self.snapshot = snapshot
        self.restore = restore
        self.pause = pause
        self.resume = resume
        self.speed = speed
        self.reset = reset
        self.screenshot = screenshot
        self.fields = fields
        self.actions = actions
        self.projectRegistration = projectRegistration
    }

    private enum CodingKeys: String, CodingKey {
        case liveState, snapshot, restore, pause, resume, speed, reset, screenshot,
             fields, actions, projectRegistration
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        liveState = try values.decodeIfPresent(Bool.self, forKey: .liveState) ?? false
        snapshot = try values.decodeIfPresent(Bool.self, forKey: .snapshot) ?? false
        restore = try values.decodeIfPresent(Bool.self, forKey: .restore) ?? false
        pause = try values.decodeIfPresent(Bool.self, forKey: .pause) ?? false
        resume = try values.decodeIfPresent(Bool.self, forKey: .resume) ?? false
        speed = try values.decodeIfPresent(Bool.self, forKey: .speed) ?? false
        reset = try values.decodeIfPresent(GameDeveloperResetMode.self, forKey: .reset) ?? .none
        screenshot = try values.decodeIfPresent(Bool.self, forKey: .screenshot) ?? false
        fields = try values.decodeIfPresent(Bool.self, forKey: .fields) ?? false
        actions = try values.decodeIfPresent(Bool.self, forKey: .actions) ?? false
        projectRegistration = try values.decodeIfPresent(Bool.self, forKey: .projectRegistration) ?? false
    }
}

public struct GameDeveloperNotice: Codable, Equatable, Sendable, Identifiable {
    public let code: String
    public let message: String
    public let messageZhHans: String

    public var id: String { code + "|" + message }

    public init(code: String, message: String, messageZhHans: String? = nil) {
        self.code = code
        self.message = message
        self.messageZhHans = messageZhHans ?? message
    }

    private enum CodingKeys: String, CodingKey { case code, message, messageZhHans }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let code = try values.decode(String.self, forKey: .code)
        let message = try values.decode(String.self, forKey: .message)
        let messageZhHans = try values.decodeIfPresent(String.self, forKey: .messageZhHans)
        self.init(code: code, message: message, messageZhHans: messageZhHans)
    }
}

public struct GameDeveloperDiagnostics: Codable, Equatable, Sendable {
    public let fps: Double?
    public let frames: Int?
    public let viewportWidth: Int?
    public let viewportHeight: Int?
    public let visibility: String?
    public let canvases: Int?
    public let title: String?
    public let readyState: String?
    public let uptimeMilliseconds: Double?
    public let webAssembly: Bool?
    public let devicePixelRatio: Double?
    public let details: [String: String]

    public init(fps: Double? = nil, frames: Int? = nil,
                viewportWidth: Int? = nil, viewportHeight: Int? = nil,
                visibility: String? = nil, canvases: Int? = nil,
                title: String? = nil, readyState: String? = nil,
                uptimeMilliseconds: Double? = nil, webAssembly: Bool? = nil,
                devicePixelRatio: Double? = nil, details: [String: String] = [:]) {
        self.fps = fps
        self.frames = frames
        self.viewportWidth = viewportWidth
        self.viewportHeight = viewportHeight
        self.visibility = visibility
        self.canvases = canvases
        self.title = title
        self.readyState = readyState
        self.uptimeMilliseconds = uptimeMilliseconds
        self.webAssembly = webAssembly
        self.devicePixelRatio = devicePixelRatio
        self.details = details
    }

    private enum CodingKeys: String, CodingKey {
        case fps, frames, viewportWidth, viewportHeight, visibility, canvases, title,
             readyState, uptimeMilliseconds, webAssembly, devicePixelRatio, details
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        fps = try values.decodeIfPresent(Double.self, forKey: .fps)
        frames = try values.decodeIfPresent(Int.self, forKey: .frames)
        viewportWidth = try values.decodeIfPresent(Int.self, forKey: .viewportWidth)
        viewportHeight = try values.decodeIfPresent(Int.self, forKey: .viewportHeight)
        visibility = try values.decodeIfPresent(String.self, forKey: .visibility)
        canvases = try values.decodeIfPresent(Int.self, forKey: .canvases)
        title = try values.decodeIfPresent(String.self, forKey: .title)
        readyState = try values.decodeIfPresent(String.self, forKey: .readyState)
        uptimeMilliseconds = try values.decodeIfPresent(Double.self, forKey: .uptimeMilliseconds)
        webAssembly = try values.decodeIfPresent(Bool.self, forKey: .webAssembly)
        devicePixelRatio = try values.decodeIfPresent(Double.self, forKey: .devicePixelRatio)
        details = try values.decodeIfPresent([String: String].self, forKey: .details) ?? [:]
    }
}

public struct GameDeveloperCapabilities: Codable, Equatable, Sendable {
    public let protocolVersion: Int
    public let bridgeVersion: String
    public let engine: GameEngineID
    public let runtime: String
    public let supports: GameDeveloperSupports
    public let fields: [GameDeveloperFieldDescriptor]
    public let actions: [GameDeveloperActionDescriptor]
    public let notices: [GameDeveloperNotice]
    public let diagnostics: GameDeveloperDiagnostics

    public init(protocolVersion: Int = 1, bridgeVersion: String,
                engine: GameEngineID, runtime: String,
                supports: GameDeveloperSupports,
                fields: [GameDeveloperFieldDescriptor],
                actions: [GameDeveloperActionDescriptor],
                notices: [GameDeveloperNotice] = [],
                diagnostics: GameDeveloperDiagnostics = .init()) {
        self.protocolVersion = protocolVersion
        self.bridgeVersion = bridgeVersion
        self.engine = engine
        self.runtime = runtime
        self.supports = supports
        self.fields = fields
        self.actions = actions
        self.notices = notices
        self.diagnostics = diagnostics
    }

    public func field(_ id: String) -> GameDeveloperFieldDescriptor? {
        fields.first { $0.id == id }
    }

    public func action(_ id: String) -> GameDeveloperActionDescriptor? {
        actions.first { $0.id == id }
    }
}

public struct GameDeveloperRuntimeState: Codable, Equatable, Sendable {
    public let revision: Int
    public let capturedAt: Date
    public let values: [String: GameDeveloperValue]
    public let fieldErrors: [String: String]

    public init(revision: Int, capturedAt: Date,
                values: [String: GameDeveloperValue],
                fieldErrors: [String: String] = [:]) {
        self.revision = revision
        self.capturedAt = capturedAt
        self.values = values
        self.fieldErrors = fieldErrors
    }

    private enum CodingKeys: String, CodingKey {
        case revision, capturedAt, values, fieldErrors
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        revision = try values.decodeIfPresent(Int.self, forKey: .revision) ?? 0
        let captured = try values.decodeIfPresent(Double.self, forKey: .capturedAt)
        capturedAt = Date(timeIntervalSince1970: (captured ?? 0) / 1_000)
        self.values = try values.decodeIfPresent([String: GameDeveloperValue].self, forKey: .values) ?? [:]
        fieldErrors = try values.decodeIfPresent([String: String].self, forKey: .fieldErrors) ?? [:]
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(revision, forKey: .revision)
        try container.encode(capturedAt.timeIntervalSince1970 * 1_000, forKey: .capturedAt)
        try container.encode(values, forKey: .values)
        try container.encode(fieldErrors, forKey: .fieldErrors)
    }
}

public struct GameDeveloperFieldChange: Equatable, Sendable {
    public let id: String
    public let value: GameDeveloperValue

    public init(id: String, value: GameDeveloperValue) {
        self.id = id
        self.value = value
    }
}

public enum GameDeveloperActionStatus: String, Codable, Sendable {
    case applied
    case rejected
    case unsupported
    case reloading
}

public struct GameDeveloperActionOutcome: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let actionID: String
    public let status: GameDeveloperActionStatus
    public let message: String
    public let messageZhHans: String
    public let changedFieldIDs: [String]
    public let state: GameDeveloperRuntimeState?
    public let at: Date

    public init(id: UUID = UUID(), actionID: String, status: GameDeveloperActionStatus,
                message: String, messageZhHans: String? = nil,
                changedFieldIDs: [String] = [], state: GameDeveloperRuntimeState? = nil,
                at: Date = Date()) {
        self.id = id
        self.actionID = actionID
        self.status = status
        self.message = message
        self.messageZhHans = messageZhHans ?? message
        self.changedFieldIDs = changedFieldIDs
        self.state = state
        self.at = at
    }

    private enum CodingKeys: String, CodingKey {
        case id, actionID, status, message, messageZhHans, changedFieldIDs, state, at
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        actionID = try values.decode(String.self, forKey: .actionID)
        status = try values.decode(GameDeveloperActionStatus.self, forKey: .status)
        message = try values.decodeIfPresent(String.self, forKey: .message) ?? ""
        messageZhHans = try values.decodeIfPresent(String.self, forKey: .messageZhHans) ?? message
        changedFieldIDs = try values.decodeIfPresent([String].self, forKey: .changedFieldIDs) ?? []
        state = try values.decodeIfPresent(GameDeveloperRuntimeState.self, forKey: .state)
        at = try values.decodeIfPresent(Date.self, forKey: .at) ?? Date()
    }
}

public enum GameDeveloperCheckpointKind: String, Codable, Sendable {
    case baseline
    case beforeFieldWrite
    case beforeAction
    case beforeRestore
    case manual
}

public struct GameDeveloperCheckpoint: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let kind: GameDeveloperCheckpointKind
    public let label: String
    public let labelZhHans: String
    public let createdAt: Date
    public let engine: GameEngineID
    /// A complete engine snapshot. Nil means only field values were captured;
    /// such a checkpoint can revert fields but cannot undo arbitrary actions.
    public let snapshot: Data?
    public let fieldValues: [String: GameDeveloperValue]
    public let byteCount: Int

    public init(id: UUID = UUID(), kind: GameDeveloperCheckpointKind,
                label: String, labelZhHans: String? = nil,
                createdAt: Date = Date(), engine: GameEngineID,
                snapshot: Data?, fieldValues: [String: GameDeveloperValue],
                byteCount: Int) {
        self.id = id
        self.kind = kind
        self.label = label
        self.labelZhHans = labelZhHans ?? label
        self.createdAt = createdAt
        self.engine = engine
        self.snapshot = snapshot
        self.fieldValues = fieldValues
        self.byteCount = byteCount
    }

    public var isComplete: Bool { snapshot != nil }
}

public struct GameDeveloperSnapshot: Equatable, Sendable {
    public let engine: GameEngineID
    public let createdAt: Date
    public let data: Data
    public init(engine: GameEngineID, createdAt: Date = Date(), data: Data) {
        self.engine = engine
        self.createdAt = createdAt
        self.data = data
    }
}

public struct GameDeveloperHistoryEntry: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let actionID: String
    public let label: String
    public let labelZhHans: String
    public let status: GameDeveloperActionStatus
    public let message: String
    public let messageZhHans: String
    public let at: Date
    public let checkpointID: UUID?

    public init(id: UUID = UUID(), actionID: String, label: String,
                labelZhHans: String? = nil, status: GameDeveloperActionStatus,
                message: String, messageZhHans: String? = nil, at: Date = Date(),
                checkpointID: UUID? = nil) {
        self.id = id
        self.actionID = actionID
        self.label = label
        self.labelZhHans = labelZhHans ?? label
        self.status = status
        self.message = message
        self.messageZhHans = messageZhHans ?? message
        self.at = at
        self.checkpointID = checkpointID
    }
}

public enum GameDeveloperResetScope: Equatable, Sendable {
    case baseline
    case checkpoint(UUID)
    case restart
    case reload
}

public struct GameDeveloperSessionBinding: Equatable, Sendable, Codable {
    public let projectID: UUID
    public let owner: GameProjectOwner
    public let savedRevision: String
    public let runID: UUID
    public let engine: GameEngineID

    public init(projectID: UUID, owner: GameProjectOwner, savedRevision: String,
                runID: UUID, engine: GameEngineID) {
        self.projectID = projectID
        self.owner = owner
        self.savedRevision = savedRevision
        self.runID = runID
        self.engine = engine
    }
}

public struct GameDeveloperAttachReceipt: Equatable, Sendable {
    public let binding: GameDeveloperSessionBinding
    public let bridgeToken: UUID
    public let protocolVersion: Int
    public let runtime: String

    public init(binding: GameDeveloperSessionBinding, bridgeToken: UUID,
                protocolVersion: Int, runtime: String) {
        self.binding = binding
        self.bridgeToken = bridgeToken
        self.protocolVersion = protocolVersion
        self.runtime = runtime
    }
}
