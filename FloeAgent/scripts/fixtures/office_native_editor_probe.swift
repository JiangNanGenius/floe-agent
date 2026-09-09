// Isolated developer-signed qualification app. Synthetic documents only.
// Does not use Floe app groups, original user files, or distribution signing.
import UIKit
import FloeOfficeNative
import CryptoKit
import Darwin

@main final class OfficeEditorProbe: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    private var native: FloeOfficeNativeViewController?
    private var session: URL?
    private var working: URL?
    private var events: [[String: String]] = []
    private var expectedClose = false

    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        // Optional process-only control for locale regression experiments.
        // Never changes the user's system or persistent language preferences.
        #if FLOE_ENGLISH_PROBE
        let language: String? = "en-US"
        #elseif FLOE_SIMPLIFIED_CHINESE_PROBE
        let language: String? = "zh-CN"
        #elseif FLOE_TRADITIONAL_CHINESE_PROBE
        let language: String? = "zh-TW"
        #else
        let language = Bundle.main.object(forInfoDictionaryKey: "FloeProbeLanguage") as? String
        #endif
        if let language {
            UserDefaults.standard.setVolatileDomain(["AppleLanguages": [language]], forName: UserDefaults.argumentDomain)
        }
        let window = UIWindow(frame: UIScreen.main.bounds)
        self.window = window
        showPicker()
        window.makeKeyAndVisible()
        return true
    }

    private func showPicker() {
        let page = UIViewController()
        page.view.backgroundColor = .systemBackground
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 20
        stack.translatesAutoresizingMaskIntoConstraints = false
        page.view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: page.view.safeAreaLayoutGuide.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: page.view.safeAreaLayoutGuide.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: page.view.safeAreaLayoutGuide.topAnchor, constant: 24)
        ])
        let label = UILabel()
        label.text = "Native Office roundtrip · \(Locale.preferredLanguages.first ?? "unknown")"
        stack.addArrangedSubview(label)
        for (name, ext) in [("Word", "docx"), ("Excel", "xlsx"), ("PowerPoint", "pptx")] {
            let button = UIButton(type: .system)
            button.setTitle("Edit synthetic \(name)", for: .normal)
            button.addAction(UIAction { [weak self] _ in
                button.isEnabled = false
                FloeOfficeNativeRuntime.shared.prepare { error in
                    guard let self else { return }
                    if let error { label.text = error.localizedDescription; return }
                    do {
                        guard let input = Bundle.main.url(forResource: "fixture", withExtension: ext) else {
                            throw CocoaError(.fileNoSuchFile)
                        }
                        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                            .appendingPathComponent("OfficeRoundtrip/\(UUID().uuidString)", isDirectory: true)
                        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                        let file = root.appendingPathComponent("working.\(ext)")
                        try FileManager.default.copyItem(at: input, to: file)
                        self.session = root
                        self.working = file
                        self.events = []
                        self.record("fixtureCopied", detail: ext)
                        self.record("preferredLanguage", detail: Locale.preferredLanguages.first ?? "unknown")
                        #if FLOE_FONT_METRICS_PROBE
                        let trace = root.appendingPathComponent("font-metrics.jsonl")
                        setenv("FLOE_OFFICE_FONT_METRICS_TRACE", trace.path, 1)
                        self.record("fontMetricTracingEnabled", detail: trace.lastPathComponent)
                        #endif
                        try self.open(readOnly: false)
                    } catch { label.text = error.localizedDescription }
                }
            }, for: .touchUpInside)
            stack.addArrangedSubview(button)
        }
        window?.rootViewController = page
    }

    private func open(readOnly: Bool) throws {
        guard let session, let working else { throw CocoaError(.fileNoSuchFile) }
        let controller = try FloeOfficeNativeViewController(workingFileURL: working, sessionDirectory: session, readOnly: readOnly)
        native = controller
        controller.title = readOnly ? "Reopened readonly" : "Native editing"
        controller.onWorkingCopyOpened = { [weak self] success in self?.record("opened", detail: "\(success); readonly=\(readOnly)") }
        controller.onWorkingCopySaved = { [weak self] success in self?.record("workingPersistence", detail: "\(success)") }
        controller.onClosed = { [weak self, weak controller] success in
            guard let self, let controller, self.native === controller, !self.expectedClose else { return }
            self.record("unexpectedClose", detail: "\(success)")
            controller.title = "Editor closed unexpectedly; copies retained"
        }
        controller.navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: readOnly ? "Close preview" : "Save and reopen",
            primaryAction: UIAction { [weak self, weak controller] _ in
                guard let self, let controller else { return }
                if readOnly {
                    self.expectedClose = true
                    controller.closeWorkingCopy { error in
                        self.expectedClose = false
                        self.record("previewClosed", detail: error?.localizedDescription ?? "success")
                        if let error { controller.title = error.localizedDescription }
                        else { self.native = nil; self.showPicker() }
                    }
                    return
                }
                controller.title = "Saving native working copy…"
                self.record("saveRequested")
                controller.saveWorkingCopy { error in
                    self.record("saveCompleted", detail: error?.localizedDescription ?? "success")
                    if let error { controller.title = error.localizedDescription; return }
                    controller.title = "Saved; closing before reopen…"
                    self.expectedClose = true
                    controller.closeWorkingCopy { error in
                        self.expectedClose = false
                        self.record("editingClosed", detail: error?.localizedDescription ?? "success")
                        if let error { controller.title = error.localizedDescription; return }
                        do { try self.open(readOnly: true) }
                        catch { controller.title = error.localizedDescription }
                    }
                }
            })
        if !readOnly && ["docx", "xlsx", "pptx"].contains(working.pathExtension) {
            controller.navigationItem.leftBarButtonItem = UIBarButtonItem(
                title: "Insert attachment",
                primaryAction: UIAction { [weak self, weak controller] _ in
                    guard let self, let controller else { return }
                    do {
                        // Intentionally use a Unicode name and arbitrary binary
                        // bytes, not a document the engine can silently convert.
                        let input = session.appendingPathComponent("附件 测试 📎.bin")
                        let bytes = Data((0..<65539).map { UInt8(truncatingIfNeeded: $0) })
                        try bytes.write(to: input, options: .atomic)
                        controller.navigationItem.leftBarButtonItem?.isEnabled = false
                        controller.navigationItem.rightBarButtonItem?.isEnabled = false
                        self.record("attachmentRequested", detail: input.lastPathComponent)
                        controller.insertAttachment(fromFileURL: input) { error in
                            self.record("attachmentCompleted", detail: error?.localizedDescription ?? "success")
                            controller.title = error?.localizedDescription ?? "Attachment inserted; not saved"
                            controller.navigationItem.leftBarButtonItem?.isEnabled = true
                            controller.navigationItem.rightBarButtonItem?.isEnabled = true
                        }
                    } catch { controller.title = error.localizedDescription }
                })
        }
        if ["docx", "xlsx", "pptx"].contains(working.pathExtension) {
            var buttons = controller.navigationItem.leftBarButtonItems ?? []
            buttons.append(UIBarButtonItem(title: "Export attachments", primaryAction: UIAction { [weak self, weak controller] _ in
                guard let self, let controller else { return }
                controller.navigationItem.leftBarButtonItems?.forEach { $0.isEnabled = false }
                controller.navigationItem.rightBarButtonItem?.isEnabled = false
                controller.listAttachments { attachments, error in
                  let items = (attachments ?? []).map { (identifier: $0.identifier, name: $0.name, byteCount: $0.byteCount) }
                  MainActor.assumeIsolated {
                    func finish(_ detail: String) {
                        controller.title = detail
                        controller.navigationItem.leftBarButtonItems?.forEach { $0.isEnabled = true }
                        controller.navigationItem.rightBarButtonItem?.isEnabled = true
                    }
                    if let error {
                        let detail = (error as NSError).userInfo[NSDebugDescriptionErrorKey] as? String ?? error.localizedDescription
                        self.record("attachmentListFailed", detail: detail); finish(error.localizedDescription); return
                    }
                    self.record("attachmentsListed", detail: "\(items.count); readonly=\(readOnly)")
                    func export(_ index: Int) {
                        guard index < items.count else { finish("Exported \(items.count) embedded attachments"); return }
                        let item = items[index]
                        controller.exportAttachment(withIdentifier: item.identifier) { url, error in
                          MainActor.assumeIsolated {
                            guard let url, error == nil else {
                                let detail = (error as NSError?)?.userInfo[NSDebugDescriptionErrorKey] as? String ?? error?.localizedDescription ?? "missing URL"
                                self.record("attachmentExportFailed", detail: detail)
                                finish("Attachment export failed"); return
                            }
                            do {
                                let bytes = try Data(contentsOf: url)
                                let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
                                self.record("attachmentExported", detail: "name=\(item.name); bytes=\(bytes.count); declared=\(item.byteCount); sha256=\(hash); path=\(url.path)")
                                export(index + 1)
                            } catch { self.record("attachmentExportFailed", detail: error.localizedDescription); finish(error.localizedDescription) }
                          }
                        }
                    }
                    export(0)
                  }
                }
            }))
            if readOnly {
                buttons.append(UIBarButtonItem(title: "Edit again", primaryAction: UIAction { [weak self, weak controller] _ in
                    guard let self, let controller else { return }
                    controller.navigationItem.leftBarButtonItems?.forEach { $0.isEnabled = false }
                    controller.navigationItem.rightBarButtonItem?.isEnabled = false
                    self.expectedClose = true
                    self.record("resumeEditingRequested")
                    controller.closeWorkingCopy { error in
                        self.expectedClose = false
                        self.record("previewClosedForEditing", detail: error?.localizedDescription ?? "success")
                        if let error {
                            controller.title = error.localizedDescription
                            controller.navigationItem.leftBarButtonItems?.forEach { $0.isEnabled = true }
                            controller.navigationItem.rightBarButtonItem?.isEnabled = true
                            return
                        }
                        do { try self.open(readOnly: false) }
                        catch { controller.title = error.localizedDescription }
                    }
                }))
            }
            controller.navigationItem.leftBarButtonItems = buttons
        }
        window?.rootViewController = UINavigationController(rootViewController: controller)
    }

    private func record(_ event: String, detail: String = "") {
        events.append(["event": event, "detail": detail, "time": ISO8601DateFormatter().string(from: Date())])
        guard let session, let data = try? JSONSerialization.data(withJSONObject: events, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: session.appendingPathComponent("events.json"), options: .atomic)
    }
}
