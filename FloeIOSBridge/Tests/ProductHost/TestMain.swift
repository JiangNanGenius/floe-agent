import Darwin
import Foundation

struct ProductTest {
    let name: String
    let body: @MainActor () async throws -> Void
}

func allProductTests() -> [ProductTest] {
    [
        ProductTest(name: "productPreferenceAccessNeverTouchesLegacyKeys",
                    body: productPreferenceAccessNeverTouchesLegacyKeys),
        ProductTest(name: "preferenceMigrationKeepsLegacyDiagnosticsOut",
                    body: preferenceMigrationKeepsLegacyDiagnosticsOut),
        ProductTest(name: "desiredRunningIntentIsIndependentFromAutoRestore",
                    body: desiredRunningIntentIsIndependentFromAutoRestore),
        ProductTest(name: "usableAddressRequiresBothAuthorities",
                    body: usableAddressRequiresBothAuthorities),
        ProductTest(name: "runStateAndPrimaryActionFollowLifecycle",
                    body: runStateAndPrimaryActionFollowLifecycle),
        ProductTest(name: "approvalGateQueuesBackgroundRequestUntilForeground",
                    body: approvalGateQueuesBackgroundRequestUntilForeground),
        ProductTest(name: "approvalGateDenyStopAndTimeoutResolveOnce",
                    body: approvalGateDenyStopAndTimeoutResolveOnce),
        ProductTest(name: "approvalGateAllowsOnlyOnePrompt",
                    body: approvalGateAllowsOnlyOnePrompt),
        ProductTest(name: "approvalGateScopesCancellationAndRechecksForeground",
                    body: approvalGateScopesCancellationAndRechecksForeground),
        ProductTest(name: "approvalDisplaySanitizesUntrustedInput",
                    body: approvalDisplaySanitizesUntrustedInput),
        ProductTest(name: "diagnosticsExportIsPublicSafe",
                    body: diagnosticsExportIsPublicSafe),
        ProductTest(name: "statusLogPersistsBoundedPrivateEvents",
                    body: statusLogPersistsBoundedPrivateEvents),
        ProductTest(name: "statusLogKeepsTypedDDIProvenance",
                    body: statusLogKeepsTypedDDIProvenance),
        ProductTest(name: "statusLogRestoresHistoricalMountFactsAfterRelaunch",
                    body: statusLogRestoresHistoricalMountFactsAfterRelaunch),
        ProductTest(name: "statusLogIgnoresClientActivityChurn",
                    body: statusLogIgnoresClientActivityChurn),
        ProductTest(name: "statusLogFailureIsSafeAndMemoryOnly",
                    body: statusLogFailureIsSafeAndMemoryOnly),
        ProductTest(name: "statusLogTicketRouteReturnsRealEvents",
                    body: statusLogTicketRouteReturnsRealEvents),
        ProductTest(name: "hostServiceLifecycleIsReal",
                    body: hostServiceLifecycleIsReal),
    ]
}

@main
@MainActor
struct ProductHostTestMain {
    static func main() async {
        var failures: [(String, String)] = []
        var passes = 0
        let filter = ProcessInfo.processInfo.environment["PRODUCT_HOST_TEST_FILTER"]
        let tests = allProductTests().filter { test in
            guard let filter, !filter.isEmpty else { return true }
            return test.name.contains(filter)
        }
        print("Bridge product-host test suite: \(tests.count) tests")
        for test in tests {
            do {
                try await test.body()
                passes += 1
                print("PASS \(test.name)")
            } catch {
                failures.append((test.name, String(describing: error)))
                print("FAIL \(test.name): \(error)")
            }
        }
        print("RESULT pass=\(passes) fail=\(failures.count) total=\(passes + failures.count)")
        if !failures.isEmpty {
            for failure in failures {
                print("FAILED \(failure.0): \(failure.1)")
            }
            exit(1)
        }
        exit(0)
    }
}
