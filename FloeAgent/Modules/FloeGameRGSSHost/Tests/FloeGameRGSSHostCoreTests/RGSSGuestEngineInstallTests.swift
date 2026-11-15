// SPDX-License-Identifier: MPL-2.0
import Foundation
import XCTest
import FloeGameCore
import FloeGameRGSS
import FloeGameRGSSHostCore

final class RGSSGuestEngineInstallTests: XCTestCase {
    func testValidInstallPreflightIsReadOnlyAndChecksPins() throws {
        let fixture = try makeFixture()
        let receipt = try RGSSGuestEngineInstall(engine: .rpgMakerXP,
                                                  mapping: fixture.mapping).preflight()
        XCTAssertEqual(receipt.engine, .rpgMakerXP)
        XCTAssertEqual(receipt.binaryGuestPath, "/floe/env/opt/floe/rgss/bin/tapir-x")
        XCTAssertEqual(receipt.sourceCommit, RGSSGuestEngineInstall.sourceCommit)
        XCTAssertTrue(receipt.binarySHA256.count == 64)
        XCTAssertTrue(receipt.licensePaths.contains("licenses/tapir/LICENSE-APACHE"))
        let binaryBytes = try Data(contentsOf: fixture.binary)
        XCTAssertEqual(binaryBytes.count, 64,
                       "preflight never rewrites or executes the binary")
    }

    func testMissingBinaryFailsClosed() throws {
        let fixture = try makeFixture()
        try FileManager.default.removeItem(at: fixture.binary)
        do {
            _ = try RGSSGuestEngineInstall(engine: .rpgMakerXP,
                                           mapping: fixture.mapping).preflight()
            XCTFail("missing engine must fail")
        } catch let error as RGSSGuestRunError {
            guard case .engineInstallMissing = error else {
                return XCTFail("unexpected \(error)")
            }
        }
    }

    func testWrongArchitectureFailsClosed() throws {
        let fixture = try makeFixture()
        var header = [UInt8](repeating: 0, count: 64)
        header[0] = 0x7F; header[1] = 0x45; header[2] = 0x4C; header[3] = 0x46
        header[4] = 2; header[5] = 1
        header[18] = 0x3E; header[19] = 0x00 // x86-64, not aarch64
        try Data(header).write(to: fixture.binary)
        do {
            _ = try RGSSGuestEngineInstall(engine: .rpgMakerXP,
                                           mapping: fixture.mapping).preflight()
            XCTFail("wrong architecture must fail")
        } catch let error as RGSSGuestRunError {
            guard case .engineInstallInvalid = error else {
                return XCTFail("unexpected \(error)")
            }
        }
    }

    private struct Fixture {
        let root: URL
        let binary: URL
        let mapping: TestEnvironmentMapping
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rgss-engine-\(UUID().uuidString)", isDirectory: true)
        let engineRoot = root.appendingPathComponent("opt/floe/rgss", isDirectory: true)
        let binary = engineRoot.appendingPathComponent("bin/tapir-x")
        var header = [UInt8](repeating: 0, count: 64)
        header[0] = 0x7F; header[1] = 0x45; header[2] = 0x4C; header[3] = 0x46
        header[4] = 2; header[5] = 1
        header[18] = 0xB7; header[19] = 0x00
        try FileManager.default.createDirectory(at: binary.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(header).write(to: binary)
        let digest = GameDigest.sha256(try Data(contentsOf: binary))
        let manifest: [String: Any] = [
            "engine": RGSSGuestEngineInstall.pinID,
            "sourcePins": ["tapir": RGSSGuestEngineInstall.sourceCommit],
            "binaries": ["xp": ["sha256": digest]],
        ]
        let manifestData = try JSONSerialization.data(withJSONObject: manifest,
                                                      options: [.sortedKeys])
        try manifestData.write(to: engineRoot.appendingPathComponent("VERSION.json"))
        for relative in [
            "licenses/tapir/LICENSE-APACHE",
            "licenses/tapir/COPYRIGHT",
            "licenses/ruby181/COPYING",
            "SOURCE-OFFER.md",
        ] {
            let url = engineRoot.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try Data("notice".utf8).write(to: url)
        }
        return Fixture(root: root, binary: binary,
                       mapping: TestEnvironmentMapping(hostEnvironment: root))
    }
}

private struct TestEnvironmentMapping: RGSSGuestHostPathMapping {
    let hostEnvironment: URL

    func hostURL(forGuestPath path: String) throws -> URL {
        guard path.hasPrefix("/floe/env/") else {
            throw RGSSGuestRunError.invalidRequest("outside environment share")
        }
        return hostEnvironment.appendingPathComponent(String(path.dropFirst("/floe/env/".count)))
    }
}
