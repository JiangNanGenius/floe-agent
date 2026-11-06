import Foundation
import FloeExecution
import FloeToolboxCore
import FloeToolboxClients

public enum ToolboxBluetoothBridge {
    /// The existing service owns scanning, permissions and the peripheral. Captured immutable
    /// IDs prevent a later UI selection from redirecting an established connection.
    @MainActor public static func open(service: any BluetoothSerialServicing,runID: UUID,
                                      endpoint: BluetoothSerialEndpoint,timeout: TimeInterval = 15) async throws -> HostBluetoothSerialConnection {
        try endpoint.validate()
        let sessionID = try await service.open(runID:runID,endpoint:endpoint,timeout:timeout)
        if Task.isCancelled { await service.close(runID:runID,sessionID:sessionID); throw CancellationError() }
        return try HostBluetoothSerialConnection(maximumWriteBytes:20,exchange:{ data,wait,maximum in
            try await service.exchange(runID:runID,sessionID:sessionID,data:data,wait:wait,maxBytes:maximum)
        },close:{ await service.close(runID:runID,sessionID:sessionID) })
    }
}
