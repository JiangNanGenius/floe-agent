// SPDX-License-Identifier: MPL-2.0
import Foundation
import CoreFoundation
import FloeGameCore
@testable import FloeGameDeveloperCore

enum DeveloperTestSupport {
    static let projectID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    static let runID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    static let token = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!

    static func binding(engine: GameEngineID = .phaser) -> GameDeveloperSessionBinding {
        .init(projectID: projectID, owner: .space(recordID: projectID),
              savedRevision: "saved-1", runID: runID, engine: engine)
    }

    static func capabilities(engine: GameEngineID = .phaser) -> GameDeveloperCapabilities {
        .init(
            bridgeVersion: "test-1",
            engine: engine,
            runtime: "Test runtime",
            supports: .init(liveState: true, snapshot: true, restore: true,
                            pause: true, resume: true, speed: true,
                            reset: .reload, screenshot: true,
                            fields: true, actions: true, projectRegistration: true),
            fields: [
                .init(id: "party.gold", label: "Gold", labelZhHans: "金钱",
                      group: "Party", groupZhHans: "队伍", kind: .integer,
                      minimum: 0, maximum: 99_999_999, step: 1),
                .init(id: "player.x", label: "Player X", labelZhHans: "玩家 X",
                      group: "World", groupZhHans: "世界", kind: .number,
                      minimum: 0, maximum: 1_000),
                .init(id: "camera.roll", label: "Camera roll", labelZhHans: "相机旋转",
                      group: "Camera", groupZhHans: "相机", kind: .readOnlyNumber,
                      minimum: -360, maximum: 360),
                .init(id: "engine.paused", label: "Paused", labelZhHans: "已暂停",
                      group: "Engine", groupZhHans: "引擎", kind: .readOnlyBoolean),
                .init(id: "engine.speed", label: "Speed", labelZhHans: "速度",
                      group: "Engine", groupZhHans: "引擎", kind: .number,
                      minimum: 0.25, maximum: 4, step: 0.25),
                .init(id: "party.name", label: "Party name", labelZhHans: "队伍名称",
                      group: "Party", groupZhHans: "队伍", kind: .text,
                      maximumLength: 64)
            ],
            actions: [
                .init(id: "party.gainGold", label: "Gain gold", labelZhHans: "增加金钱",
                      group: "Party", groupZhHans: "队伍", symbol: "dollarsign.circle",
                      parameters: [.init(id: "amount", label: "Amount", labelZhHans: "数量",
                                         kind: .integer, minimum: -10_000, maximum: 10_000,
                                         step: 1, isRequired: true, defaultValue: .integer(10))]),
                .init(id: "engine.pause", label: "Pause", labelZhHans: "暂停",
                      group: "Engine", groupZhHans: "引擎", symbol: "pause.fill", isQuick: true),
                .init(id: "engine.resume", label: "Resume", labelZhHans: "继续",
                      group: "Engine", groupZhHans: "引擎", symbol: "play.fill", isQuick: true),
                .init(id: "party.destroy", label: "Destroy party", labelZhHans: "销毁队伍",
                      group: "Party", groupZhHans: "队伍", role: .destructive,
                      confirmation: .required)
            ],
            notices: [.init(code: "test-notice", message: "Test notice.", messageZhHans: "测试提示。")],
            diagnostics: .init(fps: 59.5, frames: 120, viewportWidth: 1024,
                               viewportHeight: 768, canvases: 1, webAssembly: false))
    }

    static func state(engine: GameEngineID = .phaser) -> GameDeveloperRuntimeState {
        .init(revision: 4, capturedAt: Date(), values: [
            "party.gold": .integer(120),
            "player.x": .number(12.5),
            "camera.roll": .number(1.25),
            "engine.paused": .boolean(false),
            "engine.speed": .number(1),
            "party.name": .text("Heroes")
        ])
    }
}

@MainActor
final class FakeDeveloperTransport: GameDeveloperTransport {
    let binding: GameDeveloperSessionBinding
    var capabilities: GameDeveloperCapabilities
    var state: GameDeveloperRuntimeState
    var rejectWrites = false
    var failAttach = false
    var responseSessionID: UUID?
    var responseRequestID: UUID?
    var responseDelay: Duration?
    var lastProbe = 0
    var lastRead = 0
    var lastWrite = 0
    var lastInvoke = 0
    var attachCount = 0
    var detachCount = 0
    var screenshot = Data([0x89, 0x50, 0x4E, 0x47])
    private var expectedSessionID: UUID?

    init(binding: GameDeveloperSessionBinding = DeveloperTestSupport.binding(),
         capabilities: GameDeveloperCapabilities = DeveloperTestSupport.capabilities(),
         state: GameDeveloperRuntimeState = DeveloperTestSupport.state()) {
        self.binding = binding
        self.capabilities = capabilities
        self.state = state
    }

    func attach() async throws -> GameDeveloperAttachReceipt {
        attachCount += 1
        if failAttach { throw GameDeveloperError.bridgeUnavailable("fake attach failure") }
        return .init(binding: binding, bridgeToken: DeveloperTestSupport.token,
                     protocolVersion: 1, runtime: capabilities.runtime)
    }

    func exchange(_ request: GameDeveloperTransportRequest) async throws -> GameDeveloperTransportResponse {
        if let responseDelay { try await Task.sleep(for: responseDelay) }
        expectedSessionID = expectedSessionID ?? request.sessionID
        switch request.operation {
        case .probe:
            lastProbe += 1
            return try response(request, value: JSONEncoder().encode(capabilities))
        case .read:
            lastRead += 1
            return try response(request, value: JSONEncoder().encode(state))
        case .write:
            lastWrite += 1
            let object = try JSONSerialization.jsonObject(with: request.payload) as? [String: Any] ?? [:]
            let changes = object["changes"] as? [[String: Any]] ?? []
            var changed: [String] = []
            var values = state.values
            for change in changes {
                guard let id = change["id"] as? String, let raw = change["value"],
                      capabilities.field(id) != nil,
                      let value = developerValue(raw) else { continue }
                if rejectWrites {
                    let outcome = GameDeveloperActionOutcome(
                        actionID: "fields.write", status: .rejected,
                        message: "Rejected by test transport.", state: state)
                    return try response(request, value: JSONEncoder().encode(outcome))
                }
                values[id] = value
                changed.append(id)
            }
            state = .init(revision: state.revision + 1, capturedAt: Date(), values: values)
            let outcome = GameDeveloperActionOutcome(
                actionID: "fields.write", status: .applied,
                message: "Applied \(changed.count).", changedFieldIDs: changed, state: state)
            return try response(request, value: JSONEncoder().encode(outcome))
        case .invoke:
            lastInvoke += 1
            let object = try JSONSerialization.jsonObject(with: request.payload) as? [String: Any] ?? [:]
            let id = object["id"] as? String ?? ""
            if id == "party.gainGold" {
                let args = object["arguments"] as? [String: Any] ?? [:]
                let amount = (args["amount"] as? NSNumber)?.intValue ?? 0
                var values = state.values
                values["party.gold"] = .integer((values["party.gold"]?.integerValue ?? 0) + amount)
                state = .init(revision: state.revision + 1, capturedAt: Date(), values: values)
                let outcome = GameDeveloperActionOutcome(
                    actionID: id, status: .applied, message: "Gold added.",
                    changedFieldIDs: ["party.gold"], state: state)
                return try response(request, value: JSONEncoder().encode(outcome))
            }
            if id == "engine.pause" {
                var values = state.values
                values["engine.paused"] = .boolean(true)
                state = .init(revision: state.revision + 1, capturedAt: Date(), values: values)
                let outcome = GameDeveloperActionOutcome(
                    actionID: id, status: .applied, message: "Paused.",
                    changedFieldIDs: ["engine.paused"], state: state)
                return try response(request, value: JSONEncoder().encode(outcome))
            }
            let outcome = GameDeveloperActionOutcome(
                actionID: id, status: .unsupported,
                message: "Unsupported by fake transport.", state: state)
            return try response(request, value: JSONEncoder().encode(outcome))
        case .snapshot:
            let snapshot: [String: Any] = [
                "format": "floe-developer-snapshot", "version": 1,
                "engine": binding.engine.rawValue,
                "capturedAt": Int(Date().timeIntervalSince1970 * 1_000),
                "state": ["values": state.values.mapValues { jsonValue($0) }]
            ]
            return try response(request, value: JSONSerialization.data(
                withJSONObject: ["snapshot": snapshot], options: [.sortedKeys]))
        case .restore:
            let object = try JSONSerialization.jsonObject(with: request.payload) as? [String: Any] ?? [:]
            if let snapshot = object["snapshot"] as? [String: Any],
               let inner = snapshot["state"] as? [String: Any],
               let rawValues = inner["values"] as? [String: Any] {
                var values: [String: GameDeveloperValue] = [:]
                for (key, raw) in rawValues {
                    if let value = developerValue(raw) { values[key] = value }
                }
                state = .init(revision: state.revision + 1, capturedAt: Date(), values: values)
            }
            let result: [String: Any] = [
                "restored": true,
                "state": (try JSONSerialization.jsonObject(with: JSONEncoder().encode(state))) as Any
            ]
            return try response(request, value: JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]))
        case .reset:
            return try response(request, value: Data(#"{"status":"reloading","message":"Restarting.","messageZhHans":"正在重新开始。"}"#.utf8))
        case .diagnostics:
            return try response(request, value: JSONEncoder().encode(capabilities.diagnostics))
        case .detach:
            return try response(request, value: Data("{}".utf8))
        }
    }

    func captureScreenshot() async throws -> Data { screenshot }
    func logs() -> [String] { ["fake log"] }
    func detach() { detachCount += 1 }

    private func response(_ request: GameDeveloperTransportRequest, value: Data) throws -> GameDeveloperTransportResponse {
        .init(sessionID: responseSessionID ?? request.sessionID,
              requestID: responseRequestID ?? request.requestID,
              engine: binding.engine, value: value)
    }

    private func developerValue(_ raw: Any) -> GameDeveloperValue? {
        if let text = raw as? String { return .text(text) }
        if let number = raw as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return .boolean(number.boolValue) }
            let double = number.doubleValue
            if double.rounded() == double, double >= Double(Int.min), double <= Double(Int.max) {
                return .integer(Int(double))
            }
            return .number(double)
        }
        return nil
    }

    private func jsonValue(_ value: GameDeveloperValue) -> Any {
        switch value {
        case .boolean(let flag): return flag
        case .integer(let number): return number
        case .number(let number): return number
        case .text(let text): return text
        }
    }
}
