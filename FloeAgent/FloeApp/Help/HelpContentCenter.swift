// SPDX-License-Identifier: MPL-2.0
import Foundation
import Combine
import FloeCore

/// The updater owns persistence and trust. This immutable value is only the
/// already installed payload projected into the offline reader.
struct HelpContentPackage: Sendable {
    let version: String
    let files: [String: Data]
}

enum HelpContentError: Error, LocalizedError, Equatable {
    case preparing, unavailable, expiredReference, conflictingVersion

    var errorDescription: String? {
        let chinese = Locale.preferredLanguages.first?.hasPrefix("zh") == true
        switch self {
        case .preparing: return chinese ? "正在载入指南。" : "Loading the guides."
        case .unavailable: return chinese ? "暂时无法打开指南。" : "The guides are currently unavailable."
        case .expiredReference: return chinese ? "此版本指南已不可用，请重新搜索。" : "This guide version is unavailable. Search again for a current reference."
        case .conflictingVersion: return chinese ? "指南更新未通过校验，已保留现有内容。" : "The guide update could not be verified. The existing content was retained."
        }
    }
}

/// One offline source for the reader and model tools. Preparing joins the
/// existing local content load; it never checks GitHub or installs a package.
@MainActor
final class HelpContentCenter: ObservableObject {
    typealias Files = [String: Data]
    typealias VersionComparison = @Sendable (String, String) throws -> ComparisonResult

    @Published private(set) var revision = 0
    @Published private(set) var errorMessage: String?
    @Published private(set) var isPrepared = false
    private(set) var selectedVersion: String?

    private let bundledFiles: @Sendable () throws -> Files
    private let installedPackage: @MainActor () -> HelpContentPackage?
    private let awaitInitialLoad: @MainActor () async -> Void
    private let compareVersions: VersionComparison
    private let digest: @Sendable (Data) -> String
    private var preparation: Task<Void, Never>?
    private var bundled: HelpContentPackage?
    private var snapshots: [String: [HelpLanguage: HelpLibrarySnapshot]] = [:]
    private var identities: [String: String] = [:]
    private var retainedVersions: [String] = []
    private let maximumRetainedVersions = 4

    init(
        bundledFiles: @escaping @Sendable () throws -> Files,
        installedPackage: @escaping @MainActor () -> HelpContentPackage?,
        awaitInitialLoad: @escaping @MainActor () async -> Void,
        compareVersions: @escaping VersionComparison,
        digest: @escaping @Sendable (Data) -> String
    ) {
        self.bundledFiles = bundledFiles
        self.installedPackage = installedPackage
        self.awaitInitialLoad = awaitInitialLoad
        self.compareVersions = compareVersions
        self.digest = digest
    }

    func prepare() async {
        if let preparation { await preparation.value; return }
        let task = Task { @MainActor [self] in
            await awaitInitialLoad()
            let readFiles = bundledFiles
            do {
                let files = try await Task.detached(priority: .utility) { try readFiles() }.value
                bundled = HelpContentPackage(version: HelpBundleMetadata.bundledVersion, files: files)
            } catch {
                errorMessage = HelpContentError.unavailable.localizedDescription
            }
            isPrepared = true
            reload()
        }
        preparation = task
        await task.value
    }

    /// Called only by the service after its atomic install/rollback state and
    /// file cache have both been mirrored. Open readers retain their snapshot.
    func reload() {
        guard isPrepared else { return }
        let installed = installedPackage()
        do {
            let preferred: HelpContentPackage?
            if let installed, let bundled {
                // The actual SignedContentVersion comparator is injected by
                // ContentUpdateCenter. Equal immutable versions keep installed.
                preferred = try compareVersions(installed.version, bundled.version) == .orderedAscending
                    ? bundled : installed
            } else {
                preferred = installed ?? bundled
            }
            guard let preferred else { throw HelpContentError.unavailable }
            try select(preferred)
            errorMessage = nil
        } catch {
            // A corrupt or incompatible update never discards a valid active
            // snapshot. On first use, a valid bundled copy remains available.
            if selectedVersion == nil, let bundled { try? select(bundled) }
            errorMessage = HelpContentError.conflictingVersion.localizedDescription
        }
    }

    func snapshot(language: HelpLanguage) throws -> HelpLibrarySnapshot {
        guard isPrepared else { throw HelpContentError.preparing }
        guard let selectedVersion, let snapshot = snapshots[selectedVersion]?[language] else {
            throw HelpContentError.unavailable
        }
        return snapshot
    }

    func snapshot(for reference: HelpReference) throws -> HelpLibrarySnapshot {
        guard isPrepared else { throw HelpContentError.preparing }
        guard reference.packageID == HelpBundleMetadata.packageID,
              let snapshot = snapshots[reference.version]?[reference.language] else {
            throw HelpContentError.expiredReference
        }
        // Validate the complete identity rather than silently retargeting an
        // old reference to the currently selected package.
        _ = try snapshot.reference(articleID: reference.articleID, sectionID: reference.sectionID)
        return snapshot
    }

    func search(_ query: String, language: HelpLanguage, limit: Int = 12) throws -> [HelpSearchHit] {
        try snapshot(language: language).search(query, limit: limit)
    }

    func read(_ reference: HelpReference, offset: Int = 0, maximumCharacters: Int = 6000) throws -> HelpReadResult {
        try snapshot(for: reference).read(reference, offset: offset, maximumCharacters: maximumCharacters)
    }

    private func select(_ package: HelpContentPackage) throws {
        guard let manifestBytes = package.files[HelpBundleMetadata.manifestPath] else {
            throw HelpContentError.unavailable
        }
        // Version bytes are immutable even while retained for an open reader.
        let identity = digest(manifestBytes)
        if let existing = identities[package.version], existing != identity {
            throw HelpContentError.conflictingVersion
        }
        try HelpLibrarySnapshot.validatePackage(files: package.files, digest: digest)
        var localized: [HelpLanguage: HelpLibrarySnapshot] = [:]
        for language in HelpLanguage.allCases {
            let snapshot = try HelpLibrarySnapshot(files: package.files, language: language, digest: digest)
            guard snapshot.manifest.id == HelpBundleMetadata.packageID,
                  snapshot.manifest.version == package.version else {
                throw HelpContentError.conflictingVersion
            }
            localized[language] = snapshot
        }
        snapshots[package.version] = localized
        identities[package.version] = identity
        retainedVersions.removeAll { $0 == package.version }
        retainedVersions.append(package.version)
        while retainedVersions.count > maximumRetainedVersions {
            let old = retainedVersions.removeFirst()
            snapshots[old] = nil
            identities[old] = nil
        }
        selectedVersion = package.version
        revision &+= 1
    }

    /// The folder reference preserves resource paths from the signed package;
    /// never resolve arbitrary model URLs or read files outside this root.
    nonisolated static func readBundledFiles(at root: URL?) throws -> Files {
        guard let root, root.isFileURL else { throw HelpContentError.unavailable }
        let manager = FileManager.default
        guard let iterator = manager.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]) else {
            throw HelpContentError.unavailable
        }
        var files: Files = [:]
        var totalBytes = 0
        for case let file as URL in iterator {
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { throw HelpContentError.unavailable }
            guard values.isRegularFile == true else { continue }
            let relative = String(file.path.dropFirst(root.path.count + 1))
            guard !relative.isEmpty, files.count < 128 else { throw HelpContentError.unavailable }
            let data = try Data(contentsOf: file, options: [.mappedIfSafe])
            totalBytes += data.count
            guard data.count <= HelpBundleMetadata.maximumFileBytes, totalBytes <= 8_388_608 else {
                throw HelpContentError.unavailable
            }
            files[relative] = data
        }
        return files
    }
}
