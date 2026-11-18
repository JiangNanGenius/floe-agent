import AppKit
import Foundation
import UniformTypeIdentifiers
import FloeToolboxCore
import FloeToolboxUtilities

/// A file the user explicitly chose in NSOpenPanel. The selection owns the
/// security-scoped access for as long as the checksum operation retains it.
/// No directory is scanned and no file is opened without this selection.
struct MacChecksumFileInfo: Sendable {
    let isRegularFile: Bool
    let title: String
    let byteCount: UInt64?
}

/// Injectable only inside this module so tests can verify the order of the
/// scope, metadata and file operations without touching user-selected files.
struct MacChecksumFileAccess: Sendable {
    let beginScope: @Sendable (URL) -> Bool
    let endScope: @Sendable (URL) -> Void
    let inspect: @Sendable (URL) throws -> MacChecksumFileInfo
    let open: @Sendable (URL) throws -> FileHandle
    let didClose: @Sendable () -> Void

    static let system = MacChecksumFileAccess(
        beginScope: { $0.startAccessingSecurityScopedResource() },
        endScope: { $0.stopAccessingSecurityScopedResource() },
        inspect: { url in
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .nameKey])
            return MacChecksumFileInfo(
                isRegularFile: values.isRegularFile == true,
                title: values.name ?? url.lastPathComponent,
                byteCount: values.fileSize.map { UInt64(max(0, $0)) }
            )
        },
        open: { try FileHandle(forReadingFrom: $0) },
        didClose: {}
    )
}

private final class MacChecksumScopeLease: Sendable {
    private let url: URL
    private let active: Bool
    private let end: @Sendable (URL) -> Void

    init(url: URL, access: MacChecksumFileAccess) {
        self.url = url
        self.end = access.endScope
        self.active = access.beginScope(url)
    }

    deinit {
        if active { end(url) }
    }
}

public final class MacChecksumSelection: Sendable {
    public let title: String
    public let byteCount: UInt64?
    private let readOperation: ToolboxByteReader

    public convenience init(url: URL) throws {
        try self.init(url: url, access: .system)
    }

    init(url: URL, access: MacChecksumFileAccess) throws {
        // Enter the scope before reading metadata or opening the file. The
        // lease is released on every throwing path as well as after the last
        // reader reference closes the handle.
        let lease = MacChecksumScopeLease(url: url, access: access)
        let info = try access.inspect(url)
        guard info.isRegularFile else { throw ToolboxError.invalid("regular file") }
        let reader = try MacFileReader(url: url, lease: lease, access: access)
        self.title = info.title
        self.byteCount = info.byteCount
        self.readOperation = { offset, maximumBytes in
            try await reader.read(offset: offset, maximumBytes: maximumBytes)
        }
    }

    /// A bounded fake reader can be injected by component tests.
    init(title: String, byteCount: UInt64?, read: @escaping ToolboxByteReader) {
        self.title = title
        self.byteCount = byteCount
        self.readOperation = read
    }

    public var read: ToolboxByteReader { readOperation }
}

/// File reads stay isolated from the main actor and are bounded by the
/// caller's requested byte count. The reader never seeks outside the file.
private actor MacFileReader {
    private let handle: FileHandle
    private let lease: MacChecksumScopeLease
    private let didClose: @Sendable () -> Void

    init(url: URL, lease: MacChecksumScopeLease, access: MacChecksumFileAccess) throws {
        handle = try access.open(url)
        self.lease = lease
        self.didClose = access.didClose
    }

    func read(offset: UInt64, maximumBytes: Int) throws -> Data {
        guard maximumBytes > 0 else { return Data() }
        try handle.seek(toOffset: offset)
        return try handle.read(upToCount: maximumBytes) ?? Data()
    }

    deinit {
        try? handle.close()
        didClose()
    }
}

@MainActor
public enum MacToolboxFilePanels {
    public static func chooseChecksumFile(locale: Locale) async throws -> MacChecksumSelection? {
        let panel = NSOpenPanel()
        panel.title = MacToolboxText.t("选择要校验的文件", "Choose a file to verify", locale)
        panel.prompt = MacToolboxText.t("选择", "Choose", locale)
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = true
        guard await run(panel) == .OK, let url = panel.url else { return nil }
        return try MacChecksumSelection(url: url)
    }

    public static func chooseImage(locale: Locale) async -> URL? {
        let panel = NSOpenPanel()
        panel.title = MacToolboxText.t("选择包含二维码的图片", "Choose an image with a QR code", locale)
        panel.prompt = MacToolboxText.t("选择", "Choose", locale)
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.image]
        guard await run(panel) == .OK else { return nil }
        return panel.url
    }

    public static func savePNG(_ data: Data, suggestedName: String, locale: Locale) async throws -> URL? {
        let panel = NSSavePanel()
        panel.title = MacToolboxText.t("导出二维码", "Export QR code", locale)
        panel.nameFieldStringValue = suggestedName
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        guard await run(panel) == .OK, let url = panel.url else { return nil }
        try data.write(to: url, options: .atomic)
        return url
    }

    public static func saveText(_ text: String, suggestedName: String, contentType: UTType, locale: Locale,
                                title: String) async throws -> URL? {
        let panel = NSSavePanel()
        panel.title = title
        panel.prompt = MacToolboxText.t("导出", "Export", locale)
        panel.nameFieldStringValue = suggestedName
        panel.allowedContentTypes = [contentType]
        panel.canCreateDirectories = true
        guard await run(panel) == .OK, let url = panel.url else { return nil }
        try Data(text.utf8).write(to: url, options: .atomic)
        return url
    }

    private static func run(_ panel: NSSavePanel) async -> NSApplication.ModalResponse {
        await withCheckedContinuation { continuation in
            panel.begin { response in continuation.resume(returning: response) }
        }
    }

    private static func run(_ panel: NSOpenPanel) async -> NSApplication.ModalResponse {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: .cancel)
                    return
                }
                panel.begin { response in continuation.resume(returning: response) }
            }
        } onCancel: {
            Task { @MainActor in panel.cancel(nil) }
        }
    }
}
