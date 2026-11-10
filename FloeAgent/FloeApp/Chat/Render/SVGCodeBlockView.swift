// FloeApp — SVG code-fence preview with source fallback.
//
// SPDX-License-Identifier: MPL-2.0
//
// A fenced ```svg block renders its picture through the SAME bounded,
// JavaScript-disabled renderer that the image.renderSVG tool encodes
// with. The source always stays viewable and copyable, and any
// rejection, cancellation or capacity refusal falls back to the plain
// source with one concise bilingual line. Streaming partial documents
// stay on the source surface — validation only succeeds on a complete
// document, so no half-fence ever loads a page, and identical bytes
// replay from the shared preview cache instead of reloading.
//
// Cancellation is real: each render attempt owns a fresh
// CancellationToken (the renderer polls the native flag) plus a
// generation counter that fences every late callback. The preview
// lives only in RAM: sharing hands the exact rendered bytes to
// ShareLink via a PNG Transferable; no temp file is written unless the
// user explicitly shares, and the share payload itself stays in
// memory.

#if canImport(SwiftUI) && canImport(UIKit) && canImport(FloeImages)
import SwiftUI
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import FloeImages
import FloeTools

/// One fenced SVG block: live preview when the source validates,
/// the full code surface otherwise.
struct SVGCodeBlockView: View {
    /// Fence info-string language (kept for the header tag).
    let language: String?
    /// Verbatim code content; never inline-parsed.
    let code: String

    @State private var phase: Phase = .checking
    @State private var didCopy = false
    /// Source stays reachable under the preview; toggling never drops
    /// the rendered bytes (reverse toggle shows the picture again).
    @State private var sourceExpanded = false
    /// Per-render generation: cancelling or new tokens bump it, and a
    /// stale completion is fenced before it may touch the surface.
    @State private var generation = 0
    @State private var renderToken: CancellationToken?

    enum Phase: Equatable {
        /// Not yet validated (first pass for these exact bytes).
        case checking
        /// Still streaming / not a complete valid document: source only.
        case sourceOnly
        /// Valid document waiting for its bounded render slot.
        case rendering
        /// Rendered PNG shown; `width`×`height` are real pixels.
        case preview(Data, width: Int, height: Int)
        /// Valid document but rendering failed: source + reason.
        case failed(reason: String)

        static func == (lhs: Phase, rhs: Phase) -> Bool {
            switch (lhs, rhs) {
            case (.checking, .checking), (.sourceOnly, .sourceOnly), (.rendering, .rendering):
                return true
            case (.preview(let a, let w1, let h1), .preview(let b, let w2, let h2)):
                return a == b && w1 == w2 && h1 == h2
            case (.failed(let a), .failed(let b)):
                return a == b
            default:
                return false
            }
        }
    }

    private static let previewMaxEdge = 960
    private static let sourceMaxHeight: CGFloat = 260

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            bodySurface
        }
        .background(FloeTheme.groupedSurface, in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat.svgBlock")
        // Keyed on the EXACT bytes: each new token
        // replaces the task, the stale preview is fenced before the new
        // validation, and repeated identical content resolves from the
        // shared preview cache instead of reloading the page.
        .task(id: code) {
            await renderIfNeeded(key: RenderKey(code: code, generation: generation))
        }
        .onDisappear {
            renderToken?.cancel()
            generation += 1
        }
    }

    struct RenderKey: Equatable, Hashable {
        let code: String
        let generation: Int
    }

    @ViewBuilder
    private var bodySurface: some View {
        switch phase {
        case .preview(let data, let width, let height):
            VStack(alignment: .leading, spacing: 6) {
                if !sourceExpanded, let image = UIImage(data: data) {
                    Image(uiImage: image)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity)
                        .frame(maxHeight: 420)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .accessibilityLabel(Text(ChatBilingualCatalog.localized(
                            key: "chat.svg_preview.label",
                            en: "SVG preview",
                            zh: "SVG 预览")))
                        .accessibilityIdentifier("chat.svgPreview.image")
                }
                controls(previewData: data, width: width, height: height)
                if sourceExpanded {
                    sourceSurface(maxHeight: Self.sourceMaxHeight)
                }
            }
            .padding(10)
        case .rendering:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(ChatBilingualCatalog.localized(
                    key: "chat.svg_preview.rendering",
                    en: "Rendering preview…",
                    zh: "正在渲染预览…"))
                    .font(FloeTheme.Typography.metadata)
                    .foregroundStyle(.secondary)
                Button {
                    cancelRender()
                } label: {
                    Text(ChatBilingualCatalog.localized(
                        key: "chat.svg_preview.cancel",
                        en: "Cancel",
                        zh: "取消"))
                        .frame(minWidth: 44, minHeight: FloeTheme.minimumTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .font(FloeTheme.Typography.metadata)
                .foregroundStyle(FloeTheme.primary)
                .accessibilityIdentifier("chat.svgPreview.cancel")
                Spacer(minLength: 0)
            }
            .padding(10)
            .accessibilityIdentifier("chat.svgPreview.rendering")
            sourceSurface(maxHeight: Self.sourceMaxHeight)
        case .checking, .sourceOnly:
            sourceSurface()
        case .failed(let reason):
            VStack(alignment: .leading, spacing: 6) {
                Label(reason, systemImage: "exclamationmark.triangle")
                    .font(FloeTheme.Typography.metadata)
                    .foregroundStyle(FloeTheme.destructive)
                    .lineLimit(2)
                sourceSurface(maxHeight: Self.sourceMaxHeight)
            }
            .accessibilityIdentifier("chat.svgPreview.fallback")
        }
    }

    @ViewBuilder
    private func controls(previewData: Data, width: Int, height: Int) -> some View {
        HStack(spacing: 6) {
            Text("\(width)×\(height)")
                .font(FloeTheme.Typography.metadata)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("chat.svgPreview.size")
                .accessibilityLabel("\(width)×\(height)")
            Spacer(minLength: 8)
            Button {
                sourceExpanded.toggle()
            } label: {
                Label(
                    sourceExpanded
                        ? ChatBilingualCatalog.localized(
                            key: "chat.svg_preview.hide_source",
                            en: "Show picture",
                            zh: "查看图片")
                        : ChatBilingualCatalog.localized(
                            key: "chat.svg_preview.show_source",
                            en: "Show source",
                            zh: "查看源码"),
                    systemImage: sourceExpanded ? "picture" : "chevron.left.forwardslash.chevron.right")
                    .font(FloeTheme.Typography.metadata)
                    .frame(minHeight: FloeTheme.minimumTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("chat.svgPreview.sourceToggle")
            ShareLink(
                item: SVGPreviewShareItem(data: previewData),
                preview: SharePreview(
                    "SVG",
                    image: UIImage(data: previewData).map { Image(uiImage: $0) } ?? Image(systemName: "picture"))
            ) {
                Label(
                    ChatBilingualCatalog.localized(
                        key: "chat.svg_preview.share_png",
                        en: "Share PNG",
                        zh: "分享 PNG"),
                    systemImage: "square.and.arrow.up")
                    .font(FloeTheme.Typography.metadata)
                    .frame(minHeight: FloeTheme.minimumTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("chat.svgPreview.share")
        }
    }

    /// The unchanged code typography: horizontally scrollable,
    /// selectable, never inline-parsed. When height-bounded the long
    /// sources scroll on both axes inside the message surface.
    private func sourceSurface(maxHeight: CGFloat? = nil) -> some View {
        ScrollView([.horizontal, .vertical], showsIndicators: true) {
            Text(code)
                .font(FloeTheme.Typography.evidence)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .padding(10)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("chat.svgPreview.sourceText")
        }
        .frame(maxHeight: maxHeight ?? .infinity, alignment: .leading)
    }

    private var header: some View {
        HStack(spacing: 8) {
            if let language, !language.isEmpty {
                Text(language)
                    .font(FloeTheme.Typography.metadata)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(
                        String(localized: "codeblock.language") + " " + language
                    )
            }
            Spacer()
            Button {
                UIPasteboard.general.string = code
                didCopy = true
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    didCopy = false
                }
            } label: {
                Label(
                    didCopy
                        ? LocalizedStringKey("action.copied")
                        : LocalizedStringKey("action.copy"),
                    systemImage: didCopy ? "checkmark" : "doc.on.doc")
                    .font(FloeTheme.Typography.metadata)
                    .foregroundStyle(didCopy ? FloeTheme.success : FloeTheme.primary)
            }
            .buttonStyle(.plain)
            .frame(minWidth: FloeTheme.minimumTarget, minHeight: FloeTheme.minimumTarget)
            .accessibilityLabel(
                didCopy
                    ? LocalizedStringKey("action.copied")
                    : LocalizedStringKey("action.copy"))
            .accessibilityIdentifier("chat.svgPreview.copy")
        }
        .padding(.leading, 10)
        .padding(.trailing, 4)
    }

    // MARK: - Render pipeline

    /// Explicit user cancellation: signal the NATIVE renderer token,
    /// bump the generation so any late completion is fenced, and show
    /// the source. The bytes stay cached for the same fence content.
    @MainActor
    private func cancelRender() {
        renderToken?.cancel()
        renderToken = nil
        generation += 1
        phase = .sourceOnly
    }

    @MainActor
    private func renderIfNeeded(key: RenderKey) async {
        // Any previous in-flight render for older bytes is fenced.
        renderToken?.cancel()
        let token = CancellationToken()
        renderToken = token
        let bytes = key.code.utf8.count
        // Guard the cheap ceilings before touching the validator so a
        // mid-stream tail of a huge fence never queues work.
        guard bytes <= SVGSafetyLimits.maxSourceBytes else {
            phase = .failed(reason: ChatBilingualCatalog.localized(
                key: "chat.svg_preview.too_large",
                en: "SVG is too large to preview; source is shown.",
                zh: "SVG 过大，无法预览；已显示源码。"))
            return
        }
        phase = .checking
        let document: ValidatedSVGDocument
        do {
            document = try SVGDocumentValidator.validate(key.code)
        } catch let rejection as SVGDocumentRejection {
            // Partial streaming fences land here every token until the
            // fence closes: stay on the plain source surface, silent.
            if isLikelyIncomplete(rejection) {
                phase = .sourceOnly
            } else {
                phase = .failed(reason: Self.message(for: rejection))
            }
            return
        } catch {
            phase = .failed(reason: ChatBilingualCatalog.localized(
                key: "chat.svg_preview.invalid",
                en: "This SVG is not safe or complete; source is shown.",
                zh: "此 SVG 不安全或不完整；已显示源码。"))
            return
        }
        phase = .rendering
        do {
            let png = try await SVGRendering.previewPNG(
                for: document, maxEdge: Self.previewMaxEdge,
                cancellation: token)
            // FENCE: only the current generation may paint.
            guard generation == key.generation, renderToken === token,
                  !Task.isCancelled, !token.isCancelled,
                  case .rendering = phase else { return }
            guard let size = SVGPreviewGeometry.pixelSize(pngData: png) else {
                phase = .failed(reason: ChatBilingualCatalog.localized(
                    key: "chat.svg_preview.invalid_output",
                    en: "The preview could not be verified; source is shown.",
                    zh: "预览无法验证；已显示源码。"))
                return
            }
            phase = .preview(png, width: size.width, height: size.height)
        } catch is CancellationError {
            guard generation == key.generation else { return }
        } catch let error as SVGRenderingError {
            guard generation == key.generation, renderToken === token,
                  !token.isCancelled, case .rendering = phase else { return }
            if case .cancelled = error { return }
            phase = .failed(reason: Self.message(for: error))
        } catch {
            guard generation == key.generation, renderToken === token,
                  case .rendering = phase else { return }
            phase = .failed(reason: ChatBilingualCatalog.localized(
                key: "chat.svg_preview.render_failed",
                en: "The preview failed; source is shown.",
                zh: "预览失败；已显示源码。"))
        }
        if renderToken === token {
            renderToken = nil
        }
    }

    /// Partial streaming fences: a missing root close or an unfinished
    /// trailing token is EXPECTED mid-stream and must not show errors.
    private func isLikelyIncomplete(_ rejection: SVGDocumentRejection) -> Bool {
        switch rejection {
        case .missingRootSVG, .notWellFormed, .tooLarge:
            return true
        default:
            return false
        }
    }

    static func message(for rejection: SVGDocumentRejection) -> String {
        switch rejection {
        case .unknownElement, .unknownNamespace,
             .processingInstruction, .doctypeOrEntityDeclaration, .eventAttribute:
            return ChatBilingualCatalog.localized(
                key: "chat.svg_preview.unsafe",
                en: "This SVG contains executable or external content; source is shown.",
                zh: "此 SVG 包含可执行或外部内容；已显示源码。")
        case .unsafeReference:
            return ChatBilingualCatalog.localized(
                key: "chat.svg_preview.external",
                en: "This SVG references an external resource; source is shown.",
                zh: "此 SVG 引用外部资源；已显示源码。")
        case .unsafeCSS:
            return ChatBilingualCatalog.localized(
                key: "chat.svg_preview.css",
                en: "This SVG carries unsafe styles; source is shown.",
                zh: "此 SVG 样式不安全；已显示源码。")
        case .tooManyElements, .tooDeep, .duplicateID, .referenceGraph:
            return ChatBilingualCatalog.localized(
                key: "chat.svg_preview.complex",
                en: "This SVG is too complex to preview safely; source is shown.",
                zh: "此 SVG 过于复杂，无法安全预览；已显示源码。")
        case .invalidDimensions:
            return ChatBilingualCatalog.localized(
                key: "chat.svg_preview.dimensions",
                en: "This SVG has invalid size declarations; source is shown.",
                zh: "此 SVG 尺寸声明无效；已显示源码。")
        case .unknownAttribute:
            return ChatBilingualCatalog.localized(
                key: "chat.svg_preview.attribute",
                en: "This SVG uses unsupported attributes; source is shown.",
                zh: "此 SVG 包含不支持的属性；已显示源码。")
        default:
            return ChatBilingualCatalog.localized(
                key: "chat.svg_preview.invalid",
                en: "This SVG is not safe or complete; source is shown.",
                zh: "此 SVG 不安全或不完整；已显示源码。")
        }
    }

    static func message(for error: SVGRenderingError) -> String {
        switch error {
        case .cancelled:
            return ChatBilingualCatalog.localized(
                key: "chat.svg_preview.cancelled",
                en: "Preview cancelled; source is shown.",
                zh: "预览已取消；已显示源码。")
        case .timedOut, .busy:
            return ChatBilingualCatalog.localized(
                key: "chat.svg_preview.busy",
                en: "The SVG renderer is busy or timed out; source is shown.",
                zh: "SVG 渲染繁忙或超时；已显示源码。")
        default:
            return ChatBilingualCatalog.localized(
                key: "chat.svg_preview.render_failed",
                en: "The preview failed; source is shown.",
                zh: "预览失败；已显示源码。")
        }
    }
}

/// In-memory PNG share payload: the exact bytes the shared renderer
/// produced. Nothing touches disk for a mere preview.
struct SVGPreviewShareItem: Transferable {
    let data: Data

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .png) { item in
            item.data
        }
    }
}

/// Small non-View helpers so the surface stays free of hidden IO.
enum SVGPreviewGeometry {
    static func pixelSize(pngData: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(pngData as CFData, nil),
              CGImageSourceGetStatus(source) == .statusComplete,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [String: Any],
              let width = properties[kCGImagePropertyPixelWidth as String] as? Int,
              let height = properties[kCGImagePropertyPixelHeight as String] as? Int,
              width > 0, height > 0 else { return nil }
        return (width, height)
    }
}
#endif
