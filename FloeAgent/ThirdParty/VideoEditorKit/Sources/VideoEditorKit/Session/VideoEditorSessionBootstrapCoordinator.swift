import Foundation

public enum VideoEditorSessionBootstrapCoordinator {

    public enum BootstrapState: Equatable, Sendable {

        case idle
        case loading
        case loaded(URL)
        case failed(String)

    }

    // MARK: - Public Methods

    public static func initialState(
        for source: VideoEditorSessionSource?
    ) -> BootstrapState {
        switch source {
        case .none:
            return .idle
        case .fileURL(let url):
            return .loaded(url)
        case .importedFile:
            return .loading
        }
    }

    public static func resolveState(
        for source: VideoEditorSessionSource?
    ) async -> BootstrapState {
        switch source {
        case .none:
            return .idle
        case .fileURL(let url):
            return .loaded(url)
        case .importedFile(let source):
            do {
                return .loaded(try await source.resolveURL())
            } catch {
                return .failed(error.localizedDescription)
            }
        }
    }

}
