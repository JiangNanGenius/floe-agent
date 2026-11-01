import SwiftUI
import UIKit

/// Restrained Floe accent used for selection and primary actions. The light
/// variant is darker so text and controls keep contrast on white.
enum BridgeProductTheme {
    static let accent = Color(uiColor: UIColor { traits in
        if traits.userInterfaceStyle == .dark {
            return UIColor(red: 0.35, green: 0.84, blue: 1.0, alpha: 1)
        }
        return UIColor(red: 0.0, green: 0.47, blue: 0.63, alpha: 1)
    })

    static let stop = Color(uiColor: .systemRed)
    static let success = Color(uiColor: .systemGreen)
    static let warning = Color(uiColor: .systemOrange)
    static let danger = Color(uiColor: .systemRed)
    static let contentMaxWidth: CGFloat = 760
}

extension BridgeProductRunState {
    var title: String {
        switch self {
        case .needsSetup: return BridgeProductCopy.needsSetup
        case .idle: return BridgeProductCopy.readyToStart
        case .preparing: return BridgeProductCopy.preparing
        case .running: return BridgeProductCopy.running
        case .stopped: return BridgeProductCopy.stopped
        case .needsAttention: return BridgeProductCopy.needsAttention
        case .reopenRequired: return BridgeProductCopy.reopenRequired
        }
    }

    var detail: String {
        switch self {
        case .needsSetup: return BridgeProductCopy.statusNeedsSetupDetail
        case .idle: return BridgeProductCopy.statusReadyDetail
        case .preparing: return BridgeProductCopy.statusPreparingDetail
        case .running: return BridgeProductCopy.statusRunningDetail
        case .stopped: return BridgeProductCopy.statusStoppedDetail
        case .needsAttention: return BridgeProductCopy.statusAttentionDetail
        case .reopenRequired: return BridgeProductCopy.statusReopenDetail
        }
    }

    var symbol: String {
        switch self {
        case .needsSetup: return "wrench.and.screwdriver"
        case .idle: return "play.circle"
        case .preparing: return "hourglass"
        case .running: return "checkmark.circle.fill"
        case .stopped: return "stop.circle"
        case .needsAttention: return "exclamationmark.triangle.fill"
        case .reopenRequired: return "arrow.counterclockwise.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .running: return BridgeProductTheme.success
        case .preparing: return BridgeProductTheme.warning
        case .needsAttention, .reopenRequired: return BridgeProductTheme.danger
        case .needsSetup: return BridgeProductTheme.warning
        case .idle, .stopped: return .secondary
        }
    }
}

enum BridgeProductFormat {
    static func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        let value = formatter.localizedString(for: date, relativeTo: Date())
        return value.isEmpty ? BridgeProductCopy.justNow : value
    }

    static func timestamp(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return "—" }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fallback = ISO8601DateFormatter()
        fallback.formatOptions = [.withInternetDateTime]
        guard let date = formatter.date(from: raw) ?? fallback.date(from: raw) else {
            return raw
        }
        return date.formatted(date: .abbreviated, time: .standard)
    }

    static func address(_ url: URL?) -> String {
        url?.absoluteString ?? "—"
    }
}

/// Native status line. Words always carry the state; color is secondary.
struct BridgeProductStatusLine: View {
    let state: BridgeProductRunState

    var body: some View {
        Label {
            Text(state.title)
                .font(.title3.weight(.semibold))
        } icon: {
            Image(systemName: state.symbol)
                .font(.title3)
        }
        .foregroundStyle(state.tint)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(state.title))
    }
}

/// One owner action, pinned to the bottom so Start/Stop remains reachable
/// during preparation and while the service runs.
struct BridgeProductPrimaryBar: View {
    let action: BridgeProductPrimaryAction
    let canStart: Bool
    let canStop: Bool
    let onStart: () -> Void
    let onStop: () -> Void
    let onSetup: () -> Void

    var body: some View {
        Group {
            switch action {
            case .start:
                Button(action: onStart) {
                    Label(BridgeProductCopy.startBridge, systemImage: "play.fill")
                        .frame(maxWidth: .infinity, minHeight: 46)
                }
                .buttonStyle(.borderedProminent)
                .tint(BridgeProductTheme.accent)
                .disabled(!canStart)
                .accessibilityIdentifier("bridge.primary.start")
            case .stop:
                Button(action: onStop) {
                    Label(BridgeProductCopy.stopBridge, systemImage: "stop.fill")
                        .frame(maxWidth: .infinity, minHeight: 46)
                }
                .buttonStyle(.borderedProminent)
                .tint(BridgeProductTheme.stop)
                .disabled(!canStop)
                .accessibilityIdentifier("bridge.primary.stop")
            case .setup:
                Button(action: onSetup) {
                    Label(BridgeProductCopy.setUpBridge, systemImage: "wrench.and.screwdriver")
                        .frame(maxWidth: .infinity, minHeight: 46)
                }
                .buttonStyle(.borderedProminent)
                .tint(BridgeProductTheme.accent)
                .accessibilityIdentifier("bridge.primary.setup")
            case .reopen:
                Label(BridgeProductCopy.reopenApp, systemImage: "arrow.counterclockwise.circle.fill")
                    .font(.headline)
                    .foregroundStyle(BridgeProductTheme.danger)
                    .frame(maxWidth: .infinity, minHeight: 46)
                    .accessibilityElement(children: .combine)
            }
        }
        .font(.body.weight(.semibold))
    }
}

/// Small copied/error feedback that belongs to the model, not to a view's
/// transient lifetime.
struct BridgeProductBanner: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "info.circle")
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .combine)
    }
}
