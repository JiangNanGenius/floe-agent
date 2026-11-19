// SPDX-License-Identifier: MPL-2.0
#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import FloeCore

enum FloeUserAgreement {
    static let storageKey = "floe.userAgreement.acceptedRelease"
    static let currentReceipt = "accepted"

    static func hasAccepted(_ saved: String) -> Bool {
        if saved == currentReceipt { return true }
        // Releases through 1.8.48 stored the app version and agreement revision.
        return saved.wholeMatch(of: /[0-9]+(?:\.[0-9]+)*\/[0-9]+/) != nil
    }

    static var bypassForTesting: Bool {
        #if DEBUG
        let process = ProcessInfo.processInfo
        if process.arguments.contains("--ui-test-user-agreement") { return false }
        return process.arguments.contains("-ui-testing")
            || process.environment["XCTestConfigurationFilePath"] != nil
        #else
        return false
        #endif
    }

    static var title: String { FloeL10n.isChinese ? "Floe 用户协议" : "Floe User Agreement" }
    static var document: String { FloeL10n.isChinese ? chinese : english }

    private static let chinese = """
    **Floe 用户协议**

    本协议适用于 Floe 应用、桌面客户端、Bridge 及其他配套软件。点击「同意并继续」即表示你接受本协议。**Floe 免费提供软件工具，不内置任何由 Floe 提供的生成服务。**软件提供文件处理、创作、自动化、第三方服务连接和结果展示等功能。具体功能因平台、设备、版本和配置而异。你自行选择和配置第三方在线服务或端侧模型。使用第三方在线服务时，请求由相应服务商处理，内容由该服务商生成并返回。服务的使用条件、费用、额度和可用性以该服务商的规定为准。**对于端侧生成，Floe 只提供运行环境。**内容由第三方公开发布的模型在你的设备上生成。你应依法使用第三方服务，遵守对应的服务条款，并按各模型的许可条款下载和使用端侧模型。生成内容可能存在错误、遗漏，或不适合你的用途。你自行决定是否采用、执行、分享或发布这些内容，并在操作前核验内容、使用权限及可能产生的影响。你对自行利用第三方服务或端侧模型实施的违法行为依法承担相应责任。Floe 对第三方返回的内容造成的损失不承担赔偿责任。你授权的任务可能创建、修改或删除文件、运行代码、更改设备或远程系统的状态，也可能产生第三方费用。请在授权前核对操作对象、权限范围和预期影响，并为重要文件保留备份。使用 Floe 时，请仅操作你有权使用的文件、账户、网络、设备和系统，尊重他人的合法权益，遵守适用法律。请勿利用 Floe 实施诈骗、侵权、未经授权的访问或其他违法行为。你创建或导入的内容，其权利仍归你或相应权利人所有。导入、修改或分享他人的内容时，请遵守相应的授权条件。软件中的开源组件按各自的许可证使用。软件更新、系统升级或第三方服务变动可能影响部分功能的兼容性和可用性。你可以随时停止使用 Floe，并通过软件支持的导出功能保留所需文件。
    """

    private static let english = """
    **Floe User Agreement**

    This agreement applies to the Floe app, desktop client, Bridge, and other companion software. Selecting “Agree and Continue” means you accept this agreement. **Floe provides software tools free of charge. It does not include any generation service provided by Floe.** The software provides file processing, creative tools, automation, connections to third-party services, and display of results. Available features depend on your platform, device, software version, and configuration. You choose and configure third-party online services or on-device models yourself. When you use a third-party online service, that provider processes your requests and generates and returns the content. The provider sets the terms of use, fees, quotas, and availability of its service. **For on-device generation, Floe provides only the runtime environment.** Models publicly released by third parties generate content on your device. You must use third-party services lawfully, comply with their terms, and download and use on-device models in accordance with their licenses. Generated content may contain errors or omissions or may be unsuitable for your purposes. You decide whether to use, execute, share, or publish it. Before doing so, verify the content, your rights to use it, and the possible effects. You are responsible under applicable law for unlawful acts you carry out using third-party services or on-device models. Floe is not liable for losses caused by content returned by third parties. Tasks you authorize may create, modify, or delete files, run code, change the state of devices or remote systems, or incur third-party charges. Before authorizing a task, check its target, permissions, and expected effects, and back up important files. When using Floe, operate only on files, accounts, networks, devices, and systems you are authorized to use. Respect the rights of others and comply with applicable law. Do not use Floe for fraud, infringement, unauthorized access, or other unlawful conduct. Rights to content you create or import remain with you or the respective rights holders. When importing, modifying, or sharing others’ content, follow the applicable license terms. Open-source components are used under their respective licenses. Software updates, system upgrades, or changes to third-party services may affect the compatibility and availability of some features. You may stop using Floe at any time and keep the files you need using the software’s export features.
    """
}

struct FloeUserAgreementGate<Content: View>: View {
    @AppStorage(FloeUserAgreement.storageKey) private var acceptedAgreement = ""
    @State private var pendingEntryURL: URL?
    @ViewBuilder let content: (Binding<URL?>) -> Content

    var body: some View {
        if FloeUserAgreement.bypassForTesting || FloeUserAgreement.hasAccepted(
            acceptedAgreement) {
            content($pendingEntryURL)
        } else {
            FirstLaunchAgreementView(acceptedReceipt: $acceptedAgreement)
                .onOpenURL { pendingEntryURL = $0 }
        }
    }
}

struct FirstLaunchAgreementView: View {
    @Binding var acceptedReceipt: String
    @State private var showingAgreement = true
    @State private var acceptedInSheet = false

    var body: some View {
        ContentUnavailableView {
            Label(FloeUserAgreement.title, systemImage: "doc.text")
        } description: {
            Text(FloeL10n.isChinese ? "同意用户协议后即可使用 Floe。" : "Accept the user agreement to use Floe.")
        } actions: {
            Button(FloeL10n.isChinese ? "查看协议" : "View Agreement") { showingAgreement = true }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("agreement.reopen")
        }
        .sheet(isPresented: $showingAgreement, onDismiss: finishAcceptance) {
            NavigationStack {
                FloeUserAgreementDocument()
                    .safeAreaInset(edge: .bottom) {
                        VStack(spacing: 8) {
                            Button {
                                acceptedInSheet = true
                                showingAgreement = false
                            } label: {
                                Text(FloeL10n.isChinese ? "同意并继续" : "Agree and Continue")
                                    .frame(maxWidth: .infinity, minHeight: 44)
                            }
                            .buttonStyle(.borderedProminent)
                            .accessibilityIdentifier("agreement.accept")
                            Button {
                                showingAgreement = false
                            } label: {
                                Text(FloeL10n.isChinese ? "不同意" : "Decline")
                                    .frame(maxWidth: .infinity, minHeight: 44)
                            }
                            .accessibilityIdentifier("agreement.decline")
                        }
                        .frame(maxWidth: 560)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity)
                        .background(.regularMaterial)
                    }
            }
            .interactiveDismissDisabled()
            .presentationDetents([.large])
        }
    }

    private func finishAcceptance() {
        guard acceptedInSheet else { return }
        acceptedReceipt = FloeUserAgreement.currentReceipt
    }
}

struct FloeUserAgreementDocument: View {
    var body: some View {
        ScrollView {
            Text((try? AttributedString(markdown: FloeUserAgreement.document,
                options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
                ?? AttributedString(FloeUserAgreement.document))
                .frame(maxWidth: 640, alignment: .leading)
                .padding(20)
                .frame(maxWidth: .infinity)
                .textSelection(.enabled)
        }
        .navigationTitle(FloeUserAgreement.title)
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("agreement.document")
    }
}
#endif
