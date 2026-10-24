import libgit2

/// Options for sorting the log.
public struct LogSortingOption: OptionSet, Sendable {
    // MARK: - Properties

    public let rawValue: UInt32

    // MARK: - Initializers

    init(_ sortType: git_sort_t) {
        rawValue = sortType.rawValue
    }

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    // MARK: - Options

    /// No sorting.
    public static let none = LogSortingOption(GIT_SORT_NONE)

    /// Sort by commit time.
    public static let time = LogSortingOption(GIT_SORT_TIME)

    /// Sort by topological order.
    public static let topological = LogSortingOption(GIT_SORT_TOPOLOGICAL)

    /// Sort by reverse.
    public static let reverse = LogSortingOption(GIT_SORT_REVERSE)
}
