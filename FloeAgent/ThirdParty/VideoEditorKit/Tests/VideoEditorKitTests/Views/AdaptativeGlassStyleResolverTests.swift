import Testing

@testable import VideoEditorKit

@Suite("AdaptativeGlassStyleResolverTests")
struct AdaptativeGlassStyleResolverTests {

    @Test
    func tintedProminentStyleUsesHigherTintOpacity() {
        let style = AdaptativeGlassStyleResolver.resolve(
            shape: .roundedRectangle(cornerRadius: 24),
            prominent: true,
            tintProvided: true,
            isInteractive: false
        )

        #expect(style.shape == .roundedRectangle(cornerRadius: 24))
        #expect(style.isInteractive == false)
        #expect(style.tintOpacity == 0.30)
    }

    @Test
    func tintedNonProminentInteractiveStyleKeepsInteractiveFlag() {
        let style = AdaptativeGlassStyleResolver.resolve(
            shape: .circle,
            prominent: false,
            tintProvided: true,
            isInteractive: true
        )

        #expect(style.shape == .circle)
        #expect(style.isInteractive)
        #expect(style.tintOpacity == 0.18)
    }

    @Test
    func untintedStyleDoesNotApplyTintOpacity() {
        let style = AdaptativeGlassStyleResolver.resolve(
            shape: .capsule,
            prominent: true,
            tintProvided: false,
            isInteractive: true
        )

        #expect(style.shape == .capsule)
        #expect(style.isInteractive)
        #expect(style.tintOpacity == nil)
    }

}
