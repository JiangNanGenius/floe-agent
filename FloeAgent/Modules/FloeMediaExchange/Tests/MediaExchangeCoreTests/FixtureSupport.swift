// SPDX-License-Identifier: MPL-2.0

import Foundation
import XCTest
@testable import MediaExchangeCore

enum Fixture {
    static let root: URL = {
        // .../Tests/MediaExchangeCoreTests/FixtureSupport.swift
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }()

    static func url(_ relative: String) -> URL {
        root.appendingPathComponent(relative)
    }

    static func data(_ relative: String) throws -> Data {
        try Data(contentsOf: url(relative))
    }
}

enum TestSupport {
    static func temporaryDirectory(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-media-exchange-\(UUID().uuidString)-\(name)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    static func sha256(_ data: Data) -> String {
        ExchangeProjectManifest.sha256(data)
    }
}
