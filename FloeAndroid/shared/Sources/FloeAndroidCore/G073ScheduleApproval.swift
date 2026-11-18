// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeCore
import FloeModels
import FloeTools

/// Private App-host review only. This is a projection, not a schedule or a
/// grant; the original scheduler validates and persists the eventual draft.
enum G073ScheduleApproval {
    typealias Value = SettingsDomainV1.JSONValue
    static let grantBound = true

    static func details(args: G073TaskScheduleTool.Arguments,
                        binding: G073TaskScheduleToolBinding) -> [String: Value]? {
        guard args.action == "create", args.id == nil, args.enable == nil, args.limit == nil,
              let rawTime = args.scheduledAt, !rawTime.isEmpty,
              let cadence = args.cadence.flatMap(TaskScheduleCadence.init(rawValue:)),
              let rawPrompt = args.prompt else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var anchor = formatter.date(from: rawTime)
        if anchor == nil { formatter.formatOptions = [.withInternetDateTime]; anchor = formatter.date(from: rawTime) }
        guard let anchor else { return nil }
        let prompt = rawPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        var title = args.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if title.isEmpty { title = String(prompt.prefix(40)) }
        guard safe(prompt, limit: 16_384, allowNewline: true),
              safe(title, limit: 160, allowNewline: false) else { return nil }
        let zone = TimeZone.current.identifier
        guard safe(zone, limit: 128, allowNewline: false), TimeZone(identifier: zone) != nil else { return nil }
        if let environment = binding.environmentID {
            guard binding.workspaceID != nil, safe(environment, limit: 128, allowNewline: false) else { return nil }
        }
        let interval: Int?
        if cadence == .interval {
            guard (args.intervalSeconds == nil) != (args.intervalHours == nil) else { return nil }
            if let seconds = args.intervalSeconds { interval = seconds }
            else if let hours = args.intervalHours, (1...8_760).contains(hours) { interval = hours * 3_600 }
            else { return nil }
            guard let interval, (60...31_536_000).contains(interval) else { return nil }
        } else {
            guard args.intervalSeconds == nil, args.intervalHours == nil else { return nil }
            interval = nil
        }
        let upstream: UUID?
        if cadence == .afterSuccess {
            guard let raw = args.upstreamRunID, let parsed = UUID(uuidString: raw) else { return nil }
            upstream = parsed
        } else {
            guard args.upstreamRunID == nil else { return nil }
            upstream = nil
        }
        let weekday = cadence == .weekly ? Calendar.current.component(.weekday, from: anchor) : nil
        return [
            "kind": .string("scheduleCreate"), "action": .string("create"),
            "title": .string(title), "prompt": .string(prompt), "cadence": .string(cadence.rawValue),
            "scheduledAt": .string(G073WireDate.iso(anchor)), "timezone": .string(zone),
            "weekday": weekday.map { .integer(Int64($0)) } ?? .null,
            "intervalSeconds": interval.map { .integer(Int64($0)) } ?? .null,
            "upstreamRunID": upstream.map { .string($0.uuidString.lowercased()) } ?? .null,
            "workspaceID": binding.workspaceID.map { .string($0.uuidString.lowercased()) } ?? .null,
            "modelID": .string(binding.modelID.uuidString.lowercased()),
            "environmentID": binding.environmentID.map { .string($0) } ?? .null,
            "approvalMode": .string(binding.policy.approvalMode.rawValue),
            "recoveryPolicy": .string(binding.policy.recoveryPolicy.rawValue),
            "notificationPolicy": .string(binding.policy.notificationPolicy.rawValue),
        ]
    }

    static func arguments(_ data: Data) -> G073TaskScheduleTool.Arguments? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys).isSubset(of: ["action", "title", "prompt", "cadence", "scheduledAt", "intervalHours", "intervalSeconds", "upstreamRunID"])
        else { return nil }
        return try? JSONDecoder().decode(G073TaskScheduleTool.Arguments.self, from: data)
    }

    static func digest(_ details: [String: Value]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: FacadeRunDomain.unwrap(.object(details)), options: [.sortedKeys]) else { return nil }
        return RunWireDigest.sha256Hex(data)
    }

    private static func safe(_ text: String, limit: Int, allowNewline: Bool) -> Bool {
        !text.isEmpty && text.utf8.count <= limit && text.unicodeScalars.allSatisfy { scalar in
            if allowNewline && scalar.value == 10 { return true }
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator, .surrogate, .unassigned: return false
            default: return true
            }
        }
    }
}

/// One in-memory expected projection for a manually accepted invocation.
/// It contains only a hash and is consumed before the scheduler mutates state.
final class G073ScheduleApprovalGate: @unchecked Sendable {
    static let shared = G073ScheduleApprovalGate()
    private let lock = NSLock()
    private var pending: [String: String] = [:]
    private func key(_ run: UUID, _ call: String, _ grant: UUID) -> String {
        run.uuidString + ":" + grant.uuidString + ":" + call
    }
    func stage(run: UUID, call: String, grant: UUID, digest: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let k = key(run, call, grant)
        guard pending.count < 128, pending[k] == nil else { return false }
        pending[k] = digest
        return true
    }
    func take(run: UUID, call: String, grant: UUID) -> String? {
        lock.lock(); defer { lock.unlock() }
        return pending.removeValue(forKey: key(run, call, grant))
    }
    func discard(run: UUID, call: String, grant: UUID) {
        lock.lock(); defer { lock.unlock() }
        pending.removeValue(forKey: key(run, call, grant))
    }
    func retire(run: UUID) {
        lock.lock(); defer { lock.unlock() }
        let prefix = run.uuidString + ":"
        pending = pending.filter { !$0.key.hasPrefix(prefix) }
    }
}
