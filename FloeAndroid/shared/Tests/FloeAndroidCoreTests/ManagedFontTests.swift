// SPDX-License-Identifier: MPL-2.0
import XCTest
import Foundation
import FloeTools
@testable import FloeAndroidCore

final class ManagedFontTests: XCTestCase {
    private func message(_ op: String, epoch: UInt64 = 17, id: String? = nil,
                         receipt: String? = nil) -> [String: Any] {
        var result: [String: Any] = ["operation": op, "epoch": NSNumber(value: epoch)]
        if let id { result["ticketID"] = id }
        if let receipt { result["receipt"] = receipt }
        return result
    }
    private func claim(_ mailbox: FontHostMailbox) async throws -> String {
        for _ in 0..<100 {
            if let ticket = mailbox.handleMessage(message("font.host.claim"))["ticket"] as? [String: Any],
               let id = ticket["id"] as? String { return id }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw NSError(domain: "ManagedFontTests.claim", code: 1)
    }
    func testClaimedCancellationDoesNotManufacturePhysicalSettlement() async throws {
        let mailbox = FontHostMailbox(rootIsCurrent: { $0 == 17 })
        XCTAssertEqual(mailbox.handleMessage(message("font.host.bind"))["ok"] as? Bool, true)
        let token = CancellationToken()
        let operation = Task { try await mailbox.submit(epoch: 17,
            request: Data("{}".utf8), cancellation: token) }
        let id = try await claim(mailbox)
        XCTAssertEqual(mailbox.handleMessage(message("font.host.close"))["drained"] as? Bool, false)
        XCTAssertEqual(mailbox.handleMessage(message("font.host.canCommit", id: id))["allowed"] as? Bool, false)
        XCTAssertEqual(mailbox.handleMessage(message("font.host.settle", id: id,
            receipt: "{\"ok\":false,\"error\":\"cancelled\"}"))["ok"] as? Bool, true)
        _ = try await operation.value
        XCTAssertEqual(mailbox.handleMessage(message("font.host.close"))["drained"] as? Bool, true)
    }
    func testLostAcknowledgementOnlyRepeatsSettlementNotMutation() async throws {
        let mailbox = FontHostMailbox(rootIsCurrent: { $0 == 17 })
        _ = mailbox.handleMessage(message("font.host.bind"))
        let operation = Task { try await mailbox.submit(epoch: 17,
            request: Data("{}".utf8), cancellation: CancellationToken()) }
        let id = try await claim(mailbox)
        let receipt = "{\"ok\":true,\"removed\":true}"
        XCTAssertEqual(mailbox.handleMessage(message("font.host.settle", id: id, receipt: receipt))["ok"] as? Bool, true)
        _ = try await operation.value
        XCTAssertEqual(mailbox.handleMessage(message("font.host.settle", id: id, receipt: receipt))["ok"] as? Bool, true)
        XCTAssertEqual(mailbox.handleMessage(message("font.host.settle", id: id,
            receipt: "{\"ok\":false}"))["ok"] as? Bool, false)
    }
    func testForeignEpochCannotCompleteOwnedWorkOrFreeItsDrain() async throws {
        let mailbox = FontHostMailbox(rootIsCurrent: { $0 > 0 })
        _ = mailbox.handleMessage(message("font.host.bind"))
        let operation = Task { try await mailbox.submit(epoch: 17,
            request: Data("{}".utf8), cancellation: CancellationToken()) }
        let id = try await claim(mailbox)
        XCTAssertEqual(mailbox.handleMessage(message("font.host.bind", epoch: 18))["ok"] as? Bool, false)
        XCTAssertEqual(mailbox.handleMessage(message("font.host.settle", epoch: 18,
            id: id, receipt: "{\"ok\":true}"))["ok"] as? Bool, false)
        XCTAssertEqual(mailbox.handleMessage(message("font.host.close"))["drained"] as? Bool, false)
        _ = mailbox.handleMessage(message("font.host.settle", id: id, receipt: "{\"ok\":false}"))
        _ = try await operation.value
    }
    func testBooleanEpochIsNotAnAuthority() {
        let mailbox = FontHostMailbox(rootIsCurrent: { _ in true })
        let response = mailbox.handleMessage(["operation": "font.host.bind", "epoch": true])
        XCTAssertEqual(response["ok"] as? Bool, false)
    }
}
