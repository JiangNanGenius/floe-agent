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
        #expect(!actions.contains("observe"), "original-file observation is a different representation")
        for kind in CadServiceOperationCatalog.kinds {
            let exposed = try #require(capabilities["\(kind)_actions"] as? [String])
            #expect(exposed == CadServiceOperationCatalog.actionNames(forKind: kind))
        }
        #expect(!(capabilities["mesh_actions"] as? [String] ?? []).contains("text"))
        #expect((capabilities["operation_names"] as? [String] ?? []).contains("sketch.addText"))
    }
}
#endif
