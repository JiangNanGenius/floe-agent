import SwiftUI

struct PrimaryActionButton: View {

    // MARK: - Public Properties

    let title: String
    let isEnabled: Bool
    let progress: Double?
    let action: () -> Void

    // MARK: - Body

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.headline.weight(.bold))
                .foregroundStyle(labelColor)
                .contentTransition(.numericText())
                .frame(maxWidth: .infinity, minHeight: Metrics.height)
                .padding(.horizontal, Metrics.horizontalPadding)
                .background(buttonBackground)
                .overlay {
                    buttonBorder
                }
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .padding(.top)
        .safeAreaPadding(.horizontal)
    }

    // MARK: - Initializer

    init(
        title: String,
        isEnabled: Bool = true,
        progress: Double? = nil,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.isEnabled = isEnabled
        self.progress = progress
        self.action = action
    }

    // MARK: - Private Properties

    private var isLoading: Bool {
        progress != nil
    }

    private var buttonBackground: some View {
        RoundedRectangle(cornerRadius: Metrics.cornerRadius, style: .continuous)
            .fill(backgroundColor)
    }

    private var buttonBorder: some View {
        ZStack {
            if isLoading == false {
                RoundedRectangle(cornerRadius: Metrics.cornerRadius, style: .continuous)
                    .strokeBorder(.white.opacity(0.18), lineWidth: 1)
            }

            if let progress {
                RoundedRectangle(cornerRadius: Metrics.cornerRadius, style: .continuous)
                    .trim(from: 0, to: progress.clamped(to: 0...1))
                    .stroke(
                        .blue,
                        style: StrokeStyle(
                            lineWidth: Metrics.progressLineWidth,
                            lineCap: .round,
                            lineJoin: .round
                        )
                    )
                    .animation(.easeInOut(duration: 0.2), value: progress)
            }
        }
    }

    private var labelColor: Color {
        isLoading ? .accentColor : .white
    }

    private var backgroundColor: Color {
        if isLoading {
            return Color.accentColor.opacity(0.14)
        }

        return Theme.accent.opacity(isEnabled ? 1.0 : 0.45)
    }

}

private enum Metrics {
    static let height: CGFloat = 56
    static let cornerRadius: CGFloat = 16
    static let horizontalPadding: CGFloat = 20
    static let progressLineWidth: CGFloat = 4
}

#Preview {
    VStack(spacing: 16) {
        PrimaryActionButton(title: "Apply") {}
        PrimaryActionButton(title: "Exporting 42%", progress: 0.42) {}
        PrimaryActionButton(title: "Disabled", isEnabled: false) {}
    }
}
