// FloeApp — Device-wide font library shared by every Floe workspace.

#if canImport(UIKit)
import Foundation
import CoreText
import CryptoKit
import FloeCore
import FloeExecution
import FloeModels
import FloeTools
import FloeWorkspace

struct ManagedFontRecord: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let fileName: String
    let displayName: String
    let familyNames: [String]
    let postScriptNames: [String]
    let byteCount: Int64
}

/// Real CoreText registration verification, shared by the bundled and the
/// device font stores.
///
/// `CTFontManagerCreateFontDescriptorsFromURL` parses a font file; it returns
/// descriptors for a file that was never registered for this process.
/// Treating those descriptors as proof of success is exactly how a failed CJK
/// registration stayed invisible while the engine rendered every Chinese
/// glyph as a tofu box. The only reliable check is that the process resolves
/// the font's declared PostScript name back to that same font.
enum CoreTextFontRegistration {
    /// `kCTFontManagerErrorAlreadyRegistered`: a duplicate registration, not a
    /// defect.
    static let alreadyRegisteredCode = 105

    enum Outcome: Equatable {
        case registered
        case alreadyRegistered
        case failed
    }

    private static func errorCode(_ error: Unmanaged<CFError>?) -> Int? {
        guard let error else { return nil }
        return ((error.takeRetainedValue() as Error) as NSError).code
    }

    /// The PostScript names a font file declares (parse-only, no registration).
    static func declaredPostScriptNames(at url: URL) -> [String] {
        guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL)
                as? [CTFontDescriptor] else { return [] }
        return descriptors.compactMap {
            CTFontDescriptorCopyAttribute($0, kCTFontNameAttribute) as? String
        }.filter { !$0.isEmpty }
    }

    /// True when this process resolves `name` to a font with exactly that
    /// PostScript name. A missing font resolves to a fallback (or nil), never
    /// to the requested name, so a merely parseable file can not satisfy this.
    static func resolves(postScriptName name: String) -> Bool {
        guard !name.isEmpty else { return false }
        let font = CTFontCreateWithNameAndOptions(name as CFString, 12, nil,
                                                  CTFontOptions.preventAutoActivation)
        return (CTFontCopyPostScriptName(font) as String)
            .caseInsensitiveCompare(name) == .orderedSame
    }

    /// Classifies one registration attempt against real resolution.
    static func outcome(registered: Bool,
                        error: Unmanaged<CFError>?,
                        url: URL) -> (Outcome, String?) {
        let names = declaredPostScriptNames(at: url)
        if let resolved = names.first(where: resolves(postScriptName:)) {
            let duplicate = !registered && errorCode(error) == alreadyRegisteredCode
            return (duplicate ? .alreadyRegistered : .registered, resolved)
        }
        return (.failed, names.first)
    }

    /// Registers `url` for this process and verifies the registration (not the
    /// file's parseability). Returns the outcome and the resolved name, if any.
    static func register(url: URL) -> (Outcome, String?) {
        var error: Unmanaged<CFError>?
        let success = CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error)
        return outcome(registered: success, error: error, url: url)
    }
}

enum DeviceFontError: LocalizedError {
    case invalidFont
    case unsupportedExtension
    case tooLarge
    case badResponse(Int)
    case notFound

    var errorDescription: String? {
        switch self {
        case .invalidFont: "文件不是 CoreText 可识别的字体。"
        case .unsupportedExtension: "仅支持 TTF、OTF、TTC 和 OTC 字体。"
        case .tooLarge: "字体文件超过 32 MB 限制。"
        case .badResponse(let code): "字体下载失败（HTTP \(code)）。"
        case .notFound: "找不到这个 Floe 全局字体。"
        }
    }
}

/// Arbitrary downloaded fonts cannot be installed silently for every iOS app.
/// Floe therefore stores one validated copy in Application Support and
/// process-registers it at launch, making it global to every Floe workspace.
actor DeviceFontStore {
    static let maximumFontBytes = 32 * 1_024 * 1_024

    let rootURL: URL

    init(rootURL: URL? = nil) {
        if let rootURL {
            self.rootURL = rootURL
        } else {
            let support = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first ?? FileManager.default.temporaryDirectory
            self.rootURL = support
                .appendingPathComponent("FloeAgent", isDirectory: true)
                .appendingPathComponent("Fonts", isDirectory: true)
        }
    }

    func activateManagedFonts() -> [String] {
        var failures: [String] = []
        for url in fontFiles() {
            // A failed registration is only ignored when the process really
            // resolves the font (an already-registered font): descriptors that
            // merely parse from the file never count as success.
            let (outcome, _) = CoreTextFontRegistration.register(url: url)
            if outcome == .failed { failures.append(url.lastPathComponent) }
        }
        return failures
    }

    func list() -> [ManagedFontRecord] {
        fontFiles().compactMap { try? inspect(url: $0) }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    func importFont(from sourceURL: URL) throws -> ManagedFontRecord {
        try ensureDirectory()
        let values = try sourceURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true else { throw DeviceFontError.invalidFont }
        guard let size = values.fileSize, size <= Self.maximumFontBytes else {
            throw DeviceFontError.tooLarge
        }
        let ext = try validatedExtension(sourceURL.pathExtension)
        let data = try Data(contentsOf: sourceURL, options: [.mappedIfSafe])
        guard data.count <= Self.maximumFontBytes else { throw DeviceFontError.tooLarge }
        return try persist(data: data, extension: ext)
    }

    func install(from remoteURL: URL) async throws -> ManagedFontRecord {
        try PublicNetworkTargetPolicy.validate(remoteURL)
        let ext = try validatedExtension(remoteURL.pathExtension)
        let data = try await PublicFontDownloader.download(
            remoteURL,
            maximumBytes: Self.maximumFontBytes
        )
        return try persist(data: data, extension: ext)
    }

    func remove(id: String) throws {
        guard id.count == 64, id.allSatisfy({ $0.isHexDigit }) else {
            throw DeviceFontError.notFound
        }
        guard let url = fontFiles().first(where: { $0.deletingPathExtension().lastPathComponent == id }) else {
            throw DeviceFontError.notFound
        }
        var error: Unmanaged<CFError>?
        _ = CTFontManagerUnregisterFontsForURL(url as CFURL, .process, &error)
        try FileManager.default.removeItem(at: url)
    }

    private func persist(data: Data, extension ext: String) throws -> ManagedFontRecord {
        try ensureDirectory()
        let digest = FloeDigest.sha256Hex(data)
        let destination = rootURL.appendingPathComponent("\(digest).\(ext)")
        if !FileManager.default.fileExists(atPath: destination.path) {
            let temporary = rootURL.appendingPathComponent(".\(UUID().uuidString).\(ext)")
            defer { try? FileManager.default.removeItem(at: temporary) }
            try data.write(to: temporary, options: [.atomic])
            // Validate the bytes before they receive a stable managed name.
            _ = try inspect(url: temporary, idOverride: digest, fileNameOverride: destination.lastPathComponent)
            try FileManager.default.moveItem(at: temporary, to: destination)
        }
        var error: Unmanaged<CFError>?
        let registered = CTFontManagerRegisterFontsForURL(destination as CFURL, .process, &error)
        let (outcome, _) = CoreTextFontRegistration.outcome(registered: registered,
                                                            error: error,
                                                            url: destination)
        guard outcome != .failed else {
            // The bytes parse but this process can not resolve the font: it is
            // unusable, so it must not stay looking installed.
            try? FileManager.default.removeItem(at: destination)
            throw DeviceFontError.invalidFont
        }
        return try inspect(url: destination)
    }

    private func inspect(
        url: URL,
        idOverride: String? = nil,
        fileNameOverride: String? = nil
    ) throws -> ManagedFontRecord {
        guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor],
              !descriptors.isEmpty else { throw DeviceFontError.invalidFont }
        let familyNames = Set(descriptors.compactMap {
            CTFontDescriptorCopyAttribute($0, kCTFontFamilyNameAttribute) as? String
        }).sorted()
        let postScriptNames = Set(descriptors.compactMap {
            CTFontDescriptorCopyAttribute($0, kCTFontNameAttribute) as? String
        }).sorted()
        guard !familyNames.isEmpty || !postScriptNames.isEmpty else { throw DeviceFontError.invalidFont }
        let displayName = descriptors.compactMap {
            CTFontDescriptorCopyAttribute($0, kCTFontDisplayNameAttribute) as? String
        }.first ?? postScriptNames.first ?? familyNames.first ?? url.deletingPathExtension().lastPathComponent
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        return ManagedFontRecord(
            id: idOverride ?? url.deletingPathExtension().lastPathComponent,
            fileName: fileNameOverride ?? url.lastPathComponent,
            displayName: displayName,
            familyNames: familyNames,
            postScriptNames: postScriptNames,
            byteCount: size
        )
    }

    private func ensureDirectory() throws {
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    }

    private func fontFiles() -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ))?.filter { ["ttf", "otf", "ttc", "otc"].contains($0.pathExtension.lowercased()) } ?? []
    }

    private func validatedExtension(_ value: String) throws -> String {
        let ext = value.lowercased()
        guard ["ttf", "otf", "ttc", "otc"].contains(ext) else {
            throw DeviceFontError.unsupportedExtension
        }
        return ext
    }
}

private final class PublicFontRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let url = request.url, (try? PublicNetworkTargetPolicy.validate(url)) != nil else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}

private enum PublicFontDownloader {
    static func download(_ url: URL, maximumBytes: Int) async throws -> Data {
        try PublicNetworkTargetPolicy.validate(url)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 90
        let session = URLSession(
            configuration: configuration,
            delegate: PublicFontRedirectDelegate(),
            delegateQueue: nil
        )
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(from: url)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw DeviceFontError.badResponse((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        if response.expectedContentLength > Int64(maximumBytes) { throw DeviceFontError.tooLarge }
        var data = Data()
        if response.expectedContentLength > 0 {
            data.reserveCapacity(min(maximumBytes, Int(response.expectedContentLength)))
        }
        for try await byte in bytes {
            guard data.count < maximumBytes else { throw DeviceFontError.tooLarge }
            data.append(byte)
        }
        return data
    }
}

private enum FontToolOutput {
    static func make(_ text: String) -> ToolExecutionOutput {
        return ToolExecutionOutput(digesting: text, exitStatus: 0)
    }
}

struct FontListTool: AgentTool {
    struct Arguments: Decodable, Sendable {}
    static let name = "font.list"
    static let toolDescription = "List fonts installed once in Floe's global font library. These fonts are available to document and PDF work in every Floe workspace; check this before downloading a missing font again."
    static let parametersJSON = #"{"type":"object","additionalProperties":false}"#
    static let riskLabels: Set<RiskLabel> = []
    static let isSideEffecting = false
    let store: DeviceFontStore
    func validate(_ args: Arguments) throws {}
    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled()
        let records = await store.list()
        let payload = records.map {
            "\($0.id)\t\($0.displayName)\t\($0.familyNames.joined(separator: ", "))\t\($0.byteCount) bytes"
        }.joined(separator: "\n")
        return FontToolOutput.make(payload.isEmpty ? "No Floe-global fonts are installed." : payload)
    }
}

struct FontInstallTool: AgentTool {
    struct Arguments: Decodable, Sendable { let url: String?; let path: String? }
    static let name = "font.install"
    static let toolDescription = "Install one validated TTF/OTF/TTC/OTC font into Floe's global font library from either a direct public HTTPS URL or a workspace-relative path. Use when a document needs a missing font. One digest-addressed copy is reused by every Floe workspace. Private/LAN URLs, credentials, non-font files, and files over 32 MB are rejected."
    static let parametersJSON = #"{"type":"object","properties":{"url":{"type":"string","description":"Direct public HTTPS font URL"},"path":{"type":"string","description":"Workspace-relative font file"}},"additionalProperties":false,"oneOf":[{"required":["url"]},{"required":["path"]}]}"#
    static let riskLabels: Set<RiskLabel> = [.networkAccess, .readsFiles, .writesFiles]
    static let isSideEffecting = true
    let store: DeviceFontStore
    func validate(_ args: Arguments) throws {
        let hasURL = !(args.url?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        let hasPath = !(args.path?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        guard hasURL != hasPath else {
            throw FloeError.validationFailed("Provide exactly one of url or path")
        }
    }
    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled()
        let record: ManagedFontRecord
        if let raw = args.url?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            guard let url = URL(string: raw) else { throw FloeError.validationFailed("Invalid font URL") }
            record = try await store.install(from: url)
        } else {
            guard let path = args.path?.trimmingCharacters(in: .whitespacesAndNewlines),
                  let root = context.workspaceRootURL else {
                throw FloeError.invalidConfiguration("No task workspace is available")
            }
            try context.authorizeWorkspacePath(path)
            let source = try WorkspacePathGuard(rootURL: root).resolve(path)
            record = try await store.importFont(from: source)
        }
        return FontToolOutput.make("Installed Floe-global font \(record.displayName) (\(record.id)); available to every Floe workspace.")
    }
}

struct FontRemoveTool: AgentTool {
    struct Arguments: Decodable, Sendable { let id: String }
    static let name = "font.remove"
    static let toolDescription = "Permanently remove one digest-addressed font from Floe's global font library. This affects every Floe workspace and therefore remains approval-gated."
    static let parametersJSON = #"{"type":"object","properties":{"id":{"type":"string","pattern":"^[0-9a-fA-F]{64}$"}},"required":["id"],"additionalProperties":false}"#
    static let riskLabels: Set<RiskLabel> = [.deletesFiles]
    static let isSideEffecting = true
    let store: DeviceFontStore
    func validate(_ args: Arguments) throws {
        guard args.id.count == 64, args.id.allSatisfy({ $0.isHexDigit }) else {
            throw FloeError.validationFailed("id must be a SHA-256 font identifier")
        }
    }
    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled()
        try await store.remove(id: args.id.lowercased())
        return FontToolOutput.make("Removed Floe-global font \(args.id.lowercased()).")
    }
}

func registerFontTools(store: DeviceFontStore, registry: ToolRunnerRegistry = .shared) {
    ToolCatalog.register(FontListTool.self)
    registry.register(FontListTool(store: store))
    ToolCatalog.register(FontInstallTool.self)
    registry.register(FontInstallTool(store: store))
    ToolCatalog.register(FontRemoveTool.self)
    registry.register(FontRemoveTool(store: store))
}
#endif
