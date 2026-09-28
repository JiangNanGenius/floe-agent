// FloeApp — process-wide Office memory coordination seam (Build 233 R2).
//
// Every Office surface (workspace preview, IDE tab, Notes, fullscreen editor)
// mounts its own `OfficeFileSession`, but only some of those views resolve the
// `AppEnvironment` that owns the local-model runtime. A per-view closure alone
// therefore leaves the preview/IDE surfaces without idle-model shedding even
// though they run the same memory-heavy engine preparation.
//
// `AppEnvironment` installs one handler here at launch; sessions use it as the
// fallback when no owning surface injected its own (tests and qualification
// hosts inject a scripted closure directly and never touch this singleton).
// The handler is exactly `AppEnvironment.shedIdleLocalModelForOffice`, so the
// safety contract lives in the runtime: only a physically idle mapping is
// released, active inference/benchmarks/retained tasks are never unloaded and
// nothing is cancelled.
#if canImport(SwiftUI) && canImport(UIKit)
import Foundation

@MainActor
final class OfficeMemoryCoordination {
    static let shared = OfficeMemoryCoordination()

    private var shedHandler: (@MainActor (String) async -> String?)?

    private init() {}

    /// Installed once by `AppEnvironment` at launch. Passing nil clears it.
    func install(shed: (@MainActor (String) async -> String?)?) {
        shedHandler = shed
    }

    var isInstalled: Bool { shedHandler != nil }

    /// Asks for an idle resident local model to be released. Returns the
    /// released model identifier, or nil when a claim retained the mapping,
    /// nothing was resident, or no handler is installed.
    func shedIdleResidentEngine(reason: String) async -> String? {
        guard let shedHandler else { return nil }
        return await shedHandler(reason)
    }
}
#endif
