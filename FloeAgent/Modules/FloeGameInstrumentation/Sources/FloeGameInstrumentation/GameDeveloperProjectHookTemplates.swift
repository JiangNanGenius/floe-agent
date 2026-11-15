// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeGameCore
import FloeGameDeveloperCore

struct GameDeveloperProjectHookTemplate: Sendable, Equatable {
    let id: String
    let resource: String
    let sdkPath: String
    let sha256: String
    let bytes: Int
    let data: Data
}

protocol GameDeveloperInstrumentationBundleTemplates {
    var catalogVersion: String { get }
    var frozenSourceRevision: String { get }
    var pinsSHA256: String { get }
    var license: GameDeveloperInstrumentationTemplate { get }
    var notice: Data { get }
    var templatePins: [GameDeveloperBundleTemplatePin] { get }
}

extension GameDeveloperInstrumentationTemplates: GameDeveloperInstrumentationBundleTemplates {}

extension GameDeveloperProjectHookTemplates: GameDeveloperInstrumentationBundleTemplates {
    var templatePins: [GameDeveloperBundleTemplatePin] {
        all.map { .init(id: $0.id, resource: $0.resource, sdkPath: $0.sdkPath,
                        sha256: $0.sha256, bytes: $0.bytes) }
    }
}

/// Reviewed GDevelop/Cocos resources. It is deliberately separate from the
/// Unity/Godot template pins so the two source sets can be audited and patched
/// independently. Every plan verifies these bytes before returning.
public struct GameDeveloperProjectHookTemplates: Sendable, Equatable {
    let catalogVersion: String
    let frozenSourceRevision: String
    let sdkRelativeRoot: String
    let pinsSHA256: String
    let gdevelopBridge: GameDeveloperProjectHookTemplate
    let cocosBridge: GameDeveloperProjectHookTemplate
    let license: GameDeveloperInstrumentationTemplate
    let notice: Data

    var all: [GameDeveloperProjectHookTemplate] { [gdevelopBridge, cocosBridge] }

    func template(id: String) throws -> GameDeveloperProjectHookTemplate {
        guard let value = all.first(where: { $0.id == id }) else {
            throw GameDeveloperInstrumentationError.templateMissing(id)
        }
        return value
    }

    func template(resource: String) throws -> GameDeveloperProjectHookTemplate {
        guard let value = all.first(where: { $0.resource == resource }) else {
            throw GameDeveloperInstrumentationError.templateMissing(resource)
        }
        return value
    }

    public init() throws {
        guard let pinsURL = Bundle.module.url(forResource: "PROJECT-HOOK-PINS", withExtension: "json",
                                              subdirectory: "Resources") else {
            throw GameDeveloperInstrumentationError.templateMissing("Resources/PROJECT-HOOK-PINS.json")
        }
        let pinsData: Data
        do { pinsData = try Data(contentsOf: pinsURL) }
        catch { throw GameDeveloperInstrumentationError.templateMissing("Resources/PROJECT-HOOK-PINS.json") }
        let pins: Pins
        do { pins = try JSONDecoder().decode(Pins.self, from: pinsData) }
        catch { throw GameDeveloperInstrumentationError.templateIntegrity("PROJECT-HOOK-PINS.json") }
        guard pins.schemaVersion == 1,
              pins.catalogVersion == GameDeveloperEngineCatalog.version,
              pins.frozenSourceRevision == GameDeveloperInstrumentationConstants.frozenSourceRevision else {
            throw GameDeveloperInstrumentationError.templateIntegrity("project hook pins metadata")
        }
        let expectedIDs = ["gdevelopBridge", "cocosBridge"]
        guard pins.templates.count == expectedIDs.count,
              Set(pins.templates.map(\.id)) == Set(expectedIDs) else {
            throw GameDeveloperInstrumentationError.templateIntegrity("project hook template id set")
        }
        func load(_ item: Pins.Item) throws -> GameDeveloperProjectHookTemplate {
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
        var loaded: [String: GameDeveloperProjectHookTemplate] = [:]
        for item in pins.templates { loaded[item.id] = try load(item) }
        guard let gdevelopBridge = loaded["gdevelopBridge"],
              let cocosBridge = loaded["cocosBridge"] else {
            throw GameDeveloperInstrumentationError.templateIntegrity("project hook template mapping")
        }
        guard let licenseURL = Self.bundleResource("LICENSE") else {
            throw GameDeveloperInstrumentationError.templateMissing("Resources/LICENSE")
        }
        let licenseData: Data
        do { licenseData = try Data(contentsOf: licenseURL) }
        catch { throw GameDeveloperInstrumentationError.templateMissing("Resources/LICENSE") }
        guard licenseData.count == pins.license.bytes,
              GameDigest.sha256(licenseData) == pins.license.sha256 else {
            throw GameDeveloperInstrumentationError.templateIntegrity("project hook LICENSE")
        }
        guard let noticeURL = Self.bundleResource("PROJECT-HOOK-NOTICE.md") else {
            throw GameDeveloperInstrumentationError.templateMissing("Resources/PROJECT-HOOK-NOTICE.md")
        }
        let notice: Data
        do { notice = try Data(contentsOf: noticeURL) }
        catch { throw GameDeveloperInstrumentationError.templateMissing("Resources/PROJECT-HOOK-NOTICE.md") }
        guard !notice.isEmpty else {
            throw GameDeveloperInstrumentationError.templateIntegrity("PROJECT-HOOK-NOTICE.md")
        }
        self.init(catalogVersion: pins.catalogVersion,
                  frozenSourceRevision: pins.frozenSourceRevision,
                  sdkRelativeRoot: pins.sdkRelativeRoot,
                  pinsSHA256: GameDigest.sha256(pinsData),
                  gdevelopBridge: gdevelopBridge,
                  cocosBridge: cocosBridge,
                  license: .init(id: "license", resource: pins.license.resource,
                                 sdkPath: pins.license.sdkPath, sha256: pins.license.sha256,
                                 bytes: pins.license.bytes, data: licenseData),
                  notice: notice)
    }

    /// Test-only injection. Normal callers can only load the pinned bundle.
    init(catalogVersion: String = GameDeveloperEngineCatalog.version,
         frozenSourceRevision: String = GameDeveloperInstrumentationConstants.frozenSourceRevision,
         sdkRelativeRoot: String = "test",
         pinsSHA256: String = "test",
         gdevelopBridge: GameDeveloperProjectHookTemplate,
         cocosBridge: GameDeveloperProjectHookTemplate,
         license: GameDeveloperInstrumentationTemplate,
         notice: Data) {
        self.catalogVersion = catalogVersion
        self.frozenSourceRevision = frozenSourceRevision
        self.sdkRelativeRoot = sdkRelativeRoot
        self.pinsSHA256 = pinsSHA256
        self.gdevelopBridge = gdevelopBridge
        self.cocosBridge = cocosBridge
        self.license = license
        self.notice = notice
    }

    /// Fails closed when a reviewed template loses the host gate or gains a
    /// player-reachable effect. Called by every GDevelop/Cocos plan.
    func dormancy(for engine: GameEngineID) throws -> GameDeveloperInstrumentationDormancy {
        switch engine {
        case .gdevelop: return try Self.validateGDevelopDormancy(gdevelopBridge.data)
        case .cocosCreator: return try Self.validateCocosDormancy(cocosBridge.data)
        default: throw GameDeveloperInstrumentationError.unsupportedEngine(engine)
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

    private static func validateGDevelopDormancy(_ data: Data) throws -> GameDeveloperInstrumentationDormancy {
        guard let text = String(data: data, encoding: .utf8) else {
            throw GameDeveloperInstrumentationError.dormancyUnverified("GDevelop bridge is not UTF-8")
        }
        var failures: [String] = []
        for required in ["window.FloeDeveloper", "registerPushed", "updatePushed",
                         "takeCommands", "ackCommand", "getTimeManager", "renderAndStep",
                         "getObjects", "setNumber", "setString", "setBoolean",
                         "engine.step", "object.setPosition", "variable.set", "setInterval(publish"] {
            if !text.contains(required) { failures.append("GDevelop bridge is missing \(required)") }
        }
        let gates = text.components(separatedBy: "window.FloeDeveloper").count - 1
        if gates < 2 { failures.append("GDevelop bridge has \(gates) window.FloeDeveloper gates, expected at least 2") }
        if let host = text.range(of: "window.FloeDeveloper"),
           let timer = text.range(of: "setInterval") {
            if host.lowerBound > timer.lowerBound {
                failures.append("GDevelop bridge starts its timer before checking the host")
            }
        } else {
            failures.append("GDevelop bridge has no host/timer ordering")
        }
        for forbidden in ["eval(", "new Function", "XMLHttpRequest", "WebSocket", "fetch(",
                          "createElement", "importScripts", "document.cookie"] where text.contains(forbidden) {
            failures.append("GDevelop bridge contains forbidden \(forbidden)")
        }
        guard failures.isEmpty else {
            throw GameDeveloperInstrumentationError.dormancyUnverified(failures.joined(separator: "; "))
        }
        return .init(
            hostObjectName: GameDeveloperInstrumentationConstants.hostObjectName,
            gated: true,
            evidence: [
                "The script returns before scene capture, registration or setInterval unless window.FloeDeveloper provides the fixed typed API.",
                "Pauses, time scale, variables and positions are applied only to public GDJS RuntimeGame/RuntimeScene/Variable/RuntimeObject objects.",
                "A missing or replaced host object stops the only polling loop; no DOM, network, evaluator or native API is used."
            ],
            productionBehavior: "Without the Floe host page object the exported game contains an inert script file and no menu, polling loop or command surface.",
            productionBehaviorZhHans: "没有 Floe 宿主页面对象时，导出的游戏只包含一个惰性脚本文件，没有菜单、轮询或命令入口。")
    }

    private static func validateCocosDormancy(_ data: Data) throws -> GameDeveloperInstrumentationDormancy {
        guard let text = String(data: data, encoding: .utf8) else {
            throw GameDeveloperInstrumentationError.dormancyUnverified("Cocos component is not UTF-8")
        }
        var errors: [String] = []
        for required in ["(globalThis as any).FloeDeveloper", "hostReady(D)", "addPersistRootNode",
                         "setInterval", "clearInterval", "removePersistRootNode",
                         "takeCommands", "ackCommand", "d.tick", "d.pause()", "d.resume()"] {
            if !text.contains(required) { errors.append("Cocos component is missing \(required)") }
        }
        if let host = text.range(of: "hostReady(D)") {
            if let persist = text.range(of: "addPersistRootNode"), host.lowerBound > persist.lowerBound {
                errors.append("Cocos component persists the node before checking the host")
            }
            if let timer = text.range(of: "setInterval"), host.lowerBound > timer.lowerBound {
                errors.append("Cocos component starts its timer before checking the host")
            }
        } else {
            errors.append("Cocos component has no host availability check")
        }
        for forbidden in ["eval(", "new Function", "XMLHttpRequest", "WebSocket", "fetch(",
                          "input.on", "videoPlayer", "OpenGL"] where text.contains(forbidden) {
            errors.append("Cocos component contains forbidden \(forbidden)")
        }
        guard errors.isEmpty else {
            throw GameDeveloperInstrumentationError.dormancyUnverified(errors.joined(separator: "; "))
        }
        return .init(
            hostObjectName: GameDeveloperInstrumentationConstants.hostObjectName,
            gated: true,
            evidence: [
                "onLoad returns before addPersistRootNode, registration or setInterval unless window.FloeDeveloper provides the fixed typed API.",
                "The component reads only the imported public cc Director/Game objects and stops its timer and persistence when the host disappears.",
                "No input listener, DOM access, evaluator, network call or native API is added."
            ],
            productionBehavior: "Without the Floe host page object the attached component is inert, starts no timer and exposes no menu.",
            productionBehaviorZhHans: "没有 Floe 宿主页面对象时，附加组件保持惰性，不启动计时器，也不暴露菜单。")
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
