// FloeWorkspace — Reader session (open, windows, find, supersede).
//
// SPDX-License-Identifier: MPL-2.0
//
// One actor owns the currently open document. A new `open` supersedes any
// earlier one; the caller's task cancellation (document switch, dismissal)
// stops a running index scan at the next chunk boundary and the session never
// publishes a partially decoded result.

import Foundation

/// Open result plus the retained full index (line table + chapters) that
/// windows and find need.
public struct ReaderOpenBundle: Sendable {
    public var result: ReaderOpenResult
    public var index: ReaderFileIndex
    public init(result: ReaderOpenResult, index: ReaderFileIndex) {
        self.result = result
        self.index = index
    }
}

public actor ReaderSession {
    public private(set) var identity: ReaderDocumentIdentity?
    public private(set) var encoding: ReaderTextEncoding?
    /// Whether the current encoding was detected automatically or chosen by
    /// the user for this open.
    public private(set) var encodingSelection: ReaderEncodingSelection = .auto
    public private(set) var totalLines = 0
    public private(set) var byteLength: Int64 = 0
    public private(set) var notices: [ReaderNotice] = []
    public private(set) var chapters: [ReaderChapterHeading] = []
    /// Set when the stored position was restored; nil when there was none or
    /// the fingerprint no longer matched (the reader then starts at the top).
    public private(set) var restoredPosition: ReaderPosition?

    private var source: ReaderFileSource?
    private var index: ReaderFileIndex?
    private var generation = 0

    public init() {}

    /// Opens (or re-opens) a document. Passing a different source supersedes
    /// the previous one: a concurrent open throws `.superseded`, and the
    /// caller's task cancellation throws `.cancelled`.
    public func open(
        source: ReaderFileSource,
        restoring: ReaderPosition? = nil,
        preferredEncoding: ReaderEncodingSelection = .auto,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> ReaderOpenResult {
        generation += 1
        let myGeneration = generation
        await Task.yield()
        try Task.checkCancellation()
        guard myGeneration == generation else { throw ReaderError.superseded }

        let bundle = try source.open(
            preferredEncoding: preferredEncoding,
            restoring: restoring,
            cancellation: .task(),
            progress: progress
        )
        try Task.checkCancellation()
        guard myGeneration == generation else { throw ReaderError.superseded }

        self.source = source
        self.index = bundle.index
        self.identity = bundle.result.identity
        self.encoding = bundle.result.encoding
        self.encodingSelection = bundle.result.encodingSelection
        self.totalLines = bundle.result.totalLines
        self.byteLength = bundle.result.byteLength
        self.notices = bundle.result.notices
        self.chapters = bundle.result.chapters
        self.restoredPosition = bundle.result.restoredPosition
        return bundle.result
    }

    /// Next/previous line-aligned window over the retained index.
    public func window(startByte: Int64, backwards: Bool = false) throws -> ReaderWindow {
        guard let source, let index else {
            throw ReaderError.sourceUnavailable("no document is open")
        }
        return try source.window(
            startByte: startByte,
            index: index,
            backwards: backwards,
            cancellation: .task()
        )
    }

    public func find(_ query: String) throws -> ReaderFindResult {
        guard let source, let index else {
            throw ReaderError.sourceUnavailable("no document is open")
        }
        return try source.find(query, index: index, cancellation: .task())
    }

    public func close() {
        generation += 1
        source = nil
        index = nil
        identity = nil
        encoding = nil
        encodingSelection = .auto
        restoredPosition = nil
    }

    /// Position derived from the leading block of a window. Pass the resolved
    /// encoding so the stored anchor stays scoped to the byte space it was
    /// measured in; existing callers may omit it.
    public static func position(
        from window: ReaderWindow,
        fingerprint: String,
        encoding: ReaderTextEncoding? = nil
    ) -> ReaderPosition {
        let anchor = window.blocks.first?.byteOffset ?? window.startByte
        return ReaderPosition(anchorByte: anchor, progress: window.progress, fingerprint: fingerprint, encoding: encoding)
    }
}
