// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit) && canImport(Metal) && canImport(MetalKit)
import UIKit
import Metal
import MetalKit

/// Presents one live visual-novel session.
///
/// Frames come from the engine either as a shared `MTLTexture` (wait on the
/// engine's `MTLSharedEvent` before sampling) or as CPU pixels, drawn into a
/// `CGImage`. The view letterboxes by the engine's canvas size and forwards
/// touches as pointer events (one finger left-clicks; a two-finger tap
/// right-clicks for KAG's menu) plus hardware Return/Space/Escape/Control.
public final class VisualNovelGameView: UIView {
    public let session: any VisualNovelGameSession
    /// Called on the main thread when the game quits on its own.
    public var onGameFinished: (() -> Void)?

    private let metalView: MTKView
    private let metalDevice: MTLDevice
    private var displayLink: CADisplayLink?
    private let commandQueue: MTLCommandQueue
    private var pipelineState: MTLRenderPipelineState?
    private var samplerState: MTLSamplerState?
    private var lastSerial: UInt64 = 0
    private var cpuLayerContents: CGImage?

    public init?(session: any VisualNovelGameSession) {
        self.session = session
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return nil }
        self.metalDevice = device
        self.commandQueue = queue
        self.metalView = MTKView(frame: .zero, device: device)
        super.init(frame: .zero)
        backgroundColor = .black
        metalView.isOpaque = false
        metalView.backgroundColor = .clear
        metalView.isPaused = true
        metalView.enableSetNeedsDisplay = true
        metalView.framebufferOnly = false
        metalView.delegate = self
        metalView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(metalView)
        NSLayoutConstraint.activate([
            metalView.topAnchor.constraint(equalTo: topAnchor),
            metalView.bottomAnchor.constraint(equalTo: bottomAnchor),
            metalView.leadingAnchor.constraint(equalTo: leadingAnchor),
            metalView.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])
        isMultipleTouchEnabled = true
        buildPipeline()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }

    public override var canBecomeFirstResponder: Bool { true }

    public func startDisplay() {
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(step))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    public override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { becomeFirstResponder() }
    }

    public func stopDisplay() {
        displayLink?.invalidate()
        displayLink = nil
        resignFirstResponder()
    }

    @objc private func step(link: CADisplayLink) {
        let running = session.tick()
        metalView.setNeedsDisplay()
        if !running {
            stopDisplay()
            onGameFinished?()
        }
    }

    // MARK: - Metal pipeline (texture frames)

    private func buildPipeline() {
        let library: MTLLibrary
        do {
            library = try metalDevice.makeLibrary(source: Self.shaders, options: nil)
        } catch {
            pipelineState = nil
            return
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "kirikiriVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "kirikiriFragment")
        descriptor.colorAttachments[0].pixelFormat = metalView.colorPixelFormat
        samplerState = metalDevice.makeSamplerState(descriptor: {
            let d = MTLSamplerDescriptor()
            d.minFilter = .linear
            d.magFilter = .linear
            d.sAddressMode = .clampToEdge
            d.tAddressMode = .clampToEdge
            return d
        }())
        pipelineState = try? metalDevice.makeRenderPipelineState(descriptor: descriptor)
    }

    // MARK: - Input

    public override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        if touches.count >= 2 {
            for touch in touches {
                let point = normalizedPoint(for: touch)
                session.pointerCancelled(x: point.x, y: point.y, button: 0)
            }
            if let touch = touches.first {
                let point = normalizedPoint(for: touch)
                session.rightClick(x: point.x, y: point.y)
            }
            return
        }
        guard let touch = touches.first else { return }
        let point = normalizedPoint(for: touch)
        session.pointerDown(x: point.x, y: point.y, button: 0)
        session.touch(phase: 0, x: point.x, y: point.y, id: 0)
    }

    public override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first, touches.count == 1 else { return }
        let point = normalizedPoint(for: touch)
        session.pointerMoved(x: point.x, y: point.y, button: 0)
        session.touch(phase: 1, x: point.x, y: point.y, id: 0)
    }

    public override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first, touches.count == 1 else { return }
        let point = normalizedPoint(for: touch)
        session.pointerUp(x: point.x, y: point.y, button: 0)
        session.touch(phase: 2, x: point.x, y: point.y, id: 0)
    }

    public override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first else { return }
        let point = normalizedPoint(for: touch)
        session.pointerCancelled(x: point.x, y: point.y, button: 0)
        session.touch(phase: 2, x: point.x, y: point.y, id: 0)
    }

    public override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses {
            guard let key = press.key else { continue }
            if let virtualKey = Self.virtualKey(for: key) {
                session.key(virtualKey: virtualKey, down: true)
            }
        }
        super.pressesBegan(presses, with: event)
    }

    public override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses {
            guard let key = press.key else { continue }
            if let virtualKey = Self.virtualKey(for: key) {
                session.key(virtualKey: virtualKey, down: false)
            }
        }
        super.pressesEnded(presses, with: event)
    }

    private func normalizedPoint(for touch: UITouch) -> (x: Float, y: Float) {
        let location = touch.location(in: self)
        // The engine letterboxes the canvas itself; report view-normalized.
        return (Float(location.x / max(bounds.width, 1)),
                Float(location.y / max(bounds.height, 1)))
    }

    /// Windows virtual-key codes understood by KiriKiri.
    static func virtualKey(for key: UIKey) -> Int32? {
        switch key.keyCode {
        case .keyboardReturnOrEnter: return 0x0D
        case .keyboardSpacebar: return 0x20
        case .keyboardEscape: return 0x1B
        case .keyboardLeftControl, .keyboardRightControl: return 0x11
        case .keyboardLeftArrow: return 0x25
        case .keyboardUpArrow: return 0x26
        case .keyboardRightArrow: return 0x27
        case .keyboardDownArrow: return 0x28
        case .keyboardPageUp: return 0x21
        case .keyboardPageDown: return 0x22
        case .keyboardDeleteOrBackspace: return 0x08
        default: return nil
        }
    }

    // MARK: - CPU frame drawing

    private func drawCPUFrame(_ frame: VisualNovelFrame) {
        guard let pixels = frame.pixels, frame.width > 0, frame.height > 0,
              bounds.width > 0, bounds.height > 0 else { return }
        let width = Int(frame.width), height = Int(frame.height), pitch = Int(frame.pitch)
        guard pitch >= width * 4, pitch <= (64 * 1024 * 1024) / height else { return }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo: CGBitmapInfo = frame.isBGRA
            ? [CGBitmapInfo.byteOrder32Little, CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue)]
            : [CGBitmapInfo.byteOrder32Big, CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue)]
        guard let provider = CGDataProvider(dataInfo: nil, data: pixels, size: pitch * height,
                                            releaseData: { _, _, _ in }) else { return }
        guard let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: pitch, space: colorSpace, bitmapInfo: bitmapInfo,
                                  provider: provider, decode: nil, shouldInterpolate: true,
                                  intent: .defaultIntent) else { return }
        // Aspect-fit inside the view using the engine canvas size.
        let canvas = session.canvasSize()
        let canvasAspect = CGFloat(canvas.width) / CGFloat(max(canvas.height, 1))
        let viewAspect = bounds.width / max(bounds.height, 1)
        var drawRect = bounds
        if canvasAspect > viewAspect {
            let height = bounds.width / canvasAspect
            drawRect = CGRect(x: 0, y: (bounds.height - height) / 2, width: bounds.width, height: height)
        } else {
            let width = bounds.height * canvasAspect
            drawRect = CGRect(x: (bounds.width - width) / 2, y: 0, width: width, height: bounds.height)
        }
        UIGraphicsBeginImageContextWithOptions(bounds.size, true, 0)
        UIColor.black.setFill()
        UIRectFill(bounds)
        UIImage(cgImage: image).draw(in: drawRect)
        let composed = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        metalView.layer.contents = composed?.cgImage
    }
}

extension VisualNovelGameView: MTKViewDelegate {
    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    public func draw(in view: MTKView) {
        guard let frame = session.currentFrame() else { return }
        if frame.serial == lastSerial { return }
        lastSerial = frame.serial
        // Metal texture path.
        if let texturePointer = frame.texture,
           let pipelineState, let samplerState,
                      let drawable = view.currentDrawable {
            let texture = Unmanaged<MTLTexture>.fromOpaque(texturePointer).takeUnretainedValue()
            let commandBuffer = self.commandQueue.makeCommandBuffer()
            if let eventPointer = frame.event {
                let event = Unmanaged<MTLSharedEvent>.fromOpaque(eventPointer).takeUnretainedValue()
                commandBuffer?.encodeWaitForEvent(event, value: frame.eventValue)
            }
            if let pass = view.currentRenderPassDescriptor,
               let encoder = commandBuffer?.makeRenderCommandEncoder(descriptor: pass) {
                encoder.setRenderPipelineState(pipelineState)
                encoder.setFragmentTexture(texture, index: 0)
                encoder.setFragmentSamplerState(samplerState, index: 0)
                encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
                encoder.endEncoding()
            }
            if let commandBuffer {
                commandBuffer.present(drawable)
                commandBuffer.commit()
            }
            return
        }
        drawCPUFrame(frame)
    }

}

extension VisualNovelGameView {
    static let shaders = """
    #include <metal_stdlib>
    using namespace metal;

    typedef struct {
        float4 position [[position]];
        float2 textureCoordinate;
    } TextureVertex;

    vertex TextureVertex kirikiriVertex(uint vertexID [[vertex_id]]) {
        float2 positions[4] = {
            float2(-1.0, -1.0), float2(1.0, -1.0),
            float2(-1.0,  1.0), float2(1.0,  1.0)
        };
        float2 coordinates[4] = {
            float2(0.0, 1.0), float2(1.0, 1.0),
            float2(0.0, 0.0), float2(1.0, 0.0)
        };
        TextureVertex out;
        out.position = float4(positions[vertexID], 0.0, 1.0);
        out.textureCoordinate = coordinates[vertexID];
        return out;
    }

    fragment float4 kirikiriFragment(TextureVertex in [[stage_in]],
                                     texture2d<float> frame [[texture(0)]],
                                     sampler frameSampler [[sampler(0)]]) {
        return frame.sample(frameSampler, in.textureCoordinate);
    }
    """
}
#endif
