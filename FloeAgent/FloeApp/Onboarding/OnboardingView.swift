// FloeApp — First-run onboarding.
//
// SPDX-License-Identifier: MPL-2.0
//
// No Floe account, no sign-in. The single first-run task is adding one
// provider and model; afterwards the app shows an honest empty state.
// Presented as a sheet until a provider+model is configured.

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI

/// First-run onboarding sheet: add a provider to begin.
struct OnboardingView: View {
    @StateObject private var viewModel: OnboardingViewModel
    @Environment(\.dismiss) private var dismiss

    init(center: ConversationCenter) {
        _viewModel = StateObject(wrappedValue: OnboardingViewModel(center: center))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 56))
                    .foregroundStyle(FloeTheme.brandGradient)
                    .accessibilityHidden(true)
                Text("onboarding.title")
                    .font(FloeTheme.Typography.title)
                    .multilineTextAlignment(.center)
                Text("onboarding.subtitle")
                    .font(FloeTheme.Typography.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                Spacer()
                NavigationLink {
                    ProviderEditorView(center: viewModel.center, existing: nil)
                } label: {
                    Text("onboarding.add_provider")
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: FloeTheme.minimumTarget)
                }
                .buttonStyle(.borderedProminent)
                .padding(.horizontal)
                NavigationLink {
                    ProviderListView(center: viewModel.center)
                } label: {
                    Text("onboarding.view_providers")
                        .frame(minHeight: FloeTheme.minimumTarget)
                }
                .padding(.bottom)
            }
            .navigationTitle("onboarding.title")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if viewModel.isConfigured {
                        Button("action.done") { dismiss() }
                    }
                }
            }
            .task { await viewModel.load() }
            .onChange(of: viewModel.isConfigured) { _, configured in
                if configured { dismiss() }
            }
        }
    }
}
#endif
