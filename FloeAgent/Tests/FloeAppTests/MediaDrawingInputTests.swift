// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import SwiftUI
import Testing
import UIKit
@testable import FloeApp

@Suite("Media physical drawing input")
@MainActor struct MediaDrawingInputTests {
    @Test func onlyInkUsesDrawingPolicyAndPrecisionSourcesWorkByDefault() {
        for tool in ["image.brush", "image.eraser", "image.pen"] {
            #expect(MediaDrawingInputPolicy.isStrokeTool(tool))
        }
        for tool in ["move", "image.rectangle", "image.lasso", "image.polygon", "image.crop", "image.eyedropper", "video.trim"] {
            #expect(!MediaDrawingInputPolicy.isStrokeTool(tool))
        }
        for type in [UITouch.TouchType.pencil, .indirect, .indirectPointer] {
            var input = MediaStrokeInputGate()
            let precisionAccepted = input.begin(type, fingerDrawing: false)
            #expect(precisionAccepted)
            input.update(fingerDrawing: false)
            #expect(input.permitsSamples(fingerDrawing: false))
            let precisionCommitted = input.finish(fingerDrawing: false)
            #expect(precisionCommitted)
            let duplicateCommit = input.finish(fingerDrawing: false)
            #expect(!duplicateCommit, "An end without an accepted active touch must never commit.")
        }
        var rejected = MediaStrokeInputGate()
        let fingerAccepted = rejected.begin(.direct, fingerDrawing: false)
        #expect(!fingerAccepted)
        let lateOptInCommit = rejected.finish(fingerDrawing: true)
        #expect(!lateOptInCommit, "Opting in later does not authorize a previously rejected touch.")
    }
    @Test func optOutAndCancellationDiscardFingerStrokeWithoutRevivingIt() {
        var input = MediaStrokeInputGate()
        let fingerAccepted = input.begin(.direct, fingerDrawing: true)
        #expect(fingerAccepted)
        input.update(fingerDrawing: false)
        input.update(fingerDrawing: true)
        #expect(!input.permitsSamples(fingerDrawing: true))
        let revokedCommit = input.finish(fingerDrawing: true)
        #expect(!revokedCommit)
        let pencilAccepted = input.begin(.pencil, fingerDrawing: false)
        #expect(pencilAccepted)
        input.cancel()
        let cancelledCommit = input.finish(fingerDrawing: false)
        #expect(!cancelledCommit)
        let pointerAccepted = input.begin(.indirectPointer, fingerDrawing: false)
        #expect(pointerAccepted)
        let pointerCommitted = input.finish(fingerDrawing: false)
        #expect(pointerCommitted)
    }
    @Test func sharedLegacyAndV2PreferenceDefaultsOffAndPersistsOptIn() throws {
        let name = "MediaDrawingInputTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        var first = AppStorage(wrappedValue: false, MediaDrawingInputPolicy.preferenceKey, store: defaults)
        #expect(!first.wrappedValue)
        first.wrappedValue = true
        let reopened = AppStorage(wrappedValue: false, MediaDrawingInputPolicy.preferenceKey, store: defaults)
        #expect(reopened.wrappedValue)
        first.wrappedValue = false
        #expect(!AppStorage(wrappedValue: false, MediaDrawingInputPolicy.preferenceKey, store: defaults).wrappedValue)
    }
}
#endif
