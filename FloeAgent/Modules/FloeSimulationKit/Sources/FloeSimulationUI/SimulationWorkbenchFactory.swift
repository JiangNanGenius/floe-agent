import Foundation
import FloeSimulationCore
import FloeSimulationRuntime
import FloeSimulationEngineering
import FloeSimulationPhysics
import FloeSimulationFields
import FloeSimulationGeometry

public enum SimulationWorkbenchFactory {
    @MainActor public static func make(document: SimulationWorkspaceDocument, directory: URL, additionalBackends: [any SimulationBackend] = [], mesher: NativeSimulationMesher = .init(driver:NetgenSimulationGeometryDriver()), geometryProvider: SimulationGeometryProvider? = nil, validateSource: SimulationSourceValidator? = nil) throws -> SimulationWorkbenchModel {
        let archive = try SimulationArchiveStore(directory:directory)
        let builtins: [any SimulationBackend] = [LegacyEngineeringSimulationBackend(),Tet4ModalSimulationBackend(),Tet4ThermoelasticSimulationBackend(loadTemperature:{ try await archive.readResultSnapshot($0) }),RapierSimulationBackend(),ParticleSimulationBackend(),MFEMSimulationDriver(),MFEMTransientHeatSimulationDriver(),NativeEngineeringSimulationBackend(),NativeFieldsSimulationBackend(domain:.flow),NativeFieldsSimulationBackend(domain:.acoustics),NativeFieldsSimulationBackend(domain:.electromagnetics),NativeCoupledSimulationBackend()]
        let coordinator = SimulationCoordinator(backends:builtins+additionalBackends,archive:archive,validateSource:validateSource)
        let workspace = SimulationWorkspaceStore(document:document,archive:archive,coordinator:coordinator)
        let meshing = geometryProvider.map { SimulationMeshingService(workspace:workspace,mesher:mesher,geometry:$0,validateSource:validateSource) }
        return .init(document:document,coordinator:coordinator,archive:archive,workspace:workspace,meshing:meshing)
    }
    @MainActor public static func openOrCreate(initial: SimulationWorkspaceDocument, directory: URL, additionalBackends: [any SimulationBackend] = [], mesher: NativeSimulationMesher = .init(driver:NetgenSimulationGeometryDriver()), geometryProvider: SimulationGeometryProvider? = nil, validateSource: SimulationSourceValidator? = nil) async throws -> SimulationWorkbenchModel {
        let archive = try SimulationArchiveStore(directory:directory)
        var document: SimulationWorkspaceDocument
        if FileManager.default.fileExists(atPath:directory.appendingPathComponent("workspace.json").path) { document = try await archive.readDocument() }
        else { document = initial }
        guard document.source.projectID == initial.source.projectID, document.source.documentID == initial.source.documentID else { throw SimulationError.invalidInput("The saved simulation belongs to another CAD document.") }
        if document.source != initial.source {
            guard initial.source.revision > document.source.revision else { throw SimulationError.staleSource }
            document.source = initial.source; document.meshes = []
            for index in document.studies.indices { document.studies[index].meshID = nil; try document.studies[index].touch() }
            // Archived results remain immutable and inspectable. The old
            // animation graph keeps its source stamp until explicitly rebound.
            try await archive.saveDocument(document)
        }
        let model = try make(document:document,directory:directory,additionalBackends:additionalBackends,mesher:mesher,geometryProvider:geometryProvider,validateSource:validateSource)
        try await model.loadSavedResults(); return model
    }
    @MainActor public static func tools(for model: SimulationWorkbenchModel, authorize: @escaping SimulationToolAuthorizer) -> SimulationToolService {
        .init(workspace:model.workspace,coordinator:model.coordinator,archive:model.archive,meshing:model.meshing,templates:SimulationStudyDefaults.templates,authorize:authorize)
    }
}
