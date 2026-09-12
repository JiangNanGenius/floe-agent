import SwiftUI

public struct VideoExportPresentationState: Equatable, Sendable {

    // MARK: - Public Properties

    public let selectedQuality: VideoQuality
    public let exportProgress: Double
    public let progressText: String
    public let errorMessage: String
    public let actionTitle: String
    public let isInteractionDisabled: Bool
    public let canExportVideo: Bool
    public let canCancelExport: Bool
    public let shouldShowLoadingView: Bool
    public let shouldShowFailureMessage: Bool
    public let isSavingBeforeExport: Bool

    public var isExporting: Bool {
        shouldShowLoadingView
    }

    public var shouldShowCancelAction: Bool {
        isExporting && canCancelExport
    }

    public var exportButtonTitle: String {
        if isExporting && isSavingBeforeExport {
            return VideoEditorStrings.savingVideoExportButtonTitle
        }

        return isExporting ? VideoEditorStrings.exportButtonTitle(progressText: progressText) : actionTitle
    }

    public var exportButtonProgress: Double {
        min(max(exportProgress, 0), 1)
    }

    // MARK: - Initializer

    public init(
        selectedQuality: VideoQuality,
        exportProgress: Double,
        progressText: String,
        errorMessage: String,
        actionTitle: String,
        isInteractionDisabled: Bool,
        canExportVideo: Bool,
        canCancelExport: Bool,
        shouldShowLoadingView: Bool,
        shouldShowFailureMessage: Bool,
        isSavingBeforeExport: Bool = false
    ) {
        self.selectedQuality = selectedQuality
        self.exportProgress = exportProgress
        self.progressText = progressText
        self.errorMessage = errorMessage
        self.actionTitle = actionTitle
        self.isInteractionDisabled = isInteractionDisabled
        self.canExportVideo = canExportVideo
        self.canCancelExport = canCancelExport
        self.shouldShowLoadingView = shouldShowLoadingView
        self.shouldShowFailureMessage = shouldShowFailureMessage
        self.isSavingBeforeExport = isSavingBeforeExport
    }

}

struct ExportQualityOptionPresentation: Equatable, Identifiable, Sendable {

    // MARK: - Public Properties

    let quality: VideoQuality
    let isSelected: Bool
    let isBlocked: Bool

    var id: VideoQuality {
        quality
    }

    var shouldNotifyBlockedTap: Bool {
        isBlocked
    }

    var subtitleLineLimit: Int? {
        quality == .original ? nil : 2
    }

    var accessibilityLabel: String {
        VideoEditorStrings.exportQualityAccessibilityLabel(
            title: quality.title,
            isBlocked: isBlocked
        )
    }

    var accessibilityValue: String {
        if isBlocked {
            VideoEditorStrings.locked
        } else if isSelected {
            VideoEditorStrings.selected
        } else {
            VideoEditorStrings.available
        }
    }

    var accessibilityHint: String {
        isBlocked
            ? VideoEditorStrings.exportQualityPremiumHint
            : VideoEditorStrings.exportQualitySelectHint
    }

    var accessibilityIdentifier: String {
        "export-quality-\(quality.rawValue)"
    }

    // MARK: - Initializer

    init(
        availability: ExportQualityAvailability,
        selectedQuality: VideoQuality
    ) {
        quality = availability.quality
        isSelected = availability.quality == selectedQuality
        isBlocked = availability.quality.isOriginal ? false : availability.isBlocked
    }

}

enum ExportQualityPresentationResolver {

    // MARK: - Public Methods

    static func normalizedQualities(
        _ qualities: [ExportQualityAvailability]
    ) -> [ExportQualityAvailability] {
        let original = ExportQualityAvailability.enabled(.original)
        let nonOriginalQualities = qualities.filter { $0.quality != .original }

        return (nonOriginalQualities + [original]).sorted {
            if $0.order == $1.order {
                return $0.quality.rawValue < $1.quality.rawValue
            }

            return $0.order < $1.order
        }
    }

    static func optionPresentations(
        for qualities: [ExportQualityAvailability],
        selectedQuality: VideoQuality
    ) -> [ExportQualityOptionPresentation] {
        normalizedQualities(qualities).map {
            ExportQualityOptionPresentation(
                availability: $0,
                selectedQuality: selectedQuality
            )
        }
    }

}

public struct VideoExporterView: View {

    // MARK: - Bindings

    @Binding private var isAlertPresented: Bool

    // MARK: - Private Properties

    private let state: VideoExportPresentationState
    private let qualities: [ExportQualityAvailability]
    private let onSelectQuality: (VideoQuality) -> Void
    private let onBlockedQualityTap: (VideoQuality) -> Void
    private let onExport: () -> Void
    private let onRetry: () -> Void
    private let onCancelExport: () -> Void
    private let onClose: () -> Void

    // MARK: - Body

    public var body: some View {
        navigationContent
            .interactiveDismissDisabled(state.isInteractionDisabled)
            .alert(
                VideoEditorStrings.exportAlertTitle,
                isPresented: $isAlertPresented
            ) {
                Button(VideoEditorStrings.tryAgain, action: onRetry)
                Button(VideoEditorStrings.ok, role: .cancel) {}
            } message: {
                Text(state.errorMessage)
            }
    }

    // MARK: - Private Properties

    private var navigationContent: some View {
        content
            .safeAreaInset(edge: .bottom) {
                footer
            }
            .navigationTitle(VideoEditorStrings.exportVideoTitle)
            .navigationBarTitleDisplayMode(.inline)
            .animation(.easeInOut, value: state)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(VideoEditorStrings.cancel, role: .cancel, action: onClose)
                        .disabled(state.isInteractionDisabled)
                }
            }
    }

    private var content: some View {
        ViewThatFits(in: .vertical) {
            exportOptionsContent
                .fixedSize(horizontal: false, vertical: true)

            ScrollView {
                exportOptionsContent
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var footer: some View {
        VStack(spacing: 12) {
            PrimaryActionButton(
                title: state.exportButtonTitle,
                isEnabled: state.canExportVideo || state.isExporting,
                progress: state.isExporting ? state.exportButtonProgress : nil,
                action: onExport
            )
            .allowsHitTesting(state.canExportVideo)
            .accessibilityValue(
                VideoEditorStrings.exportButtonAccessibilityValue(
                    progress: state.exportButtonProgress,
                    isExporting: state.isExporting
                )
            )
            .accessibilityHint(
                state.isExporting
                    ? VideoEditorStrings.exportButtonInProgressHint
                    : VideoEditorStrings.exportButtonReadyHint
            )

            if state.shouldShowCancelAction {
                Button(VideoEditorStrings.cancel, role: .cancel, action: onCancelExport)
                    .buttonStyle(.bordered)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: state.shouldShowCancelAction)
    }

    private var exportOptionsContent: some View {
        ExportQualitySelectionSection(
            qualities: qualities,
            selectedQuality: state.selectedQuality,
            state: state,
            onSelectQuality: onSelectQuality,
            onBlockedQualityTap: onBlockedQualityTap
        )
        .frame(maxWidth: .infinity, alignment: .leading)
        .safeAreaPadding(.horizontal)
        .padding(.bottom, 12)
    }

    // MARK: - Initializer

    public init(
        isAlertPresented: Binding<Bool>,
        state: VideoExportPresentationState,
        qualities: [ExportQualityAvailability] = ExportQualityAvailability.allEnabled,
        onSelectQuality: @escaping (VideoQuality) -> Void,
        onBlockedQualityTap: @escaping (VideoQuality) -> Void = { _ in },
        onExport: @escaping () -> Void,
        onRetry: @escaping () -> Void,
        onCancelExport: @escaping () -> Void,
        onClose: @escaping () -> Void
    ) {
        _isAlertPresented = isAlertPresented

        self.state = state
        self.qualities = ExportQualityPresentationResolver.normalizedQualities(qualities)
        self.onSelectQuality = onSelectQuality
        self.onBlockedQualityTap = onBlockedQualityTap
        self.onExport = onExport
        self.onRetry = onRetry
        self.onCancelExport = onCancelExport
        self.onClose = onClose
    }

}

private struct ExportQualitySelectionSection: View {

    // MARK: - Public Properties

    let qualities: [ExportQualityAvailability]
    let selectedQuality: VideoQuality
    let state: VideoExportPresentationState
    let onSelectQuality: (VideoQuality) -> Void
    let onBlockedQualityTap: (VideoQuality) -> Void

    // MARK: - Body

    var body: some View {
        let options = ExportQualityPresentationResolver.optionPresentations(
            for: qualities,
            selectedQuality: selectedQuality
        )

        VStack(alignment: .leading, spacing: 16) {
            Text(VideoEditorStrings.exportChooseQualityMessage)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.horizontal)

            VStack(spacing: 8) {
                ForEach(options) { option in
                    ExportQualityOptionRow(
                        presentation: option,
                        onTap: {
                            if option.shouldNotifyBlockedTap {
                                onBlockedQualityTap(option.quality)
                            } else {
                                onSelectQuality(option.quality)
                            }
                        }
                    )
                }
            }
            .disabled(state.isInteractionDisabled)

            if state.shouldShowFailureMessage {
                ExportFailureMessageCard(message: state.errorMessage)
            }
        }
    }

}

private struct ExportQualityOptionRow: View {

    // MARK: - Public Properties

    let presentation: ExportQualityOptionPresentation
    let onTap: () -> Void

    // MARK: - Body

    var body: some View {
        Button(action: onTap) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(presentation.quality.title)
                            .font(.headline)

                        if presentation.isBlocked {
                            PremiumQualityBadge()
                        }
                    }

                    Text(presentation.quality.subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(presentation.subtitleLineLimit)
                        .fixedSize(
                            horizontal: false,
                            vertical: true
                        )
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Spacer(minLength: 12)

                Image(systemName: trailingSymbolName)
                    .font(.headline)
                    .foregroundStyle(trailingSymbolTint)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .opacity(presentation.isBlocked ? 0.55 : 1)
            .background(rowBackground)
            .contentShape(.rect(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(presentation.accessibilityLabel)
        .accessibilityValue(presentation.accessibilityValue)
        .accessibilityHint(presentation.accessibilityHint)
        .accessibilityIdentifier(presentation.accessibilityIdentifier)
    }

    // MARK: - Private Properties

    private var trailingSymbolName: String {
        if presentation.isBlocked {
            "lock.fill"
        } else if presentation.isSelected {
            "checkmark.circle.fill"
        } else {
            "circle"
        }
    }

    private var trailingSymbolTint: Color {
        if presentation.isBlocked {
            .secondary
        } else if presentation.isSelected {
            .accentColor
        } else {
            .secondary
        }
    }

    private var rowBackground: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(
                presentation.isSelected && !presentation.isBlocked
                    ? Color.accentColor.opacity(0.16)
                    : Color.secondary.opacity(0.08)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(
                        presentation.isSelected && !presentation.isBlocked
                            ? Color.accentColor
                            : Color.secondary.opacity(0.18),
                        lineWidth: presentation.isSelected && !presentation.isBlocked ? 1.5 : 1
                    )
            }
    }

}

private struct PremiumQualityBadge: View {

    // MARK: - Body

    var body: some View {
        Text(VideoEditorStrings.premium)
            .font(.caption2.weight(.bold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.secondary.opacity(0.12))
            )
    }

}

private struct ExportFailureMessageCard: View {

    // MARK: - Public Properties

    let message: String

    // MARK: - Body

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)

            Text(message)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.yellow.opacity(0.12))
        )
    }

}

#Preview {
    @Previewable @State var isAlertPresented = false
    NavigationStack {
        VideoExporterView(
            isAlertPresented: $isAlertPresented,
            state: VideoExportPresentationState(
                selectedQuality: .medium,
                exportProgress: 0,
                progressText: "",
                errorMessage: "",
                actionTitle: VideoEditorStrings.export,
                isInteractionDisabled: false,
                canExportVideo: true,
                canCancelExport: false,
                shouldShowLoadingView: false,
                shouldShowFailureMessage: false
            ),
            onSelectQuality: { _ in },
            onExport: {},
            onRetry: {},
            onCancelExport: {},
            onClose: {}
        )
    }
}
