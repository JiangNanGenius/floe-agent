import SwiftUI
import AppKit
import AVFoundation
import QuartzCore

/// Live camera preview backed by `AVCaptureVideoPreviewLayer`. Clicks are
/// converted to device coordinates by the preview layer itself and forwarded to
/// the controller; no SwiftUI coordinate guessing is involved.
struct MacCameraPreview: NSViewRepresentable {
    let session: AVCaptureSession
    /// Digital magnification applied to the preview layer. macOS has no device
    /// zoom factor, so this never claims optical zoom.
    var zoom: CGFloat = 1
    var onFocus: ((CGPoint) -> Void)? = nil

    func makeNSView(context: Context) -> MacCameraPreviewView {
        let view = MacCameraPreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        view.onFocus = onFocus
        applyZoom(to: view)
        return view
    }

    func updateNSView(_ view: MacCameraPreviewView, context: Context) {
        if view.previewLayer.session !== session {
            view.previewLayer.session = session
        }
        view.onFocus = onFocus
        applyZoom(to: view)
    }

    private func applyZoom(to view: MacCameraPreviewView) {
        let clamped = max(1, zoom)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        view.previewLayer.setAffineTransform(CGAffineTransform(scaleX: clamped, y: clamped))
        CATransaction.commit()
    }
}

final class MacCameraPreviewView: NSView {
    let previewLayer = AVCaptureVideoPreviewLayer()
    var onFocus: ((CGPoint) -> Void)? = nil

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.masksToBounds = true
        layer?.addSublayer(previewLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        return nil
    }

    override func makeBackingLayer() -> CALayer {
        CALayer()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        previewLayer.frame = bounds
        CATransaction.commit()
    }

    override func mouseDown(with event: NSEvent) {
        guard let onFocus else {
            super.mouseDown(with: event)
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        onFocus(previewLayer.captureDevicePointConverted(fromLayerPoint: point))
    }
}
