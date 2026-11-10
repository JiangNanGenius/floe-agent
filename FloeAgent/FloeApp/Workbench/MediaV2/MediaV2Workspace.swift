// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import AVKit
import SwiftUI
import UniformTypeIdentifiers
import FloeWorkbench

/// The accepted integrated workspace: tools, layers/assets, the actual
/// canvas, properties/assistant and a multi-track video timeline.
struct MediaV2Workspace: View {
    @Bindable var session: MediaV2Session
    var onAssistant: (() -> Void)? = nil
    var onExported: ((URL) -> Void)? = nil
    var onSaveToSource: ((ImageExportOptions) async throws -> Void)? = nil
    var onMakeVariant: ((ImageExportOptions) async throws -> Void)? = nil
    @EnvironmentObject private var environment: AppEnvironment
    @Environment(\.editorCanvasOwnsTextInput) private var ownsTextInput
    @State private var importing = false
    @State private var importingCaptions = false
    @State private var objectsVisible = true
    @State private var inspectorVisible = true
    @State private var compactPanel: String?
    @State private var audio: NativeCreativeAudioSession?
    @State private var text = ""
    @State private var number = 12.0
    @State private var property = "scale"
    @State private var paintColor: Color = .teal
    @State private var showingDiagnostic = false
    @State private var showingProviderSettings = false
    var body: some View {
        GeometryReader { geometry in
            let wide = geometry.size.width >= 1050
            VStack(spacing: 0) {
                toolbar(wide: wide)
                Divider()
                toolCategories
                Divider()
                HStack(alignment: .top, spacing: 0) {
                    toolRail
                    if wide && objectsVisible { objectPanel.frame(width: 190); Divider() }
                    VStack(spacing: 0) {
                        MediaV2Preview(session: session)
                        previewControls
                        if session.project.kind == .video { Divider(); MediaV2Timeline(session: session).frame(height: max(190, min(260, geometry.size.height * 0.32))) }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    if wide && inspectorVisible { Divider(); propertiesPanel.frame(width: 280) }
                }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top).clipped()
                Divider()
                status
            }.frame(width: geometry.size.width, height: geometry.size.height, alignment: .top).clipped()
        }
        .ignoresSafeArea(.keyboard, edges: ownsTextInput ? [] : .bottom)
        .background(Color(uiColor: .systemBackground))
        .fileImporter(isPresented: $importing, allowedContentTypes: importContentTypes) { result in
            switch result {
            case .success(let url):
                if importingCaptions { Task { do { try await session.importCaptions(url) } catch { session.diagnostic = error.localizedDescription } } }
                else { Task { await session.importFile(url) } }
            case .failure(let error): session.diagnostic = error.localizedDescription
            }
        }
        .sheet(isPresented: Binding(get: { compactPanel != nil }, set: { if !$0 { compactPanel = nil } })) {
            NavigationStack {
                Group { if compactPanel == "objects" { objectPanel } else { propertiesPanel } }
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button(WorkbenchText.t("完成", "Done")) { compactPanel = nil } } }
            }.presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showingDiagnostic) {
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        Text(session.diagnostic ?? "").textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        if session.exportError as? PreparedVideoError == .emptyTimeline {
                            Button(WorkbenchText.t("导入视频或图片", "Import video or images")) { showingDiagnostic = false; beginImport() }.frame(minHeight: 44)
                        }
                    }.padding()
                }.navigationTitle(WorkbenchText.t("操作详情", "Action details"))
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button(WorkbenchText.t("完成", "Done")) { showingDiagnostic = false } } }
            }.presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showingProviderSettings) { MediaV2ProviderConfigurationView() }
        .fullScreenCover(item:$session.compoundEditorRoute) { route in
            MediaV2CompoundEditor(rootSession:session,route:route,onAssistant:onAssistant)
        }
        .onDisappear { session.stopPlayback() }
        .onChange(of: session.tool) { _, tool in
            number = tool == "image.text" ? 72 : tool.contains("exposure") ? 0 : tool.contains("speed") ? 1 : tool.contains("white-balance") ? 6500 : tool.contains("opacity") || tool.contains("hsl") ? 1 : tool.contains("pip") ? 0.4 : 12
            if let layer = session.selectedLayer, case .text(let content) = layer.content { text = content.text }
        }
    }
    private func toolbar(wide: Bool) -> some View {
        HStack(spacing: 4) {
            MusicIconButton("sidebar.left", WorkbenchText.t("图层与素材", "Layers and assets")) {
                if wide { objectsVisible.toggle() } else { compactPanel = "objects" }
            }
            Divider().frame(height: 22).padding(.horizontal, 4)
            MusicIconButton("arrow.uturn.backward", WorkbenchText.t("撤销", "Undo")) { session.undo() }.disabled(!session.canUndo)
            MusicIconButton("arrow.uturn.forward", WorkbenchText.t("重做", "Redo")) { session.redo() }.disabled(!session.canRedo)
            Menu {
                if !wide { Button(WorkbenchText.t("导入素材", "Import media"), systemImage: "square.and.arrow.down") { beginImport() } }
                if session.project.kind == .image {
                    Button(WorkbenchText.t("绘画图层", "Drawing layer"), systemImage: "paintbrush") { session.addLayer(.strokes(.init()), name: WorkbenchText.t("绘图", "Drawing")) }
                    Button(WorkbenchText.t("文字", "Text"), systemImage: "character.cursor.ibeam") { run("image.text") }
                    Button(WorkbenchText.t("形状", "Shape"), systemImage: "square.on.circle") { run("image.shape") }
                    Button(WorkbenchText.t("编组", "Group"), systemImage: "folder") { run("image.group-layer") }
                } else {
                    Button(WorkbenchText.t("视频轨", "Video track")) { session.addTrack(.visual) }
                    Button(WorkbenchText.t("音频轨", "Audio track")) { session.addTrack(.audio) }
                    Button(WorkbenchText.t("字幕", "Caption")) { run("video.caption") }
                }
            } label: { Image(systemName: "plus").frame(width: 44, height: 44) }
            Divider().frame(height: 22).padding(.horizontal, 4)
            if wide { MusicIconButton("square.and.arrow.down", WorkbenchText.t("导入素材", "Import media")) { beginImport() } }
            Menu {
                Button(session.project.kind == .image ? WorkbenchText.t("导出 PNG", "Export PNG") : WorkbenchText.t("导出 MP4", "Export MP4")) { session.export() }
                Button(WorkbenchText.t("完整工程包", "Complete original")) { exchange(.original) }
                Button(WorkbenchText.t("引用工程包", "Referenced original")) { exchange(.references) }
                if session.project.kind == .image {
                    Button("OpenRaster (.ora)") { exchange(.ora) }
                    Button("Photoshop (.psd)") { exchange(.psd) }
                    if let onSaveToSource { Button(WorkbenchText.t("更新来源", "Update source")) { Task { do { try await onSaveToSource(.init(format: .png)) } catch { session.diagnostic = error.localizedDescription } } } }
                    if let onMakeVariant { Button(WorkbenchText.t("另存一版", "Make variant")) { Task { do { try await onMakeVariant(.init(format: .png)) } catch { session.diagnostic = error.localizedDescription } } } }
                } else { Button("OpenTimelineIO (.otio)") { exchange(.otio) } }
            } label: {
                if wide { Label(WorkbenchText.t("导出", "Export"), systemImage: "square.and.arrow.up").frame(minHeight: 44) }
                else { Image(systemName: "square.and.arrow.up").frame(width: 44, height: 44) }
            }.accessibilityLabel(WorkbenchText.t("导出", "Export")).disabled(session.rendering)
            Spacer(minLength: 8)
            if wide {
                Text(session.saving ? WorkbenchText.t("正在保存…", "Saving…") : WorkbenchText.t("已保存", "Saved"))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            MusicIconButton("sidebar.right", WorkbenchText.t("属性", "Properties")) {
                if wide { inspectorVisible.toggle() } else { compactPanel = "properties" }
            }
        }.padding(.horizontal, 10).background(Color(uiColor: .secondarySystemBackground))
    }
    private var toolCategories: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(categories, id: \.self) { category in
                    Menu {
                        ForEach(session.applicableTools.filter { $0.category == category }) { tool in
                            Button { session.tool = tool.id; inspectorVisible = true } label: {
                                Text(tool.localizedTitle(languageCode: WorkbenchText.isChinese ? "zh" : "en"))
                                if session.tool == tool.id { Image(systemName: "checkmark") }
                            }
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Text(categoryTitle(category)).font(.callout)
                            Image(systemName: "chevron.down").font(.caption2.weight(.semibold))
                        }.foregroundStyle(.primary).frame(minHeight: 44).padding(.horizontal, 10)
                            .background(session.applicableTools.first(where: { $0.id == session.tool })?.category == category ? Color.primary.opacity(0.07) : .clear,
                                        in: RoundedRectangle(cornerRadius: 6))
                    }
                }
            }.padding(.horizontal, 6)
        }.accessibilityIdentifier("media.v2.toolbox")
    }
    private var categories: [String] {
        var values: [String] = []
        for tool in session.applicableTools where !values.contains(tool.category) { values.append(tool.category) }
        return values
    }
    private func categoryTitle(_ category: String) -> String {
        let names: [String: (String, String)] = ["selection": ("选区", "Selection"), "paint": ("绘画", "Paint"), "mask": ("图层与蒙版", "Layers and masks"), "transform": ("几何与画布", "Geometry"), "vector": ("文字与路径", "Text and paths"), "repair": ("修复", "Retouch"), "adjust": ("调色", "Color"), "edit": ("剪辑", "Editing"), "composite": ("合成", "Compositing"), "animation": ("动画", "Animation"), "captions": ("字幕", "Captions"), "sound": ("声音", "Audio"), "video-color": ("调色", "Color")]
        let value = names[category] ?? (category, category)
        return WorkbenchText.t(value.0, value.1)
    }
    private var toolRail: some View {
        VStack(spacing: 2) {
            ForEach(railTools, id: \.0) { value in
                Button { session.tool = value.0 } label: {
                    Image(systemName: value.1).frame(width: 44, height: 44)
                        .background(session.tool == value.0 ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 5))
                }.buttonStyle(.plain).accessibilityLabel(value.2).help(value.2)
            }
            ColorPicker(WorkbenchText.t("颜色", "Color"), selection: $paintColor, supportsOpacity: false).labelsHidden().frame(width: 44, height: 44)
                .onChange(of: paintColor) { _, color in
                    var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
                    UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a)
                    session.colorHex = String(format: "#%02X%02X%02X", Int(r * 255), Int(g * 255), Int(b * 255))
                }
            Spacer()
        }.frame(width: 48).padding(.top, 4).overlay(alignment: .trailing) { Divider() }
    }
    private var railTools: [(String, String, String)] {
        session.project.kind == .image
            ? [("move", "cursorarrow", WorkbenchText.t("移动", "Move")), ("image.rectangle", "rectangle.dashed", WorkbenchText.t("选区", "Selection")), ("image.brush", "paintbrush.pointed", WorkbenchText.t("画笔", "Brush")), ("image.eraser", "eraser", WorkbenchText.t("橡皮", "Eraser")), ("image.crop", "crop", WorkbenchText.t("裁剪", "Crop")), ("image.pen", "point.topleft.down.to.point.bottomright.curvepath", WorkbenchText.t("钢笔", "Pen")), ("image.text", "character.cursor.ibeam", WorkbenchText.t("文字", "Text")), ("image.eyedropper", "eyedropper", WorkbenchText.t("吸管", "Eyedropper"))]
            : [("video.trim", "cursorarrow", WorkbenchText.t("剪辑", "Edit")), ("video.split", "scissors", WorkbenchText.t("分割", "Split")), ("video.video-transform", "arrow.up.left.and.down.right.and.arrow.up.right.and.down.left", WorkbenchText.t("变换", "Transform")), ("video.keyframes", "diamond", WorkbenchText.t("关键帧", "Keyframes")), ("video.caption", "captions.bubble", WorkbenchText.t("字幕", "Captions")), ("video.mix", "speaker.wave.2", WorkbenchText.t("混音", "Mix"))]
    }
    private var objectPanel: some View {
        VStack(spacing: 0) {
            HStack {
                Text(session.project.kind == .image ? WorkbenchText.t("图层", "Layers") : WorkbenchText.t("素材与轨道", "Assets and tracks")).font(.caption.weight(.semibold)).lineLimit(1)
                Spacer(minLength: 0)
                if session.project.kind == .image {
                    MusicIconButton(session.multipleLayerSelection ? "checkmark.circle.fill" : "checklist", WorkbenchText.t("多选图层", "Select multiple layers")) {
                        session.multipleLayerSelection.toggle(); session.selectedLayerIDs = session.selectedLayerID.map { [$0] } ?? []
                    }
                }
                Menu {
                    if session.project.kind == .image {
                        Button(WorkbenchText.t("绘画图层", "Drawing layer")) { session.addLayer(.strokes(.init()), name: WorkbenchText.t("绘图", "Drawing")) }
                        Button(WorkbenchText.t("编组所选图层", "Group selected layers")) { run("image.group-layer") }
                    } else {
                        Button(WorkbenchText.t("视频轨", "Video track")) { session.addTrack(.visual) }
                        Button(WorkbenchText.t("音频轨", "Audio track")) { session.addTrack(.audio) }
                        Button(WorkbenchText.t("字幕轨", "Caption track")) { session.addTrack(.caption) }
                    }
                    Button(WorkbenchText.t("导入素材", "Import media")) { beginImport() }
                } label: { Image(systemName: "plus").frame(width: 44, height: 44) }
            }.padding(.leading, 10)
            Divider()
            ScrollView {
                VStack(spacing: 2) {
                    if session.project.kind == .image {
                        ForEach(session.document.layers.reversed()) { layer in layerRow(layer) }
                    } else {
                        ForEach(session.document.trackGraph.tracks) { track in
                            HStack {
                                Button { session.select(track) } label: { Label(track.name, systemImage: track.kind == .audio ? "waveform" : track.kind == .caption ? "captions.bubble" : "film").font(.caption).lineLimit(1).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading) }
                                Button { session.submit([.updateTrackFlags(id: track.id, expectedRevision: track.revision, name: nil, isMuted: !track.isMuted, isLocked: nil, volume: nil)]) } label: { Image(systemName: track.isMuted ? "speaker.slash" : "speaker.wave.1").frame(width: 36, height: 44) }
                            }.padding(.horizontal, 8).background(session.selectedTrackID == track.id ? Color.accentColor.opacity(0.1) : .clear)
                            .contextMenu {
                                Button(track.isLocked ? WorkbenchText.t("解锁轨道", "Unlock track") : WorkbenchText.t("锁定轨道", "Lock track")) {
                                    session.submit([.updateTrackFlags(id: track.id, expectedRevision: track.revision, name: nil, isMuted: nil, isLocked: !track.isLocked, volume: nil)])
                                }
                                Button(WorkbenchText.t("删除空轨道", "Delete empty track"), role: .destructive) {
                                    session.submit([.removeTrack(id: track.id, expectedRevision: track.revision)])
                                }.disabled(!track.clips.isEmpty)
                            }
                        }
                    }
                    Divider().padding(.vertical, 8)
                    Text(WorkbenchText.t("工程素材", "Project assets")).font(.caption2).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10)
                    ForEach(session.document.assets) { asset in
                        HStack(spacing: 7) {
                            PersonalEditorAssetPreview(sourceID: "media:\(session.id):\(session.document.revision):\(asset.id)", title: asset.originalName) { pixels in
                                try await PersonalEditorPreviewRequests.mediaAsset(session: session, asset: asset, pixels: pixels)
                            }.frame(width: 64, height: 48).accessibilityIdentifier("media.asset.preview.\(asset.id.uuidString)")
                            Button { session.insertExistingAsset(asset) } label: {
                                HStack(spacing: 4) {
                                    Text(asset.originalName).font(.caption2).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                                    Image(systemName: "plus.circle").font(.caption)
                                }.frame(minHeight: 44)
                            }.buttonStyle(.plain).help(WorkbenchText.t("加入当前工程", "Insert into project"))
                        }.padding(.horizontal, 8).padding(.vertical, 3)
                    }
                }
            }
        }
    }
    private func layerRow(_ layer: MediaPreparedLayer) -> some View {
        HStack(spacing: 3) {
            Button { session.select(layer) } label: {
                HStack(spacing: 8) {
                    if session.multipleLayerSelection { Image(systemName: session.selectedLayerIDs.contains(layer.id) ? "checkmark.circle.fill" : "circle").frame(width: 18) }
                    Image(systemName: layer.contentKind == .text ? "character.cursor.ibeam" : layer.contentKind == .group ? "folder" : layer.contentKind == .strokes ? "paintbrush" : layer.contentKind == .vectorPaths ? "square.on.circle" : "photo").frame(width: 28, height: 34).background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 4))
                    VStack(alignment: .leading, spacing: 3) { Text(layer.name).lineLimit(1); if layer.isLocked { Image(systemName: "lock.fill").font(.caption2) } }.font(.caption)
                    Spacer(minLength: 0)
                }.frame(minHeight: 50)
            }.buttonStyle(.plain)
            Button { session.submit([.updateLayerFlags(id: layer.id, expectedRevision: layer.revision, name: nil, isVisible: !layer.isVisible, isLocked: nil, opacity: nil)]) } label: { Image(systemName: layer.isVisible ? "eye" : "eye.slash").frame(width: 34, height: 44) }.buttonStyle(.plain)
        }.padding(.leading, CGFloat(min(8, session.layerDepth(layer))) * 8).padding(.horizontal, 7)
            .background((session.multipleLayerSelection ? session.selectedLayerIDs.contains(layer.id) : session.selectedLayerID == layer.id) ? Color.accentColor.opacity(0.1) : .clear)
            .contextMenu {
                Button(layer.isLocked ? WorkbenchText.t("解锁", "Unlock") : WorkbenchText.t("锁定", "Lock")) { session.submit([.updateLayerFlags(id: layer.id, expectedRevision: layer.revision, name: nil, isVisible: nil, isLocked: !layer.isLocked, opacity: nil)]) }
                Button(WorkbenchText.t("复制图层", "Duplicate layer")) { objectAction("image.duplicate-layer", layer: layer) }
                if layer.contentKind == .group { Button(WorkbenchText.t("取消编组", "Ungroup")) { objectAction("image.group-layer", layer: layer, flag: false) } }
                Button(WorkbenchText.t("上移", "Move up")) { session.shiftLayer(layer, by: 1) }
                Button(WorkbenchText.t("下移", "Move down")) { session.shiftLayer(layer, by: -1) }
                Button(WorkbenchText.t("删除", "Delete"), role: .destructive) { session.submit([.removeLayer(id: layer.id, expectedRevision: layer.revision)]) }
            }
    }
    private var propertiesPanel: some View {
        VStack(spacing: 0) {
            HStack {
                Text(WorkbenchText.t("属性", "Properties")).font(.subheadline.weight(.semibold))
                Spacer()
                Button { inspectorVisible = false; compactPanel = nil } label: {
                    Image(systemName: "xmark").frame(width: 44, height: 44)
                }.buttonStyle(.plain).accessibilityLabel(WorkbenchText.t("收起属性", "Hide properties"))
            }.padding(.leading, 14)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    toolProperties
                    Divider()
                    if let layer = session.selectedLayer { layerProperties(layer) }
                    if let selected = session.selectedClip { clipProperties(track: selected.track, clip: selected.clip) }
                    if let file = session.exportedFile {
                        Divider()
                        ShareLink(item: file) { Label(WorkbenchText.t("分享已导出文件", "Share exported file"), systemImage: "square.and.arrow.up").frame(minHeight: 44) }
                        if let onExported { Button(WorkbenchText.t("返回此文件", "Return this file")) { onExported(file) }.frame(minHeight: 44) }
                    }
                }.padding(14)
            }
        }.accessibilityIdentifier("media.v2.inspector")
    }
    @ViewBuilder private var toolProperties: some View {
        let descriptor = session.applicableTools.first { $0.id == session.tool }
        Text(descriptor?.localizedTitle(languageCode: WorkbenchText.isChinese ? "zh" : "en") ?? WorkbenchText.t("移动", "Move")).font(.headline)
        if ["image.remove","image.content-fill"].contains(session.tool) {
            MediaV2ContentFillInspector(session:session,onImport:{beginImport()})
        } else if ["image.boolean","image.path-text","image.outline"].contains(session.tool) {
            MediaV2VectorTextInspector(session:session)
        } else if ["image.resize","image.canvas-size"].contains(session.tool) {
            MediaV2CanvasInspector(session:session)
        } else if ["image.inpaint","image.outpaint","video.transcribe","video.translate","video.voice-separate"].contains(session.tool) {
            MediaV2ProviderInspector(session:session,onImport:{beginImport()},onImportCaptions:{beginImport(captions:true)},onConfigure:{showingProviderSettings=true})
        } else if session.tool == "video.hdr" {
            MediaV2HDRInspector(session:session)
        } else if session.tool == "video.color-match" {
            MediaV2ColorMatchInspector(session:session,onImport:{beginImport()})
        } else if ["video.tracking","video.stabilize"].contains(session.tool) {
            MediaV2VideoMotionInspector(session:session,onImport:{beginImport()})
        } else if ["video.video-curves","video.wheels","video.video-hsl","video.video-lut"].contains(session.tool) {
            MediaV2VideoColorInspector(session: session, onImport: { beginImport() })
        } else if ["video.chroma","video.video-blend"].contains(session.tool) {
            MediaV2CompositeInspector(session:session, onImport: { beginImport() })
        } else if MediaV2Session.nativePaintTools.contains(session.tool) {
            MediaV2PaintEffectsInspector(session:session)
        } else if session.tool == "video.scopes" {
            MediaV2ScopesInspector(session:session)
        } else if MediaV2Session.audioDerivationToolIDs.contains(session.tool) {
            MediaV2AudioDerivationInspector(session: session)
        } else if ["video.eq", "video.compressor"].contains(session.tool) {
            MediaV2AudioEffectsInspector(session:session)
        } else if MediaV2Session.extendedAnimationTools.contains(session.tool) {
            MediaV2AnimationInspector(session:session)
        } else if ["video.reverse", "video.freeze"].contains(session.tool) {
            MediaV2PlaybackInspector(session: session)
        } else if MediaV2Session.extendedColorTools.contains(session.tool) {
            MediaV2ColorInspector(session:session)
        } else if MediaV2Session.imageWarpToolIDs.contains(session.tool) {
            MediaV2ImageWarpInspector(session: session)
        } else if MediaV2Session.extendedImageTools.contains(session.tool) {
            MediaV2NativeSelectionInspector(session:session)
        } else if session.project.kind == .image, ["image.rectangle", "image.ellipse", "image.lasso", "image.polygon", "image.feather", "image.inverse", "image.deselect", "image.layer-mask", "image.vector-mask", "image.clip-mask"].contains(session.tool) {
            MediaV2SelectionInspector(session: session)
        } else if session.tool == "video.nest" {
            MediaV2CompoundInspector(session:session)
        } else if session.tool == "image.crop" {
            if let layer = session.selectedLayer, layer.contentKind == .raster { MediaV2CropInspector(session: session, layer: layer).id(layer.id) }
            else { Text(WorkbenchText.t("请选择图片图层。", "Select an image layer.")).font(.caption).foregroundStyle(.secondary) }
        } else if session.tool == "image.text", let layer = session.selectedLayer, layer.contentKind == .text {
            MediaV2TextInspector(session: session, layer: layer).id(layer.id)
        } else if session.tool == "image.align" {
            Button(WorkbenchText.t("水平居中", "Center horizontally")) { property = "centerX"; run("image.align") }.frame(minHeight: 44)
            Button(WorkbenchText.t("垂直居中", "Center vertically")) { property = "centerY"; run("image.align") }.frame(minHeight: 44)
        } else if session.tool == "image.blend-mode" {
            Text(WorkbenchText.t("在编组的图层属性中选择混合模式。", "Choose a blend mode in the selected group's layer properties.")).font(.caption).foregroundStyle(.secondary)
        } else if session.tool == "image.merge-layer" {
            Text(WorkbenchText.t("多选至少两个连续的同级图层。", "Select at least two adjacent sibling layers.")).font(.caption).foregroundStyle(.secondary)
            Button(WorkbenchText.t("合并所选图层", "Merge selected layers")) { run("image.merge-layer") }.frame(minHeight: 44).disabled(session.selectedLayerSet.count < 2)
        } else if session.project.kind == .video, ["video.graph", "video.keyframes", "video.easing", "video.video-transform", "video.pip"].contains(session.tool) {
            if let selected = session.selectedClip, selected.track.kind == .visual { MediaV2KeyframeInspector(session: session, clip: selected.clip).id(selected.clip.id) }
            else { Text(WorkbenchText.t("请选择视频或图片片段。", "Select a video or image clip.")).font(.caption).foregroundStyle(.secondary) }
        } else if session.project.kind == .video, ["video.video-mask", "video.video-feather"].contains(session.tool) {
            if let selected = session.selectedClip, selected.track.kind == .visual { MediaV2VideoMaskInspector(session: session, clip: selected.clip).id(selected.clip.id) }
            else { Text(WorkbenchText.t("请选择视频或图片片段。", "Select a video or image clip.")).font(.caption).foregroundStyle(.secondary) }
        } else if session.project.kind == .video, ["video.caption", "video.caption-time", "video.caption-style", "video.srt"].contains(session.tool) || session.selectedClip?.track.kind == .caption {
            MediaV2CaptionInspector(session: session, onImport: { beginImport(captions: true) })
            Divider()
            MediaV2CaptionStyleInspector(session: session)
        } else if session.project.kind == .video, ["video.mix", "video.fades", "video.audio-sync"].contains(session.tool) || session.selectedClip?.track.kind == .audio {
            MediaV2AudioInspector(session: session)
        } else if session.project.kind == .video, ["video.trim", "video.ripple", "video.roll"].contains(session.tool) {
            Text(WorkbenchText.t("拖动片段或左右边界，也可在下方输入时间。波纹操作仅影响当前轨道。", "Drag a clip or its trim handles, or enter times below. Ripple edits affect the current track.")).font(.caption).foregroundStyle(.secondary)
        } else if ["image.brush", "image.eraser", "image.pen"].contains(session.tool) {
            MusicValueSlider(title: WorkbenchText.t("大小", "Size"), value: session.brushWidth, range: 1...200, suffix: "px") { session.brushWidth = $0 }
            MusicValueSlider(title: WorkbenchText.t("硬度", "Hardness"), value: session.brushHardness, range: 0...1) { session.brushHardness = $0 }
            MusicValueSlider(title: WorkbenchText.t("不透明度", "Opacity"), value: session.brushOpacity, range: 0.01...1) { session.brushOpacity = $0 }
            if session.tool == "image.eraser" { Toggle(WorkbenchText.t("恢复擦除区域", "Restore erased area"), isOn: $session.eraserRestores).frame(minHeight: 44) }
        } else if session.tool == "image.feather" || session.tool == "video.video-feather" {
            MusicValueSlider(title: WorkbenchText.t("羽化半径", "Feather radius"), value: number, range: 0...200, suffix: "px") { number = $0; run(session.tool) }
            Text(WorkbenchText.t("半径按原画布像素计算。", "Radius uses original canvas pixels.")).font(.caption2).foregroundStyle(.secondary)
            if session.project.kind == .image { Button(WorkbenchText.t("应用为图层蒙版", "Apply as layer mask")) { run("image.layer-mask") }.frame(minHeight: 44).disabled(session.selection == nil) }
        } else if session.tool == "image.text" || session.tool == "video.caption" {
            TextField(WorkbenchText.t("文字", "Text"), text: $text, axis: .vertical).textFieldStyle(.roundedBorder)
            Button(WorkbenchText.t("应用文字", "Apply text")) { run(session.tool) }.frame(minHeight: 44)
        } else if session.tool != "move", !session.tool.hasPrefix("image.rectangle"), !session.tool.hasPrefix("image.ellipse"), !session.tool.contains("lasso"), !session.tool.contains("polygon") {
            if MediaV2Session.localToolIDs.contains(session.tool) {
                if ["video.keyframes", "video.video-transform", "video.easing"].contains(session.tool) {
                    Picker(WorkbenchText.t("属性", "Property"), selection: $property) { Text(WorkbenchText.t("缩放", "Scale")).tag("scale"); Text("X").tag("centerX"); Text("Y").tag("centerY"); Text(WorkbenchText.t("透明度", "Opacity")).tag("opacity"); Text(WorkbenchText.t("旋转", "Rotation")).tag("rotationDegrees") }
                }
                if !["image.fill", "image.layer-mask", "image.clip-mask", "image.group-layer", "image.duplicate-layer", "image.flip", "image.shape", "image.bw", "video.split", "video.video-mask"].contains(session.tool) {
                    TextField(WorkbenchText.t("数值", "Value"), value: $number, format: .number).textFieldStyle(.roundedBorder).keyboardType(.decimalPad)
                }
                Button(WorkbenchText.t("应用", "Apply")) { run(session.tool) }.frame(minHeight: 44)
            } else {
                Text(WorkbenchText.t("此工具的执行服务尚未接入。", "This tool's execution service is not connected yet.")).font(.caption).foregroundStyle(.secondary)
                Button(WorkbenchText.t("在作品助手中继续", "Continue in work assistant")) { onAssistant?() }.frame(minHeight: 44).disabled(onAssistant == nil)
            }
        }
    }
    private func layerProperties(_ layer: MediaPreparedLayer) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            MediaV2LayerInspector(session: session, layer: layer).id(layer.id)
            if layer.contentKind == .text, !["image.text","image.path-text","image.outline"].contains(session.tool) { Divider(); MediaV2TextInspector(session: session, layer: layer).id(layer.id) }
        }
    }
    private func clipProperties(track: MediaPreparedTrack, clip: MediaPreparedClip) -> some View {
        MediaV2ClipTimingInspector(session: session, track: track, clip: clip).id(clip.id)
    }
    private var previewControls: some View {
        VStack(spacing: 0) {
            if session.project.kind == .image, MediaDrawingInputPolicy.isStrokeTool(session.tool) {
                HStack { MediaFingerDrawingToggle(); Spacer() }.padding(.horizontal, 10)
            }
            HStack(spacing: 8) {
            if session.project.kind == .video {
                Button {
                    if session.player != nil { session.stopPlayback() }
                    else { if audio == nil { audio = NativeCreativeAudioSession(environment: environment) }; if let audio { session.play(authority: audio) } }
                } label: { Image(systemName: session.player == nil ? "play.fill" : "stop.fill").frame(width: 44, height: 44) }
                MusicIconButton("backward.end", WorkbenchText.t("上一帧", "Previous frame")) { session.scrub(max(0, session.playhead - 1 / (session.document.trackGraph.frameRate?.seconds ?? 30))) }
                MusicIconButton("forward.end", WorkbenchText.t("下一帧", "Next frame")) { session.scrub(session.playhead + 1 / (session.document.trackGraph.frameRate?.seconds ?? 30)) }
                Text(MusicWorkbenchFormat.time(session.playhead)).font(.caption.monospacedDigit())
            }
            Spacer()
            Button(WorkbenchText.t("适应画布", "Fit canvas")) { session.zoom = 1 }.font(.caption).frame(minHeight: 44)
            MusicIconButton("minus.magnifyingglass", WorkbenchText.t("缩小", "Zoom out")) { session.zoom = max(0.25, session.zoom / 1.25) }
            Text("\(Int(session.zoom * 100))%").font(.caption.monospacedDigit())
            MusicIconButton("plus.magnifyingglass", WorkbenchText.t("放大", "Zoom in")) { session.zoom = min(4, session.zoom * 1.25) }
            }.padding(.horizontal, 8)
        }.background(Color(uiColor: .secondarySystemBackground))
    }
    private var status: some View {
        HStack(spacing: 6) {
            if let error = session.diagnostic {
                Button { showingDiagnostic = true } label: {
                    Label(error, systemImage: "exclamationmark.triangle").lineLimit(2).multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading).foregroundStyle(.orange)
                }.buttonStyle(.plain).accessibilityHint(WorkbenchText.t("打开操作详情", "Open action details"))
                Button(WorkbenchText.t("详情", "Details")) { showingDiagnostic = true }
            } else { Text(session.project.kind == .image ? WorkbenchText.t("分层原件", "Layered original") : WorkbenchText.t("多轨工程", "Multi-track project")) }
            Spacer()
            if session.rendering { ProgressView(value: session.exportProgress).frame(width: 70); Button(WorkbenchText.t("取消", "Cancel")) { session.cancelExport() } }
            Text("\(session.document.canvas?.width ?? 0) × \(session.document.canvas?.height ?? 0)")
        }.font(.caption2).foregroundStyle(.secondary).padding(.horizontal, 10).frame(minHeight: session.diagnostic == nil ? 28 : 44)
            .accessibilityIdentifier("media.v2.status")
    }
    private func run(_ tool: String) {
        var input = MediaV2ToolInput(); input.text = ["image.text", "video.caption"].contains(tool) && !text.isEmpty ? text : nil
        if tool != "video.caption" {
            input.number = tool == "image.text" && session.tool != tool ? 72 : number
            input.color = session.colorHex; input.property = property
        }
        input.expectedRevision = session.document.revision
        if session.project.kind == .image { input.objectIDs = Array(session.selectedLayerSet) }
        Task { do { _ = try await session.performTool(tool, input: input) } catch { session.diagnostic = error.localizedDescription } }
    }
    private var importContentTypes: [UTType] {
        if importingCaptions { return [.plainText, UTType(filenameExtension: "srt") ?? .plainText, UTType(filenameExtension: "vtt") ?? .plainText] }
        return session.project.kind == .image ? [.image] : [.image, .movie, .audio]
    }
    private func beginImport(captions: Bool = false) { importingCaptions = captions; importing = true }
    private func objectAction(_ id: String, layer: MediaPreparedLayer, flag: Bool? = nil) {
        var input = MediaV2ToolInput(); input.objectID = layer.id; input.flag = flag
        input.expectedRevision = session.document.revision; input.objectIDs = Array(session.selectedLayerSet)
        Task { do { _ = try await session.performTool(id, input: input) } catch { session.diagnostic = error.localizedDescription } }
    }
    private func exchange(_ format: MediaV2ExchangeFormat) {
        Task { do { _ = try await session.exportInterchange(format) } catch { session.diagnostic = error.localizedDescription } }
    }
}

private struct MediaV2CaptionStyleInspector: View {
    @Bindable var session: MediaV2Session
    @State private var style = CaptionStyle()
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(WorkbenchText.t("字幕样式", "Caption style")).font(.headline)
            Text(WorkbenchText.t("应用到全部字幕", "Applies to all captions")).font(.caption).foregroundStyle(.secondary)
            MediaV2NumberField(title: WorkbenchText.t("字号", "Font size"), value: $style.fontSize, suffix: "px")
            ColorPicker(WorkbenchText.t("文字颜色", "Text color"), selection: Binding(get: { displayColor(style.colorHex) }, set: { style.colorHex = hex($0) }), supportsOpacity: true).frame(minHeight: 44)
            Toggle(WorkbenchText.t("字幕背景", "Caption background"), isOn: Binding(get: { style.backgroundHex != nil }, set: { style.backgroundHex = $0 ? "#000000" : nil })).frame(minHeight: 44)
            if style.backgroundHex != nil {
                ColorPicker(WorkbenchText.t("背景颜色", "Background color"), selection: Binding(get: { displayColor(style.backgroundHex ?? "#000000") }, set: { style.backgroundHex = hex($0) }), supportsOpacity: true).frame(minHeight: 44)
            }
            MediaV2NumberField(title: WorkbenchText.t("纵向位置（0–1）", "Vertical position (0–1)"), value: $style.positionY)
            Picker(WorkbenchText.t("对齐", "Alignment"), selection: Binding(get: { style.alignment ?? .center }, set: { style.alignment = $0 })) {
                Text(WorkbenchText.t("左对齐", "Leading")).tag(CaptionAlignment.leading)
                Text(WorkbenchText.t("居中", "Center")).tag(CaptionAlignment.center)
                Text(WorkbenchText.t("右对齐", "Trailing")).tag(CaptionAlignment.trailing)
            }
            Toggle(WorkbenchText.t("保持在安全区域", "Keep in safe area"), isOn: Binding(get: { style.respectsSafeArea ?? true }, set: { style.respectsSafeArea = $0 })).frame(minHeight: 44)
            Button(WorkbenchText.t("应用字幕样式", "Apply caption style")) {
                var input = MediaV2ToolInput(); input.captionStyle = style; input.expectedRevision = session.document.revision
                Task { do { _ = try await session.performTool("video.caption-style", input: input) } catch { session.diagnostic = error.localizedDescription } }
            }.frame(minHeight: 44)
        }.disabled(session.saving)
            .onAppear { style = session.document.trackGraph.captionStyle ?? CaptionStyle() }
            .onChange(of: session.document.trackGraph.captionStyleRevision) { _, _ in style = session.document.trackGraph.captionStyle ?? CaptionStyle() }
    }
    private func displayColor(_ value: String) -> Color {
        guard let rgba = try? PreparedVideoColor(hex: value) else { return .white }
        return Color(.sRGB, red: rgba.red, green: rgba.green, blue: rgba.blue, opacity: rgba.alpha)
    }
    private func hex(_ color: Color) -> String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "#%02X%02X%02X%02X", Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded()), Int((a * 255).rounded()))
    }
}
#endif
