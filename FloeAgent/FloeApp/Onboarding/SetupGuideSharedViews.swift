// FloeApp — Setup guide shared views.
//
// SPDX-License-Identifier: MPL-2.0
//
// The pieces every section reuses: the honest resource row, the preset
// picker and the small form helpers. They live here once, so one resource can
// never read differently in two sections.

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import FloeCore
import FloeLocalModels

// MARK: - Shared pieces

/// The honest resource row: real bytes, real percentage, real speed, and the
/// stage the owning service actually reported. An unknown total renders an
/// indeterminate bar instead of a fake percentage.
struct SetupResourceRowView: View {
    let row: SetupResourceRow
    var prepare: (() -> Void)? = nil
    var retry: (() -> Void)? = nil
    var cancel: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .foregroundStyle(color)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(LocalizedStringKey(row.titleKey))
                    statusLine
                        .font(FloeTheme.Typography.metadata)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                actions
            }
            if row.stage.isPreparing {
                bar
            }
        }
        .padding(.vertical, 4)
        .accessibilityIdentifier(row.id)
    }

    @ViewBuilder private var actions: some View {
        switch row.stage {
        case .notRequested:
            if let prepare {
                Button("setup.resource.prepare", action: prepare)
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("\(row.id).prepare")
            }
        case .failed, .cancelled, .paused:
            if let retry {
                Button("setup.resource.retry", action: retry)
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("\(row.id).retry")
            }
        default:
            if row.canCancel, let cancel {
                Button(role: .cancel) {
                    cancel()
                } label: {
                    Image(systemName: "xmark.circle")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("setup.resource.cancel")
                .accessibilityIdentifier("\(row.id).cancel")
            } else if row.isReady {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(FloeTheme.success)
            }
        }
    }

    /// A determinate bar is drawn ONLY for the phase whose bytes the owner
    /// really counts. Verification, extraction, unpacking and committing have
    /// their own scales, so they show an indeterminate bar with the stage name
    /// instead of a frozen "100%".
    @ViewBuilder private var bar: some View {
        if row.stage == .downloading, let fraction = row.fraction {
            ProgressView(value: fraction)
                .tint(FloeTheme.primary)
        } else if row.stage.isPreparing {
            ProgressView()
                .progressViewStyle(.linear)
                .tint(FloeTheme.primary)
        }
    }

    /// Product line under the title. Every number here is one the owner
    /// reported for the phase it is in: downloaded bytes even when the total is
    /// unknown, a percentage only when a real total exists, a speed only for a
    /// live transfer, and a failure message verbatim.
    private var statusLine: Text {
        var parts: [Text] = [Text(LocalizedStringKey(row.stage.summaryTitleKey))]
        switch row.stage {
        case .ready:
            return parts.reduce(Text(verbatim: ""), +)
        case .downloading:
            if let total = row.totalBytes, let done = row.transferredBytes {
                parts.append(Text(verbatim: " · "))
                parts.append(Text(Self.bytes(done, of: total)))
            } else if let done = row.transferredBytes, done > 0 {
                // Unknown total: still say how much really arrived.
                parts.append(Text(verbatim: " · "))
                parts.append(Text("setup.resource.downloaded \(Self.size(done))"))
            } else if row.totalBytes == nil {
                parts.append(Text(verbatim: " · "))
                parts.append(Text("setup.resource.size.unknown"))
            }
            if let speed = row.bytesPerSecond, speed > 0 {
                parts.append(Text(verbatim: " · "))
                parts.append(Text(Self.speed(speed)))
            }
            if let percent = row.percentText {
                parts.append(Text(verbatim: " · "))
                parts.append(Text(percent))
            }
        case .failed(let message):
            if !message.isEmpty {
                parts.append(Text(verbatim: " · "))
                parts.append(Text(LocalizedStringKey(message)))
            }
        case .queued, .verifying, .installing, .awaitingConfirmation, .paused,
             .cancelled, .notRequested:
            // No byte scale belongs to these phases; the stage name is the
            // whole truth, plus the declared size when the owner knows it.
            if let total = row.totalBytes, row.stage != .ready {
                parts.append(Text(verbatim: " · "))
                parts.append(Text(Self.size(total)))
            }
        }
        return parts.reduce(Text(verbatim: ""), +)
    }

    static func bytes(_ done: Int64, of total: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .binary
        return "\(formatter.string(fromByteCount: done)) / \(formatter.string(fromByteCount: total))"
    }

    static func size(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .binary
        return formatter.string(fromByteCount: bytes)
    }

    static func speed(_ bytesPerSecond: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .binary
        return "\(formatter.string(fromByteCount: bytesPerSecond))/s"
    }

    private var icon: String {
        switch row.kind {
        case .speechRecognition: "mic"
        case .voicePack: "person.wave.2"
        case .onDeviceModel: "cpu"
        case .localRuntime: "cube.box"
        case .contentUpdate: "arrow.triangle.2.circlepath"
        case .skillHub: "puzzlepiece.extension"
        }
    }

    private var color: Color {
        switch row.stage {
        case .ready: FloeTheme.success
        case .failed: FloeTheme.destructive
        case .queued, .downloading, .verifying, .installing, .awaitingConfirmation: FloeTheme.pending
        case .notRequested, .paused, .cancelled: Color.secondary
        }
    }
}

struct SetupPickingRow: View {
    let titleKey: LocalizedStringKey
    let valueKey: LocalizedStringKey
    var body: some View {
        HStack {
            Text(titleKey)
            Spacer()
            Text(valueKey)
                .font(FloeTheme.Typography.metadata)
                .foregroundStyle(.secondary)
        }
    }
}

#endif
