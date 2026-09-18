// feedback_http_cancel_probe — Build191 runtime review.
//
// Compiles the real FloeAgent/Sources/FloeExecution/HTTPRequestService.swift
// and proves an in-flight download observes its cancellation token: a stalling
// local server never answers, the token is cancelled after ~0.4 s, and the
// call must throw FloeError.cancelled well before the 30 s URLSession timeout.
// Without the token watcher the shell command that owns the download would
// hold the engine run gate until the network timeout.
//
// Built and run by run_feedback_http_cancel_probe.sh. Desktop host probe, not
// iOS acceptance.
import Foundation
import FloeCore
import FloeTools

@main
struct FeedbackHTTPCancelProbe {
    static func main() async {
        guard CommandLine.arguments.count > 1, let port = Int(CommandLine.arguments[1]) else {
            print("FAIL usage: probe <port>")
            exit(64)
        }
        let url = URL(string: "http://127.0.0.1:\(port)/stall")!
        let token = CancellationToken()
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let started = Date()
        Task {
            try? await Task.sleep(for: .milliseconds(400))
            token.cancel()
        }
        do {
            _ = try await HTTPRequestService(allowsPrivateNetwork: true).download(
                url: url, timeout: 30, maxBytes: 1024 * 1024, to: destination, cancellation: token
            )
            print("FAIL stalling download unexpectedly completed")
            exit(2)
        } catch FloeError.cancelled {
            let elapsed = Date().timeIntervalSince(started)
            print(String(format: "PASS in-flight download cancelled in %.2fs (URLSession timeout was 30s)", elapsed))
            exit(elapsed < 5 ? 0 : 3)
        } catch {
            print("FAIL wrong error: \(error)")
            exit(4)
        }
    }
}
