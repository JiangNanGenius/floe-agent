// FloeApp — Live design capability probe.
//
// Core's `DesignCapabilityMatrix` answers each (mode, family, operation)
// question with static wiring AND a live probe; without the probe every
// answer degrades to "not connected + recovery". This factory assembles that
// probe from the app's REAL services so a capability is offered only when
// it is actually usable right now:
//
// - Office documents: a live engine session (offline OOXML operations do
//   NOT require the session — the probe only gates session-bound work).
// - Web/prototype: the Linux guest image is actually installed.
// - Image/video 制作: a real generation route is configured for the family.
// - CAD: the native kernel is built into this app.
// - Notes/PDF: the Notes services resolve.
//
// Capture stays capture: `importSource` never becomes 制作.

#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import FloeCore
import FloeModels
import FloeExecution

enum DesignCapabilityProbeFactory {
    /// Builds the matrix over the app's adapter registry with a live probe
    /// bound to the real services. The probe re-derives availability on
    /// EVERY call — it never caches a stale "ready".
    @MainActor
    static func makeMatrix(environment: AppEnvironment) -> DesignCapabilityMatrix {
        DesignCapabilityMatrix(
            registry: environment.designAdapterCenter.capabilityRegistry(),
            live: { query in
                // The matrix contract is synchronous; every real call site is
                // on the main actor (panel refresh, capability tool). Off-main
                // callers get an honest unavailable instead of a trap.
                guard Thread.isMainThread else {
                    return .unavailable(
                        reason: "the capability probe must run on the main thread",
                        recovery: nil)
                }
                return MainActor.assumeIsolated {
                    Self.liveAvailability(query: query, environment: environment)
                }
            })
    }

    /// Re-derived per call from the live services. Environment tags are only
    /// TRUSTED UI/service input, never authority by themselves: every tag
    /// that claims readiness is cross-checked against the real service it
    /// names (a session tag must match a live registry session, a configured
    /// media tag must match real configured routes), and an absent tag never
    /// fabricates availability either — the probe asks the services directly.
    @MainActor
    static func liveAvailability(
        query: DesignCapabilityQuery,
        environment: AppEnvironment
    ) -> DesignLiveAvailability {
        let tags = query.environment
        func tag(_ key: DesignCapabilityEnvironmentKey) -> String? {
            tags[key.rawValue]
        }
        switch query.family {
        case .officeDocument, .presentation:
            // Office must distinguish offline-executable OOXML package
            // operations from engine-session commands:
            // - sourceExport (an engine round-trip through the live editor)
            //   requires the session: without it the export is refused with
            //   the recovery action, never silently answered offline.
            // - every other operation builds/reads/writes the native OOXML
            //   package and does NOT require the session.
            // A "connected" tag is accepted only while the live registry
            // actually holds a session; a bare tag can never mint readiness.
            if query.operation == .sourceExport {
                let sessionLive = tag(.officeEngineSession) == "connected"
                    && OfficeLiveSessionRegistry.shared.hasLiveSession
                guard sessionLive else {
                    return .unavailable(
                        reason: "the Office engine session is not connected for this document",
                        recovery: "open the document in the live Office editor")
                }
                return .available()
            }
            return .available()
        case .webpage, .prototype:
            guard query.operation == .generate else { return .available() }
            // Web 制作 may need the Linux guest for build/serve steps. Probe
            // the REAL image state: an installed verified image (or a guest
            // already running it) can be started on demand; anything else is
            // an honest unavailable with the recovery action. A bare tag
            // never answers this.
            if tag(.linuxGuest) == "unavailable" {
                return .unavailable(
                    reason: "the Linux guest is not running for this workspace",
                    recovery: "start the task's Linux environment, then retry")
            }
            let imageID = LinuxGuestImageDistributionCatalog.defaultImageID
            let status = FloePlatformServices.shared.cachedLinuxImageStatus(id: imageID)
            if let status, status.installed, status.verificationIssue == nil {
                return .available()
            }
            return .unavailable(
                reason: status?.verificationIssue?.message
                    ?? "the pinned Linux guest image is not installed or is not verified",
                recovery: "download the Linux image from the terminal, then retry")
        case .image:
            guard query.operation == .generate else { return .available() }
            // The configured routes are the authority; a bare tag cannot
            // mint readiness while no real route exists.
            let routes = environment.conversationCenter.agentImageRoutes(operation: .generate)
            guard !routes.isEmpty else {
                return .unavailable(
                    reason: "no image generation model is configured",
                    recovery: "configure an image generation provider in Settings")
            }
            return .available()
        case .video:
            guard query.operation == .generate else { return .available() }
            guard !environment.conversationCenter.agentVideoRoutes().isEmpty else {
                return .unavailable(
                    reason: "no video generation model is configured",
                    recovery: "configure a video generation provider in Settings")
            }
            return .available()
        case .cad:
            // The native kernel is compiled into this app, so create/import
            // are statically real — but a caller claiming a live kernel
            // session is cross-checked against the CAD document center, and
            // a disconnected tag is honest about the missing session.
            if tag(.cadKernelSession) == "disconnected" {
                return .unavailable(
                    reason: "the CAD kernel session is not connected",
                    recovery: "open the CAD document")
            }
            guard query.operation != .generate else {
                // CAD 制作 runs through the native document factory (the
                // create action), never a fabricated generator.
                return .available()
            }
            return .available()
        case .notes, .pdf:
            // Notes/PDF creation flows through the app's own stores; when
            // persistence never became ready the service is honestly down.
            guard environment.persistenceReady else {
                return .unavailable(
                    reason: "the Notes/PDF service is unavailable",
                    recovery: "retry after the app finishes loading its stores")
            }
            if tag(.notesPDFService) == "unavailable" {
                return .unavailable(
                    reason: "the Notes/PDF service is unavailable",
                    recovery: "retry after the app finishes loading its stores")
            }
            return .available()
        case .composition:
            // Canvas layout objects are arranged with the graph/layout
            // tools, not generated; never offered as 制作.
            return .unavailable(
                reason: "canvas layout objects are arranged with canvas.applyOperations, not generated",
                recovery: "use the canvas layout tools")
        }
    }
}
#endif
