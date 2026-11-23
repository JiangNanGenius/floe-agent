// SPDX-License-Identifier: MPL-2.0

import FloeDeviceLink
import FloeDeviceSync
import Foundation
import Testing

@Test(.timeLimit(.minutes(1)))
func approvedPeersExchangeHistoryAcrossSeveralFramesWithoutChangingTheirAddresses() async throws {
    let leftIdentity = FloeDeviceLinkIdentity.generate()
    let rightIdentity = FloeDeviceLinkIdentity.generate()
    let leftTask = UUID()
    let rightTask = UUID()
    let hiddenTask = UUID()
    let leftBytes = Data(repeating: 0xA5, count: 1_028_631)
    let rightBytes = Data(repeating: 0xFE, count: 556_341)
    let leftEndpoint = try await FloeDeviceLink.bind(identity: leftIdentity, trustedEndpointIDs: [], relay: .disabled,
                                                     bindAddress: "127.0.0.1:0")
    let rightEndpoint = try await FloeDeviceLink.bind(identity: rightIdentity, trustedEndpointIDs: [], relay: .disabled,
                                                      bindAddress: "127.0.0.1:0")
    let leftAddress = leftEndpoint.address()
    let rightAddress = rightEndpoint.address()
    let left = DeviceHistorySync(link: leftEndpoint, shares: [:], source: .init(list: { _ in
        [.init(id: leftTask, title: "Left conversation"), .init(id: hiddenTask, title: "Private")]
    }, export: { _ in leftBytes }))
    let right = DeviceHistorySync(link: rightEndpoint, shares: [:], source: .init(list: { _ in
        [.init(id: rightTask, title: "Right conversation")]
    }, export: { _ in rightBytes }))
    await left.start()
    await right.start()
    do {
        await #expect(throws: FloeDeviceLinkError.peerNotAuthorized) { try await left.offers(from: rightAddress) }
        try await left.replaceShares([rightIdentity.endpointID: [leftTask]])
        try await right.replaceShares([leftIdentity.endpointID: [rightTask]])
        #expect(try await left.offers(from: rightAddress).map(\.id) == [rightTask])
        #expect(try await right.offers(from: leftAddress).map(\.id) == [leftTask])
        #expect(try await left.history(rightTask, from: rightAddress) == rightBytes)
        #expect(try await right.history(leftTask, from: leftAddress) == leftBytes)
        await #expect(throws: DeviceHistorySyncError.notShared) { try await right.history(hiddenTask, from: leftAddress) }
        try await left.replaceShares([rightIdentity.endpointID: []])
        #expect(try await right.offers(from: leftAddress).isEmpty)
        await #expect(throws: DeviceHistorySyncError.notShared) { try await right.history(leftTask, from: leftAddress) }
    } catch {
        await left.stop()
        await right.stop()
        throw error
    }
    await left.stop()
    await right.stop()
}

private actor DeliveredHistory {
    private(set) var pages: [DeviceHistoryDelivery] = []

    func receive(_ delivery: DeviceHistoryDelivery) {
        pages.append(delivery)
    }
}

@Test(.timeLimit(.minutes(1)))
func pagesResumeOnANewConnectionAndOldPeersKeepExchangingArchives() async throws {
    let leftIdentity = FloeDeviceLinkIdentity.generate()
    let rightIdentity = FloeDeviceLinkIdentity.generate()
    let leftTask = UUID()
    let rightTask = UUID()
    let first = Data(repeating: 0xA1, count: 400_000)
    let second = Data(repeating: 0xC1, count: 17)
    let legacy = Data(repeating: 0xE2, count: 53)
    let leftEndpoint = try await FloeDeviceLink.bind(identity: leftIdentity, trustedEndpointIDs: [rightIdentity.endpointID],
                                                     relay: .disabled, bindAddress: "127.0.0.1:0")
    let rightEndpoint = try await FloeDeviceLink.bind(identity: rightIdentity, trustedEndpointIDs: [leftIdentity.endpointID],
                                                      relay: .disabled, bindAddress: "127.0.0.1:0")
    let leftAddress = leftEndpoint.address()
    let rightAddress = rightEndpoint.address()
    let left = DeviceHistorySync(link: leftEndpoint, shares: [rightIdentity.endpointID: [leftTask]], source: .init(
        list: { _ in [.init(id: leftTask, title: "Paged")] }, export: { _ in legacy },
        exportPage: { _, after, through in
            switch after {
            case nil:
                #expect(through == nil)
                return .init(archive: first, nextCursor: "first", through: 2, hasMore: true)
            case "first":
                #expect(through == nil || through == 2)
                return .init(archive: second, nextCursor: "last", through: 2, hasMore: false)
            default:
                throw DeviceHistorySyncError.cursorExpired
            }
        }
    ))
    let right = DeviceHistorySync(link: rightEndpoint, shares: [leftIdentity.endpointID: [rightTask]], source: .init(
        list: { _ in [.init(id: rightTask, title: "Legacy")] }, export: { _ in legacy }
    ))
    await left.start()
    await right.start()
    do {
        let initial = DeliveredHistory()
        await #expect(throws: DeviceHistorySyncError.disconnected) {
            try await right.transferHistory(leftTask, from: leftAddress, after: "expired") { delivery in
                await initial.receive(delivery)
                throw DeviceHistorySyncError.disconnected
            }
        }
        guard case .page(let receivedFirst, let cursor) = await initial.pages.first else {
            Issue.record("Expected a page after the expired cursor was reset")
            throw DeviceHistorySyncError.invalidResponse
        }
        #expect(receivedFirst == first && cursor == "first")

        try await left.replaceShares([rightIdentity.endpointID: []])
        await #expect(throws: DeviceHistorySyncError.notShared) {
            try await right.transferHistory(leftTask, from: leftAddress, after: cursor) { _ in
                Issue.record("A revoked page must never reach the receiver")
            }
        }
        try await left.replaceShares([rightIdentity.endpointID: [leftTask]])
        let resumed = DeliveredHistory()
        try await right.transferHistory(leftTask, from: leftAddress, after: cursor) { await resumed.receive($0) }
        let pages = await resumed.pages
        #expect(pages.count == 1)
        guard case .page(let receivedSecond, let last) = pages.first else {
            throw DeviceHistorySyncError.invalidResponse
        }
        #expect(receivedSecond == second && last == "last")
        #expect(try await right.history(leftTask, from: leftAddress) == legacy)
        let fallback = DeliveredHistory()
        try await left.transferHistory(rightTask, from: rightAddress, after: nil) { await fallback.receive($0) }
        guard case .archive(let receivedArchive) = await fallback.pages.first else {
            throw DeviceHistorySyncError.invalidResponse
        }
        #expect(receivedArchive == legacy)
    } catch {
        await left.stop()
        await right.stop()
        throw error
    }
    await left.stop()
    await right.stop()
}
