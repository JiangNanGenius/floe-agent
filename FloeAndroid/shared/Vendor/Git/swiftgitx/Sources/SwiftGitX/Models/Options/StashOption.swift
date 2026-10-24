import libgit2

/// Options for stashing changes.
public struct StashOption: OptionSet, Sendable {
    // MARK: - Properties

    public let rawValue: UInt32

    // MARK: - Initializers

    init(_ stashFlag: git_stash_flags) {
        rawValue = stashFlag.rawValue
    }

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    // MARK: - Options

    /// No option, default behavior.
    public static let `default` = StashOption(GIT_STASH_DEFAULT)

    /// All changes already added to the index are left intact.
    public static let keepIndex = StashOption(GIT_STASH_KEEP_INDEX)

    /// All untracked files are also stashed.
    public static let includeUntracked = StashOption(GIT_STASH_INCLUDE_UNTRACKED)

    /// All ignored files are also stashed.
    public static let includeIgnored = StashOption(GIT_STASH_INCLUDE_IGNORED)

    /// All ignored and untracked files are also stashed.
    public static let keepAll = StashOption(GIT_STASH_KEEP_ALL)
}
