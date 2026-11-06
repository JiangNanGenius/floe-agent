// SPDX-License-Identifier: MPL-2.0
import Foundation
import XCTest
import FloeCanvasCore
@testable import FloeCanvasExchange

/// Locates the coordinator-prepared interop fixtures. The default is the
/// read-only shared directory; an environment override is honored for
/// machines that keep it elsewhere.
enum ExchangeFixtureSupport {
    static let environmentKey = "FLOE_CANVAS_INTEROP_FIXTURES"

    static var root: URL {
        if let override = ProcessInfo.processInfo.environment[environmentKey], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<12 {
            url.deleteLastPathComponent()
            let candidate = url
                .appendingPathComponent("Local", isDirectory: true)
                .appendingPathComponent("Private", isDirectory: true)
                .appendingPathComponent("infinite-canvas-qualification-20261103", isDirectory: true)
                .appendingPathComponent("interop-fixtures", isDirectory: true)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        XCTFail("interop fixtures not found; set \(environmentKey)")
        return URL(fileURLWithPath: "/missing")
    }

    static func data(_ name: String) throws -> Data {
        let url = root.appendingPathComponent(name)
        return try Data(contentsOf: url)
    }

    static func json(_ name: String) throws -> JSONValue {
        try JSONFidelity.parse(data(name))
    }
}
