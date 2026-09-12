import Foundation
import FloeCore
import SWCompression

/// Reads and builds Debian binary packages. Compression for `control.tar.*`
/// and `data.tar.*` is injectable so the app can route gz/xz/zst through the
/// bundled runtime; the default supports gzip and uncompressed tar.
public struct DebArchive: Sendable {
    public struct Payload: Sendable {
        public var control: Deb822
        public var controlEntries: [TarArchive.Entry]
        public var dataEntries: [TarArchive.Entry]
        public var scripts: [String: String]
        public var containsNativeExecutable: Bool
        public var requiresBase: String?
    }

    public enum CompressionError: Error, CustomStringConvertible {
        case unsupported(String)

        public var description: String {
            switch self {
            case .unsupported(let name): return "unsupported compression: \(name)"
            }
        }
    }

    public typealias Decompressor = @Sendable (_ memberName: String, _ data: Data) throws -> Data

    public static let defaultDecompressor: Decompressor = { name, data in
        if name.hasSuffix(".tar") { return data }
        if name.hasSuffix(".tar.gz") || name.hasSuffix(".tgz") {
            return try GzipArchive.unarchive(archive: data)
        }
        throw CompressionError.unsupported(name)
    }

    public static func read(data: Data, decompressor: Decompressor = defaultDecompressor) throws -> Payload {
        let members = try ArArchive.read(data)
        guard members.contains(where: { $0.name == "debian-binary" }) else {
            throw FloeError.validationFailed("missing debian-binary member")
        }
        guard let controlMember = members.first(where: { $0.name.hasPrefix("control.tar") }) else {
            throw FloeError.validationFailed("missing control.tar member")
        }
        let controlTar = try decompressor(controlMember.name, controlMember.data)
        let controlEntries = try TarArchive.read(controlTar)
        guard let controlEntry = controlEntries.first(where: { $0.path == "./control" || $0.path == "control" }),
              let controlText = String(data: controlEntry.data, encoding: .utf8) else {
            throw FloeError.validationFailed("control file missing from control.tar")
        }
        let control = Deb822.parse(stanza: controlText)

        var dataEntries: [TarArchive.Entry] = []
        if let dataMember = members.first(where: { $0.name.hasPrefix("data.tar") }) {
            let dataTar = try decompressor(dataMember.name, dataMember.data)
            dataEntries = try TarArchive.read(dataTar)
        }
        var scripts: [String: String] = [:]
        for entry in controlEntries where entry.kind == .file {
            let name = (entry.path as NSString).lastPathComponent
            if ["preinst", "postinst", "prerm", "postrm"].contains(name),
               let text = String(data: entry.data, encoding: .utf8) {
                scripts[name] = text
            }
        }
        let containsNative = dataEntries.contains { entry in
            entry.kind == .file && ArArchive.containsNativeExecutable(entry.data)
        }
        return Payload(
            control: control,
            controlEntries: controlEntries,
            dataEntries: dataEntries,
            scripts: scripts,
            containsNativeExecutable: containsNative,
            requiresBase: control["Floe-Requires-Base"]
        )
    }

    public static func build(
        control: Deb822,
        dataEntries: [TarArchive.Entry],
        controlEntries extraControlEntries: [TarArchive.Entry] = [],
        scripts: [String: String] = [:],
        compress: Bool = true
    ) -> Data {
        var controlEntries = extraControlEntries
        controlEntries.insert(
            TarArchive.Entry(path: "./control", kind: .file, data: Data(control.serialized.utf8)),
            at: 0
        )
        if !scripts.isEmpty {
            controlEntries.insert(
                TarArchive.Entry(path: "./md5sums", kind: .file, data: Data()),
                at: controlEntries.count
            )
        }
        for (name, source) in scripts.sorted(by: { $0.key < $1.key }) {
            controlEntries.append(TarArchive.Entry(
                path: "./\(name)",
                kind: .file,
                mode: 0o755,
                data: Data(source.utf8)
            ))
        }
        let controlTar = TarArchive.write(controlEntries)
        let dataTar = TarArchive.write(dataEntries)
        let controlMember: ArArchive.Member
        let dataMember: ArArchive.Member
        if compress {
            let controlGz = try? GzipArchive.archive(data: controlTar)
            let dataGz = try? GzipArchive.archive(data: dataTar)
            controlMember = ArArchive.Member(name: "control.tar.gz", data: controlGz ?? controlTar)
            dataMember = ArArchive.Member(name: "data.tar.gz", data: dataGz ?? dataTar)
        } else {
            controlMember = ArArchive.Member(name: "control.tar", data: controlTar)
            dataMember = ArArchive.Member(name: "data.tar", data: dataTar)
        }
        return ArArchive.write([
            ArArchive.Member(name: "debian-binary", data: Data("2.0\n".utf8)),
            controlMember,
            dataMember
        ])
    }

    /// Enforcement policy used by dpkg/apt before anything is unpacked.
    public enum Installability: Sendable, Equatable {
        case compatible
        case nativePayload
        case dataOnly
    }

    public static func installability(of payload: Payload) -> Installability {
        guard payload.containsNativeExecutable else { return .compatible }
        let dataOnly = payload.control["Floe-Data-Only"]?.lowercased() == "true"
        return dataOnly ? .dataOnly : .nativePayload
    }
}
