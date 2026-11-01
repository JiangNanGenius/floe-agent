import Foundation

func requireReconciliation(_ state: BridgeDDIRecoveryState, _ expected: Bool, _ message: String) throws {
    let actual = try state.requiresReconciliation()
    precondition(actual == expected, message)
}

let fileManager = FileManager.default
let base = URL(fileURLWithPath: ProcessInfo.processInfo.environment["FLOE_DDI_TEST_ROOT"]!)
try fileManager.createDirectory(at: base, withIntermediateDirectories: true)
defer { try? fileManager.removeItem(at: base) }
let support = base.appendingPathComponent("ApplicationSupport/Bridge", isDirectory: true)
let ddi = support.appendingPathComponent("DDI", isDirectory: true)
let assets = ddi.appendingPathComponent("cryptex", isDirectory: true)
try fileManager.createDirectory(at: assets, withIntermediateDirectories: true)
let legacy = assets.appendingPathComponent(BridgeDDINativePolicy.reconciliationMarker)
try Data("legacy-unresolved".utf8).write(to: legacy)
let state = BridgeDDIRecoveryState(supportDirectory: support)
try state.migrateLegacyMarkers(in: [assets])
try requireReconciliation(state, true, "legacy marker must migrate before an install")
precondition(fileManager.fileExists(atPath: legacy.path), "migration preserves old evidence")
precondition(!state.markerURL.path.hasPrefix(ddi.path + "/"), "marker must be outside replaceable DDI assets")
// Same directory replacement boundary as an ordinary successful DDI import.
let replacement = ddi.appendingPathComponent(".import-new", isDirectory: true)
try fileManager.createDirectory(at: replacement, withIntermediateDirectories: true)
try fileManager.removeItem(at: assets)
try fileManager.moveItem(at: replacement, to: assets)
try requireReconciliation(state, true, "asset replacement must preserve unresolved operation")
// Same cache deletion boundary as removeCachedDDI.
try fileManager.removeItem(at: ddi)
try requireReconciliation(state, true, "cache removal must preserve unresolved operation")
let afterRestart = BridgeDDIRecoveryState(supportDirectory: support)
try requireReconciliation(afterRestart, true, "service reconstruction must preserve unresolved operation")
try afterRestart.clearResolvedMarker(legacyDirectories: [assets])
try requireReconciliation(afterRestart, false, "explicit resolved transition clears durable marker")
print("PASS legacy migration, asset replacement, cache deletion and service reconstruction preserve unresolved DDI state")
