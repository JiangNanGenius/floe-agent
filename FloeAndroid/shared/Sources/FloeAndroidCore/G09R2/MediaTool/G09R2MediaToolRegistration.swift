// SPDX-License-Identifier: MPL-2.0
//
// G09-R2 — truthful model discovery/registration for `media.project`
// (job-258c68e91e6840df).
//
// The ORIGINAL portable tool is registered once per runtime generation into
// the SAME root `ToolRunnerRegistry` used by the model. It is visible only
// while ALL of these are real:
//
//  * the creative domain accepted a live root epoch;
//  * that epoch is not root-stopping;
//  * a real Kotlin render-ticket consumer has polled/heartbeat recently
//    (the mailbox consumer readiness lease; `bind` alone is not proof);
//  * the host is explicitly enabled (App setting / composition).
//
// On epoch change, renderer stop or lease expiry the descriptor disappears
// from discovery and an already-admitted call fails closed. No success-only
// availability, no phone-tool alias and no duplicate installer exist here.
import Foundation
import FloeCore
import FloeTools
import FloeAndroidWorkbench

/// Synchronous, lock-guarded availability projection. It contains no project
/// or user content; it is the only state the discovery closure reads.
final class G09R2MediaToolAvailability: @unchecked Sendable {
    static let shared = G09R2MediaToolAvailability(
        mailbox: G09R2MediaRenderHostMailbox.shared)

    private let lock = NSLock()
    private let mailbox: G09R2MediaRenderHostMailbox
    private var epoch: UInt64 = 0
    private var stopping = false
    private var enabled = true

    init(mailbox: G09R2MediaRenderHostMailbox) {
        self.mailbox = mailbox
    }

    func markBound(epoch: UInt64) {
        guard epoch > 0 else { return }
        lock.lock()
        self.epoch = epoch
        stopping = false
        lock.unlock()
    }

    func markStopping(epoch: UInt64) {
        lock.lock()
        if self.epoch == epoch { stopping = true }
        lock.unlock()
    }

    func markUnbound(epoch: UInt64) {
        lock.lock()
        if self.epoch == epoch {
            self.epoch = 0
            stopping = false
        }
        lock.unlock()
    }

    func setEnabled(_ value: Bool) {
        lock.lock(); enabled = value; lock.unlock()
    }

    func resetForTesting() {
        lock.lock()
        epoch = 0
        stopping = false
        enabled = true
        lock.unlock()
    }

    struct Snapshot: Sendable {
        var available: Bool
        var enabled: Bool
        var epoch: UInt64?
        var consumerReady: Bool
        var reason: String?
    }

    func snapshot() -> Snapshot {
        lock.lock()
        let currentEpoch = epoch
        let isStopping = stopping
        let isEnabled = enabled
        lock.unlock()
        guard isEnabled else {
            return Snapshot(available: false, enabled: false, epoch: nil,
                            consumerReady: false, reason: "disabled")
        }
        guard currentEpoch > 0 else {
            return Snapshot(available: false, enabled: true, epoch: nil,
                            consumerReady: false, reason: "notBound")
        }
        guard !isStopping else {
            return Snapshot(available: false, enabled: true, epoch: currentEpoch,
                            consumerReady: false, reason: "rootStopping")
        }
        guard mailbox.isBound(to: currentEpoch) else {
            return Snapshot(available: false, enabled: true, epoch: currentEpoch,
                            consumerReady: false, reason: "rendererUnbound")
        }
        guard mailbox.consumerReady(epoch: currentEpoch) else {
            return Snapshot(available: false, enabled: true, epoch: currentEpoch,
                            consumerReady: false, reason: "consumerUnavailable")
        }
        return Snapshot(available: true, enabled: true, epoch: currentEpoch,
                        consumerReady: true, reason: nil)
    }

    var isAvailable: Bool { snapshot().available }
}

// MARK: - Capability advertisement

struct G09R2MediaToolCapabilityDTO: Encodable, Sendable {
    var registered: Bool
    var enabled: Bool
    var available: Bool
    var epoch: UInt64?
    var consumerReady: Bool
    var reason: String?
    var actions: [String]
    var imageFormats: [String]
    var videoCodecs: [String]
    var measurableImageFormats: [String]
    /// True only while the real native command/CAS backend is bound and not
    /// stopping; fill/cut do not need the raster consumer.
    var fillSelection: Bool
    /// True only while the real native command/CAS backend is bound and not
    /// stopping.
    var cutSelection: Bool
    /// True only while the real render-ticket consumer is bound and live.
    var mergeLayers: Bool
    /// True only while the real render-ticket consumer is bound and live.
    var copySelection: Bool
    var enrichmentReasons: [String: String]
}

enum G09R2MediaToolRegistration {
    /// The actual portable tool instance currently installed. Retained only
    /// for bounded diagnostics; no caller can bypass the registry.
    ///
    /// Capability is derived from the SAME `G09R2MediaToolAvailability`
    /// snapshot that gates `runner.isAvailable`. A bound/consumer-ready
    /// renderer advertises the real fill/cut/merge/copy implementations; an
    /// unbound, stopped, disabled or consumer-less generation advertises false
    /// with the actual reason. No fixed prose and no fake ready state.
    static func capability(
        availability: G09R2MediaToolAvailability = .shared
    ) -> G09R2MediaToolCapabilityDTO {
        let snapshot = availability.snapshot()
        // Fill/cut commit through the native project command/CAS backend and
        // do not rasterize; they are available once the exact session epoch is
        // bound and not stopping. Merge/copy additionally require the real
        // render-ticket consumer lease (bind alone is not proof).
        let commandsReady = snapshot.enabled && snapshot.epoch != nil &&
            snapshot.reason != "rootStopping"
        let rendererReady = snapshot.available
        var reasons: [String: String] = [:]
        if !commandsReady {
            let reason = snapshot.reason ?? "nativeCommandBackendUnavailable"
            reasons["fill_selection"] = reason
            reasons["cut_selection"] = reason
        }
        if !rendererReady {
            let reason = snapshot.reason ?? "rendererUnavailable"
            reasons["merge_layers"] = reason
            reasons["copy_selection"] = reason
        }
        return G09R2MediaToolCapabilityDTO(
            registered: true,
            enabled: snapshot.enabled,
            available: snapshot.available,
            epoch: snapshot.epoch,
            consumerReady: snapshot.consumerReady,
            reason: snapshot.reason,
            actions: G09R2MediaProjectToolHost.actions,
            imageFormats: G09R2MediaProjectToolHost.imageFormats,
            videoCodecs: G09R2MediaProjectToolHost.videoCodecs,
            measurableImageFormats: G09R2MediaProjectToolHost.measurableImageFormats,
            fillSelection: commandsReady,
            cutSelection: commandsReady,
            mergeLayers: rendererReady,
            copySelection: rendererReady,
            enrichmentReasons: reasons)
    }

    /// Installs the ORIGINAL `MediaProjectTool` over the REAL host. The
    /// availability closure is the model-discovery gate; the executable
    /// runner itself is always the same original tool/authority path.
    @discardableResult
    static func install(
        service: G09CreativeDomainService,
        registry: ToolRunnerRegistry,
        availability: G09R2MediaToolAvailability = .shared,
        mailbox: G09R2MediaRenderHostMailbox = .shared,
        proposals: G09R2MediaToolProposalStore = .shared,
        grants: G09R2MediaToolGrants? = nil,
        config: G09R2MediaToolHostConfig = G09R2MediaToolHostConfig()
    ) -> Bool {
        ToolCatalog.register(MediaProjectTool.self)
        let effectiveGrants = grants ?? (service === BridgeV5.service
            ? G09R2MediaToolGrants.shared
            : G09R2MediaToolGrants(
                service: service, mailbox: mailbox, proposals: proposals))
        // ONE immutable host (and original portable tool) per invocation.
        // The durable proposal/grant stores and render mailbox remain shared;
        // caller identity is never stored in a mutable projectID-keyed
        // registry, so two tasks touching the same workspace cannot overwrite
        // each other between an authorize await and a proposal/export await.
        let placeholder = G09R2MediaProjectToolHost(
            service: service, mailbox: mailbox, proposals: proposals,
            grants: effectiveGrants, config: config)
        var runner = AnyAgentTool(MediaProjectTool(host: placeholder))
        runner.run = { argumentsJSON, context in
            let arguments = try? JSONDecoder().decode(
                MediaProjectTool.Arguments.self, from: argumentsJSON)
            let call = arguments.map {
                G09R2MediaToolCallContext(
                    projectID: $0.projectID, arguments: $0, context: context)
            }
            let host = G09R2MediaProjectToolHost(
                service: service, mailbox: mailbox, proposals: proposals,
                grants: effectiveGrants, config: config, call: call)
            let tool = AnyAgentTool(MediaProjectTool(host: host))
            var output = try await tool.run(argumentsJSON, context)
            if arguments?.action == .capabilities,
               let text = host.normalizedCapabilityText() {
                // ONE truthful capability answer. The portable prose is
                // replaced, not appended to: merge/copy are explicitly
                // unsupported and the export formats match this host.
                output = ToolExecutionOutput(
                    digesting: text,
                    exitStatus: output.exitStatus,
                    artifacts: output.artifacts,
                    outputFiles: output.outputFiles,
                    requiresUserAction: output.requiresUserAction)
            }
            return output
        }
        runner.isAvailable = { availability.isAvailable }
        registry.register(runner)
        return true
    }
}
