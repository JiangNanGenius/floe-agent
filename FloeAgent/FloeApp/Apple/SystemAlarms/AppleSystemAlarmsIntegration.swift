// FloeApp — system AlarmKit registration + PRIMARY integration contract.
//
// SPDX-License-Identifier: MPL-2.0
//
// PRIMARY INTEGRATION (one call from AppEnvironment.bootstrap, immediately
// after the other register*Apple*Tools calls):
//
//     registerAppleAlarmTools(database: database)
//
// The service is created and owned by this helper (service-owned, never
// View-owned); `start()` begins the native observer and the integrator may
// call `stop()` from its app-lifecycle teardown. The settings capability
// switch remains the existing AppleCapability gate — see the exact
// AppleCapability patch in the handoff, which adds an `alarm` case with the
// `apple.alarm.` prefix so the model never sees the capability when disabled.
//
// REQUIRED host metadata (owned by the integrator; exact patch in handoff):
//   * Info.plist `NSAlarmKitUsageDescription` (non-empty). Without it the
//     system refuses to schedule any alarm.
//   * No extra entitlement is required for AlarmKit itself. A countdown/timer
//     presentation expects a widget extension for its Live Activity; without
//     one the system may dismiss a timer alert, so timer support is gated
//     behind the app actually shipping that extension (see isAvailable).

#if canImport(UIKit) && canImport(AlarmKit)
import Foundation
import UIKit
import FloeCore
import FloeTools
import FloePersistence
import AlarmKit

enum SystemAlarmForeground {
    static func isActive() async -> Bool {
        await MainActor.run {
            UIApplication.shared.applicationState == .active
        }
    }
}

/// Process-wide service owner. Re-registering must reuse the same service so
/// a second native observer or ledger is never created.
enum AppleSystemAlarmServices {
    static func makeService(database: DatabaseManager) -> SystemAlarmService {
        SystemAlarmService(
            native: AlarmKitNativeManager(),
            store: SQLiteSystemAlarmStore(database: database),
            isForeground: { await SystemAlarmForeground.isActive() }
        )
    }
}

@MainActor
func registerAppleAlarmTools(
    database: DatabaseManager,
    registry: ToolRunnerRegistry = .shared,
    existingService: SystemAlarmService? = nil,
    native: (any SystemAlarmNativeManaging)? = nil,
    isForeground: @escaping @Sendable () async -> Bool = {
        await SystemAlarmForeground.isActive()
    }
) -> SystemAlarmService {
    let service = existingService ?? SystemAlarmService(
        native: native ?? AlarmKitNativeManager(),
        store: SQLiteSystemAlarmStore(database: database),
        isForeground: isForeground
    )

    ToolCatalog.register(AppleAlarmScheduleTool.self)
    var schedule = AnyAgentTool(AppleAlarmScheduleTool(
        service: service, isForeground: isForeground))
    schedule.isAvailable = { AlarmKitNativeManager().isAvailable }
    registry.register(schedule)

    ToolCatalog.register(AppleAlarmListTool.self)
    registry.register(AppleAlarmListTool(service: service))

    ToolCatalog.register(AppleAlarmCancelTool.self)
    var cancel = AnyAgentTool(AppleAlarmCancelTool(service: service))
    cancel.isAvailable = { AlarmKitNativeManager().isAvailable }
    registry.register(cancel)

    ToolCatalog.register(AppleAlarmStatusTool.self)
    registry.register(AppleAlarmStatusTool(service: service))

    // Begin native observation without blocking the synchronous bootstrap;
    // the observation task is service-owned and torn down by `stop()`.
    Task { await service.start() }
    return service
}
#endif
