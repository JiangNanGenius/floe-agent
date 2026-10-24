import libgit2

/// A sequence of commits.
///
/// This sequence is an async sequence that iterates over the commits in a repository.
///
/// - Warning: The sequence's task should be cancelled before ``Repository`` is deinitialized.
public struct CommitSequence: Sequence {
    public typealias Element = Commit

    public let root: Commit
    public let sorting: LogSortingOption

    private let repositoryPointer: OpaquePointer

    init(root: Commit, sorting: LogSortingOption, repositoryPointer: OpaquePointer) {
        self.root = root
        self.sorting = sorting
        self.repositoryPointer = repositoryPointer
    }

    public func makeIterator() -> CommitIterator {
        CommitIterator(root: root, sorting: sorting, repositoryPointer: repositoryPointer)
    }
}

public class CommitIterator: IteratorProtocol {
    public let root: Commit
    public let sorting: LogSortingOption

    private let walkerPointer: OpaquePointer?
    private let repositoryPointer: OpaquePointer

    init(root: Commit, sorting: LogSortingOption, repositoryPointer: OpaquePointer) {
        self.root = root
        self.sorting = sorting

        self.repositoryPointer = repositoryPointer

        // Create a rev walker
        var walkerPointer: OpaquePointer?
        git_revwalk_new(&walkerPointer, repositoryPointer)

        self.walkerPointer = walkerPointer

        // Set the root commit
        var rootID = root.id.raw
        git_revwalk_push(walkerPointer, &rootID)

        // Set the sorting
        git_revwalk_sorting(walkerPointer, sorting.rawValue)
    }

    deinit {
        git_revwalk_free(walkerPointer)
    }

    public func next() -> Commit? {
        // Task should not be cancelled
        if Task.isCancelled { return nil }

        // Get the next commit
        var oid = git_oid()
        let status = git_revwalk_next(&oid, walkerPointer)

        // Check if the status is OK
        guard status == GIT_OK.rawValue else {
            return nil
        }

        return try? ObjectFactory.lookupObject(oid: oid, repositoryPointer: repositoryPointer)
    }
}
