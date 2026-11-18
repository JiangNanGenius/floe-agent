// SPDX-License-Identifier: MPL-2.0
//
// Mac toolbox — instrument browser.
//
// A native desktop split view: instrument list on the left, the selected real
// tool on the right. Unsupported sensors keep their entry and show the actual
// API limitation; they never open a fake instrument surface.

import SwiftUI

public struct MacToolboxInstrumentsRootView: View {
    @Environment(\.locale) private var locale
    @State private var selection: MacInstrument? = .location
    @State private var catalog = MacInstrumentCatalog()

    public init() {}

    public var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section(macToolboxText("仪器", "Instruments", locale)) {
                    ForEach(MacInstrument.allCases) { instrument in
                        row(for: instrument)
                            .tag(instrument)
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 210, ideal: 240, max: 300)
        } detail: {
            if let selection {
                detail(for: selection)
            } else {
                ContentUnavailableView(
                    macToolboxText("选择一个工具", "Choose an instrument", locale),
                    systemImage: "wrench.and.screwdriver",
                    description: Text(macToolboxText("从左侧选择定位、标尺或图片测量。",
                                                     "Choose Location, Ruler or Photo measure from the sidebar.", locale)))
            }
        }
        .navigationTitle(macToolboxText("工具箱", "Toolbox", locale))
        .frame(minWidth: 980, minHeight: 680)
        .accessibilityIdentifier("mac.toolbox.root")
    }

    @ViewBuilder private func row(for instrument: MacInstrument) -> some View {
        let availability = catalog.availability(for: instrument)
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: instrument.systemImage)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(instrument.title(locale))
                Text(instrument.subtitle(locale))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            if case .unsupported = availability {
                Image(systemName: "slash.circle")
                    .foregroundStyle(.secondary)
                    .help(macToolboxText("此 Mac 目标没有可用的传感器接口", "No usable sensor API in this Mac target", locale))
            } else if case .needsSetup = availability {
                Image(systemName: "exclamationmark.circle")
                    .foregroundStyle(.orange)
            }
        }
        .accessibilityIdentifier("mac.toolbox.instrument.\(instrument.rawValue)")
    }

    @ViewBuilder private func detail(for instrument: MacInstrument) -> some View {
        let availability = catalog.availability(for: instrument)
        switch (instrument, availability) {
        case (.location, .available), (.location, .needsSetup):
            MacLocationInstrumentView()
        case (.ruler, _):
            MacRulerInstrumentView()
        case (.photoMeasurement, _):
            MacPhotoMeasureView()
        case (_, .unsupported(let notice)):
            MacInstrumentLimitationView(instrument: instrument, notice: notice)
        case (_, .needsSetup(let notice)):
            MacInstrumentLimitationView(instrument: instrument, notice: notice)
        case (_, .available):
            MacInstrumentLimitationView(
                instrument: instrument,
                notice: MacInstrumentNotice(
                    zh: "此工具尚未在此 Mac 构建中提供。",
                    en: "This instrument is not available in this Mac build yet."))
        }
    }
}

public struct MacInstrumentLimitationView: View {
    @Environment(\.locale) private var locale
    public let instrument: MacInstrument
    public let notice: MacInstrumentNotice

    public init(instrument: MacInstrument, notice: MacInstrumentNotice) {
        self.instrument = instrument
        self.notice = notice
    }

    public var body: some View {
        VStack(spacing: 18) {
            Image(systemName: instrument.systemImage)
                .font(.system(size: 46))
                .foregroundStyle(.secondary)
            Text(instrument.title(locale))
                .font(.title2.weight(.semibold))
            Text(notice.text(locale))
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 560)
                .fixedSize(horizontal: false, vertical: true)
            Label(macToolboxText("此入口保留在工具箱中；没有读数就不会显示读数。",
                                 "The entry remains in the toolbox; no reading is shown without one.", locale),
                  systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(36)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("mac.toolbox.limitation.\(instrument.rawValue)")
    }
}
