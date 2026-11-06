// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import StoreKit

enum APNsInstallChannelDetector {
    static func detect() async -> APNsInstallChannel {
        #if targetEnvironment(simulator)
        return .development
        #else
        do {
            // No refresh(), purchase, account prompt or receipt-name guess.
            // Failure/unverified data remains unknown and cannot imply Store.
            let result = try await AppTransaction.shared
            guard case .verified(let transaction) = result,
                  transaction.bundleID == Bundle.main.bundleIdentifier else { return .unknown }
            switch transaction.environment {
            case .production: return .appStore
            case .sandbox: return .testFlight
            case .xcode: return .development
            default: return .unknown
            }
        } catch { return .unknown }
        #endif
    }
}
#endif
