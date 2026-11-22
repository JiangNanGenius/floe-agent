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
