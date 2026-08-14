// FloeApp — Home tab shell (thin).
//
// SPDX-License-Identifier: MPL-2.0
//
// T03 made Home Chat-first: the tab root is ChatHomeView on every
// idiom. This file remains only as the iPad overview detail column
// (HomeOverviewDetailView) that explains the work surface while no
// thread is selected. The old card-stack workbench was removed; Active
// Tasks live in the recent-thread list and Pending Approvals surface as
// a badge strip above the composer.

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI

/// A deliberate iPad detail surface for Home. The middle column is the
/// Chat-first home; this column explains what can be opened there while
/// no thread is selected.
struct HomeOverviewDetailView: View {
    var body: some View {
        VStack(spacing: 28) {
            Spacer()
            ZStack {
                RoundedRectangle(cornerRadius: 28)
                    .fill(FloeTheme.brandGradient)
                    .frame(width: 108, height: 108)
                    .shadow(color: FloeTheme.primary.opacity(0.2), radius: 24, y: 10)
                Image(systemName: "bubble.left.and.text.bubble.right.fill")
                    .font(.system(size: 48, weight: .medium))
                    .foregroundStyle(.white)
            }
            .accessibilityHidden(true)

            VStack(spacing: 9) {
                Text("home.detail.title")
                    .font(.largeTitle.weight(.bold))
                Text("home.detail.subtitle")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 520)
            }

            HStack(spacing: 12) {
                HomeCapability(icon: "bubble.left.and.text.bubble.right", title: "home.capability.threads")
                HomeCapability(icon: "checkmark.shield", title: "home.capability.approvals")
                HomeCapability(icon: "folder", title: "home.capability.workspace")
            }
            Spacer()
        }
        .padding(36)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(FloeTheme.readingSurface)
        .navigationTitle("app.name")
    }
}

private struct HomeCapability: View {
    let icon: String
    let title: LocalizedStringKey

    var body: some View {
        VStack(spacing: 9) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(FloeTheme.primary)
            Text(title)
                .font(FloeTheme.Typography.metadata.weight(.medium))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: 132, minHeight: 90)
        .padding(10)
        .background(FloeTheme.groupedSurface, in: RoundedRectangle(cornerRadius: 18))
    }
}
#endif
