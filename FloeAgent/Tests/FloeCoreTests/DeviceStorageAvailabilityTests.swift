import Foundation
import Testing
@testable import FloeCore

@Suite("Device storage availability")
struct DeviceStorageAvailabilityTests {
    @Test func boundariesAndUnknownCapacity() {
        #expect(DeviceStorageAvailability(availableBytes: nil).level == .normal)
        #expect(DeviceStorageAvailability(availableBytes: -1).availableBytes == nil)
        #expect(DeviceStorageAvailability(availableBytes: 0).level == .critical)
        #expect(DeviceStorageAvailability(availableBytes: DeviceStorageAvailability.criticalBytes - 1).level == .critical)
        #expect(DeviceStorageAvailability(availableBytes: DeviceStorageAvailability.criticalBytes).level == .low)
        #expect(DeviceStorageAvailability(availableBytes: DeviceStorageAvailability.lowBytes - 1).level == .low)
        #expect(DeviceStorageAvailability(availableBytes: DeviceStorageAvailability.lowBytes).level == .normal)
        #expect(DeviceStorageAvailability(availableBytes: nil).formattedAvailable == nil)
    }

    @Test func recognizesOnlyTypedStorageFailures() {
        for (domain, code) in [(NSCocoaErrorDomain, 640), (NSPOSIXErrorDomain, 28),
                               (NSPOSIXErrorDomain, 69), ("GRDB.DatabaseError", 13),
                               ("GRDB.DatabaseError", 13 | 256)] {
            #expect(StorageSpaceFailure.matches(NSError(domain: domain, code: code)))
        }
        for (domain, code) in [(NSCocoaErrorDomain, 513), (NSPOSIXErrorDomain, 13),
                               ("GRDB.DatabaseError", 11), ("unrelated", 13)] {
            #expect(!StorageSpaceFailure.matches(NSError(domain: domain, code: code)))
        }
        // A provider's text mentioning storage is not device evidence.
        #expect(!StorageSpaceFailure.matches(NSError(domain: "HTTP", code: 500,
            userInfo: [NSLocalizedDescriptionKey: "disk full"])))
    }

    @Test func followsBoundedUnderlyingErrors() {
        let full = NSError(domain: NSPOSIXErrorDomain, code: 28)
        let wrapped = NSError(domain: NSURLErrorDomain, code: -3003,
            userInfo: [NSUnderlyingErrorKey: full])
        #expect(StorageSpaceFailure.matches(wrapped))
        #expect(StorageSpaceFailure.matches(NSError(domain: "batch", code: 1,
            userInfo: ["NSMultipleUnderlyingErrors": [NSError(domain: "HTTP", code: 500), wrapped]])))
        var deep = full
        for _ in 0..<40 { deep = NSError(domain: "wrapper", code: 0, userInfo: [NSUnderlyingErrorKey: deep]) }
        #expect(!StorageSpaceFailure.matches(deep))
    }
}
