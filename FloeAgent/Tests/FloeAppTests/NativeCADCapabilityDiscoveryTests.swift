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
        #expect(capabilities["animation_actions"] as? [String] == CADAnimationService.advertisedActions)
        #expect(Set(CadNativeEditActions.animation) == Set(CADAnimationService.advertisedActions))
        #expect(!actions.contains("observe"), "original-file observation is a different representation")
        for kind in CadServiceOperationCatalog.kinds {
            let exposed = try #require(capabilities["\(kind)_actions"] as? [String])
            #expect(exposed == CadServiceOperationCatalog.actionNames(forKind: kind))
        }
        #expect(!(capabilities["mesh_actions"] as? [String] ?? []).contains("text"))
        #expect((capabilities["operation_names"] as? [String] ?? []).contains("sketch.addText"))

        // X33: the three model-facing vocabularies (kernel operation_names,
        // tool schema and capability summary) must agree, and a guaranteed
        // refusal must never be advertised as an executable operation.
        let operationNames = try #require(capabilities["operation_names"] as? [String])
        #expect(operationNames == FloeCADDocument.nativeOperationNames)
        #expect(CadNativeOperationVocabulary.executable == FloeCADDocument.nativeOperationNames)
        #expect(!operationNames.contains("feature.scaleFace"))
        #expect(!operationNames.contains("feature.rotateFace"))
        let unavailable = try #require(
            capabilities["unavailable_operations"] as? [[String: Any]])
        let unavailableNames = Set(unavailable.compactMap { $0["op"] as? String })
        #expect(unavailableNames == Set(CadNativeOperationVocabulary.unavailable))
        #expect(unavailableNames == Set(FloeCADDocument.unavailableNativeOperations.compactMap {
            $0["op"] as? String
        }))
        #expect(unavailable.allSatisfy { ($0["code"] as? String) == "exact_edit_unsupported" })
        #expect(unavailable.allSatisfy { ($0["available"] as? Bool) == false })
        #expect(CadNativeOperationVocabulary.unavailable.allSatisfy { !operationNames.contains($0) })

        // The seven service vocabularies come from the real executors, and
        // the FloeWorkbench catalog/detail table is pinned to the same names.
        #expect(capabilities["assembly_actions"] as? [String] == CADAssemblyService.actions)
        #expect(capabilities["drawing_actions"] as? [String] == CADDrawingService.actions)
        #expect(capabilities["script_actions"] as? [String] == CADScriptService.actions)
        #expect(capabilities["mesh_actions"] as? [String] == CADMeshService.advertisedActions)
        #expect(capabilities["material_actions"] as? [String] == CADMaterialService.actions)
        #expect(capabilities["parameter_actions"] as? [String] == CADParameterService.actions)
        #expect(capabilities["animation_actions"] as? [String] == CADAnimationService.advertisedActions)
        #expect(Set(CadNativeEditActions.material) == Set(CADMaterialService.actions))
        #expect(Set(CadNativeEditActions.parameters) == Set(CADParameterService.actions))
        #expect(CadServiceOperationCatalog.actionNames(forKind: "assembly") == CADAssemblyService.actions)
        #expect(CadServiceOperationCatalog.actionNames(forKind: "drawing") == CADDrawingService.actions)
        #expect(CadServiceOperationCatalog.actionNames(forKind: "script") == CADScriptService.actions)
        #expect(CadServiceOperationCatalog.actionNames(forKind: "mesh") == CADMeshService.advertisedActions)
        #expect(!CADMeshService.actions.isEmpty)
        #expect(!CADMeshService.advertisedActions.contains("text"))
        #expect(CADMeshService.actions.contains("text"),
                "the historical text_mesh_unavailable refusal path stays recognized")

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
