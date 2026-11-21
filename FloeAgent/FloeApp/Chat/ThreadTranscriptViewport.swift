// SPDX-License-Identifier: MPL-2.0

import FloeCore
import SwiftUI

struct ThreadTranscriptLayout {
    let viewportFrame: CGRect
    let earlierActivityDemand: UInt64
}

/// A new token also makes a second jump to the same row actionable.
struct ThreadTranscriptJump: Equatable {
    var id = UUID()
    let rowID: String
}

struct ThreadTranscriptUpdates: Equatable {
    let textBytes: Int
    let reasoningBytes: Int
    let eventCount: Int
    let messageCount: Int
    let isRunning: Bool
}

/// Shared iPad and Mac message viewport. The host supplies rows and their
/// durable identity while the viewport owns paging and the reader's position.
struct ThreadTranscriptViewport<Rows: View>: View {
    let ready: Bool
    let searchIsActive: Bool
    let jump: ThreadTranscriptJump?
    let updates: ThreadTranscriptUpdates
    let firstRowID: String?
    let hasEarlierMessages: Bool
    let loadingEarlierMessages: Bool
    var maximumLineWidth: CGFloat? = nil
    let loadEarlier: () async -> Bool
    @ViewBuilder let rows: (ThreadTranscriptLayout) -> Rows

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var latestFollow = LatestMessageFollowState()
    @State private var isUserScrolling = false
    @State private var viewportFrame = CGRect.zero
    @State private var activityDemand: UInt64 = 0
    @State private var earlierRequest: UUID?
    @State private var showsReturnToLatest = false

    private var latestAnchor: String { "thread-latest-anchor" }

    private struct ScrollMetrics: Equatable {
        let offset: Double
        let height: Double
        let bottomDistance: Double
    }

    var body: some View {
        ScrollViewReader { proxy in
            ZStack(alignment: .bottomTrailing) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if hasEarlierMessages { earlierButton }
                        rows(ThreadTranscriptLayout(viewportFrame: viewportFrame,
                                                    earlierActivityDemand: activityDemand))
                        Color.clear.frame(height: 1).id(latestAnchor)
                    }
                    .padding()
                    .frame(maxWidth: maximumLineWidth ?? .infinity)
                    .frame(maxWidth: .infinity)
                }
                .accessibilityIdentifier("thread.messages.viewport")
                .defaultScrollAnchor(.bottom, for: .initialOffset)
                .onScrollPhaseChange { old, phase in
                    if phase == .interacting, old != .interacting { activityDemand &+= 1 }
                    isUserScrolling = phase == .tracking || phase == .interacting || phase == .decelerating
                    if phase == .idle { followLatest(with: proxy) }
                }
                .onScrollGeometryChange(for: ScrollMetrics.self) { geometry in
                    ScrollMetrics(offset: geometry.contentOffset.y,
                                  height: geometry.contentSize.height,
                                  bottomDistance: geometry.contentSize.height + geometry.contentInsets.bottom
                                    - geometry.contentOffset.y - geometry.containerSize.height)
                } action: { old, new in
                    latestFollow.observe(offset: new.offset, bottomDistance: new.bottomDistance,
                                         userScrolling: isUserScrolling)
                    showsReturnToLatest = latestFollow.isAwayFromLatest && !latestFollow.followsLatest
                    if old.height != new.height { followLatest(with: proxy) }
                }
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { viewportFrame = $0 }

                if showsReturnToLatest {
                    Button {
                        latestFollow.returnToLatest()
                        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.24)) {
                            proxy.scrollTo(latestAnchor, anchor: .bottom)
                        }
                        showsReturnToLatest = false
                    } label: {
                        Image(systemName: "arrow.down")
                            .font(.system(size: 15, weight: .semibold))
                            .frame(width: FloeTheme.minimumTarget, height: FloeTheme.minimumTarget)
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.circle)
                    .padding(.trailing, 14)
                    .padding(.bottom, 12)
                    .accessibilityLabel("chat.thread_detail_view.jump_to_latest")
                    .accessibilityHint("chat.thread_detail_view.scroll_to_the_latest_message_in")
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .onChange(of: ready) { _, ready in
                guard ready else { return }
                latestFollow.returnToLatest()
                showsReturnToLatest = false
                followLatest(with: proxy)
            }
            .onChange(of: updates) { _, _ in followLatest(with: proxy) }
            .task(id: jump) {
                guard let jump else { return }
                await Task.yield()
                guard !Task.isCancelled else { return }
                latestFollow.pauseFollowing()
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                    proxy.scrollTo(jump.rowID, anchor: .center)
                }
                showsReturnToLatest = true
            }
            .task(id: earlierRequest) {
                guard earlierRequest != nil else { return }
                let anchor = firstRowID
                latestFollow.pauseFollowing()
                let inserted = await loadEarlier()
                guard inserted, !Task.isCancelled, let anchor else { return }
                await Task.yield()
                guard !Task.isCancelled else { return }
                proxy.scrollTo(anchor, anchor: .top)
            }
        }
    }

    private var earlierButton: some View {
        Button("chat.thread_detail_view.load_earlier_messages", systemImage: "arrow.up.circle") {
            earlierRequest = UUID()
        }
        .buttonStyle(.bordered)
        .frame(maxWidth: .infinity)
        .disabled(loadingEarlierMessages)
        .accessibilityIdentifier("thread.history.earlier")
        .accessibilityHint("chat.thread_detail_view.load_thirty_more_older_messages_each")
    }

    private func followLatest(with proxy: ScrollViewProxy) {
        guard ready, latestFollow.followsLatest, !isUserScrolling, !searchIsActive else { return }
        proxy.scrollTo(latestAnchor, anchor: .bottom)
    }
}
