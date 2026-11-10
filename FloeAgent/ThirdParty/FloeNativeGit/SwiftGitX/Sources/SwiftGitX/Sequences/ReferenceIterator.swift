import libgit2

public class ReferenceIterator: IteratorProtocol {
    private var referenceIterator: UnsafeMutablePointer<git_reference_iterator>?
    private let repositoryPointer: OpaquePointer

    init(glob: String? = nil, repositoryPointer: OpaquePointer) {
        self.repositoryPointer = repositoryPointer

        // Create a reference iterator
        if let glob {
            git_reference_iterator_glob_new(&referenceIterator, repositoryPointer, glob)
        } else {
            git_reference_iterator_new(&referenceIterator, repositoryPointer)
        }
    }

    deinit {
        git_reference_iterator_free(referenceIterator)
    }

    public func next() -> (any Reference)? {
        var referencePointer: OpaquePointer?

        while true {
            // Task should not be cancelled
            if Task.isCancelled { return nil }

            // Get the next reference
            let status = git_reference_next(&referencePointer, referenceIterator)
            defer { git_reference_free(referencePointer) }

            // Check if the status is ITEROVER. If so, return nil
            if status == GIT_ITEROVER.rawValue { return nil }

            // Check if the reference pointer is not nil and the status is OK
            // If any error occurs, continue to the next iteration
            guard let referencePointer, status == GIT_OK.rawValue else {
                continue
            }

            // Try to create a reference from the pointer
            // If the reference is not valid, continue to the next iteration
            if let reference = try? ReferenceFactory.makeReference(pointer: referencePointer) {
                return reference
            } else {
                continue
            }
        }
    }
}
