// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Testing
import UIKit
@testable import FloeCAD

@Suite("Texture painter shares CAD physical drawing policy")
@MainActor struct CADTextureDrawingInputTests {
    @Test func actualRecognizerAllowsPencilAndPointerWithoutFingerOptIn() {
        let recognizer = CADTexturePaintStrokeRecognizer(target: nil, action: nil)
        recognizer.configure(enabled: true, fingerDrawingEnabled: false)
        let precision = Set([UITouch.TouchType.pencil, .indirect, .indirectPointer].map { NSNumber(value: $0.rawValue) })
        #expect(Set(recognizer.allowedTouchTypes) == precision)
        recognizer.configure(enabled: true, fingerDrawingEnabled: true)
        #expect(Set(recognizer.allowedTouchTypes) == precision.union([NSNumber(value: UITouch.TouchType.direct.rawValue)]))
        recognizer.configure(enabled: true, fingerDrawingEnabled: false)
        #expect(Set(recognizer.allowedTouchTypes) == precision)
    }
    @Test func admittedStrokeIsRevokedByOptOutOrDisabledOwnerAndCannotBeCommittedTwice() {
        var input = CADTexturePaintStrokeGate()
        let fingerAccepted = input.begin(CADViewportInputSource(.direct), enabled: true, fingerDrawingEnabled: false)
        #expect(!fingerAccepted)
        let rejectedCommit = input.finish()
        #expect(!rejectedCommit)
        for type in [UITouch.TouchType.pencil, .indirect, .indirectPointer] {
            let precisionAccepted = input.begin(CADViewportInputSource(type), enabled: true, fingerDrawingEnabled: false)
            #expect(precisionAccepted)
            input.update(enabled: true, fingerDrawingEnabled: false)
            let precisionCommitted = input.finish()
            #expect(precisionCommitted)
            let duplicateCommit = input.finish()
            #expect(!duplicateCommit)
        }
        let enabledFingerAccepted = input.begin(.finger, enabled: true, fingerDrawingEnabled: true)
        #expect(enabledFingerAccepted)
        input.update(enabled: true, fingerDrawingEnabled: false)
        input.update(enabled: true, fingerDrawingEnabled: true)
        #expect(!input.permitsSamples)
        let revokedFingerCommit = input.finish()
        #expect(!revokedFingerCommit)
        let pointerAccepted = input.begin(.pointer, enabled: true, fingerDrawingEnabled: false)
        #expect(pointerAccepted)
        input.update(enabled: false, fingerDrawingEnabled: false)
        input.update(enabled: true, fingerDrawingEnabled: false)
        let disabledOwnerCommit = input.finish()
        #expect(!disabledOwnerCommit)
        let pencilAccepted = input.begin(.pencil, enabled: true, fingerDrawingEnabled: false)
        #expect(pencilAccepted)
        input.cancel()
        let cancelledCommit = input.finish()
        #expect(!cancelledCommit)
    }
}
#endif
