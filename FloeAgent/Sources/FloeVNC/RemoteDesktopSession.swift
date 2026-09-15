// SPDX-License-Identifier: MPL-2.0
import Foundation

/// Pixel/input contract shared by RFB and RDP. Protocol negotiation,
/// authentication and credentials stay with each transport. Existing visual
/// tools keep their fresh-frame/evidence checks above this boundary.
public protocol RemoteDesktopSession: AnyObject, Sendable {
    var isConnected: Bool { get }
    var currentState: VNCSessionState { get }
    var currentFrameRevision: UInt64 { get }
    var currentVisualEvidence: VNCVisualEvidence? { get }
    var currentStructuredEvidence: VNCStructuredEvidence? { get }
    func rememberVisualEvidence(_ evidence: VNCVisualEvidence)
    func rememberStructuredEvidence(_ evidence: VNCStructuredEvidence)
    func captureJPEG(compressionQuality: Double) throws -> VNCFrameCapture
    func mouseMove(x: UInt16, y: UInt16) throws
    func mouseDown(x: UInt16, y: UInt16) throws
    func mouseUp(x: UInt16, y: UInt16) throws
    func scroll(up: Bool, x: UInt16, y: UInt16, steps: UInt32) throws
    func click(x: UInt16, y: UInt16) throws
    func send(namedKey: String) throws
    func send(text: String) throws
    func send(text: String, submit: Bool) throws
}

public extension RemoteDesktopSession {
    func captureJPEG() throws -> VNCFrameCapture { try captureJPEG(compressionQuality: 0.78) }
    func scroll(up: Bool, x: UInt16, y: UInt16) throws { try scroll(up: up, x: x, y: y, steps: 1) }
    func send(text: String, submit: Bool) throws {
        try send(text: text)
        if submit { try send(namedKey: "return") }
    }
    func click(x: UInt16, y: UInt16) throws {
        try mouseMove(x: x, y: y)
        try mouseDown(x: x, y: y)
        do { try mouseUp(x: x, y: y) }
        catch { try? mouseUp(x: x, y: y); throw error }
    }
}

extension VNCSession: RemoteDesktopSession {}
