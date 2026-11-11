import SwiftUI
import MapKit
import FloeToolboxUtilities
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

public enum ToolboxLocationPhase: Sendable, Equatable {
    case idle, permission, locating, live, paused, denied, disabled, unavailable
}

/// The host supplies authorized system fixes; the map never starts a second
/// location manager or substitutes its own cached location for those fixes.
public struct ToolboxLocationWorkbench: View {
    @Environment(\.locale) private var locale
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .body) private var readingPointSize: CGFloat = 17
    @ScaledMetric(relativeTo: .caption) private var labelPointSize: CGFloat = 12
    @State private var camera = MapCameraPosition.automatic
    @State private var following = true
    @State private var satellite = false
    @State private var naming = false
    @State private var placeName = ""
    @State private var error: String?
    @State private var saving = false
    @State private var savedNote = false
    private let fix: ToolboxLocationFix?
    private let phase: ToolboxLocationPhase
    private let precise: Bool
    private let places: [ToolboxSavedLocation]
    private let start: @MainActor () -> Void
    private let pause: @MainActor () -> Void
    private let refresh: @MainActor () -> Void
    private let savePlace: @MainActor (String, ToolboxLocationFix) async throws -> Void
    private let removePlace: @MainActor (UUID) async throws -> Void
    private let saveNote: (@MainActor (ToolboxLocationFix) async throws -> Void)?

    public init(fix: ToolboxLocationFix?, phase: ToolboxLocationPhase, precise: Bool,
                places: [ToolboxSavedLocation], start: @escaping @MainActor () -> Void,
                pause: @escaping @MainActor () -> Void, refresh: @escaping @MainActor () -> Void,
                savePlace: @escaping @MainActor (String, ToolboxLocationFix) async throws -> Void,
                removePlace: @escaping @MainActor (UUID) async throws -> Void,
                saveNote: (@MainActor (ToolboxLocationFix) async throws -> Void)? = nil) {
        self.fix = fix?.isValid == true ? fix : nil; self.phase = phase; self.precise = precise
        self.places = places; self.start = start; self.pause = pause; self.refresh = refresh
        self.savePlace = savePlace; self.removePlace = removePlace; self.saveNote = saveNote
    }

    private func t(_ zh: String, _ en: String) -> String { locale.language.languageCode?.identifier == "zh" ? zh : en }
    private var running: Bool { phase == .live || phase == .locating || phase == .permission }

    public var body: some View {
        GeometryReader { geometry in
            let wide = geometry.size.width >= 800 && !typeSize.isAccessibilitySize
            Group {
                if wide {
                    HStack(alignment: .top, spacing: 0) {
                        mapPanel.frame(maxWidth: .infinity, maxHeight: .infinity)
                        Divider()
                        ScrollView { information(width: 282).padding(24) }.frame(width: 330)
                    }
                } else {
                    ScrollView {
                        VStack(spacing: 0) {
                            mapPanel.frame(height: max(340, geometry.size.height * 0.58))
                            information(width: max(0, geometry.size.width - 40)).padding(20)
                        }
                    }
                }
            }
        }
        .background(panelBackground)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("toolbox.location.workbench")
        .onChange(of: fix) { _, value in
            savedNote = false
            if following, let value { focus(value) }
        }
        .onChange(of: camera.positionedByUser) { _, value in if value { following = false } }
        .onAppear { if let fix { focus(fix) } }
        .alert(t("标记位置", "Save a place"), isPresented: $naming) {
            TextField(t("名称", "Name"), text: $placeName).accessibilityIdentifier("toolbox.location.placeName")
            Button(t("取消", "Cancel"), role: .cancel) {}
            Button(t("保存", "Save")) {
                guard let fix else { return }
                perform { try await savePlace(placeName, fix) }
            }.disabled(placeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .alert(t("未能完成", "Unable to complete"), isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button(t("好", "OK"), role: .cancel) { error = nil }
        } message: { Text(error ?? "") }
    }

    private var mapPanel: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                Picker(t("地图样式", "Map style"), selection: $satellite) {
                    Text(t("地图", "Map")).tag(false)
                    Text(t("卫星", "Satellite")).tag(true)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 240)
                .accessibilityIdentifier("toolbox.location.mapStyle")
                Spacer(minLength: 0)
                Button {
                    following = true
                    if let fix { focus(fix) } else { start() }
                } label: {
                    Image(systemName: following ? "location.fill" : "location")
                        .font(.body.weight(.semibold)).frame(width: 44, height: 44)
                }
                .buttonStyle(.plain).foregroundStyle(.tint)
                .accessibilityLabel(t("回到我的位置", "Recenter on my location"))
                .accessibilityIdentifier("toolbox.location.recenter")
            }
            .padding(.horizontal, 16).padding(.vertical, 4)
            .background(.bar)
            Divider()
            mapCanvas
        }
    }

    private var mapCanvas: some View {
        Map(position: $camera) {
            ForEach(places) { place in
                Marker(place.name, systemImage: "mappin", coordinate: coordinate(place.fix)).tint(.orange)
            }
            if let fix {
                MapCircle(center: coordinate(fix), radius: fix.horizontalAccuracy).foregroundStyle(.blue.opacity(0.12))
                Annotation(t("我的位置", "My location"), coordinate: coordinate(fix), anchor: .center) {
                    ZStack {
                        Circle().fill(.background).frame(width: 28, height: 28)
                        Circle().fill(.blue).frame(width: 18, height: 18)
                    }
                    .accessibilityLabel(t("当前位置，精度", "Current location, accuracy") + " \(fix.horizontalAccuracy.formatted(.number.precision(.fractionLength(0)))) m")
                }
            }
        }
        .mapStyle(satellite ? .imagery(elevation: .flat) : .standard(elevation: .flat))
        .mapControls { MapCompass(); MapScaleView() }
        .accessibilityIdentifier("toolbox.location.map")
    }

    private func information(width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            locationControls
            if phase == .denied || phase == .disabled { permissionHelp }
            if let fix {
                fixDetails(fix, width: width)
                locationActions(fix)
            } else {
                ContentUnavailableView(t("等待位置", "Waiting for your location"), systemImage: "location.circle", description: Text(t("开始定位后，在这里查看经纬度、海拔和速度。", "Start locating to see coordinates, altitude and speed.")))
            }
            Divider()
            savedPlaces
        }
    }

    private var locationControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(t("位置详情", "Location details")).font(.title2.bold())
            Label(statusText, systemImage: statusSymbol)
                .font(.subheadline).foregroundStyle(supportingText)
                .accessibilityIdentifier("toolbox.location.status")
            HStack {
                Button { if running { pause() } else { start() } } label: {
                    Label(running ? t("暂停定位", "Pause") : t("开始定位", "Locate me"), systemImage: running ? "pause.fill" : "location.fill")
                }.buttonStyle(.borderedProminent).controlSize(.regular).accessibilityIdentifier("toolbox.location.start")
                Button(action: refresh) { Image(systemName: "arrow.clockwise").frame(minWidth: 44, minHeight: 44) }
                    .buttonStyle(.plain).accessibilityLabel(t("刷新位置", "Refresh location"))
            }
        }
    }

    private var permissionHelp: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(phase == .disabled ? t("请在系统设置中打开定位服务。", "Turn on Location Services in system settings.") : t("请允许 Floe 在使用期间访问位置。", "Allow Floe to access your location while using the app."))
                .font(.subheadline)
            #if os(iOS)
            Button(t("打开设置", "Open Settings")) {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            }.buttonStyle(.bordered)
            #endif
        }
    }

    private func locationActions(_ fix: ToolboxLocationFix) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button { copy(fix.coordinateText) } label: { Label(t("复制坐标", "Copy"), systemImage: "doc.on.doc") }
                if let url = fix.mapsURL { ShareLink(item: url) { Label(t("分享", "Share"), systemImage: "square.and.arrow.up") } }
            }.buttonStyle(.bordered).controlSize(.large)
            Button {
                placeName = t("位置", "Place") + " " + fix.timestamp.formatted(date: .omitted, time: .shortened)
                naming = true
            } label: { Label(t("标记这个位置", "Save this place"), systemImage: "mappin.and.ellipse") }
                .buttonStyle(.bordered).controlSize(.large).disabled(saving).accessibilityIdentifier("toolbox.location.savePlace")
            if let saveNote {
                Button {
                    perform { try await saveNote(fix); savedNote = true }
                } label: { Label(savedNote ? t("已存入手记", "Saved to Notes") : t("存入手记", "Save to Notes"), systemImage: savedNote ? "checkmark" : "note.text.badge.plus") }
                    .buttonStyle(.bordered).controlSize(.large).disabled(saving)
            }
            if saving { ProgressView(t("正在保存", "Saving")) }
        }
    }

    private var savedPlaces: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(t("标记的地点", "Saved places")).font(.headline)
            if places.isEmpty {
                Text(t("给常用地点做个标记，方便下次找到。", "Save places you want to find again.")).font(.subheadline).foregroundStyle(supportingText)
            }
            ForEach(places) { place in savedPlaceRow(place) }
        }
    }

    private func savedPlaceRow(_ place: ToolboxSavedLocation) -> some View {
        HStack {
            Button { following = false; focus(place.fix) } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(place.name).foregroundStyle(.primary)
                    Text(place.fix.coordinateText).font(.caption.monospaced()).foregroundStyle(supportingText)
                }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            }.buttonStyle(.plain)
            Menu {
                if let url = place.fix.mapsURL { ShareLink(item: url) { Label(t("分享位置", "Share location"), systemImage: "square.and.arrow.up") } }
                Button(role: .destructive) { perform { try await removePlace(place.id) } } label: {
                    Label(t("删除标记", "Delete place"), systemImage: "trash")
                }
            } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }
            .accessibilityLabel(t("地点操作", "Place actions") + " " + place.name)
        }
    }

    private func fixDetails(_ fix: ToolboxLocationFix, width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            readingSection(t("坐标", "Coordinates"), symbol: "location.circle") {
                readingPair(
                    .init(title: t("纬度", "Latitude"), value: fix.latitude.formatted(.number.precision(.fractionLength(6))) + "°", identifier: "toolbox.location.latitude"),
                    .init(title: t("经度", "Longitude"), value: fix.longitude.formatted(.number.precision(.fractionLength(6))) + "°", identifier: "toolbox.location.longitude"), width: width)
            }
            readingSection(t("海拔与精度", "Altitude and accuracy"), symbol: "mountain.2") {
                readingPair(
                    .init(title: t("海拔", "Altitude"), value: measurement(fix.altitude, "m"), identifier: "toolbox.location.altitude"),
                    .init(title: t("水平精度", "Horizontal accuracy"), value: "± " + measurement(fix.horizontalAccuracy, "m"), identifier: "toolbox.location.horizontalAccuracy"), width: width)
                Divider().padding(.horizontal, 14)
                readingPair(
                    .init(title: t("垂直精度", "Vertical accuracy"), value: fix.verticalAccuracy.map { "± " + measurement($0, "m") } ?? t("暂无数据", "Unavailable")),
                    .init(title: t("位置精度", "Location precision"), value: precise ? t("精确位置", "Precise") : t("大致位置", "Approximate")), width: width)
            }
            readingSection(t("移动信息", "Movement"), symbol: "location.north.line") {
                readingPair(
                    .init(title: t("速度", "Speed"), value: measurement(fix.speed.map { $0 * 3.6 }, "km/h")),
                    .init(title: t("行进方向", "Course"), value: measurement(fix.course, "°")), width: width)
            }
            TimelineView(.periodic(from: .now, by: 1)) { context in
                VStack(alignment: .leading, spacing: 8) {
                    Text(t("采样时间：", "Sampled: ") + fix.timestamp.formatted(date: .abbreviated, time: .standard))
                        .font(.caption).monospacedDigit().foregroundStyle(supportingText)
                    if !fix.isFresh(at: context.date) {
                        Label(t("上次的位置记录，刷新以更新。", "Previous location. Refresh to update."), systemImage: "clock")
                            .font(.caption).foregroundStyle(supportingText)
                    }
                }.padding(.horizontal, 2)
            }
        }
    }

    private struct Reading {
        let title: String
        let value: String
        var identifier: String? = nil
    }

    @ViewBuilder
    private func readingPair(_ leading: Reading, _ trailing: Reading, width: CGFloat) -> some View {
        let minimum = max(requiredWidth(leading), requiredWidth(trailing))
        if !typeSize.isAccessibilitySize && minimum * 2 + 1 <= width {
            HStack(spacing: 0) {
                readingCell(leading)
                Divider().frame(height: 44).padding(.vertical, 12)
                readingCell(trailing)
            }
        } else {
            VStack(spacing: 0) {
                readingRow(leading.title, value: leading.value, identifier: leading.identifier)
                Divider().padding(.horizontal, 14)
                readingRow(trailing.title, value: trailing.value, identifier: trailing.identifier)
            }
        }
    }

    private func readingCell(_ reading: Reading) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(reading.title).font(.caption).foregroundStyle(supportingText)
            readingValue(reading.value, identifier: reading.identifier)
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .padding(.horizontal, 14).padding(.vertical, 12)
    }

    private func requiredWidth(_ reading: Reading) -> CGFloat {
        #if os(iOS)
        let valueFont = UIFont.monospacedDigitSystemFont(ofSize: readingPointSize, weight: .medium)
        let titleFont = UIFont.systemFont(ofSize: labelPointSize)
        #else
        let valueFont = NSFont.monospacedDigitSystemFont(ofSize: readingPointSize, weight: .medium)
        let titleFont = NSFont.systemFont(ofSize: labelPointSize)
        #endif
        let value = (reading.value as NSString).size(withAttributes: [.font: valueFont]).width
        let title = (reading.title as NSString).size(withAttributes: [.font: titleFont]).width
        return max(value, title) + 28
    }

    private func readingSection<Content: View>(_ title: String, symbol: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: symbol).font(.subheadline.weight(.semibold))
                .foregroundStyle(supportingText).padding(.horizontal, 2)
            VStack(spacing: 0, content: content)
                .background(readingBackground, in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private func readingRow(_ title: String, value: String, identifier: String? = nil) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                Text(title).foregroundStyle(supportingText)
                Spacer(minLength: 4)
                readingValue(value, identifier: identifier)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(title).foregroundStyle(supportingText)
                readingValue(value, identifier: identifier)
            }
        }
        .font(.subheadline)
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .padding(.horizontal, 14).padding(.vertical, 2)
    }

    private func readingValue(_ value: String, identifier: String?) -> some View {
        Text(value).font(.body.monospacedDigit().weight(.medium))
            .foregroundStyle(.primary).textSelection(.enabled)
            .accessibilityIdentifier(identifier ?? value)
    }

    private func measurement(_ value: Double?, _ unit: String) -> String {
        value.map { $0.formatted(.number.precision(.fractionLength(1))) + " " + unit } ?? t("暂无数据", "Unavailable")
    }

    // Keep small labels readable on both grouped surfaces and dark appearance.
    private var supportingText: Color { Color.primary.opacity(0.76) }

    private var panelBackground: Color {
        #if os(iOS)
        Color(uiColor: .systemGroupedBackground)
        #else
        Color(nsColor: .windowBackgroundColor)
        #endif
    }
    private var readingBackground: Color {
        #if os(iOS)
        Color(uiColor: .secondarySystemGroupedBackground)
        #else
        Color(nsColor: .controlBackgroundColor)
        #endif
    }

    private func coordinate(_ fix: ToolboxLocationFix) -> CLLocationCoordinate2D { .init(latitude: fix.latitude, longitude: fix.longitude) }
    private func focus(_ fix: ToolboxLocationFix) {
        camera = .camera(MapCamera(centerCoordinate: coordinate(fix), distance: max(500, min(2_000_000, fix.horizontalAccuracy * 6))))
    }
    private func perform(_ action: @escaping @MainActor () async throws -> Void) {
        guard !saving else { return }
        saving = true
        Task { @MainActor in
            defer { saving = false }
            do { try await action() }
            catch ToolboxLocationArchive.ArchiveError.archiveFull {
                self.error = t("已保存 200 个地点，请删除不再需要的标记后重试。", "You have saved 200 places. Remove an unneeded place and try again.")
            }
            catch ToolboxLocationArchive.ArchiveError.invalidArchive {
                self.error = t("地点记录无法读取，原文件已保留。请先重试读取记录。", "Saved places could not be read. The original file is preserved. Try loading the records again.")
            }
            catch ToolboxLocationArchive.ArchiveError.invalidLocation {
                self.error = t("请检查位置数据，并使用较短的地点名称。", "Check the position and use a shorter place name.")
            }
            catch { self.error = t("未能保存，请检查存储空间后重试。", "Unable to save. Check available storage and try again.") }
        }
    }
    private func copy(_ value: String) {
        #if os(iOS)
        UIPasteboard.general.string = value
        #elseif os(macOS)
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(value, forType: .string)
        #endif
    }
    private var statusText: String {
        switch phase {
        case .idle: t("尚未定位", "Ready to locate")
        case .permission: t("等待定位授权", "Waiting for permission")
        case .locating: t("正在定位", "Locating")
        case .live: precise ? t("位置已更新", "Location updated") : t("大致位置", "Approximate location")
        case .paused: t("定位已暂停", "Location paused")
        case .denied: t("需要定位权限", "Location access needed")
        case .disabled: t("定位服务已关闭", "Location Services are off")
        case .unavailable: t("暂时无法定位", "Location unavailable")
        }
    }
    private var statusSymbol: String {
        switch phase {
        case .live: "location.fill"
        case .permission, .locating: "location.magnifyingglass"
        case .denied, .disabled, .unavailable: "location.slash"
        case .paused: "pause.circle"
        case .idle: "location.circle"
        }
    }
}
