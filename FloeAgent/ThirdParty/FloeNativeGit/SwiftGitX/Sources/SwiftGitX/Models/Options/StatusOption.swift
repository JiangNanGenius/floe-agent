import libgit2

/// Options for the status operation.
public struct StatusOption: OptionSet, Sendable {
    // MARK: - Properties

    public let rawValue: UInt32

    // MARK: - Initializers

    init(_ statusFlag: git_status_opt_t) {
        rawValue = statusFlag.rawValue
    }

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    public static let `default`: StatusOption = [.includeUntracked, .recurseUntrackedDirectories]

    // TODO: Add documentation considering the libgit2 documentation of git_status_opt_t

    public static let includeUntracked = StatusOption(GIT_STATUS_OPT_INCLUDE_UNTRACKED)

    public static let includeIgnored = StatusOption(GIT_STATUS_OPT_INCLUDE_IGNORED)

    public static let includeUnmodified = StatusOption(GIT_STATUS_OPT_INCLUDE_UNMODIFIED)

    public static let excludeSubmodules = StatusOption(GIT_STATUS_OPT_EXCLUDE_SUBMODULES)

    public static let recurseUntrackedDirectories = StatusOption(GIT_STATUS_OPT_RECURSE_UNTRACKED_DIRS)

    public static let disablePathSpecMatch = StatusOption(GIT_STATUS_OPT_DISABLE_PATHSPEC_MATCH)

    public static let recurseIgnoredDirectories = StatusOption(GIT_STATUS_OPT_RECURSE_IGNORED_DIRS)

    public static let renamesIndex = StatusOption(GIT_STATUS_OPT_RENAMES_HEAD_TO_INDEX)

    public static let renamesWorkingTree = StatusOption(GIT_STATUS_OPT_RENAMES_INDEX_TO_WORKDIR)

    public static let sortCaseSensitively = StatusOption(GIT_STATUS_OPT_SORT_CASE_SENSITIVELY)

    public static let sortCaseInsensitively = StatusOption(GIT_STATUS_OPT_SORT_CASE_INSENSITIVELY)

    public static let renamesFromRewrites = StatusOption(GIT_STATUS_OPT_RENAMES_FROM_REWRITES)

    public static let noRefresh = StatusOption(GIT_STATUS_OPT_NO_REFRESH)

    public static let updateIndex = StatusOption(GIT_STATUS_OPT_UPDATE_INDEX)

    public static let includeUnreadable = StatusOption(GIT_STATUS_OPT_INCLUDE_UNREADABLE)

    public static let includeUnreadableAsUntracked = StatusOption(GIT_STATUS_OPT_INCLUDE_UNREADABLE_AS_UNTRACKED)
}
