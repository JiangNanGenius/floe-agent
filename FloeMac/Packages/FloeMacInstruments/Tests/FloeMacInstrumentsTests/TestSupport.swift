// SPDX-License-Identifier: MPL-2.0

import CoreGraphics
import Foundation
import ImageIO
import XCTest
import UniformTypeIdentifiers
@testable import FloeMacInstruments
import FloeToolboxUtilities

enum MacToolboxTestRoot {
    static func makeDirectory(_ name: String) throws -> URL {
        let root: URL
        if let configured = ProcessInfo.processInfo.environment["MAC_TOOLBOX_TEST_ROOT"], !configured.isEmpty {
            root = URL(fileURLWithPath: configured, isDirectory: true)
        } else {
            root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
                .appendingPathComponent("test-run", isDirectory: true)
        }
        let directory = root.appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        return directory
    }

    static func remove(_ directory: URL) {
        try? FileManager.default.removeItem(at: directory)
    }
}

enum SyntheticImage {
    static func png(width: Int, height: Int,
                    topLeft: CGColor = CGColor(red: 1, green: 0, blue: 0, alpha: 1),
                    body: CGColor = CGColor(red: 0.2, green: 0.35, blue: 0.8, alpha: 1)) throws -> Data {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw NSError(domain: "SyntheticImage", code: 1)
        }
        context.setFillColor(body)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(topLeft)
        context.fill(CGRect(x: 0, y: height - 8, width: 8, height: 8))
        guard let image = context.makeImage() else { throw NSError(domain: "SyntheticImage", code: 2) }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else {
            throw NSError(domain: "SyntheticImage", code: 3)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw NSError(domain: "SyntheticImage", code: 4) }
        return output as Data
    }
}

@MainActor
final class FakeMacInstrumentPlatform: MacInstrumentPlatform {
    var locationEnabled: Bool
    init(locationEnabled: Bool) { self.locationEnabled = locationEnabled }
    func locationServicesEnabled() -> Bool { locationEnabled }
}

@MainActor
final class FakeLocationSource: MacLocationSource {
    var authorization: MacLocationAuthorization = .notDetermined
    var precise = true
    var servicesEnabled = true
    var onEvent: (@MainActor (MacLocationSourceEvent) -> Void)?
    private(set) var authorizationRequests = 0
    private(set) var startTokens: [UUID] = []
    private(set) var stopCount = 0
    var lastToken: UUID? { startTokens.last }

    func requestWhenInUseAuthorization() {
        authorizationRequests += 1
    }

    func start(token: UUID) {
        startTokens.append(token)
    }

    func stop() {
        stopCount += 1
    }

    func emit(_ event: MacLocationSourceEvent) {
        onEvent?(event)
    }

    func emitFix(latitude: Double = 37.3349,
                 longitude: Double = -122.0090,
                 accuracy: Double = 12,
                 altitude: Double? = 30,
                 speed: Double? = 1.5) {
        guard let token = lastToken else { return }
        emit(.fix(token: token, ToolboxLocationFix(
            latitude: latitude, longitude: longitude, horizontalAccuracy: accuracy,
            timestamp: Date(), altitude: altitude,
            verticalAccuracy: altitude == nil ? nil : 5,
            speed: speed, course: 90)))
    }
}
