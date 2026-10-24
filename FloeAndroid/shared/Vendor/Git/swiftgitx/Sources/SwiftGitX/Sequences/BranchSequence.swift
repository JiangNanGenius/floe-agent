import libgit2

public struct BranchSequence: Sequence {
    let type: BranchType

    private let repositoryPointer: OpaquePointer

    init(type: BranchType, repositoryPointer: OpaquePointer) {
        self.type = type
        self.repositoryPointer = repositoryPointer
    }

    public func makeIterator() -> BranchIterator {
        BranchIterator(type: type, repositoryPointer: repositoryPointer)
    }
}

public class BranchIterator: IteratorProtocol {
    public let type: BranchType

    private var branchIterator: OpaquePointer?
    private let repositoryPointer: OpaquePointer

    init(type: BranchType, repositoryPointer: OpaquePointer) {
        self.type = type
        self.repositoryPointer = repositoryPointer

        // Create a branch iterator
        git_branch_iterator_new(&branchIterator, repositoryPointer, type.raw)
    }

    deinit {
        git_branch_iterator_free(branchIterator)
    }

    public func next() -> Branch? {
        var branchPointer: OpaquePointer?
        var type = type.raw

        while true {
            // Task should not be cancelled
            if Task.isCancelled { return nil }

            // Get the next branch
            let status = git_branch_next(&branchPointer, &type, branchIterator)
            defer { git_reference_free(branchPointer) }

            // Check if the status is ITEROVER. If so, return nil
            if status == GIT_ITEROVER.rawValue { return nil }

            // Check if the branch pointer is not nil and the status is OK
            // If any error occurs, continue to the next iteration
            guard let branchPointer, status == GIT_OK.rawValue else {
                continue
            }

            // Try to create a branch from the pointer
            // If the reference is not valid, continue to the next iteration
            if let branch = try? Branch(pointer: branchPointer) {
                return branch
            } else {
                continue
            }
        }
    }
}
