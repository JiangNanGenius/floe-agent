// SPDX-License-Identifier: MPL-2.0
//
// G05-R2 Office AI (job-1db1a7a8d5da457a) — Core composition seam for the
// Office AI lane. One place decides what the trusted host generation means:
//  * the Kotlin pump binding (`floe_office_ai_bind`) is the ONLY event that
//    installs the `document.office.edit` runner into the shared registry;
//    `isAvailable` then rides the mailbox's exact-epoch bound state, so the
//    tool registers when usable and is undiscoverable/undeclinable otherwise;
//  * the pump close (`floe_office_ai_close`, exact epoch) retires every
//    edit context minted under the closing generation — late callbacks can
//    resolve nothing against a dead root;
//  * `RuntimeFacadeJobBindings` receives the ORIGINAL
//    `NativeJobServiceAdapter` for deferred authorized applies through the
//    same bridge port (idempotent auto-injection when the caller did not
//    override it), so there is exactly ONE implementation of the capture /
//    model-think / apply invariant across inline and job paths.
//
// Nothing here starts threads, touches JNI/Kotlin directly, or registers
// model-reachable command keys. All of it is Swift-side composition the
// trusted host already drives through the delivered C ABI.

import Foundation
import FloeTools
import FloeAndroidJobTools

public final class OfficeAIComposition: @unchecked Sendable {
    public static let shared = OfficeAIComposition()

    private let lock = NSLock()
    private var installed = false

    /// The production port (bridge over the shared mailbox + context store).
    public var port: any OfficeEditEnginePort { OfficeAIHostBridge.shared }

    private init() {}

    /// Idempotent install of the two-sided tool registration. Called from
    /// the pump-bind export (primary, generation-accurate trigger) and from
    /// `RuntimeFacadeJobBindings.register()` (so a jobs composition re-runs
    /// the registration against the CURRENT bridge without duplication side
    /// effects — `ToolRunnerRegistry.register` replaces by name anyway).
    public func installToolIfNeeded() {
        lock.lock()
        installed = true
        lock.unlock()
        registerOfficeDocumentEditTool(
            port: OfficeAIHostBridge.shared,
            serviceProvider: { RuntimeFacadeJobBindings.shared.service },
            registry: .shared)
    }

    /// Exact-generation teardown hook (called by `floe_office_ai_close`).
    public func retireContextsForClosingGeneration() {
        OfficeAIHostBridge.shared.retireAllContexts()
    }

    /// Composition diagnostics (typed counts; never ids, handles or paths).
    public func statsJSON() -> String {
        let installedValue: Bool = { lock.lock(); defer { lock.unlock() }; return installed }()
        return "{\"toolInstalled\":\(installedValue),\"laneLive\":\(OfficeAIHostBridge.shared.isHostLaneLive()),"
            + "\"mailbox\":\(OfficeAIHostMailbox.shared.statsJSON()),"
            + "\"contexts\":\(OfficeAIHostBridge.shared.contextStatsJSON())}"
    }
}
