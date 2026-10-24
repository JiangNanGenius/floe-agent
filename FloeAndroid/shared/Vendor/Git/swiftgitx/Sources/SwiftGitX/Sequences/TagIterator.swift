public class TagIterator: IteratorProtocol {
    private let referenceIterator: ReferenceIterator

    init(repositoryPointer: OpaquePointer) {
        referenceIterator = ReferenceIterator(
            glob: "\(GitDirectoryConstants.tags)*",
            repositoryPointer: repositoryPointer
        )
    }

    public func next() -> Tag? {
        let reference = referenceIterator.next()

        return reference as? Tag
    }
}
