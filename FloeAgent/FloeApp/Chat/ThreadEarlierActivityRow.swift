// FloeApp — Bounded continuous tool history shared by chat surfaces.
// SPDX-License-Identifier: MPL-2.0

#if canImport(UIKit)
import SwiftUI

/// Display state of the continuous earlier-activity boundary row.
enum ThreadEarlierActivityMode: Equatable {
    /// Idle marker: no fetch is running and nothing failed. The row never
    /// imitates activity here, so a spinner can never stick after the
    /// episode ended — the next bounded page arrives on a real demand edge.
    case quiet
    /// A bounded earlier page is genuinely in flight.
    case loading
    /// The last fetch failed for this run: one compact, real retry keeps
    /// the boundary actionable instead of hiding history behind a dead
    /// fake button. Cleared by the next success or a conversation reload.
    case failed
}

/// One bounded page per visible edge or user scroll gesture. Keeping a
/// short thread visible never drains the store; another gesture can demand
/// more even when the content is too short to move off screen.
enum ThreadEarlierActivityPolicy {
    static func mode(loading: Bool, failed: Bool) -> ThreadEarlierActivityMode {
        if loading { return .loading }
        if failed { return .failed }
        return .quiet
    }

    static func nextAutoLoadStep(visible: Bool, hasMore: Bool, loading: Bool, failed: Bool)
        -> ThreadEarlierActivityStep {
        guard visible, !failed, hasMore else { return .stop }
        return loading ? .wait : .load
    }
}

enum ThreadEarlierActivityStep: Equatable {
    case load
    case wait
    case stop
}

/// The auto-paging boundary for one run's not-yet-loaded earlier tool
/// history. It renders nothing actionable in normal states: older records
/// simply become available as the row enters the thread viewport.
struct ThreadEarlierActivityRow: View {
    @ObservedObject var viewModel: ThreadDetailViewModel
    let runID: UUID
    /// The thread scroll viewport in global coordinates. Zero (unmeasured)
    /// counts as not visible so a row can never page off-screen.
    var viewportFrame: CGRect
    var scrollDemand: UInt64 = 0

    private struct Demand: Hashable {
        var runID: UUID
        var gesture: UInt64
    }

    @State private var rowFrame: CGRect = .zero
    @State private var isVisible = false

    private var mode: ThreadEarlierActivityMode {
        ThreadEarlierActivityPolicy.mode(
            loading: viewModel.loadingEventRunIDs.contains(runID),
            failed: viewModel.failedEarlierEventRunIDs.contains(runID))
    }

    var body: some View {
        content
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity)
            .accessibilityIdentifier("thread.events.earlier.\(runID.uuidString)")
            .background(GeometryReader { geometry in
                Color.clear
                    .onAppear { rowFrame = geometry.frame(in: .global) }
                    .onChange(of: geometry.frame(in: .global)) { _, new in
                        rowFrame = new
                    }
            })
            .onChange(of: rowFrame) { _, _ in refreshVisibility() }
            .onChange(of: viewportFrame) { _, _ in refreshVisibility() }
            .task(id: isVisible ? Demand(runID: runID, gesture: scrollDemand) : nil) {
                guard isVisible else { return }
                while !Task.isCancelled {
                    switch ThreadEarlierActivityPolicy.nextAutoLoadStep(
                        visible: isVisible,
                        hasMore: viewModel.earlierEventRunIDs.contains(runID),
                        loading: viewModel.loadingEventRunIDs.contains(runID),
                        failed: viewModel.failedEarlierEventRunIDs.contains(runID)
                    ) {
                    case .stop:
                        return
                    case .wait:
                        do { try await Task.sleep(for: .milliseconds(50)) }
                        catch { return }
                    case .load:
                        await viewModel.loadEarlierEvents(runID: runID)
                        return
                    }
                }
            }
    }

    private func refreshVisibility() {
        isVisible = viewportFrame.width > 0
            && viewportFrame.height > 0
            && rowFrame.intersects(viewportFrame)
    }

    @ViewBuilder private var content: some View {
        switch mode {
        case .quiet:
            // A 1pt quiet marker: nothing to tap, nothing folded away — the
            // next bounded page arrives on the next visibility demand edge.
            Color.clear
                .frame(height: 1)
        case .loading:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text(ChatBilingualCatalog.localized(
                    key: "chat.thread_detail_view.loading_earlier_tool_activity",
                    en: "Loading earlier tool activity",
                    zh: "正在加载更早的工具记录"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .accessibilityLabel(Text(ChatBilingualCatalog.localized(
                key: "chat.thread_detail_view.loading_earlier_tool_activity",
                en: "Loading earlier tool activity",
                zh: "正在加载更早的工具记录")))
        case .failed:
            HStack(spacing: 8) {
                Text(ChatBilingualCatalog.localized(
                    key: "chat.thread_detail_view.earlier_tool_activity_load_failed",
                    en: "Couldn't load earlier tool activity",
                    zh: "无法加载更早的工具记录"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button {
                    Task { await viewModel.loadEarlierEvents(runID: runID) }
                } label: {
                    Text("action.retry")
                }
                .font(.footnote)
                .accessibilityIdentifier("thread.events.earlier-retry.\(runID.uuidString)")
            }
        }
    }
}

#endif
