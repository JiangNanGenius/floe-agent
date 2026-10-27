// SPDX-License-Identifier: MPL-2.0
//
// G05-R2 Office AI (job-1db1a7a8d5da457a) — two-sided registration for
// `document.office.edit`, mirroring the delivered shell-family pattern:
// the compile-time `ToolCatalog` descriptor PLUS a concrete runner whose
// `isAvailable` is the ACTUAL executable-surface gate (discovery, execution,
// descriptor lookup and `jobs.submit` admission's runner intersection all
// evaluate it). The tool registers when the App host lane is genuinely bound
// to the live native root generation and stays unreachable otherwise; there
// is no "advertised but dead" state, and a retired generation hides it again
// without any removal dance.

import Foundation
import FloeTools

/// Register (or re-register for the CURRENT generation) the Office AI tool
/// into the shared registry. The production Core composition calls this from
/// `RuntimeFacadeJobBindings.register()` BEFORE the job-target runner loop so
/// `document.office.edit` can be admitted when — and ONLY when — its host
/// lane is live.
@discardableResult
public func registerOfficeDocumentEditTool(
    port: any OfficeEditEnginePort,
    serviceProvider: @escaping @Sendable () -> BackgroundJobService?,
    registry: ToolRunnerRegistry = .shared
) -> Bool {
    ToolCatalog.register(OfficeDocumentEditTool.self)
    var runner = AnyAgentTool(OfficeDocumentEditTool(port: port, serviceProvider: serviceProvider))
    runner.isAvailable = { port.isHostLaneLive() }
    registry.register(runner)
    return true
}

/// Exact-name removal (retirement helper for tests/diagnostics; production
/// retirement rides the `isAvailable` gate so discovery hides the tool
/// without removing the catalog documentation entry).
public func unregisterOfficeDocumentEditTool(
    registry: ToolRunnerRegistry = .shared
) {
    registry.unregister { $0 == OfficeDocumentEditTool.name }
}
