#if os(iOS)
import AVFoundation
import SwiftUI
import UIKit

/// The QR entry uses the same leased camera and preview as Scan and Read.
/// A result is returned once; closing or backgrounding releases the camera.
@MainActor struct ToolboxQRScannerView: View {
    let onResult: (String) -> Void
    @Environment(\.locale) private var locale
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var service = OpticsCaptureService.shared
    @StateObject private var model = OpticsScannerModel()
    @State private var finished = false

    var body: some View {
        NavigationStack {
            surface
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.background)
                .navigationTitle(workbenchText("扫描二维码", "Scan QR code", locale))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(workbenchText("取消", "Cancel", locale)) { close() }
                            .accessibilityIdentifier("toolbox.qr.scan.cancel")
                    }
                }
        }
        .onAppear { model.start() }
        .onDisappear { finished = true; model.stop() }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { model.stop() }
            else if !finished { model.start() }
        }
        .onChange(of: service.latestCodes) { _, codes in
            guard !finished, model.ownsCapture, service.running,
                  let code = codes.first(where: {
                      $0.symbology == AVMetadataObject.ObjectType.qr.rawValue && !$0.payload.isEmpty
                  }) else { return }
            finished = true
            model.stop()
            onResult(code.payload)
            dismiss()
        }
    }

    @ViewBuilder private var surface: some View {
        if model.busyNotice || (model.ownsCapture && service.issue == .cameraBusy) {
            message("camera", workbenchText("相机正在使用中", "Camera in use", locale),
                    workbenchText("请关闭其他相机工具后重试。", "Close the other camera tool, then try again.", locale), retry: true)
        } else if model.ownsCapture && service.authorization == .denied {
            VStack(spacing: 16) {
                message("camera.fill", workbenchText("需要相机权限", "Camera access needed", locale),
                        workbenchText("允许相机访问后即可扫描，也可以取消并选择图片。", "Allow camera access to scan, or cancel and choose an image.", locale), retry: false)
                Button(workbenchText("打开设置", "Open Settings", locale)) {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .accessibilityIdentifier("toolbox.qr.scan.settings")
            }
            .padding(.bottom, 24)
            .accessibilityIdentifier("toolbox.qr.scan.denied")
        } else if model.ownsCapture && service.authorization == .unavailable {
            message("camera", workbenchText("相机不可用", "Camera unavailable", locale),
                    workbenchText("此设备没有可用相机，请取消后选择图片识别。", "This device has no available camera. Cancel and choose an image instead.", locale), retry: false)
                .accessibilityIdentifier("toolbox.qr.scan.unavailable")
        } else if model.ownsCapture && service.issue == .interrupted {
            message("camera", workbenchText("扫描已中断", "Scanning interrupted", locale),
                    workbenchText("返回应用后重试。", "Return to the app, then try again.", locale), retry: true)
        } else if model.ownsCapture, case .sessionFailed = service.issue {
            message("exclamationmark.triangle", workbenchText("无法启动相机", "Unable to start camera", locale),
                    workbenchText("请重试，或取消后选择图片识别。", "Try again, or cancel and choose an image.", locale), retry: true)
        } else if model.ownsCapture && service.running {
            VStack(spacing: 16) {
                ZStack {
                    OpticsCameraPreview(session: service.session, host: model.previewHost)
                    Image(systemName: "viewfinder")
                        .resizable().scaledToFit().foregroundStyle(.white.opacity(0.9))
                        .frame(maxWidth: 240, maxHeight: 240).padding(32)
                        .accessibilityHidden(true)
                }
                .clipShape(RoundedRectangle(cornerRadius: 20))
                .accessibilityLabel(workbenchText("相机预览，对准二维码", "Camera preview. Point at a QR code.", locale))
                .accessibilityIdentifier("toolbox.qr.scan.preview")
                Text(workbenchText("将二维码放入画面，识别后会自动返回。", "Place the QR code in view. The result returns automatically.", locale))
                    .font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(20)
        } else {
            ProgressView(workbenchText("正在启动相机…", "Starting camera…", locale))
                .accessibilityIdentifier("toolbox.qr.scan.starting")
        }
    }

    private func message(_ symbol: String, _ title: String, _ detail: String, retry: Bool) -> some View {
        ContentUnavailableView {
            Label(title, systemImage: symbol)
        } description: {
            Text(detail)
        } actions: {
            if retry {
                Button(workbenchText("重试", "Try again", locale)) { model.retry() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .accessibilityIdentifier("toolbox.qr.scan.retry")
            }
        }
    }

    private func close() {
        finished = true
        model.stop()
        dismiss()
    }
}
#endif
