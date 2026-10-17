// Hosted tests must use the same service graph as the visible application.
#if canImport(UIKit) && DEBUG
import Foundation
@testable import FloeApp

@MainActor
func appQualificationEnvironment() async throws -> AppEnvironment {
    let deadline = Date().addingTimeInterval(30)
    while Date() < deadline {
        if let environment = AppEnvironment.qualificationLaunchEnvironment {
            if environment.persistenceReady { return environment }
            if let error = environment.bootstrapError {
                // Avoid assertion reflection of the entire environment and
                // its persisted local state. Preserve the actual launch error.
                throw NSError(domain: "AppQualificationBootstrap", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: String(error.prefix(256))])
            }
        }
        try await Task.sleep(for: .milliseconds(100))
    }
    throw NSError(domain: "AppQualificationBootstrap", code: 2,
                  userInfo: [NSLocalizedDescriptionKey: "Actual application launch did not become ready"])
}
#endif
