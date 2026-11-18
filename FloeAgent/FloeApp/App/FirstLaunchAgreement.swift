// SPDX-License-Identifier: MPL-2.0
#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import FloeCore

// The receipt is a local preference for this release and agreement revision.
// It carries no identity, timestamp, or event history.
enum FloeUserAgreement {
    static let storageKey = "floe.userAgreement.acceptedRelease"
    static let revision = "1"

    static func receipt(for version: String) -> String { "\(version)/\(revision)" }

    static let currentVersion = Bundle.main.object(
        forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    static let currentReceipt = receipt(for: currentVersion)

    static func hasAccepted(_ saved: String, version: String) -> Bool {
        saved == receipt(for: version)
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
    **适用范围**

    本协议适用于 Floe 应用、桌面客户端、Bridge 及其他配套软件。请阅读后选择是否同意。选择「同意并继续」即表示你接受本协议。

    **软件与第三方服务**

    Floe 提供 AI 对话、文件和创作工具，也可以连接你选择的服务和设备。功能因版本、平台和配置而异。你自行选择和配置的 AI、云端或其他第三方服务适用各自的条款和费用。Floe 中列出的服务预设不代表合作或背书。

    **AI 输出与任务执行**

    AI 输出可能出错、遗漏或不适合你的用途。请在使用、执行、发布或商用前核验结果和相关权利。医疗、法律、财务和工程安全等重要事项不应仅依赖 AI 输出。

    你授权的任务可能修改文件、运行代码、改变设备或远程系统的状态，或产生第三方费用。请核对操作范围及目标，并为重要资料保留备份。

    **合理使用与内容权利**

    请在你有权使用的文件、设备、网络和账户范围内操作，不得利用 Floe 诈骗、侵权、违法或绕过他人的授权与安全措施。你创建或导入的内容，其权利由你或相应权利人享有。软件、第三方组件和模型中的开源部分仍按各自许可证使用。

    **更新、停止使用与责任**

    软件更新、系统兼容性和第三方服务变化可能影响功能。你可以随时停止使用，并在适用功能中导出需要保留的文件。你与 Floe 各自依法承担应负的责任。本协议不限制你依法享有的消费者权利，也不排除法律规定不得排除的责任。

    **协议变更与联系**

    后续版本会在应用内展示适用的协议。有关协议或软件的问题，可通过 Floe 的支持入口联系维护者。
    """

    private static let english = """
    **Scope**

    This agreement covers the Floe apps, desktop client, Bridge, and related software. Read it before choosing whether to accept. By selecting Agree and Continue, you accept this agreement.

    **Software and third-party services**

    Floe provides AI chat, file and creative tools, and connections to services and devices you choose. Features vary by release, platform, and configuration. AI, cloud, and other third-party services you configure have their own terms and charges. A provider preset in Floe does not imply a partnership or endorsement.

    **AI output and task execution**

    AI output can be wrong, incomplete, or unsuitable for your purpose. Before using, running, publishing, or commercially distributing it, check the result and the relevant rights. Do not rely solely on AI output for important medical, legal, financial, or engineering safety decisions.

    Tasks you authorize may change files, run code, affect devices or remote systems, or incur third-party charges. Check the target and scope of an operation and back up important work.

    **Acceptable use and content rights**

    Use Floe only with files, devices, networks, and accounts you are authorized to use. Do not use it for fraud, infringement, unlawful activity, or to bypass someone else's permissions or safeguards. Rights in content you create or import remain with you or the relevant rights holder. Open-source software, components, and models remain subject to their own licenses.

    **Updates, stopping use, and responsibility**

    App updates, system compatibility, and changes to third-party services may affect features. You can stop using Floe at any time and export files you want to keep where the app supports export. You and Floe each remain responsible as provided by applicable law. This agreement does not limit your statutory consumer rights or exclude liability that cannot lawfully be excluded.

    **Changes and contact**

    Future releases show the applicable agreement in the app. For questions about the agreement or the software, contact the maintainer through Floe support.
    """
}

struct FirstLaunchAgreementView: View {
    @Binding var acceptedReceipt: String
    @State private var showingAgreement = true

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
        .sheet(isPresented: $showingAgreement) {
            NavigationStack {
                FloeUserAgreementDocument()
                    .safeAreaInset(edge: .bottom) {
                        VStack(spacing: 8) {
                            Button {
                                acceptedReceipt = FloeUserAgreement.currentReceipt
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
