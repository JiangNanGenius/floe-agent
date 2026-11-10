import libgit2

/// Options for restoring.
public struct RestoreOption: OptionSet, Sendable {
    // MARK: - Properties

    public let rawValue: UInt32

    // MARK: - Initializers

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    // MARK: - Options

    /// Restore the working tree.
    public static let workingTree = RestoreOption(rawValue: 1 << 0)

    /// Restore the index.
    public static let staged = RestoreOption(rawValue: 1 << 1)
}
