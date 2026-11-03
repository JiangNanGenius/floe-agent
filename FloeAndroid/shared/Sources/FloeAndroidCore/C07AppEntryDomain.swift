// SPDX-License-Identifier: MPL-2.0
//
// C07 App-entry shared contract.
//
// This is the cross-platform, side-effect-free policy for external links and
// share/open descriptors. It deliberately owns NO storage, grant, network,
// task, approval or execution authority: parsing a link or validating a share
// never opens a file, starts a run or approves anything. The Android platform
// host (app/host/entryflow) performs the real Intent, grant, store and Notes
// hand-offs; this file keeps the contract identical to the iOS donor.
import Foundation

// MARK: - Routes

/// A navigation or intake request, never authority to execute or read.
public enum C07AppEntryRoute: Equatable, Sendable {
    case newTask
    case task(UUID)
    case schedule(UUID)
    case share(UUID?)

    public static let maximumURLBytes = 8_192

    public static func parse(_ raw: String) throws -> Self {
        guard raw.utf8.count <= maximumURLBytes else {
            throw C07AppEntryRouteError.tooLong
        }
        guard !raw.isEmpty,
              !raw.unicodeScalars.contains(where: { $0.value < 0x21 || $0.value == 0x7F }) else {
            throw C07AppEntryRouteError.malformedURL
        }
        guard raw.lowercased().hasPrefix("floe://") else {
            throw C07AppEntryRouteError.unsupportedScheme
        }
        guard let parts = URLComponents(string: raw),
              parts.scheme?.lowercased() == "floe",
              parts.user == nil,
              parts.password == nil,
              parts.port == nil,
              parts.fragment == nil else {
            throw C07AppEntryRouteError.malformedURL
        }
        let host = parts.host?.lowercased() ?? ""
        let path = parts.percentEncodedPath
        guard !path.contains("%"), !path.contains("\\"), !path.contains("..") else {
            throw C07AppEntryRouteError.malformedURL
        }
        let query = parts.percentEncodedQuery
        switch host {
        case "new":
            guard path.isEmpty || path == "/" else {
                throw C07AppEntryRouteError.malformedURL
            }
            guard query == nil else { throw C07AppEntryRouteError.unexpectedParameters }
            return .newTask
        case "task":
            return .task(try parseIDRoute(path: path, query: query))
        case "schedule":
            return .schedule(try parseIDRoute(path: path, query: query))
        case "share":
            guard path.isEmpty || path == "/" else {
                throw C07AppEntryRouteError.malformedURL
            }
            guard let query else { return .share(nil) }
            guard !query.contains("%"), !query.contains("&"),
                  query.filter({ $0 == "=" }).count == 1 else {
                throw C07AppEntryRouteError.unexpectedParameters
            }
            let name = String(query.prefix(while: { $0 != "=" }))
            let value = String(query.drop(while: { $0 != "=" }).dropFirst())
            guard name == "intake" else {
                throw C07AppEntryRouteError.unexpectedParameters
            }
            guard let id = canonicalUUID(value) else {
                throw C07AppEntryRouteError.invalidTarget
            }
            return .share(id)
        default:
            throw C07AppEntryRouteError.unsupportedAction
        }
    }

    public static func parse(url: URL) throws -> Self {
        try parse(url.absoluteString)
    }

    public var url: URL {
        switch self {
        case .newTask:
            return URL(string: "floe://new")!
        case .task(let id):
            return URL(string: "floe://task/" + id.uuidString.lowercased())!
        case .schedule(let id):
            return URL(string: "floe://schedule/" + id.uuidString.lowercased())!
        case .share(let id):
            let suffix = id.map { "?intake=" + $0.uuidString.lowercased() } ?? ""
            return URL(string: "floe://share" + suffix)!
        }
    }

    private static func parseIDRoute(path: String, query: String?) throws -> UUID {
        guard query == nil else { throw C07AppEntryRouteError.unexpectedParameters }
        guard path.count == 37, path.hasPrefix("/") else {
            throw C07AppEntryRouteError.invalidTarget
        }
        guard let id = canonicalUUID(String(path.dropFirst())) else {
            throw C07AppEntryRouteError.invalidTarget
        }
        return id
    }

    private static func canonicalUUID(_ value: String) -> UUID? {
        let characters = Array(value)
        guard characters.count == 36,
              characters[8] == "-",
              characters[13] == "-",
              characters[18] == "-",
              characters[23] == "-",
              characters.allSatisfy({ $0.isHexDigit || $0 == "-" }),
              let parsed = UUID(uuidString: value),
              parsed.uuidString.lowercased() == value.lowercased() else {
            return nil
        }
        return parsed
    }
}

public enum C07AppEntryRouteError: String, Error, Equatable, Sendable {
    case tooLong
    case malformedURL
    case unsupportedScheme
    case unsupportedAction
    case unexpectedParameters
    case invalidTarget
}

// MARK: - Share/open policy

public enum C07ShareItemKind: String, Sendable, Equatable {
    case text
    case file
}

/// One untrusted incoming item descriptor. `byteCount == -1` means the
/// provider did not declare a size; the platform then enforces the cap while
/// copying. The type and size are hints, never permissions.
public struct C07ShareItemDescriptor: Equatable, Sendable {
    public var kind: C07ShareItemKind
    public var mimeType: String
    public var byteCount: Int64
    public var textBytes: Int64
    public var fileName: String?

    public init(
        kind: C07ShareItemKind,
        mimeType: String,
        byteCount: Int64,
        textBytes: Int64 = 0,
        fileName: String? = nil
    ) {
        self.kind = kind
        self.mimeType = mimeType
        self.byteCount = byteCount
        self.textBytes = textBytes
        self.fileName = fileName
    }
}

public struct C07ShareLimits: Equatable, Sendable {
    public var maxItems: Int
    public var maxTextBytes: Int64
    public var maxItemBytes: Int64
    public var maxTotalBytes: Int64
    public var maxFileNameCharacters: Int

    public init(
        maxItems: Int = 5,
        maxTextBytes: Int64 = 1_048_576,
        maxItemBytes: Int64 = 67_108_864,
        maxTotalBytes: Int64 = 134_217_728,
        maxFileNameCharacters: Int = 120
    ) {
        self.maxItems = max(1, maxItems)
        self.maxTextBytes = max(1, maxTextBytes)
        self.maxItemBytes = max(1, maxItemBytes)
        self.maxTotalBytes = max(1, maxTotalBytes)
        self.maxFileNameCharacters = max(1, maxFileNameCharacters)
    }

    public static let standard = C07ShareLimits()
}

public enum C07ShareRefusal: String, Error, Equatable, Sendable {
    case empty
    case itemLimit
    case textTooLarge
    case itemTooLarge
    case totalTooLarge
    case unsupportedType
    case packageMixed
    case invalidDescriptor
}

/// What admitted bytes ARE for consumer routing. Admission metadata only: it
/// grants no execution, rendering, upload or preview authority.
public enum C07ShareContentClass: String, Sendable, Equatable {
    case text
    case image
    case audio
    case video
    case pdf
    case office
    case cad
    case source
    case data
    case package
}

/// Existing Floe package owners. `rawValue` is the exact Data Exchange
/// `restoreKind` for the three archive kinds; `cad` is the directory package
/// owner. A package is handed to that owner for inspection/review and is never
/// restored, remapped or auto-imported by intake.
public enum C07SharePackageKind: String, Sendable, Equatable {
    case none
    case note
    case canvas
    case backup
    case cad

    public var isPackage: Bool { self != .none }
}

/// One admitted content format. The Android host additionally proves the
/// magic family; this shared table owns the consumer capability matrix.
public struct C07ShareFormat: Sendable, Equatable {
    public let mimeType: String
    public let contentClass: C07ShareContentClass
    public let extensions: Set<String>
    public let canTask: Bool
    public let canNotes: Bool
    public let packageKind: C07SharePackageKind

    public init(
        mimeType: String,
        contentClass: C07ShareContentClass,
        extensions: Set<String>,
        canTask: Bool = true,
        canNotes: Bool = true,
        packageKind: C07SharePackageKind = .none
    ) {
        self.mimeType = mimeType
        self.contentClass = contentClass
        self.extensions = extensions
        self.canTask = canTask
        self.canNotes = canNotes
        self.packageKind = packageKind
    }
}

public struct C07ShareAdmission: Equatable, Sendable {
    public let items: [C07ShareItemDescriptor]
    public let totalKnownBytes: Int64
    public let textBytes: Int64
    /// Both existing destinations accept bounded opaque data files. A package
    /// is never offered to Task/Notes; it has exactly one review owner.
    public let taskAvailable: Bool
    public let notesAvailable: Bool
    public let packageKind: C07SharePackageKind
}

public enum C07SharePolicy {
    /// Text/source/config extensions admitted as SOURCE data. They are stored
    /// as bytes only; nothing is rendered, parsed or executed.
    private static let textExtensions: Set<String> = [
        "txt", "text", "log", "csv", "tsv", "md", "markdown", "mdx", "rst", "org",
        "json", "jsonl", "ndjson", "json5", "xml", "yaml", "yml", "toml", "ini",
        "cfg", "conf", "config", "properties", "env", "lock", "sql", "sh", "bash",
        "zsh", "fish", "py", "pyw", "pyi", "js", "mjs", "cjs", "jsx", "ts", "mts",
        "cts", "tsx", "kt", "kts", "java", "scala", "groovy", "gradle", "c", "h",
        "cc", "cpp", "cxx", "hpp", "hh", "hxx", "m", "mm", "cs", "fs", "vb", "rs",
        "go", "rb", "php", "pl", "pm", "lua", "r", "swift", "dart", "ex", "exs",
        "erl", "hrl", "hs", "lhs", "clj", "cljs", "sol", "vue", "svelte", "astro",
        "html", "htm", "xhtml", "css", "scss", "sass", "less", "tex", "bib",
        "diff", "patch", "srt", "vtt", "asm", "s", "proto", "graphql", "gql",
        "cmake", "mk", "ninja", "plist",
    ]

    private static let sourceMimes: Set<String> = [
        "application/json", "application/xml", "application/javascript",
        "application/x-javascript", "application/typescript", "application/x-sh",
        "application/x-yaml", "application/yaml", "application/sql",
        "application/toml", "application/x-httpd-php", "application/x-python-code",
    ]

    /// Installable executable containers. No existing in-App consumer opens
    /// them, so they stay refused instead of being staged and mistaken for
    /// something Floe could run.
    private static let refusedExtensions: Set<String> = [
        "apk", "apks", "xapk", "aab", "dex", "odex", "vdex", "oat", "art",
        "elf", "exe", "dll", "msi", "dmg", "pkg", "deb", "rpm", "ipa", "jar",
        "class", "wasm",
    ]

    private static let packageFormats: [C07ShareFormat] = [
        C07ShareFormat(
            mimeType: "application/vnd.floe.package.note",
            contentClass: .package, extensions: ["floenote"],
            canTask: false, canNotes: false, packageKind: .note
        ),
        C07ShareFormat(
            mimeType: "application/vnd.floe.package.canvas",
            contentClass: .package, extensions: ["flocanvas"],
            canTask: false, canNotes: false, packageKind: .canvas
        ),
        C07ShareFormat(
            mimeType: "application/vnd.floe.package.backup",
            contentClass: .package, extensions: ["floebackup"],
            canTask: false, canNotes: false, packageKind: .backup
        ),
        C07ShareFormat(
            mimeType: "application/vnd.floe.cad.package",
            contentClass: .package, extensions: ["floecad"],
            canTask: false, canNotes: false, packageKind: .cad
        ),
    ]

    /// CAD is extension-routed here; the actual pinned reader proves content.
    private static let cadFormats: [C07ShareFormat] = [
        C07ShareFormat(mimeType: "application/dxf", contentClass: .cad, extensions: ["dxf"]),
        C07ShareFormat(mimeType: "application/acad", contentClass: .cad, extensions: ["dwg"]),
        C07ShareFormat(mimeType: "application/step", contentClass: .cad, extensions: ["step", "stp"]),
        C07ShareFormat(mimeType: "model/iges", contentClass: .cad, extensions: ["iges", "igs"]),
        C07ShareFormat(mimeType: "application/octet-stream", contentClass: .cad, extensions: ["brep"]),
        C07ShareFormat(mimeType: "model/gltf-binary", contentClass: .cad, extensions: ["glb"]),
        C07ShareFormat(mimeType: "text/plain", contentClass: .cad, extensions: ["gltf", "obj"]),
        C07ShareFormat(mimeType: "model/stl", contentClass: .cad, extensions: ["stl"]),
        C07ShareFormat(mimeType: "model/3mf", contentClass: .cad, extensions: ["3mf"]),
    ]

    private static let formats: [C07ShareFormat] = [
        C07ShareFormat(mimeType: "application/pdf", contentClass: .pdf, extensions: ["pdf"]),
        C07ShareFormat(mimeType: "image/png", contentClass: .image, extensions: ["png"]),
        C07ShareFormat(mimeType: "image/jpeg", contentClass: .image, extensions: ["jpg", "jpeg"]),
        C07ShareFormat(mimeType: "image/webp", contentClass: .image, extensions: ["webp"]),
        C07ShareFormat(mimeType: "image/gif", contentClass: .image, extensions: ["gif"]),
        C07ShareFormat(mimeType: "image/heic", contentClass: .image, extensions: ["heic"]),
        C07ShareFormat(mimeType: "image/heif", contentClass: .image, extensions: ["heif"]),
        C07ShareFormat(mimeType: "image/avif", contentClass: .image, extensions: ["avif"]),
        C07ShareFormat(mimeType: "image/bmp", contentClass: .image, extensions: ["bmp"]),
        C07ShareFormat(mimeType: "image/x-ms-bmp", contentClass: .image, extensions: ["bmp"]),
        C07ShareFormat(mimeType: "audio/mpeg", contentClass: .audio, extensions: ["mp3"]),
        C07ShareFormat(mimeType: "audio/mp4", contentClass: .audio, extensions: ["m4a", "mp4", "aac"]),
        C07ShareFormat(mimeType: "audio/x-m4a", contentClass: .audio, extensions: ["m4a"]),
        C07ShareFormat(mimeType: "audio/aac", contentClass: .audio, extensions: ["aac"]),
        C07ShareFormat(mimeType: "audio/wav", contentClass: .audio, extensions: ["wav"]),
        C07ShareFormat(mimeType: "audio/x-wav", contentClass: .audio, extensions: ["wav"]),
        C07ShareFormat(mimeType: "audio/flac", contentClass: .audio, extensions: ["flac"]),
        C07ShareFormat(mimeType: "audio/ogg", contentClass: .audio, extensions: ["ogg", "oga", "opus"]),
        C07ShareFormat(mimeType: "audio/opus", contentClass: .audio, extensions: ["opus"]),
        C07ShareFormat(mimeType: "audio/webm", contentClass: .audio, extensions: ["webm"]),
        C07ShareFormat(mimeType: "video/mp4", contentClass: .video, extensions: ["mp4", "m4v"]),
        C07ShareFormat(mimeType: "video/quicktime", contentClass: .video, extensions: ["mov"]),
        C07ShareFormat(mimeType: "video/x-m4v", contentClass: .video, extensions: ["m4v"]),
        C07ShareFormat(mimeType: "video/3gpp", contentClass: .video, extensions: ["3gp"]),
        C07ShareFormat(mimeType: "video/webm", contentClass: .video, extensions: ["webm"]),
        C07ShareFormat(mimeType: "video/x-matroska", contentClass: .video, extensions: ["mkv"]),
        C07ShareFormat(mimeType: "application/zip", contentClass: .data, extensions: ["zip"]),
        C07ShareFormat(mimeType: "application/x-zip-compressed", contentClass: .data, extensions: ["zip"]),
        C07ShareFormat(
            mimeType: "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
            contentClass: .office, extensions: ["docx"]
        ),
        C07ShareFormat(
            mimeType: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
            contentClass: .office, extensions: ["xlsx"]
        ),
        C07ShareFormat(
            mimeType: "application/vnd.openxmlformats-officedocument.presentationml.presentation",
            contentClass: .office, extensions: ["pptx"]
        ),
    ]

    private static let allFormats: [C07ShareFormat] = packageFormats + cadFormats + formats

    public static func textFormat() -> C07ShareFormat {
        C07ShareFormat(mimeType: "text/plain", contentClass: .source, extensions: textExtensions)
    }

    public static func normalizedMime(_ raw: String) -> String {
        let head = raw.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
            .first ?? ""
        return String(head)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    public static func extensionOf(_ fileName: String?) -> String {
        guard let fileName, let dot = fileName.lastIndex(of: ".") else { return "" }
        return String(fileName[fileName.index(after: dot)...]).lowercased()
    }

    public static func isRefusedExecutable(_ fileExtension: String) -> Bool {
        refusedExtensions.contains(fileExtension)
    }

    /// Resolves the provider hint and the file name to one admitted format.
    /// Package and CAD extensions are authoritative identity; magic/signature
    /// reconciliation happens in the platform host before admission.
    public static func format(for mimeType: String, fileName: String?) -> C07ShareFormat? {
        let mime = normalizedMime(mimeType)
        let fileExtension = extensionOf(fileName)
        if isRefusedExecutable(fileExtension) { return nil }
        if let package = packageFormats.first(where: { $0.extensions.contains(fileExtension) }) {
            return package
        }
        if let cad = cadFormats.first(where: { $0.extensions.contains(fileExtension) }) {
            return cad
        }
        if mime.isEmpty || mime == "application/octet-stream" {
            if let exact = formats.first(where: { $0.extensions.contains(fileExtension) }) {
                return exact
            }
            if textExtensions.contains(fileExtension) { return textFormat() }
            return nil
        }
        if let named = formats.first(where: {
            $0.mimeType == mime && $0.extensions.contains(fileExtension)
        }) {
            return named
        }
        if mime == "application/zip" || mime == "application/x-zip-compressed" {
            return formats.first(where: {
                $0.contentClass == .office && $0.extensions.contains(fileExtension)
            })
        }
        if mime.hasPrefix("text/") || sourceMimes.contains(mime) { return textFormat() }
        return nil
    }

    public static func isSupported(mimeType: String, fileName: String?) -> Bool {
        format(for: mimeType, fileName: fileName) != nil
    }

    public static func validate(
        _ items: [C07ShareItemDescriptor],
        limits: C07ShareLimits = .standard
    ) -> Result<C07ShareAdmission, C07ShareRefusal> {
        guard !items.isEmpty else { return .failure(.empty) }
        guard items.count <= limits.maxItems else { return .failure(.itemLimit) }
        var totalKnown: Int64 = 0
        var textBytes: Int64 = 0
        var packages = 0
        var packageKind: C07SharePackageKind = .none
        var taskAvailable = true
        var notesAvailable = true
        var normalized: [C07ShareItemDescriptor] = []
        normalized.reserveCapacity(items.count)
        for item in items {
            switch item.kind {
            case .text:
                guard item.textBytes > 0 else { return .failure(.empty) }
                textBytes += item.textBytes
                guard item.textBytes <= limits.maxTextBytes,
                      textBytes <= limits.maxTextBytes else {
                    return .failure(.textTooLarge)
                }
                normalized.append(C07ShareItemDescriptor(
                    kind: .text,
                    mimeType: "text/plain",
                    byteCount: item.textBytes,
                    textBytes: item.textBytes,
                    fileName: nil
                ))
            case .file:
                let mime = normalizedMime(item.mimeType)
                guard !mime.isEmpty, item.byteCount >= -1 else {
                    return .failure(.invalidDescriptor)
                }
                if let name = item.fileName {
                    guard name.count <= limits.maxFileNameCharacters,
                          name.utf8.count <= limits.maxFileNameCharacters * 4,
                          !name.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else {
                        return .failure(.invalidDescriptor)
                    }
                }
                guard let format = format(for: mime, fileName: item.fileName) else {
                    return .failure(.unsupportedType)
                }
                if format.packageKind.isPackage {
                    packages += 1
                    packageKind = format.packageKind
                }
                if !format.canTask { taskAvailable = false }
                if !format.canNotes { notesAvailable = false }
                if !format.packageKind.isPackage {
                    // Package bytes are streamed by the EXISTING review owner
                    // under its own budget; the entry owner never copies them.
                    guard item.byteCount <= limits.maxItemBytes else {
                        return .failure(.itemTooLarge)
                    }
                    if item.byteCount > 0 {
                        totalKnown += item.byteCount
                        guard totalKnown <= limits.maxTotalBytes else {
                            return .failure(.totalTooLarge)
                        }
                    }
                }
                normalized.append(C07ShareItemDescriptor(
                    kind: .file,
                    mimeType: mime,
                    byteCount: item.byteCount,
                    textBytes: 0,
                    fileName: item.fileName
                ))
            }
        }
        if packages > 0 {
            // A package has exactly ONE inspection/review owner. Mixing it
            // with other items would silently split or re-bundle it.
            guard packages == 1, items.count == 1, items[0].kind == .file else {
                return .failure(.packageMixed)
            }
            taskAvailable = false
            notesAvailable = false
        }
        return .success(C07ShareAdmission(
            items: normalized,
            totalKnownBytes: totalKnown,
            textBytes: textBytes,
            taskAvailable: taskAvailable,
            notesAvailable: notesAvailable,
            packageKind: packageKind
        ))
    }
}
