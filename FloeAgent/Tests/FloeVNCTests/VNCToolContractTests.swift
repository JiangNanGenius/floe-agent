import Foundation
import Testing
@testable import FloeVNC

@Suite("VNC model tool contracts")
struct VNCToolContractTests {
    private let unavailable: VNCSessionProvider = { nil }

    @Test("Observe advertises evidence-backed framebuffer coordinates")
    func observeDescriptor() {
        #expect(VNCObserveTool.name == "vnc.observe")
        #expect(VNCObserveTool.toolDescription.contains("screenshotSHA256"))
        #expect(VNCObserveTool.toolDescription.contains("no native DOM"))
        #expect(VNCObserveTool.toolDescription.contains("recognizedText"))
        #expect(VNCObserveTool.toolEffect == .readOnly)
    }

    @Test("Structured click only accepts OCR references")
    func structuredClickValidation() throws {
        let tool = VNCClickElementTool(sessionProvider: unavailable)
        let digest = String(repeating: "d", count: 64)
        try tool.validate(.init(reference: "text-1", screenshotSHA256: digest))
        #expect(throws: (any Error).self) {
            try tool.validate(.init(reference: "button-1", screenshotSHA256: digest))
        }
    }

    @Test("Click requires valid coordinates and one or two clicks")
    func clickValidation() throws {
        let tool = VNCClickTool(sessionProvider: unavailable)
        try tool.validate(.init(x: 0, y: 0, screenshotSHA256: String(repeating: "a", count: 64)))
        #expect(throws: (any Error).self) {
            try tool.validate(.init(x: -1, y: 0, screenshotSHA256: String(repeating: "a", count: 64)))
        }
        #expect(throws: (any Error).self) {
            try tool.validate(.init(
                x: 1,
                y: 1,
                screenshotSHA256: String(repeating: "a", count: 64),
                clickCount: 3
            ))
        }
    }

    @Test("Text input is bounded")
    func textValidation() throws {
        let tool = VNCTypeTextTool(sessionProvider: unavailable)
        try tool.validate(.init(text: "hello", submit: true))
        #expect(throws: (any Error).self) { try tool.validate(.init(text: "")) }
        #expect(throws: (any Error).self) {
            try tool.validate(.init(text: String(repeating: "x", count: 4097)))
        }
    }

    @Test("Scroll rejects zero and unbounded steps")
    func scrollValidation() throws {
        let tool = VNCScrollTool(sessionProvider: unavailable)
        let digest = String(repeating: "b", count: 64)
        try tool.validate(.init(x: 10, y: 20, deltaY: -4, screenshotSHA256: digest))
        #expect(throws: (any Error).self) {
            try tool.validate(.init(x: 10, y: 20, deltaY: 0, screenshotSHA256: digest))
        }
        #expect(throws: (any Error).self) {
            try tool.validate(.init(x: 10, y: 20, deltaY: 21, screenshotSHA256: digest))
        }
    }

    @Test("Drag requires distinct bounded points and duration")
    func dragValidation() throws {
        let tool = VNCDragTool(sessionProvider: unavailable)
        let digest = String(repeating: "c", count: 64)
        try tool.validate(.init(fromX: 1, fromY: 2, toX: 10, toY: 20, screenshotSHA256: digest))
        #expect(throws: (any Error).self) {
            try tool.validate(.init(fromX: 1, fromY: 2, toX: 1, toY: 2, screenshotSHA256: digest))
        }
        #expect(throws: (any Error).self) {
            try tool.validate(.init(
                fromX: 1,
                fromY: 2,
                toX: 10,
                toY: 20,
                screenshotSHA256: digest,
                durationMilliseconds: 3_001
            ))
        }
    }

    @Test("Named key input is restricted to documented keys")
    func keyValidation() throws {
        let tool = VNCKeyPressTool(sessionProvider: unavailable)
        try tool.validate(.init(key: "Escape"))
        try tool.validate(.init(key: "F12"))
        #expect(throws: (any Error).self) { try tool.validate(.init(key: "Power")) }
    }
}
