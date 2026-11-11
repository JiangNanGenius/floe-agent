import Foundation
import Testing
@testable import FloeToolboxUtilities

@Test func locationMeasurementsKeepUnknownFieldsUnknown() {
    let fix = ToolboxLocationFix(latitude: -33.86, longitude: 151.20, horizontalAccuracy: 7, timestamp: .now,
                                 altitude: 99, verticalAccuracy: -1, speed: -1, course: 360)
    #expect(fix.isValid)
    #expect(fix.altitude == nil && fix.verticalAccuracy == nil && fix.speed == nil && fix.course == nil)
    #expect(fix.coordinateText == "-33.860000, 151.200000")
    #expect(fix.mapsURL?.host == "maps.apple.com")
}

@Test func staleFutureAndInvalidLocationAreNotCurrentFixes() {
    let now = Date()
    #expect(!ToolboxLocationFix(latitude: 91, longitude: 0, horizontalAccuracy: 1, timestamp: now).isValid)
    #expect(!ToolboxLocationFix(latitude: 0, longitude: .nan, horizontalAccuracy: 1, timestamp: now).isValid)
    #expect(!ToolboxLocationFix(latitude: 0, longitude: 0, horizontalAccuracy: -1, timestamp: now).isValid)
    #expect(!ToolboxLocationFix(latitude: 0, longitude: 0, horizontalAccuracy: 1, timestamp: now.addingTimeInterval(-16)).isFresh(at: now))
    #expect(!ToolboxLocationFix(latitude: 0, longitude: 0, horizontalAccuracy: 1, timestamp: now.addingTimeInterval(5)).isFresh(at: now))
}

@Test func savedPlacesSurviveReopenAndCorruptionIsPreserved() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("places.json")
    let archive = ToolboxLocationArchive(url: url)
    let fix = ToolboxLocationFix(latitude: 1, longitude: 2, horizontalAccuracy: 3, timestamp: Date(timeIntervalSince1970: 1234))
    let saved = try await archive.save(name: "  Test place  ", fix: fix)
    #expect(saved.count == 1 && saved[0].name == "Test place")
    #expect(try await ToolboxLocationArchive(url: url).load() == saved)
    #expect(try await archive.remove(id: saved[0].id).isEmpty)
    let corrupt = Data("recover this original".utf8)
    try corrupt.write(to: url)
    await #expect(throws: (any Error).self) { try await archive.save(name: "New", fix: fix) }
    #expect(try Data(contentsOf: url) == corrupt)
}
