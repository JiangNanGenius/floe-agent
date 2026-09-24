// FloeApp — Compact IDE status bar.
//
// SPDX-License-Identifier: MPL-2.0
//
// One small bottom row with the real pinned-workspace state: Git branch and
// change counts from the source-control snapshot (hidden entirely when the
// workspace is not a repository), the active editor kernel, and unsaved
// buffer count. Badges reflect the pinned workspace snapshot only.

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import FloeGit
import FloeWorkspace

struct IDEStatusBar: View {
    @ObservedObject var sourceControl: SourceControlCenter
    var identityMatches: Bool
    var dirtyBuffers: Int
    @Environment(\.horizontalSizeClass) private var sizeClass

    private var compact: Bool { sizeClass == .compact }

    private var changeCount: Int {
        sourceControl.snapshot.changes.filter { $0.kind != .conflicted }.count
    }

    var body: some View {
        HStack(spacing: compact ? 8 : 12) {
            if identityMatches, sourceControl.snapshot.isRepository {
                Label(sourceControl.snapshot.branch ?? IDELanguageRunText.t("游离 HEAD", "detached"),
                      systemImage: "arrow.triangle.branch")
                if changeCount > 0 {
                    Label("\(changeCount)", systemImage: "circle.dashed")
                }
                if sourceControl.isBusy {
                    ProgressView().controlSize(.mini)
                }
            } else if !identityMatches {
                Label(IDELanguageRunText.t("工作区已切换", "Workspace switched"), systemImage: "exclamationmark.lock")
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if dirtyBuffers > 0 {
                Label(
                    String(format: IDELanguageRunText.t("%d 个未保存", "%d unsaved"), dirtyBuffers),
                    systemImage: "circle.dashed.inset.filled"
                )
                .foregroundStyle(FloeTheme.primary)
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .minimumScaleFactor(compact ? 0.7 : 1)
        .padding(.horizontal, compact ? 8 : 10)
        .frame(height: 24)
        .background(FloeTheme.sidebarSurface)
        .overlay(alignment: .top) {
            Rectangle().fill(Color.primary.opacity(0.12)).frame(height: 1)
        }
        .accessibilityIdentifier("workspace.ide.statusBar")
    }
}
#endif
