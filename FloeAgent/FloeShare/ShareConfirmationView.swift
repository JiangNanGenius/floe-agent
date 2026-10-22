// SPDX-License-Identifier: MPL-2.0
//
// FloeShare — compact confirmation surface.
//
// The extension cannot activate Floe (`NSExtensionContext.open` is unsupported
// for share extensions), so success is honest: the bytes are staged in the
// App Group and the user is told to open Floe. Nothing is sent, run or
// launched from here.

import SwiftUI
import UIKit
import FloeCore

struct ShareConfirmationState: Equatable {
    enum Phase: Equatable {
        case saving
        case saved(itemCount: Int)
        case failed(message: String)
    }

    var phase: Phase
}

struct ShareConfirmationView: View {
    let state: ShareConfirmationState
    let onDone: () -> Void
    let onClose: () -> Void
    let onRetry: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            icon
            title
            detail
            Spacer(minLength: 0)
            actions
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemBackground))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("share.extension.confirmation")
    }

    @ViewBuilder
    private var icon: some View {
        switch state.phase {
        case .saving:
            ProgressView()
                .controlSize(.large)
                .accessibilityHidden(true)
        case .saved:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 40, weight: .semibold))
                .foregroundStyle(.green)
                .accessibilityHidden(true)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 40, weight: .semibold))
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private var title: some View {
        switch state.phase {
        case .saving:
            Text(FloeL10n.l("share.extension.saving"))
                .font(.headline)
                .multilineTextAlignment(.center)
        case .saved:
            Text(FloeL10n.l("share.extension.saved_title"))
                .font(.headline)
                .multilineTextAlignment(.center)
                .accessibilityIdentifier("share.extension.saved")
        case .failed:
            Text(FloeL10n.l("share.extension.failed_title"))
                .font(.headline)
                .multilineTextAlignment(.center)
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch state.phase {
        case .saving:
            Text(FloeL10n.l("share.extension.saving_detail"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        case .saved(let itemCount):
            VStack(spacing: 6) {
                Text(FloeL10n.plural(
                    "share.extension.saved_count",
                    count: itemCount
                ))
                .font(.subheadline)
                .multilineTextAlignment(.center)
                Text(FloeL10n.l("share.extension.saved_hint"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        case .failed(let message):
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var actions: some View {
        switch state.phase {
        case .saving:
            EmptyView()
        case .saved:
            Button(action: onDone) {
                Text(FloeL10n.l("share.extension.done"))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .accessibilityIdentifier("share.extension.done")
        case .failed:
            VStack(spacing: 10) {
                Button(action: onRetry) {
                    Text(FloeL10n.l("share.extension.retry"))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                Button(action: onClose) {
                    Text(FloeL10n.l("share.extension.close"))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
        }
    }
}
