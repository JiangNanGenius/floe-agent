// FloeAppTests — engineering preview session reparenting.
//
// The same EngineeringWebSession must survive the embedded ↔ fullscreen
// transition: two attach calls (different view instances) keep the SAME
// WKWebView, generation and dirty state; only an explicit retry reloads.

#if canImport(UIKit)
import Foundation
import SwiftUI
import Testing
@testable import FloeApp
import FloeCore
import FloeWorkspace

@Suite("Engineering web session reparenting", .serialized)
@MainActor
struct EngineeringWebSessionReparentTests {
    private func samplePackage() throws -> EngineeringPreviewPackage {
        guard let root = Bundle.main.url(forResource: "EngineeringViewers", withExtension: nil),
              let data = try? Data(contentsOf: root.appendingPathComponent("sample-plate.dxf")) else {
            throw FloeError.notFound("EngineeringViewers sample-plate.dxf in the app bundle")
        }
        return try EngineeringPreviewPackage.single(name: "plate.dxf", bytes: data)
    }

    @Test("second attach reuses the same web view and preserves dirty state")
    func reparentPreservesSession() throws {
        let package = try samplePackage()
        let session = EngineeringWebSession()
        let web1 = session.attach(package: package, error: Box<String?>(nil).binding,
                                  onReview: nil, onSave: { _, _ in "sha" }, onDirty: nil,
                                  dark: false, locale: "en")
        let generation1 = session.generation
        #expect(generation1 != nil)

        // Dirty state as reported by the page's dirty bridge.
        session.coordinator?.dirty = true

        // Fullscreen (a different view instance) attaches the SAME session.
        let web2 = session.attach(package: package, error: Box<String?>(nil).binding,
                                  onReview: nil, onSave: { _, _ in "sha" }, onDirty: nil,
                                  dark: false, locale: "en")
        #expect(web1 === web2)
        #expect(session.generation == generation1)
        #expect(session.coordinator?.dirty == true)

        // A same-session retry is what reloads — not a new view appearing.
        session.retry()
        #expect(session.generation == nil)
        let web3 = session.attach(package: package, error: Box<String?>(nil).binding,
                                  onReview: nil, onSave: { _, _ in "sha" }, onDirty: nil,
                                  dark: false, locale: "en")
        #expect(web3 !== web1)
        #expect(session.generation != nil)
        #expect(session.generation != generation1)
        session.tearDown()
    }

    @Test("read-only embedded → editable fullscreen upgrades the live page without reload")
    func capabilityUpgradePreservesSession() throws {
        let package = try samplePackage()
        let session = EngineeringWebSession()
        // Embedded preview: read-only (no onSave).
        let web1 = session.attach(package: package, error: Box<String?>(nil).binding,
                                  onReview: nil, onSave: nil, onDirty: nil,
                                  dark: false, locale: "en")
        let generation1 = session.generation
        #expect(session.loadedCanEdit == false)
        // Fullscreen: editable. Same web view, same generation, canEdit flipped.
        let web2 = session.attach(package: package, error: Box<String?>(nil).binding,
                                  onReview: nil, onSave: { _, _ in "sha" }, onDirty: nil,
                                  dark: false, locale: "en")
        #expect(web1 === web2)
        #expect(session.generation == generation1)
        #expect(session.loadedCanEdit == true)
        // Back to embedded read-only: still the same live page.
        let web3 = session.attach(package: package, error: Box<String?>(nil).binding,
                                  onReview: nil, onSave: nil, onDirty: nil,
                                  dark: false, locale: "en")
        #expect(web3 === web1)
        session.tearDown()
    }

    @Test("attaching a different document rebuilds instead of mixing content")
    func differentDocumentRebuilds() throws {
        let package = try samplePackage()
        let session = EngineeringWebSession()
        _ = session.attach(package: package, error: Box<String?>(nil).binding,
                           onReview: nil, onSave: nil, onDirty: nil, dark: false, locale: "en")
        let firstGeneration = session.generation
        let firstKey = session.loadedDocumentKey
        // A different document (same extension) must not reuse the page.
        let other = try EngineeringPreviewPackage.single(
            name: "other.dxf",
            bytes: Data(contentsOf: Bundle.main.url(forResource: "EngineeringViewers/sample-plate", withExtension: "dxf")!))
        _ = session.attach(package: other, error: Box<String?>(nil).binding,
                           onReview: nil, onSave: nil, onDirty: nil, dark: false, locale: "en")
        #expect(session.generation != firstGeneration)
        #expect(session.loadedDocumentKey != firstKey)
        session.tearDown()
    }
}

/// Mutable box so tests can share a Binding target without inout captures.
private final class Box<T> {
    var value: T
    init(_ value: T) { self.value = value }
    var binding: Binding<T> { Binding(get: { self.value }, set: { self.value = $0 }) }
}
#endif
