// FloeApp — guided wrapper for ReplayKit's system broadcast picker.

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import ReplayKit
import FloeCore

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
                Text("Floe 正在发起系统屏幕共享确认。请在系统面板中点“开始直播”；画面只写入 Floe 的 App Group，发送给视觉模型前仍会再次确认。")
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
        .onAppear {
            FloeLogger(category: .app).info("screenShareSheetAppeared")
        }
        .presentationDetents([.medium, .large])
    }
}

private struct SystemBroadcastPicker: UIViewRepresentable {
    final class Coordinator {
        var didRequest = false
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        let picker = RPSystemBroadcastPickerView(frame: .zero)
        picker.preferredExtension = ScreenShareCenter.screenShareExtensionID
        picker.showsMicrophoneButton = false
        picker.tintColor = .systemBlue
        requestSystemConfirmation(from: picker, coordinator: context.coordinator)
        return picker
    }

    func updateUIView(_ uiView: RPSystemBroadcastPickerView, context: Context) {
        uiView.preferredExtension = ScreenShareCenter.screenShareExtensionID
        uiView.showsMicrophoneButton = false
        uiView.tintColor = .systemBlue
        requestSystemConfirmation(from: uiView, coordinator: context.coordinator)
    }

    /// ReplayKit exposes only its system-owned broadcast button on iOS. A
    /// task-start request activates that button once after it joins the view
    /// hierarchy, which opens the real system confirmation; the final Start
    /// Broadcast decision remains the user's.
    private func requestSystemConfirmation(
        from picker: RPSystemBroadcastPickerView,
        coordinator: Coordinator
    ) {
        guard !coordinator.didRequest else { return }
        coordinator.didRequest = true
        // The system-owned UIButton is installed only after the picker enters
        // a window. Retry briefly instead of consuming the one automatic
        // request while its subview hierarchy is still empty.
        Task { @MainActor in
            for attempt in 0..<30 {
                if picker.window != nil, let button = Self.firstButton(in: picker) {
                    FloeLogger(category: .app).info(
                        "screenShareSystemConfirmationTriggered attempt=\(attempt + 1)"
                    )
                    button.sendActions(for: .touchUpInside)
                    return
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
            // Leave the visible system button usable when iOS requires a
            // genuine tap; ReplayKit always owns final consent.
            FloeLogger(category: .app).warning(
                "screenShareSystemButtonUnavailable attempts=30"
            )
        }
    }

    private static func firstButton(in view: UIView) -> UIButton? {
        if let button = view as? UIButton { return button }
        for child in view.subviews {
            if let button = firstButton(in: child) { return button }
        }
        return nil
    }
}
#endif
