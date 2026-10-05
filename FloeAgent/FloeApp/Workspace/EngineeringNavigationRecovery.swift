import Foundation

/// Only an undelivered loopback document may retry its initial navigation.
struct EngineeringNavigationRecovery {
    private(set) var attempted = false

    mutating func consume(error: NSError, page: URL?, serverAvailable: Bool,
                          delivered: Bool, completed: Bool, dirty: Bool, saving: Bool) -> Bool {
        guard !attempted, serverAvailable, !delivered, !completed, !dirty, !saving,
              let page, page.scheme == "http", page.host == "127.0.0.1",
              error.domain == NSURLErrorDomain,
              [NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost,
               NSURLErrorCannotConnectToHost, NSURLErrorTimedOut].contains(error.code) else { return false }
        attempted = true
        return true
    }
}
