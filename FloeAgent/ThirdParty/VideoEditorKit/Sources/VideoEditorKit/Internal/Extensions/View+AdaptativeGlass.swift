import SwiftUI

enum AdaptativeGlassShape: Equatable {

    // MARK: - Public Properties

    case roundedRectangle(cornerRadius: CGFloat)
    case circle
    case capsule

}

struct AdaptativeGlassStyle: Equatable {

    // MARK: - Public Properties

    let shape: AdaptativeGlassShape
    let isInteractive: Bool
    let tintOpacity: Double?

}

enum AdaptativeGlassStyleResolver {

    // MARK: - Public Methods

    static func resolve(
        shape: AdaptativeGlassShape,
        prominent: Bool,
        tintProvided: Bool,
        isInteractive: Bool
    ) -> AdaptativeGlassStyle {
        AdaptativeGlassStyle(
            shape: shape,
            isInteractive: isInteractive,
            tintOpacity: tintProvided ? (prominent ? 0.30 : 0.18) : nil
        )
    }

}

extension View {

    // MARK: - Public Methods

    nonisolated func adaptativeGlass(
        _ shape: AdaptativeGlassShape,
        prominent: Bool = false,
        tint: Color? = nil,
        isInteractive: Bool = false
    ) -> some View {
        modifier(
            AdaptativeGlassModifier(
                shape: shape,
                prominent: prominent,
                tint: tint,
                isInteractive: isInteractive
            )
        )
    }

}

struct AdaptativeGlassContainer<Content: View>: View {

    // MARK: - Public Properties

    let spacing: CGFloat
    let content: () -> Content

    // MARK: - Body

    @ViewBuilder
    var body: some View {
        if #available(iOS 26, *) {
            glassContainerContent
        } else {
            content()
        }
    }

    // MARK: - Initializer

    init(
        spacing: CGFloat = 0,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.spacing = spacing
        self.content = content
    }

    // MARK: - Private Properties

    @available(iOS 26, *)
    private var glassContainerContent: some View {
        GlassEffectContainer(spacing: spacing) {
            content()
        }
    }

}

private struct AdaptativeGlassModifier: ViewModifier {

    // MARK: - Private Properties

    private let style: AdaptativeGlassStyle
    private let tint: Color?

    // MARK: - Initializer

    nonisolated init(
        shape: AdaptativeGlassShape,
        prominent: Bool,
        tint: Color?,
        isInteractive: Bool
    ) {
        self.style = AdaptativeGlassStyleResolver.resolve(
            shape: shape,
            prominent: prominent,
            tintProvided: tint != nil,
            isInteractive: isInteractive
        )
        self.tint = tint
    }

    // MARK: - Public Methods

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            glassContent(content)
        } else {
            fallbackContent(content)
        }
    }

    // MARK: - Private Methods

    @available(iOS 26, *)
    @ViewBuilder
    private func glassContent(_ content: Content) -> some View {
        switch style.shape {
        case .roundedRectangle(let cornerRadius):
            if let tint {
                content.glassEffect(
                    resolvedGlassEffect(tint: tint),
                    in: .rect(cornerRadius: cornerRadius)
                )
            } else {
                content.glassEffect(
                    resolvedGlassEffect(),
                    in: .rect(cornerRadius: cornerRadius)
                )
            }
        case .circle:
            if let tint {
                content.glassEffect(
                    resolvedGlassEffect(tint: tint),
                    in: .circle
                )
            } else {
                content.glassEffect(
                    resolvedGlassEffect(),
                    in: .circle
                )
            }
        case .capsule:
            if let tint {
                content.glassEffect(
                    resolvedGlassEffect(tint: tint),
                    in: .capsule
                )
            } else {
                content.glassEffect(
                    resolvedGlassEffect(),
                    in: .capsule
                )
            }
        }
    }

    @ViewBuilder
    private func fallbackContent(_ content: Content) -> some View {
        switch style.shape {
        case .roundedRectangle(let cornerRadius):
            content.background(
                .ultraThinMaterial,
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
        case .circle:
            content.background(.ultraThinMaterial, in: Circle())
        case .capsule:
            content.background(.ultraThinMaterial, in: Capsule(style: .continuous))
        }
    }

    @available(iOS 26, *)
    private func resolvedGlassEffect(tint: Color? = nil) -> Glass {
        if let tint, let tintOpacity = style.tintOpacity {
            let glass = Glass.regular.tint(tint.opacity(tintOpacity))
            return style.isInteractive ? glass.interactive() : glass
        }

        return style.isInteractive ? .regular.interactive() : .regular
    }

}
