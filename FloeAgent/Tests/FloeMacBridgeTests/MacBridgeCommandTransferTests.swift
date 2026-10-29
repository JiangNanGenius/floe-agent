import Foundation
import Testing
@testable import FloeExecution

@Suite("Mac bridge unbounded command transport")
struct MacBridgeCommandTransferTests {
    @Test("Commands larger than an RPC frame select private chunked scripts")
    func multiMegabyteCommand() {
        let command = String(repeating: "printf '完整一句话\\n'\n", count: 350_000)
        #expect(command.utf8.count > 4 * 1_024 * 1_024)
        #expect(MacBridgeCommandTransfer.requiresStaging(utf8Bytes: command.utf8.count))
        #expect(!MacBridgeCommandTransfer.requiresStaging(utf8Bytes: 0))
    }
}
