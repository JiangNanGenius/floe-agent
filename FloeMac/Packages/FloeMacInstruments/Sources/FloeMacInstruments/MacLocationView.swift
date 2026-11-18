// SPDX-License-Identifier: MPL-2.0
//
// Mac toolbox — location view.
//
// Foreground-only location details. Sampling starts from an explicit button,
// stops on pause or when the tool leaves the window, and the view never shows
// a cached or guessed coordinate as a new fix.

import AppKit
import SwiftUI
import FloeToolboxUtilities

public struct MacLocationInstrumentView: View {
    @Environment(\.locale) private var locale
    @State private var model: MacLocationModel

    public init(activity: MacInstrumentActivityCoordinator? = nil,
                archive: ToolboxLocationArchive = MacLocationModel.defaultArchive) {
        _model = State(initialValue: MacLocationModel(archive: archive, activity: activity))
    }

    public init(model: MacLocationModel) {
        _model = State(initialValue: model)
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                if model.phase == .denied || model.phase == .restricted || model.phase == .disabled {
                    permissionHelp
                }
                if let fix = model.fix {
                    details(fix)
                } else {
                    waiting
                }
                savedPlaces
            }
            .padding(22)
            .frame(maxWidth: 920, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .background(MacWindowCloseObserver(onClose: { model.stop() }, stopWhenInactive: true).frame(width: 0, height: 0).accessibilityHidden(true))
        .navigationTitle(macToolboxText("位置", "Location", locale))
        .task { await model.loadPlaces() }
        .onAppear { model.activateLifecycle() }
        .onDisappear { model.pause() }
        .alert(macToolboxText("未能完成", "Unable to complete", locale),
               isPresented: Binding(get: { model.operationNotice != nil },
                                    set: { _ in })) {
            Button(macToolboxText("好", "OK", locale), role: .cancel) { model.clearOperationNotice() }
        } message: {
            Text(model.operationNotice?.text(locale) ?? "")
        }
        .accessibilityIdentifier("mac.toolbox.location")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(macToolboxText("位置详情", "Location details", locale))
                        .font(.title2.weight(.semibold))
                    Label(statusText, systemImage: statusSymbol)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("mac.toolbox.location.status")
                }
                Spacer(minLength: 12)
                if model.isUpdating {
                    Button { model.pause() } label: {
                        Label(macToolboxText("暂停", "Pause", locale), systemImage: "pause.fill")
                            .frame(minHeight: 44)
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("mac.toolbox.location.pause")
                } else {
                    Button { model.start() } label: {
                        Label(macToolboxText("开始定位", "Locate me", locale), systemImage: "location.fill")
                            .frame(minHeight: 44)
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("mac.toolbox.location.start")
                }
                Button { model.refresh() } label: {
                    Label(macToolboxText("刷新", "Refresh", locale), systemImage: "arrow.clockwise")
                        .labelStyle(.iconOnly)
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.borderless)
                .frame(minWidth: 44, minHeight: 44)
                .help(macToolboxText("刷新位置", "Refresh location", locale))
                .accessibilityLabel(macToolboxText("刷新位置", "Refresh location", locale))
                .accessibilityIdentifier("mac.toolbox.location.refresh")
            }
            if model.phase == .permission {
                Label(macToolboxText("正在等待定位授权。允许后如定位已停止，请回到此窗口再次点击开始。",
                                     "Waiting for location permission. If locating has stopped, return here and press Locate me again.", locale),
                      systemImage: "hand.raised")
                    .font(.callout).foregroundStyle(.secondary)
            } else if model.phase == .locating {
                Label(macToolboxText("正在获取新的位置…", "Getting a new location…", locale),
                      systemImage: "location.magnifyingglass")
                    .font(.callout).foregroundStyle(.secondary)
            } else if model.phase == .unavailable {
                Label(macToolboxText("暂时无法获取位置。可稍后刷新或重试。",
                                     "Location is temporarily unavailable. Refresh or try again shortly.", locale),
                      systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.orange)
                    .accessibilityIdentifier("mac.toolbox.location.unavailable")
            }
        }
    }

    private var permissionHelp: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(model.phase == .disabled
                 ? macToolboxText("系统定位服务已关闭。请在“系统设置 > 隐私与安全性 > 定位服务”中打开。",
                                  "Location Services is off. Turn it on in System Settings > Privacy & Security > Location Services.", locale)
                 : macToolboxText("Floe 没有定位权限。请在“系统设置 > 隐私与安全性 > 定位服务”中允许 Floe。",
                                  "Floe does not have location access. Allow Floe in System Settings > Privacy & Security > Location Services.", locale))
                .font(.callout)
            Text(macToolboxText("此 Mac 版本只在使用位置工具且点击开始后采样，不会在后台持续定位。",
                               "This Mac build samples only while the Location tool is open and you press Start; it does not keep locating in the background.", locale))
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityIdentifier("mac.toolbox.location.permissionHelp")
    }

    private func details(_ fix: ToolboxLocationFix) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(macToolboxText("最新位置", "Latest fix", locale), systemImage: "location.fill")
                    .font(.headline)
                Spacer()
                if !model.precise {
                    Text(macToolboxText("大致位置", "Approximate", locale))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.orange)
                }
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 12)], alignment: .leading, spacing: 12) {
                reading(macToolboxText("纬度", "Latitude", locale),
                        fix.latitude.formatted(.number.precision(.fractionLength(6))) + "°",
                        identifier: "mac.toolbox.location.latitude")
                reading(macToolboxText("经度", "Longitude", locale),
                        fix.longitude.formatted(.number.precision(.fractionLength(6))) + "°",
                        identifier: "mac.toolbox.location.longitude")
                reading(macToolboxText("水平精度", "Horizontal accuracy", locale),
                        "± " + fix.horizontalAccuracy.formatted(.number.precision(.fractionLength(1))) + " m",
                        identifier: "mac.toolbox.location.accuracy")
                reading(macToolboxText("海拔", "Altitude", locale),
                        fix.altitude.map { $0.formatted(.number.precision(.fractionLength(1))) + " m" }
                            ?? macToolboxText("暂无数据", "Unavailable", locale))
                reading(macToolboxText("垂直精度", "Vertical accuracy", locale),
                        fix.verticalAccuracy.map { "± " + $0.formatted(.number.precision(.fractionLength(1))) + " m" }
                            ?? macToolboxText("暂无数据", "Unavailable", locale))
                reading(macToolboxText("速度", "Speed", locale),
                        fix.speed.map { ($0 * 3.6).formatted(.number.precision(.fractionLength(1))) + " km/h" }
                            ?? macToolboxText("暂无数据", "Unavailable", locale))
                reading(macToolboxText("行进方向", "Course", locale),
                        fix.course.map { $0.formatted(.number.precision(.fractionLength(0))) + "°" }
                            ?? macToolboxText("暂无数据", "Unavailable", locale))
                reading(macToolboxText("采样时间", "Sampled", locale),
                        fix.timestamp.formatted(date: .abbreviated, time: .standard))
            }
            HStack(spacing: 10) {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(fix.coordinateText, forType: .string)
                } label: {
                    Label(macToolboxText("复制坐标", "Copy coordinates", locale), systemImage: "doc.on.doc")
                        .frame(minHeight: 44)
                }
                .buttonStyle(.bordered)
                if let url = fix.mapsURL {
                    Button {
                        NSWorkspace.shared.open(url)
                    } label: {
                        Label(macToolboxText("在“地图”中打开", "Open in Maps", locale), systemImage: "map")
                            .frame(minHeight: 44)
                    }
                    .buttonStyle(.bordered)
                }
                Spacer(minLength: 8)
                TextField(macToolboxText("地点名称", "Place name", locale), text: Binding(
                    get: { model.draftPlaceName }, set: { model.draftPlaceName = $0 }))
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 220)
                    .accessibilityIdentifier("mac.toolbox.location.placeName")
                Button {
                    _ = model.requestSavePlace(model.draftPlaceName)
                } label: {
                    Label(macToolboxText("标记地点", "Save place", locale), systemImage: "mappin.and.ellipse")
                        .frame(minHeight: 44)
                }
                .buttonStyle(.bordered)
                .disabled(model.draftPlaceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.saving)
                .accessibilityIdentifier("mac.toolbox.location.savePlace")
            }
            Text(macToolboxText("采样于 \(fix.timestamp.formatted(date: .abbreviated, time: .standard))",
                                "Sampled \(fix.timestamp.formatted(date: .abbreviated, time: .standard))", locale))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityIdentifier("mac.toolbox.location.details")
    }

    private func reading(_ title: String, _ value: String, identifier: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.body.monospacedDigit().weight(.medium))
                .textSelection(.enabled)
                .accessibilityIdentifier(identifier ?? "mac.toolbox.location.reading")
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
    }

    private var waiting: some View {
        VStack(spacing: 12) {
            Image(systemName: "location.circle").font(.system(size: 38)).foregroundStyle(.secondary)
            Text(macToolboxText("等待位置", "Waiting for your location", locale))
                .font(.title3.weight(.medium))
            Text(macToolboxText("点击“开始定位”后显示经纬度、海拔、精度和速度。",
                               "Press Locate me to see coordinates, altitude, accuracy and speed.", locale))
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(32)
        .accessibilityIdentifier("mac.toolbox.location.waiting")
    }

    private var savedPlaces: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(macToolboxText("标记的地点", "Saved places", locale), systemImage: "mappin.and.ellipse")
                    .font(.headline)
                Spacer()
                if !model.places.isEmpty {
                    Text("\(model.places.count)/200").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            if let failure = model.placesFailure {
                Label(failure.text(locale), systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.orange)
            }
            if model.places.isEmpty {
                Text(macToolboxText("给常用地点做个标记，方便下次找到。",
                                   "Save places you want to find again.", locale))
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(model.places) { place in
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(place.name).font(.body.weight(.medium))
                            Text(place.fix.coordinateText)
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(place.fix.coordinateText, forType: .string)
                        } label: {
                            Image(systemName: "doc.on.doc").frame(width: 32, height: 32)
                        }
                        .buttonStyle(.borderless)
                        .frame(minWidth: 44, minHeight: 44)
                        .help(macToolboxText("复制坐标", "Copy coordinates", locale))
                        Button(role: .destructive) {
                            model.requestRemovePlace(id: place.id)
                        } label: {
                            Image(systemName: "trash").frame(width: 32, height: 32)
                        }
                        .buttonStyle(.borderless)
                        .frame(minWidth: 44, minHeight: 44)
                        .help(macToolboxText("删除标记", "Delete place", locale))
                    }
                    .padding(.vertical, 4)
                    Divider()
                }
            }
        }
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityIdentifier("mac.toolbox.location.savedPlaces")
    }

    private var statusText: String {
        switch model.phase {
        case .idle: macToolboxText("尚未定位", "Ready to locate", locale)
        case .permission: macToolboxText("等待定位授权", "Waiting for permission", locale)
        case .locating: macToolboxText("正在定位", "Locating", locale)
        case .live: model.precise ? macToolboxText("位置已更新", "Location updated", locale)
            : macToolboxText("大致位置", "Approximate location", locale)
        case .paused: macToolboxText("定位已暂停", "Location paused", locale)
        case .denied: macToolboxText("需要定位权限", "Location access needed", locale)
        case .restricted: macToolboxText("定位权限受限", "Location access restricted", locale)
        case .disabled: macToolboxText("定位服务已关闭", "Location Services are off", locale)
        case .unavailable: macToolboxText("暂时无法定位", "Location unavailable", locale)
        }
    }

    private var statusSymbol: String {
        switch model.phase {
        case .live: "location.fill"
        case .permission, .locating: "location.magnifyingglass"
        case .denied, .restricted, .disabled, .unavailable: "location.slash"
        case .paused: "pause.circle"
        case .idle: "location.circle"
        }
    }
}
