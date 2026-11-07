import Foundation
import FloeSimulationCore

public struct SimulationToolFieldInfo: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var unit: String
    public var location: SimulationFieldLocation
    public var components: Int
    public var valueCount: Int
    public var isComplex: Bool
}
public struct SimulationToolFrameInfo: Codable, Equatable, Sendable {
    public var id: Int
    public var timeSeconds: Double?
    public var frequencyHz: Double?
    public var fields: [SimulationToolFieldInfo]
}
public struct SimulationToolResultInfo: Codable, Equatable, Sendable {
    public var id: UUID
    public var source: SimulationSourceRef
    public var studyID: UUID
    public var studyRevision: UInt64
    public var backend: SimulationBackendDescriptor
    public var meshID: UUID?
    public var frameOffset: Int
    public var totalFrames: Int
    public var frames: [SimulationToolFrameInfo]
    public var isStale: Bool
}

extension SimulationToolService {
    public func savedResults(_ context: SimulationToolContext) async throws -> [SimulationSavedResult] {
        _ = try await checked(context,access:.read)
        return try await archive.savedResults().filter { $0.source.projectID == context.source.projectID && $0.source.documentID == context.source.documentID }
    }
    public func resultInfo(resultID: UUID, frameOffset: Int = 0, limit: Int = 16, context: SimulationToolContext) async throws -> SimulationToolResultInfo {
        let snapshot = try await checked(context,access:.read)
        guard frameOffset >= 0, (1...64).contains(limit) else { throw SimulationError.invalidInput("Invalid result metadata page.") }
        let result = try await ownedResult(resultID,source:context.source)
        guard frameOffset <= result.frames.count else { throw SimulationError.invalidInput("The requested result metadata page is missing.") }
        let frames = result.frames[frameOffset..<min(result.frames.count,frameOffset+limit)]
        guard frames.allSatisfy({ $0.fields.count <= 256 }) else { throw SimulationError.resourceLimit("The result has too many fields for one metadata page.") }
        let current = snapshot.document.studies.first { $0.id == result.studyID }
        return .init(id:result.id,source:result.source,studyID:result.studyID,studyRevision:result.studyRevision,backend:result.backend,
                     meshID:result.mesh?.id,frameOffset:frameOffset,totalFrames:result.frames.count,frames:frames.map { frame in
            .init(id:frame.id,timeSeconds:frame.timeSeconds,frequencyHz:frame.frequencyHz,fields:frame.fields.map {
                .init(id:$0.id,name:$0.name,unit:$0.unit,location:$0.location,components:$0.components,valueCount:$0.values.count,isComplex:$0.imaginaryValues != nil)
            })
        },isStale:result.source != snapshot.document.source || result.studyRevision != current?.revision)
    }
}
