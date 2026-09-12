import CoreGraphics
import Testing

@testable import VideoEditorKit

@Suite("SocialPlatformSafeAreaTests")
struct SocialPlatformSafeAreaTests {

    @Test
    func safeAreaInsetsComputeTheSafeFrameUsingNormalizedRatios() {
        let insets = SafeAreaInsets(
            top: 0.1,
            bottom: 0.2,
            left: 0.05,
            right: 0.15
        )

        let safeFrame = insets.safeFrame(
            in: CGSize(width: 1000, height: 2000)
        )

        expect(
            safeFrame,
            equals: CGRect(x: 50, y: 200, width: 800, height: 1400)
        )
    }

    @Test
    func guideLayoutCreatesAdaptiveUnsafeRegionsAroundTheSafeFrame() {
        let insets = SafeAreaInsets(
            top: 240 / 1920,
            bottom: 660 / 1920,
            left: 120 / 1080,
            right: 120 / 1080
        )

        let guideLayout = insets.guideLayout(
            in: CGSize(width: 1080, height: 1920)
        )

        expect(
            guideLayout.safeFrame,
            equals: CGRect(x: 120, y: 240, width: 840, height: 1020)
        )
        #expect(guideLayout.unsafeRegions.map(\.role) == [.top, .bottom, .left, .right])
        expect(
            guideLayout.unsafeRegions[0].rect,
            equals: CGRect(x: 0, y: 0, width: 1080, height: 240)
        )
        expect(
            guideLayout.unsafeRegions[1].rect,
            equals: CGRect(x: 0, y: 1260, width: 1080, height: 660)
        )
        expect(
            guideLayout.unsafeRegions[2].rect,
            equals: CGRect(x: 0, y: 240, width: 120, height: 1020)
        )
        expect(
            guideLayout.unsafeRegions[3].rect,
            equals: CGRect(x: 960, y: 240, width: 120, height: 1020)
        )
    }

    @Test
    func instagramSafeAreaMatchesTheReferenceGuide() throws {
        let safeFrame = try #require(
            SocialPlatform.instagram.safeAreaInsets?.safeFrame(
                in: CGSize(width: 1080, height: 1920)
            )
        )

        expect(
            safeFrame,
            equals: CGRect(x: 64.8, y: 268.8, width: 950.4, height: 979.2)
        )
    }

    @Test
    func tikTokSafeAreaMatchesTheReferenceGuide() throws {
        let safeFrame = try #require(
            SocialPlatform.tiktok.safeAreaInsets?.safeFrame(
                in: CGSize(width: 1080, height: 1920)
            )
        )

        expect(
            safeFrame,
            equals: CGRect(x: 120, y: 240, width: 840, height: 1020)
        )
    }

    @Test
    func youtubeShortsSafeAreaMatchesTheReferenceGuide() throws {
        let safeFrame = try #require(
            SocialPlatform.youtubeShorts.safeAreaInsets?.safeFrame(
                in: CGSize(width: 1080, height: 1920)
            )
        )

        expect(
            safeFrame,
            equals: CGRect(x: 48, y: 288, width: 840, height: 960)
        )
    }

    @Test
    func universalSocialSafeAreaMatchesTheIntersectionOfThePlatformGuides() throws {
        let safeFrame = try #require(
            SafeAreaGuideProfile.universalSocial.safeAreaInsets?.safeFrame(
                in: CGSize(width: 1080, height: 1920)
            )
        )

        expect(
            safeFrame,
            equals: CGRect(x: 120, y: 288, width: 768, height: 960)
        )
    }

    @Test
    func socialVideoDestinationsMapToTheExpectedPlatforms() {
        #expect(
            VideoEditingConfiguration.SocialVideoDestination.instagramReels.socialPlatform
                == .instagram
        )
        #expect(
            VideoEditingConfiguration.SocialVideoDestination.tikTok.socialPlatform
                == .tiktok
        )
        #expect(
            VideoEditingConfiguration.SocialVideoDestination.youtubeShorts.socialPlatform
                == .youtubeShorts
        )
    }

    // MARK: - Private Methods

    private func expect(
        _ lhs: CGRect,
        equals rhs: CGRect,
        tolerance: CGFloat = 0.0001
    ) {
        #expect(abs(lhs.minX - rhs.minX) < tolerance)
        #expect(abs(lhs.minY - rhs.minY) < tolerance)
        #expect(abs(lhs.width - rhs.width) < tolerance)
        #expect(abs(lhs.height - rhs.height) < tolerance)
    }

}
