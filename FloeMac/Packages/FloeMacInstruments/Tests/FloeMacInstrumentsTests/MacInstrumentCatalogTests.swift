// SPDX-License-Identifier: MPL-2.0

import XCTest
@testable import FloeMacInstruments
import FloeToolboxCore

@MainActor
final class MacInstrumentCatalogTests: XCTestCase {
    func testEveryInstrumentMapsToAnExistingToolboxInstrument() {
        XCTAssertEqual(MacInstrument.allCases.count, 8)
        for instrument in MacInstrument.allCases {
            XCTAssertEqual(instrument.toolboxTool.group, .instruments,
                           "\(instrument.rawValue) must map to an instruments-group ToolboxTool")
            XCTAssertFalse(instrument.title(Locale(identifier: "en_US")).isEmpty)
            XCTAssertFalse(instrument.title(Locale(identifier: "zh_Hans")).isEmpty)
        }
        XCTAssertEqual(Set(MacInstrument.allCases.map(\.toolboxTool)),
                       [.level, .motion, .compass, .ruler, .measure, .location, .photoMeasure, .barometer])
    }

    func testImplementedInstrumentsAreOnlyTheRealMacSurfaces() {
        let catalog = MacInstrumentCatalog(platform: FakeMacInstrumentPlatform(locationEnabled: true))
        XCTAssertEqual(catalog.implementedInstruments, [.location, .ruler, .photoMeasurement])
        XCTAssertEqual(catalog.availability(for: .ruler), .available)
        XCTAssertEqual(catalog.availability(for: .photoMeasurement), .available)
        XCTAssertEqual(catalog.availability(for: .location), .available)
    }

    func testLocationRequiresSystemLocationServices() {
        let catalog = MacInstrumentCatalog(platform: FakeMacInstrumentPlatform(locationEnabled: false))
        guard case .needsSetup(let notice) = catalog.availability(for: .location) else {
            return XCTFail("Location must report a setup requirement when Location Services is off")
        }
        XCTAssertFalse(notice.zh.isEmpty)
        XCTAssertFalse(notice.en.isEmpty)
    }

    func testAbsentSensorAPIsHaveExplicitReasonsAndNoImplementations() {
        let catalog = MacInstrumentCatalog(platform: FakeMacInstrumentPlatform(locationEnabled: true))
        for instrument in [MacInstrument.level, .motion, .compass, .barometer, .spatialMeasurement] {
            guard case .unsupported(let notice) = catalog.availability(for: instrument) else {
                return XCTFail("\(instrument.rawValue) must be unsupported in this native Mac target")
            }
            XCTAssertFalse(notice.zh.isEmpty)
            XCTAssertFalse(notice.en.isEmpty)
            XCTAssertFalse(catalog.implementedInstruments.contains(instrument))
        }
    }
}
