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

    static var title: String { FloeL10n.l("agreement.title") }
    static var paragraphs: [String] {
        let language = FloeL10n.currentLanguageCode
        guard let resources = Bundle.main.resourceURL else { return [] }
        let preferred = language == "en" ? "Base" : language
        for code in [preferred, "Base"] {
            let url = resources.appendingPathComponent("\(code).lproj/FloeUserAgreement.md")
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let paragraphs = text.components(separatedBy: "\n\n")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            if !paragraphs.isEmpty { return paragraphs }
        }
        return []
    }
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
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        ContentUnavailableView {
            Label(FloeUserAgreement.title, systemImage: "doc.text")
        } description: {
            Text(FloeL10n.l("agreement.required"))
        } actions: {
            Button(FloeL10n.l("agreement.view")) { showingAgreement = true }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("agreement.reopen")
        }
        .sheet(isPresented: $showingAgreement, onDismiss: finishAcceptance) {
            NavigationStack {
                FloeUserAgreementDocument()
                    .safeAreaInset(edge: .bottom) {
                        ViewThatFits(in: .horizontal) {
                            if !typeSize.isAccessibilitySize {
                                HStack(spacing: 16) {
                                    declineButton
                                    Spacer(minLength: 24)
                                    acceptButton
                                }
                            }
                            VStack(spacing: 4) {
                                acceptButton
                                declineButton
                            }
                        }
                        .frame(maxWidth: 560)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 12)
                        .frame(maxWidth: .infinity)
                        .background(.regularMaterial)
                        .overlay(alignment: .top) { Divider() }
                    }
            }
            .interactiveDismissDisabled()
            .presentationDetents([.large])
        }
    }

    private var acceptButton: some View {
        Button {
            acceptedInSheet = true
            showingAgreement = false
        } label: {
            Text(FloeL10n.l("agreement.accept"))
                .font(.headline)
                .padding(.horizontal, 16)
                .frame(minHeight: 44)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.capsule)
        .disabled(FloeUserAgreement.paragraphs.isEmpty)
        .accessibilityIdentifier("agreement.accept")
    }

    private var declineButton: some View {
        Button(FloeL10n.l("agreement.decline")) { showingAgreement = false }
            .frame(minHeight: 44)
            .accessibilityIdentifier("agreement.decline")
    }

    private func finishAcceptance() {
        guard acceptedInSheet else { return }
        acceptedReceipt = FloeUserAgreement.currentReceipt
    }
}

struct FloeUserAgreementDocument: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(FloeUserAgreement.title)
                    .font(.largeTitle.weight(.bold))
                    .accessibilityAddTraits(.isHeader)
                Divider()
                    .padding(.bottom, 4)
                ForEach(Array(FloeUserAgreement.paragraphs.enumerated()), id: \.offset) { _, paragraph in
                    Text((try? AttributedString(markdown: paragraph,
                        options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
                        ?? AttributedString(paragraph))
                        .font(.body)
                        .lineSpacing(5)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: 560, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.vertical, 28)
            .frame(maxWidth: .infinity)
            .textSelection(.enabled)
        }
        .background(Color(uiColor: .systemBackground))
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("agreement.document")
    }
}
#endif
