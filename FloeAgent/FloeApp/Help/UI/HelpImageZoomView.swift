// SPDX-License-Identifier: MPL-2.0
#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import UIKit
import ImageIO

struct HelpReaderImage: Identifiable {
    let path: String
    let data: Data
    let title: String
    var id: String { path }
}

struct HelpImageZoomView: View {
    @Environment(\.dismiss) private var dismiss
    let item: HelpReaderImage
    let copy: HelpCopy

    var body: some View {
        NavigationStack {
            HelpZoomingImage(data: item.data, label: item.title.isEmpty ? copy.enlargeImage : item.title)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle(item.title.isEmpty ? copy.enlargeImage : item.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button(copy.done) { dismiss() } } }
        }
    }
}

private struct HelpZoomingImage: UIViewRepresentable {
    let data: Data
    let label: String

    func makeUIView(context: Context) -> HelpImageScrollView { HelpImageScrollView(data: data, label: label) }
    func updateUIView(_ view: HelpImageScrollView, context: Context) {}
}

private final class HelpImageScrollView: UIScrollView, UIScrollViewDelegate {
    private let imageView: UIImageView
    private var previousBounds = CGSize.zero

    init(data: Data, label: String) {
        let source = CGImageSourceCreateWithData(data as CFData, nil)
        let thumbnail = source.flatMap { CGImageSourceCreateThumbnailAtIndex($0, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 4096,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary) }
        imageView = UIImageView(image: thumbnail.map { UIImage(cgImage: $0) })
        super.init(frame: .zero)
        delegate = self
        backgroundColor = .systemBackground
        maximumZoomScale = 6
        minimumZoomScale = 1
        bouncesZoom = true
        imageView.contentMode = .scaleAspectFit
        imageView.isAccessibilityElement = true
        imageView.accessibilityLabel = label
        addSubview(imageView)
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(toggleZoom(_:)))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)
    }

    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds.size != previousBounds {
            previousBounds = bounds.size
            zoomScale = 1
            imageView.frame = CGRect(origin: .zero, size: bounds.size)
            contentSize = bounds.size
        }
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    @objc private func toggleZoom(_ recognizer: UITapGestureRecognizer) {
        if zoomScale > 1.01 { setZoomScale(1, animated: true); return }
        let point = recognizer.location(in: imageView)
        let size = CGSize(width: bounds.width / 2.5, height: bounds.height / 2.5)
        zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2,
                       width: size.width, height: size.height), animated: true)
    }
}
#endif
