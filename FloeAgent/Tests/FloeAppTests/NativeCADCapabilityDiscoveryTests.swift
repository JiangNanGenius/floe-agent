// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Testing
@testable import FloeApp
import FloeCAD
import FloeWorkbench

@Suite("Native CAD capability discovery")
@MainActor
struct NativeCADCapabilityDiscoveryTests {
    @Test func nativeSummaryUsesTheWriterAndTheExecutableServiceCatalog() throws {
        let capabilities = FloeCAD3DBridge.globalCapabilitiesObject()
        #expect(capabilities["package_schema_version"] as? Int == FloeCADDocument.supportedPackageSchemaVersion)
        #expect((capabilities["package_schema_version"] as? Int ?? 0) >= 3)
        let actions = try #require(capabilities["actions"] as? [String])
        for action in ["material", "parameters", "capture", "animation"] { #expect(actions.contains(action)) }
        #expect(capabilities["animation_actions"] as? [String] == CadNativeEditActions.animation.sorted())
        #expect(!actions.contains("observe"), "original-file observation is a different representation")
        for kind in CadServiceOperationCatalog.kinds {
            let exposed = try #require(capabilities["\(kind)_actions"] as? [String])
            #expect(exposed == CadServiceOperationCatalog.actionNames(forKind: kind))
        }
        #expect(!(capabilities["mesh_actions"] as? [String] ?? []).contains("text"))
        #expect((capabilities["operation_names"] as? [String] ?? []).contains("sketch.addText"))

        // The removed 32-pair gate must not be advertised. The envelope is
        // derived from the executable assembly service and stays inside the
        // runtime's real 8 MiB full-capture budget.
        let limits = try #require(capabilities["limits"] as? [String: Any])
        #expect(limits["max_pairs"] == nil)
        let resultBytes = try #require(limits["interference_result_bytes"] as? Int)
        #expect(resultBytes == CADAssemblyService.interferenceResultBudgetBytes)
        #expect(resultBytes > 0)
        #expect(resultBytes <= 8 * 1_024 * 1_024)
        let pairContract = try #require(limits["interference_pair_contract"] as? String)
        #expect(pairContract.contains("no fixed pair cap"))
        #expect(limits["interference_detail_digest"] as? String
                == CADAssemblyService.interferenceDetailDigestAlgorithm)
        // Viewport and animation metadata are unrelated and must survive.
        #expect(capabilities["viewport_capture"] != nil)
        #expect(capabilities["animation_actions"] as? [String] == CadNativeEditActions.animation.sorted())
    }
}
#endif
