/// Tracks the ranges actually read from a keyset-paginated timeline. A fresh
/// tail may be disjoint from history already on screen; fill those gaps before
/// paging past the oldest row. Never discard history or fetch an unbounded gap.
public struct TimelinePageCoverage<Key: Comparable & Sendable>: Sendable {
    private struct Span: Sendable {
        // nil means the database confirmed the beginning of history.
        var lower: Key?
        var upper: Key
    }
    private var spans: [Span] = []
    public init() {}

    /// The newest uncovered boundary, or nil once every range is connected
    /// all the way to the beginning of history.
    public var earlierCursor: Key? { spans.last?.lower }

    public mutating func record(first: Key?, last: Key?, before: Key? = nil, hasEarlier: Bool) {
        guard let upper = before ?? last else { return }
        guard !hasEarlier || first != nil else { return }
        let lower = hasEarlier ? first : nil
        guard lower.map({ $0 <= upper }) ?? true else { return }
        spans.append(Span(lower: lower, upper: upper))
        spans.sort {
            switch ($0.lower, $1.lower) {
            case (nil, nil): return $0.upper < $1.upper
            case (nil, _): return true
            case (_, nil): return false
            case (let a?, let b?): return a < b
            }
        }
        var merged: [Span] = []
        for span in spans {
            if let previous = merged.last,
               span.lower.map({ $0 <= previous.upper }) ?? true {
                merged[merged.count - 1].upper = max(previous.upper, span.upper)
            } else {
                merged.append(span)
            }
        }
        spans = merged
    }
}
