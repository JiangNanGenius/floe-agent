// FloeExecution — compatibility adapter to the shared native ICMP producer.
// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeCore
import FloeTools
import FloeToolboxDiagnostics

/// Existing final-report injection remains source-compatible.
typealias DeviceTracerouteHandler = @Sendable (String, Int, Int, CancellationToken) async throws -> DeviceTracerouteReport
typealias DeviceTracerouteObserverHandler = @Sendable (String, Int, Int, CancellationToken, UUID, TracerouteObserver?) async throws -> DeviceTracerouteReport
typealias DeviceTracerouteReport = ICMPTracerouteReport

enum DeviceICMPTraceroute {
    static func run(target: String, maxHops: Int, waitSeconds: Int,
                    cancellation: CancellationToken) async throws -> DeviceTracerouteReport {
        try await observe(target: target, maxHops: maxHops, waitSeconds: waitSeconds,
                          cancellation: cancellation, requestID: UUID(), onObservation: nil)
    }
    static func observe(target: String, maxHops: Int, waitSeconds: Int, cancellation: CancellationToken,
                        requestID: UUID, onObservation: TracerouteObserver?) async throws -> DeviceTracerouteReport {
        do {
            return try await ICMPTracerouteProbe.run(target: target, maximumHops: maxHops,
                timeoutSeconds: waitSeconds, requestID: requestID,
                isCancelled: { cancellation.isCancelled }, onObservation: onObservation)
        } catch is CancellationError { throw CancellationError() }
        catch let error as DiagnosticError {
            switch error {
            case .stopped: throw CancellationError()
            case .invalid(let message): throw FloeError.validationFailed(message)
            default: throw FloeError.internalError(String(describing: error))
            }
        }
    }
}
