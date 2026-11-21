// SPDX-License-Identifier: MPL-2.0
//
// Space "Files" root selection for the production Mac workbench.
//
// Projects stay optional: every conversation — including the unsaved new-task
// draft — already owns a per-task file workspace through the host's
// `fileWorkspaceForCurrentTask`, and the Space browser adds a third choice on
// top of explicit projects: the app-owned default conversations directory
// that aggregates every task's folder (`defaultConversationsDirectory`),
// plus any ad-hoc folder the user picked directly (remembered across
// launches). This file owns only that selection model, its persistence and
// the picker; the host composer/backend own draft identity, synthetic
// per-task records and the directory layout itself.

import FloeModels
import Foundation
import SwiftUI

/// Where the Space "Files" page roots its browser.
enum MacSpaceFilesRoot: Hashable {
    /// The host's default conversations directory: one folder per task,
    /// covering tasks without an explicit project. Space browsing only.
    case conversations
    /// An explicit project workspace the user chose.
    case project(UUID)
    /// Any folder the user picked directly, remembered across launches.
    case custom

    /// Persisted token for `floe.mac.workspace.spaceFilesRoot`.
    var persistedToken: String {
        switch self {
        case .conversations: return "conversations"
        case .project(let id): return "project:\(id.uuidString)"
        case .custom: return "custom"
        }
    }

    init?(persistedToken: String, projects: [WorkspaceRecord]) {
        switch persistedToken {
        case "conversations":
            self = .conversations
        case "custom":
            self = .custom
        case let token where token.hasPrefix("project:"):
            guard let id = UUID(uuidString: String(token.dropFirst("project:".count))),
                  projects.contains(where: { $0.id == id }) else { return nil }
            self = .project(id)
        default:
            return nil
        }
    }

    /// Launch restore with migration from the keys that predated the
    /// optional-project UX. Precedence: the saved mode; then the remembered
    /// project (`floe.mac.workspace.spaceProject`); then a remembered ad-hoc
    /// folder (the files view's shared bookmark); otherwise the default
    /// conversations directory, so Space files works before anything is
    /// remembered. Smoke/embedder hosts (`remembers == false`) always get
    /// the default directory and nothing is persisted.
    static func restored(raw: String?, legacyProjectRaw: String?, projects: [WorkspaceRecord],
                         hasRememberedCustomFolder: Bool, remembers: Bool) -> MacSpaceFilesRoot {
        guard remembers else { return .conversations }
        if let raw, !raw.isEmpty, let restored = MacSpaceFilesRoot(persistedToken: raw, projects: projects) {
            return restored
        }
        if let legacyProjectRaw, let id = UUID(uuidString: legacyProjectRaw),
           projects.contains(where: { $0.id == id }) {
            return .project(id)
        }
        if hasRememberedCustomFolder { return .custom }
        return .conversations
    }

    /// The shared bookmark the files surface uses for a remembered ad-hoc
    /// folder. Reading it here is migration/labeling only; the files view
    /// remains the sole writer.
    static func rememberedCustomFolderName(defaults: UserDefaults = .standard) -> String? {
        guard let bookmark = defaults.data(forKey: MacSpaceFilesRoot.customBookmarkKey) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI],
                                 relativeTo: nil, bookmarkDataIsStale: &stale) else { return nil }
        let name = url.resolvingSymlinksInPath().standardizedFileURL.lastPathComponent
        return name.isEmpty ? nil : name
    }

    static let customBookmarkKey = "floe.mac.workspace.files.rootBookmark"
}

/// The Space header control for choosing the Files root: the default
/// conversations directory, explicit projects, the remembered ad-hoc folder,
/// plus project management. All gating and side effects stay at the call
/// site through the closures; this view only renders the choice.
struct MacSpaceFilesRootPicker<ProjectActions: View>: View {
    let projects: [WorkspaceRecord]
    let root: MacSpaceFilesRoot
    /// The host's default conversations directory is available (the backend
    /// may legitimately refuse it, e.g. before storage is ready).
    let defaultAvailable: Bool
    let canAddProject: Bool
    /// Pending workspace-file edits may block leaving the displayed root.
    let canSwitch: (MacSpaceFilesRoot) -> Bool
    let select: (MacSpaceFilesRoot) -> Void
    let addProject: () -> Void
    @ViewBuilder let projectActions: (WorkspaceRecord) -> ProjectActions

    var body: some View {
        Menu {
            rootMenuContent
        } label: {
            menuLabel
        }
        .menuStyle(.borderlessButton)
        .help("mac.workspace.chooseSpaceRoot")
        .accessibilityIdentifier("workspace.space.projects")
    }

    private var menuLabel: some View {
        Label {
            Text(verbatim: labelTitle).lineLimit(1).truncationMode(.middle)
        } icon: {
            Image(systemName: "folder")
        }
    }

    private var labelTitle: String {
        switch root {
        case .conversations:
            return String(localized: "mac.workspace.spaceDefaultRoot")
        case .project(let id):
            // A deleted project self-heals on the next launch restore; until
            // then the effective mode is the ad-hoc folder flow.
            return projects.first { $0.id == id }?.name
                ?? String(localized: "mac.workspace.otherFolders")
        case .custom:
            return MacSpaceFilesRoot.rememberedCustomFolderName()
                ?? String(localized: "mac.workspace.otherFolders")
        }
    }

    @ViewBuilder private var rootMenuContent: some View {
        Button { select(.conversations) } label: {
            if case .conversations = root {
                Label("mac.workspace.spaceDefaultRoot", systemImage: "checkmark")
            } else {
                Text("mac.workspace.spaceDefaultRoot")
            }
        }
        .help("mac.workspace.spaceDefaultRootHelp")
        .disabled(!defaultAvailable || !canSwitch(.conversations))
        if !projects.isEmpty { Divider() }
        ForEach(projects) { project in
            Button { select(.project(project.id)) } label: {
                if case .project(let id) = root, id == project.id {
                    Label(project.name, systemImage: "checkmark")
                } else {
                    Text(verbatim: project.name)
                }
            }
            .disabled(!canSwitch(.project(project.id)))
        }
        Divider()
        Button { select(.custom) } label: {
            if case .custom = root {
                Label("mac.workspace.otherFolders", systemImage: "checkmark")
            } else {
                Text("mac.workspace.otherFolders")
            }
        }
        .disabled(!canSwitch(.custom))
        Button("mac.workspace.addProject", action: addProject)
            .disabled(!canAddProject)
        if case .project(let id) = root, let project = projects.first(where: { $0.id == id }) {
            Divider()
            projectActions(project)
        }
    }
}
