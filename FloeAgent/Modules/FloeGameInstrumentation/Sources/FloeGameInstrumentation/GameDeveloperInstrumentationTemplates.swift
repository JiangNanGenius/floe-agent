// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeGameCore
import FloeGameDeveloperCore

public struct GameDeveloperInstrumentationTemplate: Sendable, Equatable {
    public let id: String
    public let resource: String
    public let sdkPath: String
    public let sha256: String
    public let bytes: Int
    public let data: Data
}

/// Reviewed MPL templates with a recorded local startup-dormancy amendment. The
/// package never loads project-supplied templates and never accepts a custom
/// template set from a caller.
public struct GameDeveloperInstrumentationTemplates: Sendable, Equatable {
    public let catalogVersion: String
    public let frozenSourceRevision: String
    public let sdkRelativeRoot: String
    public let pinsSHA256: String
    public let unityBridge: GameDeveloperInstrumentationTemplate
    public let unityJSLibrary: GameDeveloperInstrumentationTemplate
    public let unityBehaviour: GameDeveloperInstrumentationTemplate
    public let godotAutoload: GameDeveloperInstrumentationTemplate
    public let license: GameDeveloperInstrumentationTemplate
    public let notice: Data

    public var all: [GameDeveloperInstrumentationTemplate] {
        [unityBridge, unityJSLibrary, unityBehaviour, godotAutoload]
    }

    public func template(id: String) throws -> GameDeveloperInstrumentationTemplate {
        guard let value = all.first(where: { $0.id == id }) else {
            throw GameDeveloperInstrumentationError.templateMissing(id)
        }
        return value
    }

    public init() throws {
        guard let pinsURL = Bundle.module.url(forResource: "TEMPLATE-PINS", withExtension: "json",
                                              subdirectory: "Resources") else {
            throw GameDeveloperInstrumentationError.templateMissing("Resources/TEMPLATE-PINS.json")
        }
        let pinsData: Data
        do { pinsData = try Data(contentsOf: pinsURL) }
        catch { throw GameDeveloperInstrumentationError.templateMissing("Resources/TEMPLATE-PINS.json") }
        let pins: Pins
        do { pins = try JSONDecoder().decode(Pins.self, from: pinsData) }
        catch { throw GameDeveloperInstrumentationError.templateIntegrity("TEMPLATE-PINS.json") }
        guard pins.schemaVersion == 1,
              pins.catalogVersion == GameDeveloperEngineCatalog.version,
              pins.frozenSourceRevision == GameDeveloperInstrumentationConstants.frozenSourceRevision else {
            throw GameDeveloperInstrumentationError.templateIntegrity("template pins metadata")
        }
        let expectedIDs = ["unityBridge", "unityJSLibrary", "unityBehaviour", "godotAutoload"]
        guard pins.templates.count == expectedIDs.count,
              Set(pins.templates.map(\.id)) == Set(expectedIDs) else {
            throw GameDeveloperInstrumentationError.templateIntegrity("template id set")
        }
        func load(_ item: Pins.Item) throws -> GameDeveloperInstrumentationTemplate {
            guard let url = Self.bundleResource(item.resource) else {
                throw GameDeveloperInstrumentationError.templateMissing(item.resource)
            }
            let data: Data
            do { data = try Data(contentsOf: url) }
            catch { throw GameDeveloperInstrumentationError.templateMissing(item.resource) }
            guard data.count == item.bytes, GameDigest.sha256(data) == item.sha256 else {
                throw GameDeveloperInstrumentationError.templateIntegrity(item.resource)
            }
            return .init(id: item.id, resource: item.resource, sdkPath: item.sdkPath,
                         sha256: item.sha256, bytes: item.bytes, data: data)
        }
        var loaded: [String: GameDeveloperInstrumentationTemplate] = [:]
        for item in pins.templates { loaded[item.id] = try load(item) }
        guard let unityBridge = loaded["unityBridge"],
              let unityJSLibrary = loaded["unityJSLibrary"],
              let unityBehaviour = loaded["unityBehaviour"],
              let godotAutoload = loaded["godotAutoload"] else {
            throw GameDeveloperInstrumentationError.templateIntegrity("template mapping")
        }
        guard let noticeURL = Self.bundleResource("NOTICE.md") else {
            throw GameDeveloperInstrumentationError.templateMissing("Resources/NOTICE.md")
        }
        let notice: Data
        do { notice = try Data(contentsOf: noticeURL) }
        catch { throw GameDeveloperInstrumentationError.templateMissing("Resources/NOTICE.md") }
        guard !notice.isEmpty else {
            throw GameDeveloperInstrumentationError.templateIntegrity("NOTICE.md")
        }
        self.init(catalogVersion: pins.catalogVersion,
                  frozenSourceRevision: pins.frozenSourceRevision,
                  sdkRelativeRoot: pins.sdkRelativeRoot,
                  pinsSHA256: GameDigest.sha256(pinsData),
                  unityBridge: unityBridge,
                  unityJSLibrary: unityJSLibrary,
                  unityBehaviour: unityBehaviour,
                  godotAutoload: godotAutoload,
                  license: try load(pins.license),
                  notice: notice)
    }

    /// Test-only injection. Public callers can only use the pinned bundle.
    init(catalogVersion: String = GameDeveloperEngineCatalog.version,
         frozenSourceRevision: String = GameDeveloperInstrumentationConstants.frozenSourceRevision,
         sdkRelativeRoot: String = "test",
         pinsSHA256: String = "test",
         unityBridge: GameDeveloperInstrumentationTemplate,
         unityJSLibrary: GameDeveloperInstrumentationTemplate,
         unityBehaviour: GameDeveloperInstrumentationTemplate,
         godotAutoload: GameDeveloperInstrumentationTemplate,
         license: GameDeveloperInstrumentationTemplate,
         notice: Data) {
        self.catalogVersion = catalogVersion
        self.frozenSourceRevision = frozenSourceRevision
        self.sdkRelativeRoot = sdkRelativeRoot
        self.pinsSHA256 = pinsSHA256
        self.unityBridge = unityBridge
        self.unityJSLibrary = unityJSLibrary
        self.unityBehaviour = unityBehaviour
        self.godotAutoload = godotAutoload
        self.license = license
        self.notice = notice
    }

    /// Fails closed when a reviewed template loses the host gate or gains a
    /// player-reachable effect. Called by every `plan`.
    public func dormancy(for engine: GameEngineID) throws -> GameDeveloperInstrumentationDormancy {
        switch engine {
        case .unity:
            return try Self.validateUnityDormancy(bridge: unityBridge.data,
                                                  jsLibrary: unityJSLibrary.data,
                                                  behaviour: unityBehaviour.data)
        case .godot:
            return try Self.validateGodotDormancy(godotAutoload.data)
        default:
            throw GameDeveloperInstrumentationError.unsupportedEngine(engine)
        }
    }

    private static func bundleResource(_ relative: String) -> URL? {
        if !relative.contains("/") {
            return Bundle.module.url(forResource: relative, withExtension: nil,
                                     subdirectory: "Resources")
        }
        let value = relative as NSString
        let directory = value.deletingLastPathComponent
        let file = value.lastPathComponent as NSString
        let name = file.deletingPathExtension
        let ext = file.pathExtension
        let subdirectory = directory.isEmpty ? "Resources" : "Resources/" + directory
        return Bundle.module.url(forResource: name, withExtension: ext.isEmpty ? nil : ext,
                                 subdirectory: subdirectory)
    }

    private static func validateUnityDormancy(bridge: Data, jsLibrary: Data,
                                              behaviour: Data) throws -> GameDeveloperInstrumentationDormancy {
        guard let js = String(data: jsLibrary, encoding: .utf8),
              let csharp = String(data: bridge, encoding: .utf8),
              let pump = String(data: behaviour, encoding: .utf8) else {
            throw GameDeveloperInstrumentationError.dormancyUnverified("Unity template is not UTF-8")
        }
        var failures: [String] = []
        let functions = ["FloeDeveloperAvailable", "FloeDeveloperRegister", "FloeDeveloperPublish",
                         "FloeDeveloperTakeCommands", "FloeDeveloperAck"]
        for function in functions where !js.contains(function + ":") {
            failures.append("jslib is missing \(function)")
        }
        let gates = js.components(separatedBy: "window.FloeDeveloper").count - 1
        if gates < functions.count {
            failures.append("jslib has \(gates) window.FloeDeveloper gates, expected at least \(functions.count)")
        }
        for forbidden in ["SendMessage(", "UnityEditor", "OnGUI", "System.Reflection"] where
            csharp.contains(forbidden) || pump.contains(forbidden) {
            failures.append("Unity helper contains forbidden \(forbidden)")
        }
        for required in ["#if UNITY_WEBGL && !UNITY_EDITOR", "FloeDeveloperRegister",
                         "JsonUtility", "[DllImport(\"__Internal\")]"] where !csharp.contains(required) {
            failures.append("Unity bridge is missing \(required)")
        }
        for required in ["RuntimeInitializeOnLoadMethod", "#if UNITY_WEBGL && !UNITY_EDITOR",
                         "FloeDeveloperBridge.RegisterDefault", "FloeDeveloperBridge.Publish",
                         "FloeDeveloperBridge.ApplyPending"] where !pump.contains(required) {
            failures.append("Unity behaviour is missing \(required)")
        }
        guard let gate = pump.range(of: "!FloeDeveloperBridge.HostAvailable"),
              let allocation = pump.range(of: "new GameObject("), gate.lowerBound < allocation.lowerBound,
              csharp.contains("FloeDeveloperAvailable() == 1") else {
            throw GameDeveloperInstrumentationError.dormancyUnverified("Unity automatic loop must check the host before allocation")
        }
        guard failures.isEmpty else {
            throw GameDeveloperInstrumentationError.dormancyUnverified(failures.joined(separator: "; "))
        }
        return .init(
            hostObjectName: GameDeveloperInstrumentationConstants.hostObjectName,
            gated: true,
            evidence: [
                "The availability probe and four effect entry points check window.FloeDeveloper.",
                "The C# bridge forwards only through those jslib functions; it has no reflection, SendMessage, editor or GUI path.",
                "The automatic MonoBehaviour is compiled only for UNITY_WEBGL && !UNITY_EDITOR."
            ],
            productionBehavior: "Without the Floe host page object the task package contains no player-visible control or effect.",
            productionBehaviorZhHans: "没有 Floe 宿主页面对象时，游戏包内没有玩家可见的控制项或效果。"
        )
    }

    private static func validateGodotDormancy(_ data: Data) throws -> GameDeveloperInstrumentationDormancy {
        guard let text = String(data: data, encoding: .utf8) else {
            throw GameDeveloperInstrumentationError.dormancyUnverified("Godot template is not UTF-8")
        }
        var failures: [String] = []
        for required in ["if not OS.has_feature(\"web\"):", "window.FloeDeveloper",
                         "registerPushed", "updatePushed", "takeCommands", "ackCommand",
                         "Engine.time_scale", "get_tree().paused = true", "get_tree().paused = false"] {
            if !text.contains(required) { failures.append("Godot autoload is missing \(required)") }
        }
        let gates = text.components(separatedBy: "window.FloeDeveloper").count - 1
        if gates < 3 { failures.append("Godot autoload has \(gates) window.FloeDeveloper gates, expected at least 3") }
        for forbidden in ["OS.execute", "OS.create_process", "create_process("] where text.contains(forbidden) {
            failures.append("Godot autoload contains forbidden \(forbidden)")
        }
        guard let ready = text.range(of: "func _ready()"),
              let disabled = text.range(of: "set_process(false)", range: ready.lowerBound..<text.endIndex),
              let registration = text.range(of: "\t_register()", range: ready.lowerBound..<text.endIndex),
              disabled.lowerBound < registration.lowerBound,
              text.contains("if not _has_host():") else {
            throw GameDeveloperInstrumentationError.dormancyUnverified("Godot automatic loop must remain disabled without a host")
        }
        guard failures.isEmpty else {
            throw GameDeveloperInstrumentationError.dormancyUnverified(failures.joined(separator: "; "))
        }
        return .init(
            hostObjectName: GameDeveloperInstrumentationConstants.hostObjectName,
            gated: true,
            evidence: [
                "The autoload returns before registration unless the Web feature is active.",
                "Registration, value updates and command reads all check window.FloeDeveloper.",
                "Only engine.time_scale, engine.pause and engine.resume commands are handled; no evaluator or process launch exists."
            ],
            productionBehavior: "Without the Floe host page object the autoload performs no registration and consumes no commands.",
            productionBehaviorZhHans: "没有 Floe 宿主页面对象时，自动加载不会登记，也不会接收命令。"
        )
    }
}

private struct Pins: Decodable {
    struct Item: Decodable {
        let id: String
        let resource: String
        let sdkPath: String
        let sha256: String
        let bytes: Int
    }

    let schemaVersion: Int
    let catalogVersion: String
    let frozenSourceRevision: String
    let sdkRelativeRoot: String
    let templates: [Item]
    let license: Item
}
