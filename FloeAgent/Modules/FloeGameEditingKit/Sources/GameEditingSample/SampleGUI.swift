// SPDX-License-Identifier: MPL-2.0
import Foundation
import SwiftUI
import FloeGameEditingCore
import FloeGameEditingUI

#if canImport(AppKit)
import AppKit

private struct SampleRootView: View {
    @ObservedObject var session: GameEditingSession
    @State private var locale: GameEditLocale = GameEditLocale.host

    var body: some View {
        TabView {
            GameEditingSessionView(session: session)
                .tabItem {
                    Label(session.baseProject.title, systemImage: "gamecontroller")
                }
            AssetBrowserView(session: session)
                .tabItem {
                    Label {
                        EditText(GameEditCopy("Assets", "素材"))
                    } icon: { Image(systemName: "folder") }
                }
        }
        .environment(\.gameEditLocale, locale)
        .toolbar {
            ToolbarItem(placement: .automatic) {
                EditButton {
                    locale = locale == .chinese ? .english : .chinese
                } label: {
                    Text(locale == .chinese ? "EN" : "中文")
                }
            }
        }
        .frame(minWidth: 900, minHeight: 620)
    }
}

enum SampleGUI {
    static func run() {
        let application = NSApplication.shared
        application.setActivationPolicy(.regular)

        Task { @MainActor in
            do {
                let (_, session, _) = try await SampleProjectFactory.makeSession()
                let window = NSWindow(
                    contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
                    styleMask: [.titled, .closable, .miniaturizable, .resizable],
                    backing: .buffered, defer: false)
                window.title = "Floe Game Editing — \(session.baseProject.title)"
                window.contentView = NSHostingView(rootView: SampleRootView(session: session))
                window.center()
                window.makeKeyAndOrderFront(nil)
                application.activate(ignoringOtherApps: true)
            } catch {
                let alert = NSAlert()
                alert.messageText = "Sample failed to start"
                alert.informativeText = String(describing: error)
                alert.runModal()
                NSApplication.shared.terminate(nil)
            }
        }

        application.run()
    }
}
#endif
