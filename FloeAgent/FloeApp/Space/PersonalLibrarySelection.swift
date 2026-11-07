// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation

/// One visible row in the Files page: either a durable work or a plain folder.
/// Identity is the record id (works) or the library-relative path plus folder
/// resource identity (folders), so a stale row can never merge with a moved
/// original and a replaced folder can never absorb its unrelated successor.
enum PersonalLibrarySelectionItem: Hashable, Identifiable, Sendable {
    case work(PersonalContentRecord)
    case folder(PersonalLibraryFolder)

    var id: String {
        switch self {
        case .work(let record): "work:" + record.id.uuidString
        case .folder(let folder): "folder:" + folder.relativePath + ":" + folder.resourceIdentity
        }
    }
    var title: String {
        switch self {
        case .work(let record): record.title
        case .folder(let folder): folder.name
        }
    }
    var relativePath: String {
        switch self {
        case .work(let record): record.relativePath
        case .folder(let folder): folder.relativePath
        }
    }
    /// True when this item sits strictly inside the given folder path. A work
    /// directly in the folder is covered; a folder is covered only by a real
    /// ancestor, never by itself.
    func isInside(_ components: [String]) -> Bool {
        switch self {
        case .work(let record): record.folders.starts(with: components)
        case .folder(let folder): folder.components.count > components.count && folder.components.starts(with: components)
        }
    }
}

/// Shared by the list and thumbnail layouts. Selection is always bounded to
/// the rows the user can currently see: `selectAll` replaces the set with the
/// supplied visible results instead of accumulating, and nothing outside that
/// scope can silently join the deletion set after a refresh or a search.
struct PersonalLibrarySelectionModel: Sendable {
    private(set) var isSelecting = false
    private(set) var selected: [String: PersonalLibrarySelectionItem] = [:]

    var isEmpty: Bool { selected.isEmpty }

    mutating func begin(with item: PersonalLibrarySelectionItem? = nil) {
        isSelecting = true
        selected.removeAll()
        if let item { selected[item.id] = item }
    }
    mutating func cancel() {
        isSelecting = false
        selected.removeAll()
    }
    /// Replaces the selection with exactly the currently visible results.
    mutating func selectAll(_ visible: [PersonalLibrarySelectionItem]) {
        guard isSelecting else { return }
        selected = Dictionary(visible.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
    }
    mutating func toggle(_ item: PersonalLibrarySelectionItem) {
        guard isSelecting else { return }
        // Tapping an item covered by a selected ancestor narrows the
        // selection to just that item; it is never a silent no-op and it
        // never deselects unrelated rows.
        let ancestors = selected.values.filter { existing in
            guard case .folder(let folder) = existing else { return false }
            return item.isInside(folder.components)
        }
        if !ancestors.isEmpty {
            for ancestor in ancestors { selected.removeValue(forKey: ancestor.id) }
            selected[item.id] = item
            return
        }
        if selected.removeValue(forKey: item.id) == nil { selected[item.id] = item }
    }
    /// The deletion set. Selected folders absorb their selected descendants so
    /// no original is visited twice, no child result hides an ancestor
    /// failure, and no sibling with a matching name prefix is touched.
    func effectiveSelection() -> [PersonalLibrarySelectionItem] {
        Self.deduplicated(selected.values.sorted {
            $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending
        })
    }
    /// A row shows checked exactly when it is part of the deletion set.
    func isSelected(_ item: PersonalLibrarySelectionItem) -> Bool {
        selected[item.id] != nil || selected.values.contains { existing in
            guard case .folder(let folder) = existing else { return false }
            return item.isInside(folder.components)
        }
    }

    /// Parent/child dedupe shared with the batch operation so the UI model and
    /// the executor can never disagree about what will be deleted. Exact
    /// duplicates collapse to one visit as well.
    static func deduplicated(_ items: [PersonalLibrarySelectionItem]) -> [PersonalLibrarySelectionItem] {
        var seen = Set<String>()
        let unique = items.filter { seen.insert($0.id).inserted }
        let folders = unique.compactMap { item -> PersonalLibraryFolder? in
            if case .folder(let folder) = item { return folder }
            return nil
        }
        return unique.filter { item in
            !folders.contains { item.isInside($0.components) }
        }
    }
}

struct PersonalLibraryBatchFailure: Sendable {
    let item: PersonalLibrarySelectionItem
    let message: String
}

/// The batch outcome keeps successes and failures apart so the UI can report
/// both honestly; undeleted items stay in the library for the user to handle.
struct PersonalLibraryBatchDeleteResult: Sendable {
    var deleted: [PersonalLibrarySelectionItem] = []
    var failed: [PersonalLibraryBatchFailure] = []

    var summary: String {
        if failed.isEmpty {
            return deleted.isEmpty ? "" : IDELanguageRunText.t("已删除 \(deleted.count) 项。", "Deleted \(deleted.count) item(s).")
        }
        return IDELanguageRunText.t("已删除 \(deleted.count) 项，\(failed.count) 项未能删除。",
            "Deleted \(deleted.count) item(s); \(failed.count) could not be deleted.")
    }
    /// Bounded per-item reasons for the partial-failure notice.
    var failureDetail: String {
        failed.prefix(3).map { "“\($0.item.title)”：\($0.message)" }.joined(separator: "\n")
    }
}
#endif
