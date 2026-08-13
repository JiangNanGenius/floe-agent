import Foundation
import RoyalVNCKit

public enum VNCSessionState: Sendable, Hashable {
    case disconnected
    case connecting
    case connected
    case failed(String)
}

/// RoyalVNCKit session facade with credential ownership and a small,
/// thread-safe callback surface suitable for UIKit/SwiftUI renderers.
public final class VNCSession: NSObject, VNCConnectionDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let password: String?
    private var connection: VNCConnection?
    private var framebuffer: VNCFramebuffer?
    private var frameHandler: ((VNCFramebuffer) -> Void)?
    private var stateHandler: ((VNCSessionState) -> Void)?
    private var frameTimes: [ContinuousClock.Instant] = []

    public init(host: String, port: UInt16, password: String?) {
        self.password = password
        let settings = VNCConnection.Settings(
            isDebugLoggingEnabled: false,
            hostname: host,
            port: port,
            isShared: true,
            isScalingEnabled: true,
            useDisplayLink: false,
            inputMode: .forwardKeyboardShortcutsIfNotInUseLocally,
            isClipboardRedirectionEnabled: false,
            colorDepth: .depth24Bit,
            frameEncodings: .default
        )
        super.init()
        let connection = VNCConnection(settings: settings)
        connection.delegate = self
        self.connection = connection
    }

    public func connect() {
        emit(state: .connecting)
        connection?.connect()
    }

    public func disconnect() {
        connection?.disconnect()
    }

    public func onFrame(_ handler: ((VNCFramebuffer) -> Void)?) {
        let current = lock.withLock {
            frameHandler = handler
            return framebuffer
        }
        if let current, let handler { handler(current) }
    }

    public func onStateChange(_ handler: ((VNCSessionState) -> Void)?) {
        lock.withLock { stateHandler = handler }
    }

    public var currentFramebuffer: VNCFramebuffer? {
        lock.withLock { framebuffer }
    }

    public var measuredFramesPerSecond: Double {
        lock.withLock {
            guard frameTimes.count >= 2,
                  let first = frameTimes.first,
                  let last = frameTimes.last
            else { return 0 }
            let duration = first.duration(to: last)
            let seconds = Double(duration.components.seconds)
                + Double(duration.components.attoseconds) / 1e18
            return seconds > 0 ? Double(frameTimes.count - 1) / seconds : 0
        }
    }

    public func mouseMove(x: UInt16, y: UInt16) { connection?.mouseMove(x: x, y: y) }
    public func mouseDown(x: UInt16, y: UInt16) { connection?.mouseButtonDown(.left, x: x, y: y) }
    public func mouseUp(x: UInt16, y: UInt16) { connection?.mouseButtonUp(.left, x: x, y: y) }
    public func scroll(up: Bool, x: UInt16, y: UInt16, steps: UInt32 = 1) {
        connection?.mouseWheel(up ? .up : .down, x: x, y: y, steps: steps)
    }

    public func send(_ key: VNCKeyCode) {
        connection?.keyDown(key)
        connection?.keyUp(key)
    }

    public func send(text: String) {
        for character in text {
            if character.isNewline {
                send(.return)
            } else {
                for key in VNCKeyCode.withCharacter(character) { send(key) }
            }
        }
    }

    public func connection(_ connection: VNCConnection, stateDidChange connectionState: VNCConnection.ConnectionState) {
        switch connectionState.status {
        case .disconnected:
            if let error = connectionState.error { emit(state: .failed(error.localizedDescription)) }
            else { emit(state: .disconnected) }
        case .connecting: emit(state: .connecting)
        case .connected: emit(state: .connected)
        case .disconnecting: break
        }
    }

    public func connection(
        _ connection: VNCConnection,
        credentialFor authenticationType: VNCAuthenticationType,
        completion: @escaping (VNCCredential?) -> Void
    ) {
        _ = authenticationType
        completion(password.map(VNCPasswordCredential.init(password:)))
    }

    public func connection(_ connection: VNCConnection, didCreateFramebuffer framebuffer: VNCFramebuffer) {
        publish(framebuffer)
    }

    public func connection(_ connection: VNCConnection, didResizeFramebuffer framebuffer: VNCFramebuffer) {
        publish(framebuffer)
    }

    public func connection(
        _ connection: VNCConnection,
        didUpdateFramebuffer framebuffer: VNCFramebuffer,
        x: UInt16,
        y: UInt16,
        width: UInt16,
        height: UInt16
    ) {
        _ = (x, y, width, height)
        publish(framebuffer)
    }

    public func connection(_ connection: VNCConnection, didUpdateCursor cursor: VNCCursor) {
        _ = cursor
    }

    private func publish(_ framebuffer: VNCFramebuffer) {
        let handler = lock.withLock {
            self.framebuffer = framebuffer
            let now = ContinuousClock.now
            frameTimes.append(now)
            let cutoff = now.advanced(by: .seconds(-2))
            frameTimes.removeAll { $0 < cutoff }
            return frameHandler
        }
        handler?(framebuffer)
    }

    private func emit(state: VNCSessionState) {
        let handler = lock.withLock { stateHandler }
        handler?(state)
    }
}

#if canImport(SwiftUI) && canImport(UIKit) && canImport(MetalKit)
import SwiftUI
import UIKit
import MetalKit
import CoreImage

public struct VNCViewer: UIViewRepresentable {
    public let session: VNCSession

    public init(session: VNCSession) {
        self.session = session
    }

    public func makeUIView(context: Context) -> UIView {
        RemoteMetalView(session: session)
    }

    public func updateUIView(_ uiView: UIView, context: Context) {}

    public static func dismantleUIView(_ uiView: UIView, coordinator: Void) {
        (uiView as? RemoteMetalView)?.detach()
    }
}

private final class RemoteMetalView: MTKView, MTKViewDelegate, UIKeyInput {
    private let session: VNCSession
    private let renderContext: CIContext
    private let renderCommandQueue: MTLCommandQueue
    private var remoteSize = CGSize.zero
    private var lastPoint = (x: UInt16(0), y: UInt16(0))

    init(session: VNCSession) {
        self.session = session
        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalError("Floe Agent requires a Metal-capable device")
        }
        guard let commandQueue = device.makeCommandQueue() else {
            fatalError("Could not create the VNC Metal command queue")
        }
        self.renderContext = CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
        self.renderCommandQueue = commandQueue
        super.init(frame: .zero, device: device)
        framebufferOnly = false
        enableSetNeedsDisplay = true
        isPaused = true
        clearColor = MTLClearColorMake(0, 0, 0, 1)
        colorPixelFormat = .bgra8Unorm
        delegate = self
        isMultipleTouchEnabled = true

        let scroll = UIPanGestureRecognizer(target: self, action: #selector(scrollGesture(_:)))
        scroll.minimumNumberOfTouches = 2
        scroll.maximumNumberOfTouches = 2
        addGestureRecognizer(scroll)

        session.onFrame { [weak self] framebuffer in
            DispatchQueue.main.async {
                self?.remoteSize = framebuffer.cgSize
                self?.setNeedsDisplay()
            }
        }
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    var hasText: Bool { false }
    override var canBecomeFirstResponder: Bool { true }

    func insertText(_ text: String) { session.send(text: text) }
    func deleteBackward() { session.send(.delete) }

    func detach() {
        session.onFrame(nil)
        session.disconnect()
    }

    func draw(in view: MTKView) {
        guard let drawable = currentDrawable,
              let commandBuffer = renderCommandQueue.makeCommandBuffer(),
              let image = session.currentFramebuffer?.ciImage
        else { return }

        let target = CGSize(width: drawableSize.width, height: drawableSize.height)
        let scale = min(target.width / image.extent.width, target.height / image.extent.height)
        let scaled = CGSize(width: image.extent.width * scale, height: image.extent.height * scale)
        let origin = CGPoint(x: (target.width - scaled.width) / 2, y: (target.height - scaled.height) / 2)
        let transformed = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .transformed(by: CGAffineTransform(translationX: origin.x, y: origin.y))

        renderContext.render(
            transformed,
            to: drawable.texture,
            commandBuffer: commandBuffer,
            bounds: CGRect(origin: .zero, size: target),
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        becomeFirstResponder()
        guard let point = touches.first?.location(in: self), let remote = remotePoint(point) else { return }
        lastPoint = remote
        session.mouseMove(x: remote.x, y: remote.y)
        session.mouseDown(x: remote.x, y: remote.y)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let point = touches.first?.location(in: self), let remote = remotePoint(point) else { return }
        lastPoint = remote
        session.mouseMove(x: remote.x, y: remote.y)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        if let point = touches.first?.location(in: self), let remote = remotePoint(point) { lastPoint = remote }
        session.mouseUp(x: lastPoint.x, y: lastPoint.y)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        session.mouseUp(x: lastPoint.x, y: lastPoint.y)
    }

    @objc private func scrollGesture(_ gesture: UIPanGestureRecognizer) {
        guard gesture.state == .changed else { return }
        let velocity = gesture.velocity(in: self)
        guard abs(velocity.y) > 80 else { return }
        session.scroll(up: velocity.y > 0, x: lastPoint.x, y: lastPoint.y)
        gesture.setTranslation(.zero, in: self)
    }

    private func remotePoint(_ point: CGPoint) -> (x: UInt16, y: UInt16)? {
        guard remoteSize.width > 0, remoteSize.height > 0 else { return nil }
        let scale = min(bounds.width / remoteSize.width, bounds.height / remoteSize.height)
        let size = CGSize(width: remoteSize.width * scale, height: remoteSize.height * scale)
        let rect = CGRect(
            x: (bounds.width - size.width) / 2,
            y: (bounds.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
        guard rect.contains(point) else { return nil }
        let x = min(max((point.x - rect.minX) / rect.width, 0), 1)
        let y = min(max((point.y - rect.minY) / rect.height, 0), 1)
        return (
            UInt16(min(Double(UInt16.max), Double(x * remoteSize.width))),
            UInt16(min(Double(UInt16.max), Double(y * remoteSize.height)))
        )
    }
}
#endif
