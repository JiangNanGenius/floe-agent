// FloeApp — Remote session coordinator (app-level seam).
//
// SPDX-License-Identifier: MPL-2.0
//
// Owns SSH/VNC session objects independent of any view and reconciles the
// in-memory handle with the durable `remote_sessions` row so backgrounded
// or relaunched sessions report connected/suspended/unknown honestly.
// T01 ships the compile-clean shell; T04 fills in session ownership.

#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import FloeModels
import FloePersistence

/// Coordinates SSH terminal and VNC sessions for the UI layer.
@MainActor
final class RemoteSessionCenter: ObservableObject {

    /// Durable session records keyed by session ID. Populated by T04.
    @Published private(set) var sessions: [UUID: RemoteSessionRecord] = [:]

    let environment: AppEnvironment

    init(environment: AppEnvironment) {
        self.environment = environment
    }
}
#endif
