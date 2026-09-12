//
//  CameraPreviewView.swift
//  VideoEditorKit
//
//  Created by Adriano Souza Costa on 23.03.2026.
//

import AVFoundation
import SwiftUI

struct CameraPreviewView: View {

    // MARK: - Private Properties

    private let captureSession: AVCaptureSession

    // MARK: - Body

    var body: some View {
        CameraPreviewBridge(captureSession)
    }

    // MARK: - Initializer

    init(_ captureSession: AVCaptureSession) {
        self.captureSession = captureSession
    }

}

#Preview {
    CameraPreviewView(AVCaptureSession())
        .frame(height: 400)
}
