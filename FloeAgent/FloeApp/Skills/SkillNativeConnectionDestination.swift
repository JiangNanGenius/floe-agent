// FloeApp — typed navigation destination for an App-native Skill connection.
//
// The generic Skill configuration page owns the field row and pushes this
// destination inside its existing NavigationStack. This view creates no
// top-level Settings item, no second sheet and no second client: the
// AppEnvironment integration caches one connection center (and its native
// client) per exact profile.

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import FloeCore
import FloeSync

struct SkillNativeConnectionDestination: View {
    let request: SkillConfigurationConnectionRequest
    @EnvironmentObject private var environment: AppEnvironment
    @State private var requestedValidation = false

    var body: some View {
        Group {
            if let center = environment.nativeExternalOAuthIntegration.connectionCenter(for: request) {
                NativeExternalOAuthConnectionView(center: center)
            } else if let center = environment.iosBridgeIntegration.connectionCenter(for: request) {
                IOSBridgeConnectionView(center: center)
                    .task { validateIfReady(center) }
                    .onChange(of: center.status) { _, status in
                        if status != .ready { requestedValidation = false }
                        validateIfReady(center)
                    }
            } else {
                ContentUnavailableView {
                    Label(
                        SkillConfigurationCopy.text(
                            "Connection unavailable",
                            "连接不可用"
                        ),
                        systemImage: "iphone.slash"
                    )
                } description: {
                    Text(SkillConfigurationCopy.text(
                        "This configuration cannot open the local iOS Bridge connection on this device.",
                        "此配置无法在此设备上打开本机 iOS Bridge 连接。"
                    ))
                }
            }
        }
    }

    /// Pairing installs a new connection revision. Run the real loopback
    /// validator once the page observes a ready connection so observe/control
    /// become discoverable without asking the user to press Validate again.
    @MainActor
    private func validateIfReady(_ center: IOSBridgeConnectionCenter) {
        guard !requestedValidation, center.status == .ready else { return }
        requestedValidation = true
        let profile = request.scope.profile
        Task { _ = await environment.iosBridgeIntegration.validateBridgeConnection(profile: profile) }
    }
}
#endif
