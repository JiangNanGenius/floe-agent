// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import Testing
@testable import FloeApp
@testable import FloeCAD
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
    @Test func loftSurfaceActionsAndCompletePagedHelpReachActualTypedDecoders() throws {
        #expect(CadNativeEditActions.loftSurface.isSubset(of:CadNativeEditActions.parameters))
        #expect(CadNativeEditActions.loftSurface.isSubset(of:Set(CADParameterService.actions)))
        let topic=try #require(CadDocumentHelp.fullText(for:"loft-surfaces"))
        #expect(topic.contains("legacy"));#expect(topic.contains("Guides"));#expect(topic.contains("refused"))
        var page=0,assembled=""
        while true {
            let candidate = try CadDocumentHelp.page(.init(topic:"loft-surfaces",page:page,pageSize:1000))
            let row = try #require(candidate)
            assembled += row.text
            guard let next=row.nextPage else { break };page=next
        }
        #expect(page > 0);#expect(assembled == topic)
        let schema=try #require(JSONSerialization.jsonObject(with:Data(CadDocumentTool.parametersJSON.utf8)) as? [String:Any])
        let properties=try #require(schema["properties"] as? [String:Any])
        #expect(((properties["payload"] as? [String:Any])?["description"] as? String)?.contains("loft-surfaces") == true)
        for example in CadNativeEditActions.loftSurfaceExamples {
            let payload=try #require(JSONSerialization.jsonObject(with:Data(example.utf8)) as? [String:Any])
            let action=try #require(payload["action"] as? String)
            #expect(CadNativeEditActions.parameters.contains(action))
            let envelope=try JSONSerialization.data(withJSONObject:["action":"parameters","path":"example.floecad","payload":example])
            let request=try JSONDecoder().decode(CadDocumentArguments.self,from:envelope)
            #expect(request.action == .parameters);#expect(request.payload == example)
            if action == "loft.create" {
                let data=try JSONSerialization.data(withJSONObject:try #require(payload["sections"]))
                let refs=try JSONDecoder().decode([ProfileRef].self,from:data)
                let definition=try JSONDecoder().decode(LoftDefinition.self,
                    from:JSONSerialization.data(withJSONObject:try #require(payload["definition"])))
                try definition.requireSupported(sectionCount:refs.count)
            }
            if action == "surface.create" || action == "surface.update" {
                let data=try JSONSerialization.data(withJSONObject:try #require(payload["definition"]))
                let definition=try JSONDecoder().decode(CADSurfaceDefinition.self,from:data)
                try definition.validate()
            }
        }
    }

    @Test func texturePaintDiscoveryUsesExistingMaterialRouteAndCompletePagedHelp() throws {
        let actions=Set(CADMaterialService.actions)
        for action in ["paint.read","paint.stroke","paint.bakeAO","paint.status","paint.cancel"] {
            #expect(actions.contains(action));#expect(CadNativeEditActions.material.contains(action))
        }
        let full=try #require(CadDocumentHelp.fullText(for:"texture-paint"))
        #expect(full.contains("BVH"));#expect(full.contains("flattened"));#expect(full.contains("source_sha256"))
        var page=0,joined=""
        while true {
            let row=try #require(CadDocumentHelp.page(.init(topic:"texture-paint",page:page,pageSize:1000)))
            joined += row.text;guard let next=row.nextPage else { break };page=next
        }
        #expect(joined==full);#expect(page>0)
        let payload=#"{"action":"paint.stroke","body_id":"00000000-0000-4000-8000-000000000001","source_sha256":"synthetic","expected_change_count":1,"hits":[{"triangle":0,"barycentric":[0.25,0.5,0.25]}],"color_srgb":[1,0,0,1]}"#
        let outer=try JSONSerialization.data(withJSONObject:["action":"material","path":"example.floecad","payload":payload])
        let decoded=try JSONDecoder().decode(CadDocumentArguments.self,from:outer)
        #expect(decoded.action == .material);#expect(decoded.payload==payload)
        let object=try #require(JSONSerialization.jsonObject(with:Data(payload.utf8)) as? [String:Any])
        let hits=try JSONDecoder().decode([CADTexturePaintHit].self,from:JSONSerialization.data(withJSONObject:try #require(object["hits"])))
        #expect(hits.count==1);#expect(hits[0].triangle==0);#expect(hits[0].barycentric.x==0.25)
    }

}
#endif
