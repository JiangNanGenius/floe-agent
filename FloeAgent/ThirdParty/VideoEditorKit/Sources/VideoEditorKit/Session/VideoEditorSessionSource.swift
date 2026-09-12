import Foundation

/// An asynchronously resolved imported-file source used to bootstrap a video editor session.
public struct VideoEditorImportedFileSource: Sendable, Equatable {

    // MARK: - Public Properties

    /// Stable identifier used to distinguish one import task from another.
    public let taskIdentifier: String

    // MARK: - Private Properties

    private let resolver: @Sendable () async throws -> URL

    // MARK: - Initializer

    /// Creates a source that resolves a local file URL on demand.
    public init(
        taskIdentifier: String,
        resolveURL resolver: @escaping @Sendable () async throws -> URL
    ) {
        self.taskIdentifier = taskIdentifier
        self.resolver = resolver
    }

    // MARK: - Public Methods

    /// Resolves the imported file into a local file URL that the editor can open.
    public func resolveURL() async throws -> URL {
        try await resolver()
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.taskIdentifier == rhs.taskIdentifier
    }

}

/// The supported ways to provide a source video to `VideoEditorView`.
public enum VideoEditorSessionSource: Sendable, Equatable {

    case fileURL(URL)
    case importedFile(VideoEditorImportedFileSource)

    // MARK: - Public Properties

    /// Returns the file URL when the source is already locally available.
    public var fileURL: URL? {
        switch self {
        case .fileURL(let url):
            url
        case .importedFile:
            nil
        }
    }

    /// Stable identifier used to detect source changes across async bootstrapping steps.
    public var taskIdentifier: String {
        switch self {
        case .fileURL(let url):
            "file:\(url.absoluteString)"
        case .importedFile(let source):
            "imported:\(source.taskIdentifier)"
        }
    }

    // MARK: - Public Methods

    /// Resolves the source into a local file URL, awaiting import work when necessary.
    public func resolveURL() async throws -> URL {
        switch self {
        case .fileURL(let url):
            url
        case .importedFile(let source):
            try await source.resolveURL()
        }
    }

}
