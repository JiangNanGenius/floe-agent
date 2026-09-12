//
//  RecordVideoView.swift
//  VideoEditorKit
//
//  Created by Adriano Souza Costa on 23.03.2026.
//

import SwiftUI

struct RecordVideoView: View {

    // MARK: - Environments

    @Environment(\.dismiss) private var dismiss

    // MARK: - States

    @State private var cameraManager = CameraManager()

    // MARK: - Private Properties

    private let onFinishRecord: (URL) -> Void

    // MARK: - Body

    var body: some View {
        NavigationStack {
            ZStack {
                CameraPreviewView(cameraManager.session)
                    .ignoresSafeArea()
            }
            .safeAreaInset(edge: .bottom) {
                Button {
                    cameraManager.toggleRecording()
                } label: {
                    Circle()
                        .fill(cameraManager.isRecording ? Theme.primary : Theme.destructive)
                        .frame(width: 55, height: 55)
                }
                .padding(.bottom, 16)
            }
            .navigationBarBackButtonHidden(true)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.headline.weight(.semibold))
                            .frame(width: 44, height: 44)
                            .foregroundStyle(Theme.primary)
                            .circleControl()
                    }
                    .buttonStyle(.plain)
                }

                ToolbarItem(placement: .principal) {
                    Text(cameraManager.recordedDuration.formatterTimeString())
                        .font(.headline.monospacedDigit())
                }
            }
        }
        .preferredColorScheme(.dark)
        .onChange(of: cameraManager.finalURL) { _, newValue in
            if newValue != nil, let url = cameraManager.consumeFinalURL() {
                onFinishRecord(url)
                dismiss()
            }
        }
    }

    // MARK: - Initializer

    init(_ onFinishRecord: @escaping (URL) -> Void) {
        self.onFinishRecord = onFinishRecord
    }

}

#Preview {
    RecordVideoView { _ in }
}
