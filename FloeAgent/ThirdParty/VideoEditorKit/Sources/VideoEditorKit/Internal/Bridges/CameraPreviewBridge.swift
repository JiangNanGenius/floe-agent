//
//  CameraPreviewBridge.swift
//  VideoEditorKit
//
//  Created by Codex on 09.04.2026.
//

import AVFoundation
import SwiftUI

final class CaptureSessionPreviewView: UIView {

    // MARK: - Private Properties

    private let captureSession: AVCaptureSession

    // MARK: - Initializer

    init(_ captureSession: AVCaptureSession) {
        self.captureSession = captureSession
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Public Methods

    override class var layerClass: AnyClass {
        AVCaptureVideoPreviewLayer.self
    }

    override func didMoveToSuperview() {
        super.didMoveToSuperview()

        guard let videoPreviewLayer else {
            assertionFailure("Expected AVCaptureVideoPreviewLayer backing layer.")
            return
        }

        if superview != nil {
            videoPreviewLayer.session = captureSession
            videoPreviewLayer.videoGravity = .resizeAspectFill
        } else {
            videoPreviewLayer.session = nil
            videoPreviewLayer.removeFromSuperlayer()
        }
    }

    // MARK: - Private Properties

    private var videoPreviewLayer: AVCaptureVideoPreviewLayer? {
        layer as? AVCaptureVideoPreviewLayer
    }

}

struct CameraPreviewBridge: UIViewRepresentable {

    // MARK: - Public Properties

    typealias UIViewType = CaptureSessionPreviewView

    // MARK: - Private Properties

    private let captureSession: AVCaptureSession

    // MARK: - Initializer

    init(_ captureSession: AVCaptureSession) {
        self.captureSession = captureSession
    }

    // MARK: - Public Methods

    func makeUIView(context: Context) -> CaptureSessionPreviewView {
        CaptureSessionPreviewView(captureSession)
    }

    func updateUIView(_ uiView: CaptureSessionPreviewView, context: Context) {}

}
