// FloeApp — native Skill Hub showcase media views (lane file).
//
// SPDX-License-Identifier: MPL-2.0
//
// Presentation-only SwiftUI wrappers over the service-owned,
// publication-pinned media center. Rules these views enforce:
//
//   * fallback first: every surface renders the honest bundled artwork or
//     system glyph immediately and overlays the real cover when it has been
//     fetched and validated — a missing, failed or unsafe image NEVER leaves
//     a blank reserved box and NEVER blocks or disables a verified CTA;
//   * demand-driven: an image is requested only when its card/detail is on
//     screen and the showcase document actually declares it;
//   * media identity is always the same immutable publication commit Y as
//     the signed catalog — nothing here reads a mutable ref or a URL;
//   * SVG and any unknown format is never rendered natively (the center
//     already refuses it; these views additionally never even demand it);
//   * captions and credits are shown exactly as authored — a screenshot or
//     example is presented as what it says it is, never as proof that the
//     app performed anything.

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import FloeSkills

/// Shelf-level composition decisions for media, mirroring the existing
/// one-decision-per-shelf rule so sibling rows never branch per item.
enum SkillHubMediaLayout {
    /// A compact per-skill thumbnail replaces the system glyph tile only
    /// while the shelf's effective column width leaves room next to the
    /// title, summary and CTA. Accessibility text sizes keep the known glyph.
    static func prefersThumbnail(columnWidth: CGFloat, isAccessibilityText: Bool) -> Bool {
        !isAccessibilityText && columnWidth >= 240
    }

    /// Detail cover bands never reserve more than this height, so a tall
    /// natural aspect cannot push the verified actions off-screen.
    static let maximumDetailCoverHeight: CGFloat = 320
    static let detailCoverPlaceholderRatio: CGFloat = 16.0 / 9.0
}

extension SkillHubShowcase.MediaRef {
    /// Path only when the native renderer supports the declared format.
    var renderablePath: String? { isNativelyRenderable ? path : nil }
}

extension SkillHubShowcase.MediaRef: Identifiable {
    public var id: String { path }
}

/// Loads ONE publication-pinned image through the shared media center and
/// keeps the caller's fallback visible until validated bytes exist.
struct SkillHubPublicationImage<Loaded: View, Fallback: View>: View {
    let ref: SkillHubShowcase.MediaRef?
    let commit: String?
    let media: SkillHubMediaCenter
    @ViewBuilder let loaded: (UIImage) -> Loaded
    @ViewBuilder let fallback: () -> Fallback
    @State private var image: UIImage?

    private var demandKey: String { "\(commit ?? "")|\(ref?.renderablePath ?? "")" }

    var body: some View {
        Group {
            if let image {
                loaded(image)
            } else {
                fallback()
            }
        }
        .task(id: demandKey) {
            let key = demandKey
            // Never hold a previous demand's bitmap while a new identity
            // loads: the row shows its honest fallback, not a stale
            // publication's image. Shared caches stay service-owned.
            image = nil
            guard let commit, let path = ref?.renderablePath else {
                return
            }
            let loaded = await media.image(path: path, commit: commit)
            guard !Task.isCancelled, key == demandKey else { return }
            image = loaded
        }
        .onDisappear {
            // Release the row-local reference when the card scrolls away;
            // the LRU/disk caches (and any shared transfer) are the
            // service's to bound — never purge them from a view.
            image = nil
        }
    }
}

/// Compact square thumbnail for directory rows: the showcase cover when the
/// publication declares one; otherwise the SAME frame paints the existing
/// bundled category JPEG (aspect-fill), so ordinary rows visibly carry a
/// picture even offline or for SVG-only offers. The system glyph remains
/// only as the genuine missing-bundled-asset emergency. The frame is
/// identical in every state, so shelf row heights never move.
struct SkillHubShowcaseThumbnail: View {
    let ref: SkillHubShowcase.MediaRef?
    let commit: String?
    let media: SkillHubMediaCenter
    let category: SkillHubCategory
    let systemImage: String
    let skillID: String
    var side: CGFloat = 44

    var body: some View {
        SkillHubPublicationImage(ref: ref, commit: commit, media: media) { image in
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: side, height: side)
                .clipped()
                .accessibilityLabel(ref?.alt?.value() ?? "")
        } fallback: {
            if UIImage(named: category.artworkName) != nil {
                Image(category.artworkName)
                    .resizable()
                    .scaledToFill()
                    .frame(width: side, height: side)
                    .clipped()
                    .accessibilityHidden(true)
            } else {
                Image(systemName: systemImage)
                    .font(.title2)
                    .foregroundStyle(category.tint)
                    .frame(width: side, height: side)
                    .background(category.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 11))
                    .accessibilityHidden(true)
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: 11))
        .contentShape(RoundedRectangle(cornerRadius: 11))
        // The loaded cover is aspect-filled and clipped to the compact tile.
        // Without one explicit element, the accessibility frame follows the
        // unclipped image bounds (a 4:3 cover reports 59×44 for a 44×44 tile)
        // and can overlap the row text for VoiceOver and hit testing. One
        // element over the SAME square frame keeps the reported control
        // proportional to the visible compact media.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(ref?.alt?.value() ?? "")
        .accessibilityIdentifier("skills.thumbnail.\(skillID)")
    }
}

/// Featured-card artwork band (16:9). The bundled category JPEG stays as the
/// immediate base; the real per-skill cover overlays it once validated, so
/// the card never repaints into a blank box mid-scroll.
struct SkillHubFeaturedCover: View {
    let ref: SkillHubShowcase.MediaRef?
    let commit: String?
    let media: SkillHubMediaCenter
    let artworkName: String
    let skillID: String

    var body: some View {
        GeometryReader { artwork in
            ZStack {
                Image(artworkName)
                    .resizable()
                    .scaledToFill()
                    .frame(width: artwork.size.width, height: artwork.size.height)
                    .clipped()
                    .accessibilityHidden(true)
                SkillHubPublicationImage(ref: ref, commit: commit, media: media) { image in
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: artwork.size.width, height: artwork.size.height)
                        .clipped()
                        .accessibilityLabel(ref?.alt?.value() ?? "")
                } fallback: {
                    Color.clear
                }
            }
            .frame(width: artwork.size.width, height: artwork.size.height)
        }
        .accessibilityHidden(true)
        .accessibilityIdentifier("skills.featured.cover.\(skillID)")
    }
}

/// The detail-page hero cover. Shows the verified natural aspect of the real
/// cover when present; before/without it the bundled category artwork fills
/// the same rounded band so the page never reserves a giant blank box. The
/// band exposes the authored alternative text, or the category for bundled
/// artwork, as one image with the same bounds as the visible band.
struct SkillHubDetailCover: View {
    let ref: SkillHubShowcase.MediaRef?
    let commit: String?
    let media: SkillHubMediaCenter
    let category: SkillHubCategory
    let skillID: String

    /// Bundled fallback band height: modest on purpose — the card never
    /// reserves a giant blank box while the real cover is absent or loading.
    private let placeholderBandHeight: CGFloat = 170

    private var coverAccessibilityLabel: Text {
        if let alt = ref?.alt?.value(), !alt.isEmpty {
            return Text(verbatim: alt)
        }
        return Text(category.title)
    }

    var body: some View {
        SkillHubPublicationImage(ref: ref, commit: commit, media: media) { image in
            let ratio = image.size.height > 0
                ? image.size.width / image.size.height
                : SkillHubMediaLayout.detailCoverPlaceholderRatio
            Image(uiImage: image)
                .resizable()
                .aspectRatio(ratio, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .frame(maxHeight: SkillHubMediaLayout.maximumDetailCoverHeight)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .accessibilityLabel(ref?.alt?.value() ?? "")
        } fallback: {
            GeometryReader { band in
                Image(category.artworkName)
                    .resizable()
                    .scaledToFill()
                    .frame(width: band.size.width, height: band.size.height)
                    .clipped()
                    .accessibilityHidden(true)
            }
            .frame(height: placeholderBandHeight)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(coverAccessibilityLabel)
        .accessibilityAddTraits(.isImage)
        .accessibilityIdentifier("skills.detail.cover.\(skillID)")
    }
}

/// The signed-publication gallery strip for one skill. Rendered only when the
/// showcase actually declares gallery media; a tap opens the truthful viewer
/// with the authored caption and credit. Thumbnails failing to load simply
/// keep their neutral placeholder — they never block anything else.
struct SkillHubGalleryStrip: View {
    let refs: [SkillHubShowcase.MediaRef]
    let commit: String?
    let media: SkillHubMediaCenter
    let skillID: String
    let category: SkillHubCategory
    @State private var selection: SkillHubShowcase.MediaRef?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(Array(refs.enumerated()), id: \.element.id) { index, ref in
                    Button { selection = ref } label: {
                        SkillHubPublicationImage(ref: ref, commit: commit, media: media) { image in
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFill()
                        } fallback: {
                            Rectangle()
                                .fill(category.tint.opacity(0.08))
                                .overlay {
                                    Image(systemName: "photo")
                                        .foregroundStyle(category.tint)
                                }
                        }
                        .frame(width: 124, height: 86)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(ref.alt?.value() ?? SkillHubCopy.galleryItemLabel(index: index + 1))
                    .accessibilityIdentifier("skills.gallery.item.\(skillID).\(index)")
                }
            }
            .padding(.vertical, 2)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("skills.gallery.\(skillID)")
        .sheet(item: $selection) { ref in
            SkillHubGalleryViewer(ref: ref, commit: commit, media: media)
        }
    }
}

/// Full-size viewer for one gallery item: the image exactly as published,
/// its truthful caption and its credit line. No controls, no actions.
struct SkillHubGalleryViewer: View {
    let ref: SkillHubShowcase.MediaRef?
    let commit: String?
    let media: SkillHubMediaCenter
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                SkillHubPublicationImage(ref: ref, commit: commit, media: media) { image in
                    let ratio = image.size.height > 0 ? image.size.width / image.size.height : 1
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(ratio, contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .accessibilityLabel(ref?.alt?.value() ?? "")
                } fallback: {
                    VStack(spacing: 8) {
                        Image(systemName: "photo")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        Text(SkillHubCopy.imageUnavailable)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityHidden(true)
                }
                if let caption = ref?.caption?.value(), !caption.isEmpty {
                    Text(caption)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("skills.gallery.caption")
                }
                if let credit = ref?.credit.value(), !credit.isEmpty {
                    Text("\(SkillHubCopy.mediaCreditLabel): \(credit)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("skills.gallery.credit")
                }
            }
            .padding(16)
            .navigationTitle(SkillHubCopy.galleryTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(SkillHubCopy.galleryClose) { dismiss() }
                        .accessibilityIdentifier("skills.gallery.close")
                }
            }
        }
    }
}

/// Bilingual presentation copy for the media surfaces, following the
/// existing SkillHubCopy pattern so the English and Simplified Chinese
/// strings ship with the views; the catalog merge list is in the handoff.
extension SkillHubCopy {
    static var galleryTitle: String { localized("skills.hub.gallery", en: "Gallery", zh: "图集") }
    static var mediaCreditLabel: String { localized("skills.hub.gallery.credit", en: "Credit", zh: "来源") }
    static var galleryClose: String { localized("skills.hub.gallery.close", en: "Close", zh: "关闭") }
    static var imageUnavailable: String {
        localized("skills.hub.gallery.unavailable", en: "Image unavailable", zh: "图片暂不可用")
    }
    static func galleryItemLabel(index: Int) -> String {
        "\(localized("skills.hub.gallery.item_word", en: "Image", zh: "图片")) \(index)"
    }
}
#endif
