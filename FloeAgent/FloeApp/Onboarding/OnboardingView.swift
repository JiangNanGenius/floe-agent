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
            ScrollView {
                VStack(spacing: 28) {
                    onboardingHeader
                    privacyPromise
                    actions
                }
                .frame(maxWidth: 560)
                .padding(.horizontal, 28)
                .padding(.vertical, 36)
                .frame(maxWidth: .infinity)
            }
            .background(FloeTheme.groupedSurface)
            .navigationBarTitleDisplayMode(.inline)
            .task {
                await viewModel.load()
                if viewModel.isConfigured { dismiss() }
            }
            .onChange(of: viewModel.isConfigured) { _, configured in
                if configured { dismiss() }
            }
        }
    }

    private var onboardingHeader: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle()
                    .fill(FloeTheme.brandGradient)
                    .frame(width: 82, height: 82)
                Image(systemName: "wave.3.right.circle.fill")
                    .font(.system(size: 42, weight: .medium))
                    .foregroundStyle(.white)
            }
            .shadow(color: FloeTheme.primary.opacity(0.22), radius: 18, y: 8)
            .accessibilityHidden(true)

            VStack(spacing: 8) {
                Text("onboarding.title")
                    .font(.largeTitle.weight(.bold))
                    .multilineTextAlignment(.center)
                Text("onboarding.subtitle")
                    .font(FloeTheme.Typography.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var privacyPromise: some View {
        VStack(alignment: .leading, spacing: 16) {
            OnboardingPoint(
                icon: "person.crop.circle.badge.checkmark",
                title: "onboarding.point.no_account.title",
                detail: "onboarding.point.no_account.detail"
            )
            Divider()
            OnboardingPoint(
                icon: "key.horizontal",
                title: "onboarding.point.your_keys.title",
                detail: "onboarding.point.your_keys.detail"
            )
            Divider()
            OnboardingPoint(
                icon: "checkmark.shield",
                title: "onboarding.point.approvals.title",
                detail: "onboarding.point.approvals.detail"
            )
        }
        .padding(20)
        .background(FloeTheme.readingSurface, in: RoundedRectangle(cornerRadius: 22))
        .overlay {
            RoundedRectangle(cornerRadius: 22)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        }
    }

    private var actions: some View {
        VStack(spacing: 10) {
            NavigationLink {
                ProviderEditorView(center: viewModel.center, existing: nil)
            } label: {
                HStack {
                    Text("onboarding.add_provider")
                        .font(.headline)
                    Spacer()
                    Image(systemName: "arrow.right")
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 18)
                .frame(maxWidth: .infinity, minHeight: 52)
                .background(FloeTheme.brandGradient, in: RoundedRectangle(cornerRadius: 16))
            }
            .buttonStyle(.plain)

            NavigationLink {
                ProviderListView(center: viewModel.center)
            } label: {
                Text("onboarding.view_providers")
                    .frame(maxWidth: .infinity, minHeight: FloeTheme.minimumTarget)
            }
            .buttonStyle(.plain)
            .foregroundStyle(FloeTheme.primary)
        }
    }
}

private struct OnboardingPoint: View {
    let icon: String
    let title: LocalizedStringKey
    let detail: LocalizedStringKey

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(FloeTheme.primary)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(FloeTheme.Typography.metadata)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }
}
#endif
