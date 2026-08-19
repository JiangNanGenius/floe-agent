// FloeShare — Share extension for receiving content from other apps.
//
// Receives text, URLs, and images shared from other apps via the iOS share
// sheet. Saves the payload to the shared App Group container and opens the
// main app with a custom URL scheme so the agent can process it.

import UIKit
import UniformTypeIdentifiers

final class ShareViewController: UIViewController {
    private static let appGroupID = "group.org.floeagent.ios"
    private static let urlScheme = "floe://share"

    override func viewDidLoad() {
        super.viewDidLoad()
        handleSharedContent()
    }

    private func handleSharedContent() {
        guard let extensionContext = extensionContext,
              let inputItems = extensionContext.inputItems as? [NSExtensionItem] else {
            close()
            return
        }

        for item in inputItems {
            guard let attachments = item.attachments else { continue }
            for provider in attachments {
                if provider.hasItemConformingToTypeIdentifier(UTType.text.identifier) {
                    provider.loadItem(forTypeIdentifier: UTType.text.identifier) { [weak self] data, _ in
                        if let text = data as? String {
                            self?.saveAndOpen(payload: ["type": "text", "content": text])
                        }
                    }
                    return
                }
                if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                    provider.loadItem(forTypeIdentifier: UTType.url.identifier) { [weak self] data, _ in
                        if let url = data as? URL {
                            self?.saveAndOpen(payload: ["type": "url", "content": url.absoluteString])
                        }
                    }
                    return
                }
                if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                    provider.loadItem(forTypeIdentifier: UTType.image.identifier) { [weak self] data, _ in
                        if let url = data as? URL,
                           let imageData = try? Data(contentsOf: url) {
                            self?.saveImageAndOpen(imageData: imageData)
                        }
                    }
                    return
                }
            }
        }
        close()
    }

    private func saveAndOpen(payload: [String: String]) {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: Self.appGroupID
        ) else { close(); return }
        let inbox = container.appendingPathComponent("ShareInbox")
        try? FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        let file = inbox.appendingPathComponent("\(UUID().uuidString).json")
        if let data = try? JSONSerialization.data(withJSONObject: payload) {
            try? data.write(to: file)
        }
        openMainApp()
    }

    private func saveImageAndOpen(imageData: Data) {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: Self.appGroupID
        ) else { close(); return }
        let inbox = container.appendingPathComponent("ShareInbox")
        try? FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        let file = inbox.appendingPathComponent("\(UUID().uuidString).jpg")
        try? imageData.write(to: file)
        openMainApp()
    }

    private func openMainApp() {
        guard let url = URL(string: Self.urlScheme) else { close(); return }
        extensionContext?.open(url) { [weak self] _ in
            self?.close()
        }
    }

    private func close() {
        extensionContext?.completeRequest(returningItems: nil)
    }
}
