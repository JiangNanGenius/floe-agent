// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeCore

/// Trusted-App lifecycle ingress for the durable GitHub Actions engine —
/// NOTHING ELSE. There is no workspace command, model tool or V3 route that
/// can start, stop or fake cloud-run polling through this seam:
///
/// * `scene(active:sceneID:)` is the Android mapping of the original iOS
///   `GitHubActionsJobCenter` scene-phase forwarding: the FIRST active scene
///   starts the engine's bounded local poller and the LAST deactivation
///   pauses it. Pausing never claims the remote run stopped — durable
///   records re-query honestly at the next activation or the next generation.
/// * Scene identity is supplied by the trusted App (activity/window), never
///   by model output or payload bytes.
/// * Every hop re-checks the accepted native epoch through
///   `G04GitActionsRegistry`; a stale generation answers a typed refusal and
///   can never touch a newer generation's engines.
///
/// All Actions DATA (preview/dispatch/records/refresh/jobs/logs/artifacts/
/// streaming download/cancel/intent/template install) rides the EXISTING
/// closed `workspace.read`/`workspace.write` grammar through
/// `G04WorkspaceGit` — this file intentionally exposes no data path, so no
/// new V3 outer keys or payload authority exist here.
enum G04GitActionsHostAPI {
    /// 0 = delivered to the live domain; -501 = no live generation for this
    /// epoch; -105 = malformed scene identity.
    static func scene(epoch: UInt64, active: Bool, sceneID: String) -> Int32 {
        guard epoch > 0, !sceneID.isEmpty, sceneID.utf8.count <= 64,
              sceneID.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") })
        else { return -105 }
        guard let domain = G04GitActionsRegistry.domain(epoch: epoch) else { return -501 }
        Task { await domain.scene(active: active, sceneID: sceneID) }
        return 0
    }
}

@_cdecl("floe_g04_git_actions_scene")
public func floeG04GitActionsScene(_ epoch: UInt64, _ active: Int32,
                                   _ sceneID: UnsafePointer<CChar>?) -> Int32 {
    guard let sceneID else { return -105 }
    let text = String(cString: sceneID)
    return G04GitActionsHostAPI.scene(epoch: epoch, active: active != 0, sceneID: text)
}
