import SwiftUI

struct VideoEditorShellView: View {

    // MARK: - States

    @State private var bootstrapAttempt = 0
    @State private var bootstrapState: VideoEditorSessionBootstrapCoordinator.BootstrapState

    // MARK: - Body

    var body: some View {
        NavigationStack {
            GeometryReader { proxy in
                content(for: proxy.size)
                    .navigationTitle(Self.navigationTitle(title, bootstrapState: bootstrapState))
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            cancelAction()
                        }

                        ToolbarItem(
                            placement: VideoEditorToolbarActionLayout.exportPlacement.toolbarItemPlacement
                        ) {
                            secondaryAction()
                        }

                        if #available(iOS 26.0, *) {
                            ToolbarSpacer(
                                .fixed,
                                placement: VideoEditorToolbarActionLayout.separatorPlacement.toolbarItemPlacement
                            )
                        }

                        ToolbarItem(
                            placement: VideoEditorToolbarActionLayout.savePlacement.toolbarItemPlacement
                        ) {
                            primaryAction()
                        }
                    }
                    .navigationBarTitleDisplayMode(.inline)
            }
        }
        .task(id: bootstrapTaskID) {
            await resolveSessionSource()
        }
    }

    // MARK: - Private Properties

    private let title: String?
    private let session: VideoEditorSession
    private let callbacks: VideoEditorCallbacks
    private let onCancel: () -> Void
    private let onBootstrapStateChanged: (VideoEditorSessionBootstrapCoordinator.BootstrapState) -> Void
    private let cancelAction: () -> AnyView
    private let secondaryAction: () -> AnyView
    private let primaryAction: () -> AnyView
    private let loadedContent: (CGSize, URL) -> AnyView

    private var bootstrapTaskID: String {
        "\(session.bootstrapTaskIdentifier)-\(bootstrapAttempt)"
    }

    // MARK: - Initializer

    init<CancelAction: View, SecondaryAction: View, PrimaryAction: View, LoadedContent: View>(
        _ title: String? = nil,
        session: VideoEditorSession,
        callbacks: VideoEditorCallbacks = .init(),
        onCancel: @escaping () -> Void,
        onBootstrapStateChanged: @escaping (VideoEditorSessionBootstrapCoordinator.BootstrapState) -> Void = { _ in
        },
        @ViewBuilder cancelAction: @escaping (_ action: @escaping () -> Void) -> CancelAction = { action in
            Button(VideoEditorStrings.cancel, action: action)
        },
        @ViewBuilder secondaryAction: @escaping () -> SecondaryAction = { EmptyView() },
        @ViewBuilder primaryAction: @escaping () -> PrimaryAction = { EmptyView() },
        @ViewBuilder loadedContent:
            @escaping (_ availableSize: CGSize, _ resolvedSourceVideoURL: URL) -> LoadedContent
    ) {
        _bootstrapState = State(
            initialValue: VideoEditorSessionBootstrapCoordinator.initialState(for: session.source)
        )

        self.title = title
        self.session = session
        self.callbacks = callbacks
        self.onCancel = onCancel
        self.onBootstrapStateChanged = onBootstrapStateChanged
        self.cancelAction = {
            AnyView(cancelAction(onCancel))
        }
        self.secondaryAction = {
            AnyView(secondaryAction())
        }
        self.primaryAction = {
            AnyView(primaryAction())
        }
        self.loadedContent = { availableSize, resolvedSourceVideoURL in
            AnyView(
                loadedContent(
                    availableSize,
                    resolvedSourceVideoURL
                )
            )
        }
    }

    // MARK: - Private Methods

    static func navigationTitle(
        _ title: String?,
        bootstrapState: VideoEditorSessionBootstrapCoordinator.BootstrapState
    ) -> String {
        switch bootstrapState {
        case .loaded:
            title ?? ""
        case .idle, .loading, .failed:
            ""
        }
    }

    @ViewBuilder
    private func content(for availableSize: CGSize) -> some View {
        switch bootstrapState {
        case .idle:
            bootstrapStatusView(
                title: VideoEditorStrings.addVideoTitle,
                message: VideoEditorStrings.addVideoMessage
            )
        case .loading:
            bootstrapLoadingView
        case .loaded(let resolvedSourceVideoURL):
            loadedContent(
                availableSize,
                resolvedSourceVideoURL
            )
        case .failed(let message):
            bootstrapFailureView(message: message)
        }
    }

    private var bootstrapLoadingView: some View {
        ProgressView()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .safeAreaPadding()
    }

    private func bootstrapFailureView(message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(.secondary)

            Text(VideoEditorStrings.unableToOpenVideoTitle)
                .font(.headline)

            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            HStack(spacing: 12) {
                Button(VideoEditorStrings.close) {
                    onCancel()
                }

                Button(VideoEditorStrings.retry) {
                    bootstrapAttempt += 1
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func bootstrapStatusView(
        title: String,
        message: String
    ) -> some View {
        VStack(spacing: 12) {
            Text(title)
                .font(.headline)

            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func resolveSessionSource() async {
        let initialState = VideoEditorSessionBootstrapCoordinator.initialState(
            for: session.source
        )
        publishBootstrapState(initialState)

        guard case .loading = initialState else { return }

        let resolvedState = await VideoEditorSessionBootstrapCoordinator.resolveState(
            for: session.source
        )

        guard !Task.isCancelled else { return }
        publishBootstrapState(resolvedState)
    }

    private func publishBootstrapState(
        _ state: VideoEditorSessionBootstrapCoordinator.BootstrapState
    ) {
        bootstrapState = state
        onBootstrapStateChanged(state)

        if case .loaded(let resolvedSourceVideoURL) = state {
            callbacks.onSourceVideoResolved(resolvedSourceVideoURL)
        }
    }

}

#Preview {
    VideoEditorShellView(
        "Preview",
        session: VideoEditorSession(source: nil),
        onCancel: {},
        loadedContent: { _, _ in
            Text("Loaded content")
        }
    )
}
