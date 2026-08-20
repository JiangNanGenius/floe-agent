// FloeApp — guided wrapper for ReplayKit's system broadcast picker.

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import ReplayKit

struct BroadcastPickerView: View {
    @ObservedObject var center: ScreenShareCenter
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Image(systemName: "rectangle.inset.filled.and.person.filled")
                    .font(.system(size: 52))
                    .foregroundStyle(.blue)
                Text("共享屏幕给 Floe").font(.title2.bold())
                Text("点下方系统按钮，在弹出的列表中选择 Floe Agent，然后点“开始直播”。画面只写入 Floe 的 App Group；发送给视觉模型前仍会再次确认。")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
                SystemBroadcastPicker()
                    .frame(width: 72, height: 72)
                    .accessibilityLabel("开始屏幕共享")
                Label(
                    center.isSharing ? "正在接收屏幕画面" : "等待系统开始屏幕共享",
                    systemImage: center.isSharing ? "checkmark.circle.fill" : "hourglass"
                )
                .foregroundStyle(center.isSharing ? .green : .secondary)
                if let error = center.sharingError {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
                Spacer()
            }
            .padding(.top, 36)
            .navigationTitle("屏幕共享")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") {
                        dismiss()
                    }
                }
            }
        }
        .task { center.startSharing() }
        .presentationDetents([.medium, .large])
    }
}

private struct SystemBroadcastPicker: UIViewRepresentable {
    func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        let picker = RPSystemBroadcastPickerView(frame: .zero)
        picker.preferredExtension = ScreenShareCenter.screenShareExtensionID
        picker.showsMicrophoneButton = false
        return picker
    }

    func updateUIView(_ uiView: RPSystemBroadcastPickerView, context: Context) {
        uiView.preferredExtension = ScreenShareCenter.screenShareExtensionID
        uiView.showsMicrophoneButton = false
    }
}
#endif
