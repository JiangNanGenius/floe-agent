#if canImport(UIKit)
import SwiftUI
import ImageIO
import UniformTypeIdentifiers
@preconcurrency import ZLImageEditor

/// Shared local image workbench. The host owns asset registration and canvas placement.
@MainActor
struct FloeImageEditorView: View {
    let sourceURL: URL?
    let onSave: (Data) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var original: UIImage?
    @State private var edited: UIImage?
    @State private var editModel: ZLEditImageModel?
    @State private var saving = false
    @State private var error: String?

    var body: some View {
        ZStack {
            if let original {
                FloeImageEditorController(image: original, editModel: editModel) { image, model in
                    edited = image
                    editModel = model
                    Task { await save() }
                } onCancel: {
                    dismiss()
                }
                .ignoresSafeArea()
                .allowsHitTesting(!saving)
            } else {
                ContentUnavailableView {
                    Label("图像工作台", systemImage: "photo")
                } description: {
                    Text(error ?? "正在读取本机素材…")
                } actions: {
                    Button("关闭") { dismiss() }
                }
            }
            if saving {
                ProgressView("正在保存副本…")
                    .padding(24)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
        }
        .interactiveDismissDisabled(saving)
        .task {
            guard original == nil else { return }
            do {
                guard let sourceURL else { throw ImageEditorFileError.missingSource }
                original = try ImageEditorFiles.load(sourceURL)
            } catch { self.error = error.localizedDescription }
        }
        .alert("图片处理未完成", isPresented: Binding(
            get: { error != nil }, set: { if !$0 { error = nil } }
        )) {
            if edited != nil {
                Button("重试保存") { Task { await save() } }
            }
            Button("返回", role: .cancel) { error = nil }
        } message: { Text(error ?? "") }
    }

    private func save() async {
        guard let edited, !saving else { return }
        saving = true
        defer { saving = false }
        do {
            let data = try ImageEditorFiles.verifiedPNG(edited)
            try await onSave(data)
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

@MainActor
struct FloeImageEditorController: UIViewControllerRepresentable {
    let image: UIImage
    let editModel: ZLEditImageModel?
    let onFinish: (UIImage, ZLEditImageModel?) -> Void
    let onCancel: () -> Void

    func makeUIViewController(context: Context) -> ZLEditImageViewController {
        // All Floe hosts use the same configuration; no per-document global overrides.
        ZLImageEditorConfiguration.default().tools = [.draw, .clip, .textSticker, .mosaic, .filter, .adjust]
        ZLImageEditorUIConfiguration.default().toolTitleTintColor = .label
        ZLImageEditorUIConfiguration.default().toolTitleNormalColor = .secondaryLabel
        ZLImageEditorConfiguration.default().clipRatios = [.custom, .wh1x1, .wh4x3, .wh3x4, .wh16x9, .wh9x16]
        let controller = ZLEditImageViewController(image: image, editModel: editModel)
        controller.automaticallyDismiss = false
        controller.doneBtn.accessibilityIdentifier = "image.editor.done"
        controller.cancelBtn.accessibilityIdentifier = "image.editor.cancel"
        controller.editFinishBlock = onFinish
        controller.cancelBlock = onCancel
        return controller
    }

    func updateUIViewController(_ controller: ZLEditImageViewController, context: Context) {}
}

enum ImageEditorFileError: LocalizedError {
    case missingSource, invalidImage, tooLarge, invalidOutput
    var errorDescription: String? {
        switch self {
        case .missingSource: "素材尚未下载到本机。"
        case .invalidImage: "无法读取这份图片。"
        case .tooLarge: "图片超过当前编辑上限（2400 万像素或单边 16384 像素），请先缩小副本。"
        case .invalidOutput: "导出的图片未通过重新读取校验，请重试。"
        }
    }
}

@MainActor
enum ImageEditorFiles {
    static func load(_ url: URL) throws -> UIImage {
        guard url.isFileURL,
              (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
              let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else { throw ImageEditorFileError.invalidImage }
        guard width <= 16_384, height <= 16_384, width * height <= 24_000_000 else {
            throw ImageEditorFileError.tooLarge
        }
        // Apply EXIF orientation once; never silently downsample the user's original.
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(width, height)
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw ImageEditorFileError.invalidImage
        }
        return UIImage(cgImage: image)
    }

    static func verifiedPNG(_ image: UIImage) throws -> Data {
        guard let pixels = image.cgImage, let data = image.pngData(),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetType(source) as String? == UTType.png.identifier,
              let decoded = CGImageSourceCreateImageAtIndex(source, 0, nil),
              decoded.width == pixels.width, decoded.height == pixels.height else {
            throw ImageEditorFileError.invalidOutput
        }
        return data
    }
}
#endif
