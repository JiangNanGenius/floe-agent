// FloeApp — Bounded continuous tool history shared by chat surfaces.
// SPDX-License-Identifier: MPL-2.0

#if canImport(SwiftUI) && (canImport(UIKit) || os(macOS))
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
///
/// The row is platform-neutral: every input arrives as a plain value or a
/// closure. The iPad thread passes its view model through the UIKit
/// convenience init (which stays the exact historical call signature); the
/// native Mac host passes workspace-derived values directly. Both surfaces
/// keep the identical paging behavior.
struct ThreadEarlierActivityRow: View {
    let runID: UUID
    /// The thread scroll viewport in global coordinates. Zero (unmeasured)
    /// counts as not visible so a row can never page off-screen.
    var viewportFrame: CGRect
    var scrollDemand: UInt64 = 0

    // MARK: - Platform-neutral state source

    /// True while the owning store still has earlier coverage to page in.
    var hasMore: Bool
    /// True while a bounded earlier page is genuinely in flight.
    var loading: Bool
    /// True when the last fetch failed for this run.
    var failed: Bool
    /// Demand-edge entry point: loads one bounded earlier page.
    var loadEarlier: (@MainActor (UUID) async -> Void)?

    #if canImport(UIKit)
    /// The iPad thread's concrete view model. When present it is the
    /// authoritative source for the state above, read live on every poll so
    /// the row never spins against a captured value. The hosting
    /// `ThreadDetailView` already observes this model and rebuilds its rows
    /// on every published change, so a plain reference (not
    /// `@ObservedObject`, which cannot wrap an Optional) re-renders exactly
    /// as before the platform-neutral refactor.
    var viewModel: ThreadDetailViewModel?
    #endif

    /// Cross-platform convenience: one bounded page per demand edge, with
    /// the state supplied directly by the hosting surface. This is the
    /// native Mac host call shape.
    init(
        runID: UUID,
        viewportFrame: CGRect,
        scrollDemand: UInt64 = 0,
        hasMore: Bool,
        loading: Bool,
        failed: Bool,
        loadEarlier: @escaping @MainActor (UUID) async -> Void
    ) {
        self.runID = runID
        self.viewportFrame = viewportFrame
        self.scrollDemand = scrollDemand
        self.hasMore = hasMore
        self.loading = loading
        self.failed = failed
        self.loadEarlier = loadEarlier
        #if canImport(UIKit)
        self.viewModel = nil
        #endif
    }

    #if canImport(UIKit)
    /// The historical iPad call signature, unchanged: the row observes the
    /// concrete thread view model and derives every platform-neutral input
    /// from it, preserving the original paging behavior byte for byte.
    init(
        viewModel: ThreadDetailViewModel,
        runID: UUID,
        viewportFrame: CGRect,
        scrollDemand: UInt64 = 0
    ) {
        self.runID = runID
        self.viewportFrame = viewportFrame
        self.scrollDemand = scrollDemand
        self.hasMore = viewModel.earlierEventRunIDs.contains(runID)
        self.loading = viewModel.loadingEventRunIDs.contains(runID)
        self.failed = viewModel.failedEarlierEventRunIDs.contains(runID)
        self.loadEarlier = nil
        self.viewModel = viewModel
    }
    #endif

    /// One polling identity per demand edge — strictly (run, scroll
    /// demand). It must NEVER include the loading/hasMore/failed flags:
    /// taking this edge's page flips those flags, and a changed identity
    /// would cancel the read while it is in flight so the host's load fence
    /// drops the page. State is consulted live instead (the observed model
    /// on iPad; the freshly supplied host values on the Mac).
    private struct Demand: Hashable {
        var runID: UUID
        var gesture: UInt64
    }

    @State private var rowFrame: CGRect = .zero
    @State private var isVisible = false

    /// The authoritative state triple. The observed view model is read live
    /// on iPad (published changes re-render through the hosting
    /// ThreadDetailView, and the polling loop re-reads through this class
    /// reference — identical to the historical row). The plain values are
    /// the Mac source, refreshed by the host on every rebuild.
    private func currentState() -> (hasMore: Bool, loading: Bool, failed: Bool) {
        #if canImport(UIKit)
        if let viewModel {
            return (
                viewModel.earlierEventRunIDs.contains(runID),
                viewModel.loadingEventRunIDs.contains(runID),
                viewModel.failedEarlierEventRunIDs.contains(runID))
        }
        #endif
        return (hasMore, loading, failed)
    }

    private var mode: ThreadEarlierActivityMode {
        let state = currentState()
        return ThreadEarlierActivityPolicy.mode(loading: state.loading, failed: state.failed)
    }

    /// Demand-edge entry point: prefers the observed iPad model (the
    /// historical call path) and otherwise invokes the host-supplied
    /// platform-neutral loader.
    private func load(_ runID: UUID) async {
        #if canImport(UIKit)
        if let viewModel {
            await viewModel.loadEarlierEvents(runID: runID)
            return
        }
        #endif
        await loadEarlier?(runID)
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
                let state = currentState()
                switch ThreadEarlierActivityPolicy.nextAutoLoadStep(
                    visible: isVisible,
                    hasMore: state.hasMore,
                    loading: state.loading,
                    failed: state.failed
                ) {
                case .stop:
                    return
                case .wait:
                    #if canImport(UIKit)
                    // iPad (historical behavior): the edge is real but another
                    // page is still in flight; wait it out, then take this
                    // edge's one bounded page. Live model state is re-read on
                    // every poll through the class reference.
                    while !Task.isCancelled {
                        do { try await Task.sleep(for: .milliseconds(50)) }
                        catch { return }
                        let live = currentState()
                        switch ThreadEarlierActivityPolicy.nextAutoLoadStep(
                            visible: isVisible,
                            hasMore: live.hasMore,
                            loading: live.loading,
                            failed: live.failed
                        ) {
                        case .stop:
                            return
                        case .wait:
                            continue
                        case .load:
                            await load(runID)
                            return
                        }
                    }
                    #else
                    // Mac: on-demand one page per edge. A concurrent load owns
                    // the store; the next visibility or scroll demand takes
                    // the page. Never spin against captured values.
                    return
                    #endif
                case .load:
                    await load(runID)
                    return
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
                    Task { await load(runID) }
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
