// SPDX-License-Identifier: MPL-2.0

import FloeAndroidCore
import Foundation
import Testing

@Suite("Device history attachment bridge")
struct DeviceHistoryBridgeDigestTests {
    @Test("An exact lowercase SHA-256 reaches ticket validation")
    func acceptsADigestWithRoomForItsTerminator() {
        let id = UUID().uuidString
        let digest = String(repeating: "a", count: 64)

        func restore(_ value: String) -> Int32 {
            var reply = [CChar](repeating: 0, count: 256)
            return id.withCString { identifier in
                value.withCString { digestPointer in
                    reply.withUnsafeMutableBufferPointer { buffer in
                        floeDeviceHistoryAttachmentRestoreCommit(
                            Int64.max, identifier, identifier, digestPointer,
                            buffer.baseAddress, Int32(buffer.count))
                    }
                }
            }
        }

        #expect(restore(digest) == DeviceHistoryBridgeStatus.sessionUnknown)
        #expect(restore(String(digest.dropLast())) == DeviceHistoryBridgeStatus.invalidArguments)
        #expect(restore(digest + "a") == DeviceHistoryBridgeStatus.invalidArguments)
        #expect(restore(digest.uppercased()) == DeviceHistoryBridgeStatus.invalidArguments)
    }
}
