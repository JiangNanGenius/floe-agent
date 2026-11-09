import Foundation

/// Original request and checked result are loaded together for dependent
/// studies. A result's field values alone do not prove mesh/material lineage.
public struct SimulationArchivedResult: Sendable {
    public var request:SimulationRequest
    public var result:SimulationResult
    public init(request:SimulationRequest,result:SimulationResult) { self.request=request;self.result=result }
}
