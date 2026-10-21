import Foundation
import Testing
@testable import FloeCore

@Suite("System entry navigation and intake")
struct FloeAppEntryRouteTests {
    private let id = UUID(uuidString: "2A9BB479-F614-473C-B8E4-008E2DFE8222")!

    @Test func widgetAndShareLinksKeepTheirExactTarget() throws {
        #expect(try FloeAppEntryRoute.parse(URL(string: "floe://new")!) == .newTask)
        #expect(try FloeAppEntryRoute.parse(URL(string: "FLOE://TASK/\(id.uuidString)")!) == .task(id))
        #expect(try FloeAppEntryRoute.parse(URL(string: "floe://share")!) == .shareInbox(nil))
        #expect(try FloeAppEntryRoute.parse(FloeAppEntryRoute.shareInbox(id).url) == .shareInbox(id))
        #expect(FloeAppEntryRoute.task(id).url.absoluteString == "floe://task/\(id.uuidString.lowercased())")
    }

    @Test(arguments: [
        "floe://run", "floe://execute", "floe://new?prompt=run&autoSend=true",
        "floe://task/2a9bb479-f614-473c-b8e4-008e2dfe8222?run=true",
        "floe://share?envelope=2a9bb479-f614-473c-b8e4-008e2dfe8222&envelope=2a9bb479-f614-473c-b8e4-008e2dfe8222",
        "floe://user:password@new", "floe://new:123", "floe://new#run",
        "https://example.invalid/floe/new", "javascript:runTask()"
    ])
    func untrustedLinksCannotBecomeExecutionOrAmbiguousIntake(_ input: String) throws {
        #expect(throws: FloeAppEntryRouteError.self) {
            try FloeAppEntryRoute.parse(#require(URL(string: input)))
        }
    }

    @Test(arguments: [
        "floe://task", "floe://task/not-a-uuid", "floe://task/../new",
        "floe://task/%2F2a9bb479-f614-473c-b8e4-008e2dfe8222",
        "floe://task/2a9bb479-f614-473c-b8e4-008e2dfe8222/other",
        "floe://share?envelope", "floe://share?envelope=", "floe://share?task=all"
    ])
    func malformedOrForeignTargetShapesAreRejected(_ input: String) throws {
        #expect(throws: FloeAppEntryRouteError.self) {
            try FloeAppEntryRoute.parse(#require(URL(string: input)))
        }
    }

    @Test func documentProviderURLsArePreservedWithoutGrantingFileAccess() throws {
        let file = URL(fileURLWithPath: "/tmp/Synthetic document.floenote")
        #expect(try FloeAppEntryRoute.parse(file) == .externalFile(file))
        #expect(try FloeAppEntryRoute.parse(file).url == file)
        // Parsing never opens the URL. Materialization/type/ownership checks
        // belong to the App's actual document-intake service.
        #expect(throws: FloeAppEntryRouteError.self) {
            try FloeAppEntryRoute.parse(#require(URL(string: "file://remote.invalid/shared/example.floenote")))
        }
        #expect(throws: FloeAppEntryRouteError.self) {
            try FloeAppEntryRoute.parse(#require(URL(string: "file:///tmp/example.floenote?run=1")))
        }
    }

    @Test func oversizedIntakeLinksDoNotReachRouting() throws {
        let input = "floe://share?envelope=" + String(repeating: "a", count: FloeAppEntryRoute.maximumURLBytes)
        #expect(throws: FloeAppEntryRouteError.tooLong) {
            try FloeAppEntryRoute.parse(#require(URL(string: input)))
        }
    }
}
