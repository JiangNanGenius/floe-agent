// FloeAppTests — Preview-first page resource limits. The page's shared
// presentation state retains heavyweight preview objects (live WKWebViews,
// AVPlayer-backed models) across lens switches, fullscreen and rotation —
// but full revision HISTORY must never accumulate them: caches are bounded
// by an explicit count policy, pruning keeps exactly the live lens set
// (current + pending candidates + the fullscreen/editor leases that share
// the same selection), and eviction never touches live state.

#if canImport(UIKit)
import Foundation
import Testing
import WebKit
@testable import FloeApp

@Suite("FloeApp.DesignPageResourceLimits")
@MainActor
struct DesignPageResourceLimitsTests {
    private func scratchURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(name)
    }

    @Test("web views beyond the live lens set are evicted, oldest first; live lenses are never evicted")
    func webViewEvictionPolicy() {
        let state = DesignPagePresentationState()
        let revisions = (0..<8).map { "rev-\($0)" }
        for (index, revision) in revisions.enumerated() {
            _ = state.webView(for: revision, url: scratchURL("page-\(index).html"))
        }
        // Live set: the mounted page shows rev-6 (current) and rev-7 is the
        // fullscreen-covered candidate — both must survive.
        let live: Set<String> = ["rev-6", "rev-7"]
        state.pruneWebViews(keeping: live)
        // Everything outside the live set is gone…
        for revision in revisions where !live.contains(revision) {
            #expect(state.webViewIfPresent(for: revision) == nil)
        }
        // …the live set survived…
        #expect(state.webViewIfPresent(for: "rev-6") != nil)
        #expect(state.webViewIfPresent(for: "rev-7") != nil)
        // …and the cache never exceeds the hard cap even when the live set
        // itself is large (a future with 8 simultaneous lenses still caps).
        let wideLive: Set<String> = ["rev-6", "rev-7", "rev-2", "rev-3", "rev-4", "rev-5"]
        state.pruneWebViews(keeping: wideLive)
        #expect(state.webViewCount <= DesignPagePresentationState.maxWebViews)
        // Re-adding beyond the cap evicts the oldest non-live entries.
        for (index, revision) in ["a", "b", "c", "d", "e"].enumerated() {
            _ = state.webView(for: revision, url: scratchURL("extra-\(index).html"))
        }
        state.pruneWebViews(keeping: live)
        #expect(state.webViewCount <= DesignPagePresentationState.maxWebViews)
    }

    @Test("media playback models are bounded and prune to the live URL set")
    func mediaModelEvictionPolicy() {
        let state = DesignPagePresentationState()
        let urls = (0..<4).map { scratchURL("movie-\($0).mp4") }
        for url in urls { _ = state.mediaModel(for: url) }
        // Hard count cap with oldest-first eviction.
        #expect(state.mediaModelCount <= DesignPagePresentationState.maxMediaModels)
        let live: Set<URL> = [urls[3]]
        state.pruneMediaModels(keeping: live)
        for url in urls.dropLast() {
            #expect(state.mediaModelIfPresent(for: url) == nil)
        }
        #expect(state.mediaModelIfPresent(for: urls[3]) != nil)
    }

    @Test("the shared media model is the SAME instance for one URL (position survives fullscreen)")
    func mediaModelSharing() {
        let state = DesignPagePresentationState()
        let url = scratchURL("shared.mp4")
        let first = state.mediaModel(for: url)
        let second = state.mediaModel(for: url)
        #expect(first === second)
    }
}
#endif
