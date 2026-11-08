import Foundation
import FloeExecution
import FloeToolboxCore
import FloeToolboxClients

public struct ToolboxBluetoothOpenedConnection: Sendable {
    public let endpoint: BluetoothSerialEndpoint
    public let connection: HostBluetoothSerialConnection
}

public enum ToolboxBluetoothBridge {
    /// Preserves the original explicit endpoint API for existing callers.
    @MainActor public static func open(service: any BluetoothSerialServicing, runID: UUID,
                                      endpoint: BluetoothSerialEndpoint, timeout: TimeInterval = 15) async throws -> HostBluetoothSerialConnection {
        try await openResolved(service: service, runID: runID, peripheralID: endpoint.peripheralID,
                               endpoint: endpoint, timeout: timeout).connection
    }

    /// The service remains the sole peripheral/authorization owner. The actual
    /// selected endpoint is returned for history, capture and the frozen AI host.
    @MainActor public static func openResolved(service: any BluetoothSerialServicing, runID: UUID,
                                              peripheralID: UUID, endpoint: BluetoothSerialEndpoint? = nil,
                                              timeout: TimeInterval = 15,
                                              onFailure: @escaping @Sendable (any Error) async -> Void = { _ in }) async throws -> ToolboxBluetoothOpenedConnection {
        let opened = try await BluetoothSerialConnector.open(service: service, runID: runID,
            peripheralID: peripheralID, endpoint: endpoint, timeout: timeout)
        do {
            let connection = try HostBluetoothSerialConnection(maximumWriteBytes: 20, exchange: { data, wait, maximum in
                do { return try await service.exchange(runID: runID, sessionID: opened.sessionID, data: data, wait: wait, maxBytes: maximum) }
                catch {
                    if !(error is CancellationError) { await onFailure(error) }
                    throw error
                }
            }, close: { await service.close(runID: runID, sessionID: opened.sessionID) })
            return .init(endpoint: opened.endpoint, connection: connection)
        } catch {
            await service.close(runID: runID, sessionID: opened.sessionID)
            throw error
        }
    }
}
