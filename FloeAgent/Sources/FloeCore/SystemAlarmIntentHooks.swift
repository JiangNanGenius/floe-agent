// SPDX-License-Identifier: MPL-2.0
import Foundation

/// Host-installed handoff for shared LiveActivityIntent source. The widget
/// references the intent; the host installs its existing durable service.
/// An absent handler never manufactures evidence or prevents native Stop.
public actor SystemAlarmIntentHooks {
    public static let shared = SystemAlarmIntentHooks()
    public typealias BeforeStop = @Sendable (UUID) async -> Void
    private var beforeStop: BeforeStop?

    public init() {}
    public func installBeforeStop(_ handler: @escaping BeforeStop) { beforeStop = handler }
    public func preserveBeforeStop(alarmID: UUID) async { await beforeStop?(alarmID) }
}
