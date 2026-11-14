# README installation buttons

The current README row has three entries: App Store, TestFlight, and a shared Self-signing stores entry for Feather and AltStore. The shared entry opens the existing source page without selecting a signing client in advance. English and Chinese combined buttons use both original channel icons. All buttons share a 180 × 70 canvas, navy surface, border and typography, displayed at 144 × 56 with vertical breathing room when wrapped.

Channel icons are the original upstream artwork, embedded without recolouring or raster changes so the SVG has no remote image dependency:

- App Store: [Apple Developer icon](https://developer.apple.com/assets/elements/icons/app-store/app-store-128x128_2x.png).
- TestFlight: [Apple's TestFlight listing](https://apps.apple.com/app/testflight/id899247664), artwork returned by the public Apple lookup endpoint.
- Feather: [upstream icon](https://github.com/claration/feather/blob/v1.x/iOS/Resources/Icons/Main/Mac@3x.png), linked by the upstream app source.
- AltStore Classic: [upstream icon](https://github.com/altstoreio/AltStore/blob/marketplace/AltStore/Resources/Icons.xcassets/Classic/Original.appiconset/Group%2023_180.png); [press kit](https://faq.altstore.io/about-us/press-kit).

Channel names and artwork belong to their respective owners. The button shell is Floe project artwork; it does not change upstream ownership or licenses. This folder is used by the repository README, not by an App installation package. The older badge assets are retained for existing references.
