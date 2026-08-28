import Foundation
import Testing
@testable import FloeCore

@Suite("Canvas preferences")
struct CanvasPreferencesTests {
    @Test("Defaults preserve ink and require Pencil input")
    func defaults() {
        let value = CanvasPreferences()
        #expect(value.preserveInkAfterConversion)
        #expect(!value.fingerDrawingEnabled)
        #expect(value.doubleTapAction == .toggleEraser)
        #expect(value.understandingMode == .automatic)
    }

    @Test("Preferences round trip through user defaults")
    func persistence() throws {
        let suite = "CanvasPreferencesTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var expected = CanvasPreferences()
        expected.pencilWidth = 8.5
        expected.doubleTapAction = .createCard
        expected.understandingMode = .diagram
        expected.save(to: defaults)
        #expect(CanvasPreferences.load(from: defaults) == expected)
    }
}
