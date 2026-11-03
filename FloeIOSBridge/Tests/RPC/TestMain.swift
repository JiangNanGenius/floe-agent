import Darwin
import Foundation

import BridgeCore
import BridgeHost
@main
struct BridgeRPCTestMain {
    static func main() async {
        var failures: [(String, String)] = []
        var passes = 0
        let filter = ProcessInfo.processInfo.environment["RPC_TEST_FILTER"]
        let tests = allTests().filter { test in
            guard let filter, !filter.isEmpty else { return true }
            return test.name.contains(filter)
        }
        print("Bridge RPC test suite: \(tests.count) tests")
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
