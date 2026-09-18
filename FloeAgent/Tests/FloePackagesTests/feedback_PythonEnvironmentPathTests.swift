// feedback_PythonEnvironmentPathTests — Build 191 feedback repair.
//
// The writable layer's site-packages must be the first PYTHONPATH entry even
// before the first pip install creates it, otherwise a freshly installed
// distribution resolves to the bundled read-only copy (observed as
// importlib.metadata 0.9.0 shadowing the installed one).

import Foundation
import Testing
import FloeEnvironments

@Suite("feedback python environment path")
struct FeedbackPythonEnvironmentPathTests {
    @Test func writableSitePackagesLeadsEvenWhenMissing() {
        let writable = URL(fileURLWithPath: "/private/tmp/floe-feedback-\(UUID().uuidString)")
        let existing = URL(fileURLWithPath: "/private/tmp/floe-feedback-layer-\(UUID().uuidString)")
        let entries = PythonEnvironmentPath.entries(
            writableLayerURL: writable,
            stackedSitePackages: [existing]
        )
        #expect(entries.count == 2)
        #expect(entries.first?.hasSuffix("/usr/lib/floe-python/site-packages") == true)
        #expect(entries.last == existing.path)
        // The path is present even though the directory does not exist yet.
        #expect(!FileManager.default.fileExists(atPath: entries[0]))
    }

    @Test func duplicateWritableEntryIsNotRepeated() {
        let writable = URL(fileURLWithPath: "/private/tmp/floe-feedback-\(UUID().uuidString)")
        let site = writable.appendingPathComponent("usr/lib/floe-python/site-packages")
        let entries = PythonEnvironmentPath.entries(writableLayerURL: writable, stackedSitePackages: [site])
        #expect(entries.count == 1)
        #expect(entries[0].hasSuffix("/usr/lib/floe-python/site-packages"))
    }
}
