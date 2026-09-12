import SwiftUI

struct PrimaryButtonStyle: ButtonStyle {

    // MARK: - Environments

    @Environment(\.isEnabled) private var isEnabled

    // MARK: - Body

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background {
                Capsule()
                    .fill(Theme.accent.opacity(configuration.isPressed ? 0.72 : 1))
            }
            .opacity(isEnabled ? 1 : 0.45)
    }

}

extension ButtonStyle where Self == PrimaryButtonStyle {

    // MARK: - Public Properties

    static var primary: Self { .init() }

}
