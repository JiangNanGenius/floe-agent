import AppKit
import UniformTypeIdentifiers
import FloeMacMediaCore

/// Image import through a user-selected file. This is the only image authority
/// the scanner uses: no Photos library, no folder crawl, no bookmark creation.
/// Imported bytes stay in memory until the user explicitly exports them.
@MainActor
public final class MacImageImportService {
    public init() {}

    /// Presents `NSOpenPanel`. Returns nil when the user cancels. Throws a
    /// stable `MacMediaFailure` for an unreadable, non-regular, symlinked or
    /// oversized selection.
    public func chooseImageData(isStillAuthorized: @MainActor () -> Bool = { true }) throws -> Data? {
        guard isStillAuthorized() else { return nil }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.canCreateDirectories = false
        panel.resolvesAliases = false
        panel.isExtensionHidden = false
        panel.prompt = nil
        guard panel.runModal() == .OK, let url = panel.url else { return nil }

        return try Self.readSelection(url, isStillAuthorized: isStillAuthorized) { selected in
            let scoped = selected.startAccessingSecurityScopedResource()
            defer { if scoped { selected.stopAccessingSecurityScopedResource() } }
            return try MacFileImageReader.readImageData(at: selected)
        }
    }

    static func readSelection<T>(_ url: URL, isStillAuthorized: @MainActor () -> Bool,
                                 read: @MainActor (URL) throws -> T) throws -> T? {
        guard isStillAuthorized() else { return nil }
        return try read(url)
    }
}

/// Save-panel export. The panel is the user's authorization for exactly one
/// destination; the writer then performs one atomic 0600 write and verifies the
/// byte count. Nothing is saved without this explicit choice.
@MainActor
public final class MacExportSaver {
    public init() {}

    /// Only selects a destination; the app-owned draft performs the write.
    public func chooseDestination(format: MacScanExportFormat, suggestedFilename: String,
                                  isStillAuthorized: @MainActor () -> Bool) -> URL? {
        guard isStillAuthorized() else { return nil }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [Self.contentType(for: format)]
        panel.allowsOtherFileTypes = false
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = suggestedFilename
        guard panel.runModal() == .OK, let url = panel.url, isStillAuthorized() else { return nil }
        return url
    }

    /// Returns the saved URL, or nil when the user cancels.
    public func save(_ artifact: MacExportArtifact) throws -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [Self.contentType(for: artifact.format)]
        panel.allowsOtherFileTypes = false
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = artifact.suggestedFilename
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        try MacSafeFileWriter.write(artifact, to: url)
        return url
    }

    private static func contentType(for format: MacScanExportFormat) -> UTType {
        switch format {
        case .png: .png
        case .pdf: .pdf
        case .txt: .plainText
        case .csv: .commaSeparatedText
        }
    }
}
