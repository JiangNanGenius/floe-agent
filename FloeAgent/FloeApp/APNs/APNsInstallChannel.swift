// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import StoreKit

struct APNsInstallationEvidence: Sendable {
    var channel: APNsInstallChannel
    var signedAppTransaction: String?
    static let unknown = Self(channel: .unknown, signedAppTransaction: nil)
}

/// The sole process-owned StoreKit evidence query. Reading the cache never
/// waits for network/login. A cancelled uncooperative SDK call retains its
/// single slot until return, preventing repeated queries from accumulating.
@MainActor enum APNsInstallChannelDetector {
    private static var cached = APNsInstallationEvidence.unknown
    private static var worker: Task<Void, Never>?
    private static var workerID: UUID?
    private static var generation = UUID()
    private static weak var observerOwner: AnyObject?
    private static var onVerified: (@MainActor @Sendable (APNsInstallationEvidence) -> Void)?

    static func observe(owner: AnyObject, onChange: @escaping @MainActor @Sendable (APNsInstallationEvidence) -> Void) {
        observerOwner = owner; onVerified = onChange
    }
    static func cancelObservation(owner: AnyObject) {
        guard observerOwner === owner else { return }
        observerOwner = nil; onVerified = nil
        generation = UUID(); worker?.cancel()
    }
    static func detect() async -> APNsInstallChannel { await evidence().channel }
    static func evidence() async -> APNsInstallationEvidence {
        if cached.channel == .unknown && worker == nil {
            let id = UUID(), capturedGeneration = generation
            workerID = id
            worker = Task {
                let result = await query()
                guard workerID == id else { return }
                worker = nil; workerID = nil
                guard !Task.isCancelled, capturedGeneration == generation else { return }
                cached = result
                if result.signedAppTransaction != nil, observerOwner != nil { onVerified?(result) }
            }
        }
        return cached
    }
    private static func query() async -> APNsInstallationEvidence {
        #if targetEnvironment(simulator)
        return .init(channel: .development, signedAppTransaction: nil)
        #else
        do {
            // No refresh(), purchase, account prompt or receipt-name guess.
            // Failure/unverified data remains unknown and cannot imply Store.
            let result = try await AppTransaction.shared
            guard case .verified(let transaction) = result,
                  transaction.bundleID == Bundle.main.bundleIdentifier else { return .unknown }
            let channel: APNsInstallChannel
            switch transaction.environment {
            case .production: channel = .appStore
            case .sandbox: channel = .testFlight
            case .xcode: channel = .development
            default: return .unknown
            }
            let signed = result.jwsRepresentation
            guard signed.utf8.count <= 32_768 else { return .unknown }
            return .init(channel: channel, signedAppTransaction: signed)
        } catch { return .unknown }
        #endif
    }
}
#endif
