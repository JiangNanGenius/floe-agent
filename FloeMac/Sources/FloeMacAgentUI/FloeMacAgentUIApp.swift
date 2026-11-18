// Floe Mac M00 — real Mac Catalyst UI target.
//
// SPDX-License-Identifier: MPL-2.0
//
// This target compiles two untouched FloeApp sources (FloeTheme.swift and
// ErrorEventView.swift) and renders them through UIKit/SwiftUI. It is an M00
// source-reuse probe, not the full iPad shell.

import Darwin
import Foundation
import SwiftUI

@main
struct FloeMacAgentUIApp: App {
    var body: some Scene {
        WindowGroup {
            CatalystReuseView()
        }
    }
}

private struct CatalystReuseView: View {
    @State private var appeared = false

    var body: some View {
        ZStack {
            FloeTheme.groupedSurface.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(alignment: .top, spacing: 14) {
                        Image(systemName: "rectangle.on.rectangle.angled")
                            .font(.system(size: 34, weight: .semibold))
                            .foregroundStyle(FloeTheme.primary)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("agentui.title")
                                .font(FloeTheme.Typography.title)
                            Text("agentui.subtitle")
                                .font(FloeTheme.Typography.metadata)
                                .foregroundStyle(.secondary)
                        }
                    }

                    GroupBox {
                        VStack(alignment: .leading, spacing: 10) {
                            Label("agentui.catalyst", systemImage: "checkmark.seal")
                                .font(FloeTheme.Typography.section)
                                .foregroundStyle(FloeTheme.success)
                            Text("agentui.reuse")
                                .font(FloeTheme.Typography.body)
                            Text("agentui.notFull")
                                .font(FloeTheme.Typography.metadata)
                                .foregroundStyle(.secondary)
                            Text(platformSummary)
                                .font(FloeTheme.Typography.evidence)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(6)
                    }

                    ErrorEventView(message: String(localized: "agentui.errorMessage"))

                    Text("M00 · Floe Agent UI")
                        .font(FloeTheme.Typography.metadata)
                        .foregroundStyle(.secondary)
                }
                .padding(26)
                .frame(maxWidth: 820, alignment: .leading)
            }
        }
        .onAppear {
            guard !appeared else { return }
            appeared = true
            // A real use of the reused view so the probe marker corresponds
            // to a rendered source component, not a static claim.
            _ = ErrorEventView(message: "probe")
            SmokeMarker.reportIfRequested()
        }
    }

    private var platformSummary: String {
        #if targetEnvironment(macCatalyst)
        "Mac Catalyst · \(ProcessInfo.processInfo.operatingSystemVersionString)"
        #else
        "Not Mac Catalyst · \(ProcessInfo.processInfo.operatingSystemVersionString)"
        #endif
    }
}

private enum SmokeMarker {
    static func reportIfRequested() {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--smoke-marker"),
              index + 1 < arguments.count else { return }
        let path = arguments[index + 1]
        var exitAfter: TimeInterval = 1
        if let exitIndex = arguments.firstIndex(of: "--smoke-exit-after"),
           exitIndex + 1 < arguments.count,
           let seconds = TimeInterval(arguments[exitIndex + 1]) {
            exitAfter = seconds
        }
        let payload: [String: Any] = [
            "schema": "floe-mac-catalyst-smoke-v1",
            "catalyst": isCatalyst,
            "floeTheme": FloeTheme.minimumTarget == 44,
            "errorEventView": true,
            "bundlePath": Bundle.main.bundleURL.path,
            "pid": ProcessInfo.processInfo.processIdentifier,
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "appVersion": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            "appBuild": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
            "renderedAt": ISO8601DateFormatter().string(from: Date())
        ]
        do {
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys, .prettyPrinted])
            let url = URL(fileURLWithPath: path, isDirectory: false)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url, options: [.atomic])
        } catch {
            FileHandle.standardError.write(Data(("Catalyst smoke marker failed: \(error)\n").utf8))
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + max(exitAfter, 0.2)) {
            exit(0)
        }
    }

    private static var isCatalyst: Bool {
        #if targetEnvironment(macCatalyst)
        true
        #else
        false
        #endif
    }
}
