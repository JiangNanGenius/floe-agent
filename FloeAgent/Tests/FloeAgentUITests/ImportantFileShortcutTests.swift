#if canImport(SwiftUI) && canImport(UIKit)
import Testing
@testable import FloeApp

@Suite("FloeApp important file shortcuts")
struct ImportantFileShortcutTests {
    @Test("workspace paths with spaces survive structured result parsing")
    @MainActor
    func pathsWithSpaces() {
        #expect(ThreadDetailViewModel.importantPath(
            from: "patched=Sources/My Feature/main.py hunks=2 added=4 removed=1"
        ) == "Sources/My Feature/main.py")
        #expect(ThreadDetailViewModel.importantPath(
            from: "path=Reports/August Summary.csv offset=0 truncated=false totalLines=20"
        ) == "Reports/August Summary.csv")
    }

    @Test("unrelated summaries do not invent file shortcuts")
    @MainActor
    func unrelated() {
        #expect(ThreadDetailViewModel.importantPath(from: "entries=3 nextPageToken=nil") == nil)
    }
}
#endif
