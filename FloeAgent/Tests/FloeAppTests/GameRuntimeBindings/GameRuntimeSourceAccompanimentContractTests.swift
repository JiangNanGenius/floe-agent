// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import XCTest
import Foundation
import FloeGameCore
import FloeGamePortableKit
@testable import FloeApp

/// Source regression portfolio for the corrected on-demand manifest and the
/// truthful source-accompaniment status. These tests are authored but NOT
/// executed in this source-only task.
final class GameRuntimeSourceAccompanimentContractTests: XCTestCase {
    private func catalogData(state: String = "unpublished",
                             distributionReady: Bool = false) throws -> Data {
        let notice = Data("notice".utf8)
        return try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 1,
            "kind": "floe-game-runtime-source-accompaniment",
            "productionPublication": [
                "state": "unpublished", "distributionReady": false,
                "writtenOfferCreated": false, "detail": "not published",
            ],
            "packs": [
                "lovejs-11.4.1": [
                    "packID": "lovejs-11.4.1",
                    "engines": ["love"],
                    "profileID": "portable-love",
                    "licenses": [[
                        "path": "licenses/COPYING.txt",
                        "sha256": GameDigest.sha256(notice),
                        "bytes": notice.count,
                    ]],
                    "helperSources": [],
                    "relink": [],
                    "sourcePackages": [],
                    "publication": [
                        "state": state,
                        "distributionReady": distributionReady,
                        "writtenOfferCreated": false,
                        "publicURL": NSNull(),
                        "detail": "exact local bytes; publication remains explicit",
                    ],
                ],
            ],
        ], options: [.sortedKeys])
    }

    func testSourceCatalogDecodesAndExposesUnpublishedState() throws {
        let catalog = try GamePortableSourceAccompanimentCatalog(from: catalogData())
        let pack = try XCTUnwrap(catalog.accompaniment(for: .love))
        XCTAssertEqual(pack.profileID, "portable-love")
        XCTAssertEqual(pack.licenses.count, 1)
        XCTAssertFalse(pack.publication.distributionReady)
        XCTAssertEqual(pack.publication.state, "unpublished")
    }

    func testRegistryManifestDecodesSourceAndDistributionLinks() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 1,
            "generatedFrom": "test",
            "packs": [[
                "id": "lovejs-11.4.1",
                "role": "primary",
                "engines": ["love"],
                "displayName": "love.js 11.4.1",
                "version": "11.4.1",
                "license": "MIT; LGPL-2.1 mpg123",
                "kind": "reviewedPackArchive",
                "files": [],
                "licenseFiles": [],
                "markers": [],
                "sourceAccompanimentID": "lovejs-11.4.1",
                "distributionProfileID": "portable-love",
                "notes": [],
            ]],
        ], options: [.sortedKeys])
        let manifest = try JSONDecoder().decode(GameRuntimeResourceManifest.self, from: data)
        let pack = try XCTUnwrap(manifest.packs.first)
        XCTAssertEqual(pack.sourceAccompanimentID, "lovejs-11.4.1")
        XCTAssertEqual(pack.distributionProfileID, "portable-love")
    }

    func testAttributionFilesArePartOfTheManifestContract() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 1,
            "generatedFrom": "test",
            "packs": [[
                "id": "renpy-8.5.3-web",
                "role": "supplementary",
                "engines": [],
                "displayName": "Ren'Py Web",
                "version": "8.5.3",
                "license": "Ren'Py",
                "kind": "remoteArchive",
                "files": [],
                "licenseFiles": ["licenses/RENPY-LICENSE.txt"],
                "markers": ["index.html"],
                "attribution": [
                    "bundledDirectory": "Attribution/renpy",
                    "files": [[
                        "path": "licenses/RENPY-LICENSE.txt",
                        "sha256": String(repeating: "a", count: 64),
                        "bytes": 10,
                    ]],
                ],
                "notes": [],
            ]],
        ], options: [.sortedKeys])
        let manifest = try JSONDecoder().decode(GameRuntimeResourceManifest.self, from: data)
        let attribution = try XCTUnwrap(manifest.packs.first?.attribution)
        XCTAssertEqual(attribution.bundledDirectory, "Attribution/renpy")
        XCTAssertEqual(attribution.files.count, 1)
    }

    func testUnpublishedStatusIsNotPresentedAsReady() {
        let status = GameRuntimeSourceAccompanimentStatus.unpublished("source offer unpublished")
        XCTAssertFalse(status.isDistributionReady)
        XCTAssertEqual(status.text, "source offer unpublished")
    }
}
#endif
