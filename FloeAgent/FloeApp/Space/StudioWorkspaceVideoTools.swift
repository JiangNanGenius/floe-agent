// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import CryptoKit
import Darwin
import Foundation
import FloeCore
import FloePersistence
import FloeTools
import FloeWorkbench

extension Notification.Name {
    static let floeWorkspaceVideoDidChange = Notification.Name("floe.workspace.video.didChange")
}

/// Workspace originals use their own native binding and the same MediaV2
/// project store/session as the editor. Paths and manifests are data, never
/// authority. Each call reacquires the current workspace's security scope.
@MainActor enum StudioWorkspaceVideoService {
#if DEBUG
    static var afterProjectStageOpenForTesting: ((URL) throws -> Void)?
#endif
    enum NativeUIPathClassification { case unbound, verified, unavailableBound }
    struct Scope: Sendable {
        let conversationID: UUID
        let workspaceID: UUID
        let root: URL
        let container: URL
        let rootIdentity: String
        let containerIdentity: String
        let authority: StudioDocumentAccess
        let lease: WorkspaceCenter.TaskRootLease
    }

    private static func identity(_ fd: Int32) throws -> String {
        var value = stat()
        guard fstat(fd, &value) == 0, (value.st_mode & S_IFMT) == S_IFDIR else { throw PersonalContentError.changedDocument }
        return "\(value.st_dev):\(value.st_ino)"
    }

    private static func writeNewFile(_ data: Data, parent: Int32, name: String) throws {
        let fd = openat(parent, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard fd >= 0 else { throw PersonalContentError.changedDocument }
        defer { close(fd) }
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw PersonalContentError.storageUnavailable }
                offset += count
            }
        }
    }

    static func scope(coordinator: StudioCoordinator, context: ToolContext, creating: Bool) async throws -> Scope {
        let conversation = try await coordinator.conversation(context, allowedNames: ["studio.workspaceVideo", "studio.workspaceVideoRead"])
        guard let environment = coordinator.environment, let requestedRoot = context.workspaceRootURL,
              let rawContainer = context.serviceStorePaths[TypedMutationContract.workspaceStudioStoreKey] else { throw PersonalContentError.storageUnavailable }
        let store = SQLiteWorkspaceStore(database: environment.database)
        guard let workspaceID = try await store.workspaceID(conversationID: conversation),
              let workspace = try await store.workspace(id: workspaceID) else { throw PersonalContentError.storageUnavailable }
        let lease = try await environment.workspaceCenter.acquireDocumentRootOnly(workspace, ownerConversationID: conversation)
        do {
            let root = lease.url.standardizedFileURL.resolvingSymlinksInPath()
            let container = URL(fileURLWithPath: rawContainer, isDirectory: true).standardizedFileURL
            guard root == requestedRoot.standardizedFileURL.resolvingSymlinksInPath(),
                  container.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath() == root,
                  container.lastPathComponent == "Floe Studio " + String(workspaceID.uuidString.prefix(8)) else { throw PersonalContentError.changedDocument }
            try context.authorizeWorkspacePath(container.lastPathComponent)
            let rootFD = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard rootFD >= 0 else { throw PersonalContentError.storageUnavailable }
            defer { close(rootFD) }
            let rootID = try identity(rootFD), authority = try coordinator.access.get()
            var registered = try await authority.workspaceVideoRoot(workspaceID: workspaceID)
            if registered == nil {
                guard creating else { throw PersonalContentError.missingDocument }
                var intent = try await authority.workspaceVideoRootIntent(workspaceID: workspaceID)
                if intent == nil {
                    var existing = stat()
                    guard fstatat(rootFD, container.lastPathComponent, &existing, AT_SYMLINK_NOFOLLOW) != 0, errno == ENOENT else {
                        throw FloeError.validationFailed("The workspace studio folder already exists. Move the conflicting folder and retry.")
                    }
                    let stagingName = ".floe-studio-" + UUID().uuidString
                    guard mkdirat(rootFD, stagingName, mode_t(0o700)) == 0 else { throw PersonalContentError.storageUnavailable }
                    let stagingFD = openat(rootFD, stagingName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                    guard stagingFD >= 0 else { throw PersonalContentError.changedDocument }
                    let stagingID: String
                    do { stagingID = try identity(stagingFD) } catch { close(stagingFD); throw error }
                    close(stagingFD)
                    let proposed = StudioWorkspaceVideoRootIntent(workspaceID: workspaceID, relativePath: container.lastPathComponent,
                        rootIdentity: rootID, stagingName: stagingName, containerIdentity: stagingID)
                    do {
                        try await authority.reserveWorkspaceVideoRoot(proposed)
                        intent = proposed
                    } catch {
                        // Only remove our own still-empty staging directory.
                        let checkFD = openat(rootFD, stagingName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                        if checkFD >= 0 {
                            if (try? identity(checkFD)) == stagingID { _ = unlinkat(rootFD, stagingName, AT_REMOVEDIR) }
                            close(checkFD)
                        }
                        throw error
                    }
                }
                guard let intent, intent.relativePath == container.lastPathComponent, intent.rootIdentity == rootID else { throw PersonalContentError.changedDocument }
                let existingFD = openat(rootFD, intent.relativePath, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                if existingFD >= 0 {
                    defer { close(existingFD) }
                    guard try identity(existingFD) == intent.containerIdentity else { throw PersonalContentError.changedDocument }
                } else {
                    guard errno == ENOENT else { throw PersonalContentError.changedDocument }
                    let stagingFD = openat(rootFD, intent.stagingName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                    guard stagingFD >= 0 else { throw PersonalContentError.changedDocument }
                    defer { close(stagingFD) }
                    guard try identity(stagingFD) == intent.containerIdentity else { throw PersonalContentError.changedDocument }
                    try Task.checkCancellation(); try context.cancellation.throwIfCancelled()
                    guard renameatx_np(rootFD, intent.stagingName, rootFD, intent.relativePath, UInt32(RENAME_EXCL)) == 0 else {
                        throw FloeError.validationFailed(WorkbenchText.t("无法在此位置创建视频工作区。请确认文件夹可离线访问并重试，或改用本机工作区。", "Cannot create the video workspace here. Make the folder available offline and retry, or use a local workspace."))
                    }
                }
                try await authority.finishWorkspaceVideoRoot(intent)
                registered = try await authority.workspaceVideoRoot(workspaceID: workspaceID)
            }
            let containerFD = openat(rootFD, container.lastPathComponent, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard containerFD >= 0 else { throw PersonalContentError.changedDocument }
            defer { close(containerFD) }
            let containerID = try identity(containerFD)
            guard let registered, registered.relativePath == container.lastPathComponent, registered.rootIdentity == rootID,
                  registered.containerIdentity == containerID else { throw PersonalContentError.changedDocument }
            return Scope(conversationID: conversation, workspaceID: workspaceID, root: root, container: container,
                rootIdentity: rootID, containerIdentity: containerID, authority: authority, lease: lease)
        } catch { lease.release(); throw error }
    }

    private static func projectIdentity(_ directory: URL, container: URL) throws -> String {
        guard directory.deletingLastPathComponent().standardizedFileURL == container.standardizedFileURL else { throw PersonalContentError.outsideLibrary }
        let parent = open(container.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { throw PersonalContentError.changedDocument }
        defer { close(parent) }
        let fd = openat(parent, directory.lastPathComponent, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw PersonalContentError.changedDocument }
        defer { close(fd) }
        return try identity(fd)
    }

    private static func mediaIdentities(_ directory: URL) throws -> (media: String, store: String) {
        let project = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard project >= 0 else { throw PersonalContentError.changedDocument }
        defer { close(project) }
        let media = openat(project, "Media", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard media >= 0 else { throw PersonalContentError.changedDocument }
        defer { close(media) }
        let store = openat(media, "Projects", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard store >= 0 else { throw PersonalContentError.changedDocument }
        defer { close(store) }
        return (try identity(media), try identity(store))
    }

    private static func verify(_ scope: Scope) throws {
        let rootFD = open(scope.root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard rootFD >= 0 else { throw PersonalContentError.changedDocument }
        defer { close(rootFD) }
        guard try identity(rootFD) == scope.rootIdentity else { throw PersonalContentError.changedDocument }
        let containerFD = openat(rootFD, scope.container.lastPathComponent, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard containerFD >= 0 else { throw PersonalContentError.changedDocument }
        defer { close(containerFD) }
        guard try identity(containerFD) == scope.containerIdentity else { throw PersonalContentError.changedDocument }
    }

    static func managedRootForNativeUI(center: WorkspaceCenter, expectedScope: WorkspaceFileActionScope,
                                       environment: AppEnvironment) async throws -> String? {
        try expectedScope.validate(center)
        guard let workspace = center.currentWorkspace, workspace.id == expectedScope.workspaceID else { throw WorkspaceFileDeletionError.changed }
        let authority = try environment.studioCoordinator.access.get()
        guard let binding = try await authority.workspaceVideoRoot(workspaceID: workspace.id) else { return nil }
        try expectedScope.validate(center)
        guard binding.relativePath == "Floe Studio " + String(workspace.id.uuidString.prefix(8)),
              !center.isCloudWorkspacePath(binding.relativePath), !center.isNetworkWorkspacePath(binding.relativePath) else { throw WorkspaceFileDeletionError.external }
        let fd = open(expectedScope.root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw PersonalContentError.changedDocument }
        defer { close(fd) }
        guard try identity(fd) == binding.rootIdentity else { throw PersonalContentError.changedDocument }
        let child = openat(fd, binding.relativePath, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard child >= 0 else { throw PersonalContentError.changedDocument }
        defer { close(child) }
        guard try identity(child) == binding.containerIdentity else { throw PersonalContentError.changedDocument }
        try expectedScope.validate(center)
        return binding.relativePath
    }

    static func boundVideoPathsForNativeUI(center: WorkspaceCenter, expectedScope: WorkspaceFileActionScope,
                                           environment: AppEnvironment) async throws -> Set<String> {
        guard try await managedRootForNativeUI(center: center, expectedScope: expectedScope, environment: environment) != nil else { return [] }
        let authority = try environment.studioCoordinator.access.get()
        let bindings = try await authority.workspaceVideoBindingsForNativeUI(workspaceID: expectedScope.workspaceID)
        var paths = Set<String>()
        for binding in bindings {
            try Task.checkCancellation()
            try expectedScope.validate(center)
            // A missing or replaced package stays an ordinary file-tree item.
            // Only the native binding and matching live identities make it an
            // editor candidate; no new conversation grant is created.
            do {
                let opened = try await openForNativeUI(relativePath: binding.relativePath, center: center,
                                                       expectedScope: expectedScope, environment: environment)
                opened.lease.release()
                paths.insert(binding.relativePath)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Keep invalid/missing originals out of the editor. Their
                // durable binding still protects file operations separately.
            }
        }
        try expectedScope.validate(center)
        return paths
    }

    static func protectedVideoPathsForNativeUI(center: WorkspaceCenter, expectedScope: WorkspaceFileActionScope,
                                               environment: AppEnvironment) async throws -> Set<String> {
        guard let root = try await managedRootForNativeUI(center: center, expectedScope: expectedScope, environment: environment) else { return [] }
        let authority = try environment.studioCoordinator.access.get()
        guard let rootBinding = try await authority.workspaceVideoRoot(workspaceID: expectedScope.workspaceID) else { return [] }
        let bindings = try await authority.workspaceVideoBindingsForNativeUI(workspaceID: expectedScope.workspaceID)
        var paths = Set<String>()
        for binding in bindings {
            let pieces = binding.relativePath.split(separator: "/", omittingEmptySubsequences: false)
            guard pieces.count == 2, pieces[0] == Substring(root), !pieces[1].isEmpty,
                  pieces[1] != ".", pieces[1] != "..", pieces[1].lowercased().hasSuffix(".floeproject"),
                  binding.rootIdentity == rootBinding.rootIdentity else { throw PersonalContentError.changedDocument }
            paths.insert(binding.relativePath)
        }
        try Task.checkCancellation(); try expectedScope.validate(center)
        return paths
    }

    static func classifyVideoPathForNativeUI(relativePath: String, center: WorkspaceCenter,
                                              expectedScope: WorkspaceFileActionScope,
                                              environment: AppEnvironment) async throws -> NativeUIPathClassification {
        try expectedScope.validate(center)
        let authority = try environment.studioCoordinator.access.get()
        guard try await authority.workspaceVideoBindingForNativeUI(workspaceID: expectedScope.workspaceID, relativePath: relativePath) != nil else {
            try Task.checkCancellation(); try expectedScope.validate(center)
            return .unbound
        }
        do {
            let opened = try await openForNativeUI(relativePath: relativePath, center: center, expectedScope: expectedScope, environment: environment)
            opened.lease.release()
            return .verified
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation(); try expectedScope.validate(center)
            return .unavailableBound
        }
    }

    static func resolve(_ id: UUID, scope: Scope, editing: Bool) async throws -> (PersonalContentRecord, URL) {
        try verify(scope)
        guard try await scope.authority.canAccess(conversationID: scope.conversationID, projectID: id, editing: editing),
              let binding = try await scope.authority.workspaceVideoBinding(conversationID: scope.conversationID,
                  workspaceID: scope.workspaceID, projectID: id), binding.rootIdentity == scope.rootIdentity else {
            throw FloeError.unauthorized
        }
        let library = PersonalContentLibrary(root: scope.container)
        let value = try await library.resolve(id)
        try verify(scope)
        let children = try mediaIdentities(value.url)
        guard value.record.kind == .video,
              binding.relativePath == scope.container.lastPathComponent + "/" + value.record.relativePath,
              try projectIdentity(value.url, container: scope.container) == binding.projectIdentity,
              !binding.mediaIdentity.isEmpty, !binding.storeIdentity.isEmpty,
              children.media == binding.mediaIdentity, children.store == binding.storeIdentity else { throw PersonalContentError.changedDocument }
        return (value.record, value.url)
    }

    /// A user's explicit file-tree open is scoped to the selected workspace.
    /// It reads the native binding, but does not grant any model conversation.
    static func openForNativeUI(relativePath: String, center: WorkspaceCenter, expectedScope: WorkspaceFileActionScope,
                                environment: AppEnvironment) async throws -> (record: PersonalContentRecord, directory: URL, lease: WorkspaceCenter.TaskRootLease) {
        try expectedScope.validate(center)
        guard !center.isCloudWorkspacePath(relativePath), !center.isNetworkWorkspacePath(relativePath),
              let workspace = center.currentWorkspace, workspace.id == expectedScope.workspaceID else { throw WorkspaceFileDeletionError.external }
        let authority = try environment.studioCoordinator.access.get()
        guard let binding = try await authority.workspaceVideoBindingForNativeUI(workspaceID: workspace.id, relativePath: relativePath),
              let rootBinding = try await authority.workspaceVideoRoot(workspaceID: workspace.id) else { throw FloeError.unauthorized }
        try expectedScope.validate(center)
        let lease = try await center.acquireDocumentRootOnly(workspace, ownerConversationID: binding.conversationID)
        do {
            let root = lease.url.standardizedFileURL.resolvingSymlinksInPath()
            guard root == expectedScope.root,
                  rootBinding.relativePath == "Floe Studio " + String(workspace.id.uuidString.prefix(8)),
                  binding.relativePath.hasPrefix(rootBinding.relativePath + "/") else { throw PersonalContentError.changedDocument }
            let container = root.appendingPathComponent(rootBinding.relativePath, isDirectory: true)
            let scope = Scope(conversationID: binding.conversationID, workspaceID: workspace.id, root: root,
                container: container, rootIdentity: rootBinding.rootIdentity, containerIdentity: rootBinding.containerIdentity,
                authority: authority, lease: lease)
            try verify(scope)
            let value = try await PersonalContentLibrary(root: container).resolve(binding.projectID)
            try expectedScope.validate(center)
            try verify(scope)
            let children = try mediaIdentities(value.url)
            guard value.record.kind == .video,
                  binding.relativePath == rootBinding.relativePath + "/" + value.record.relativePath,
                  try projectIdentity(value.url, container: container) == binding.projectIdentity,
                  !binding.mediaIdentity.isEmpty, !binding.storeIdentity.isEmpty,
                  children.media == binding.mediaIdentity, children.store == binding.storeIdentity else { throw PersonalContentError.changedDocument }
            try await PersonalMediaFactory.verify(kind: .video, id: binding.projectID, directory: value.url)
            try expectedScope.validate(center)
            return (value.record, value.url, lease)
        } catch { lease.release(); throw error }
    }

    static func sessionForNativeUI(record: PersonalContentRecord, directory: URL, workspaceID: UUID,
                                   environment: AppEnvironment, authority: StudioDocumentAccess? = nil) async throws -> MediaV2Session {
        guard record.kind == .video else { throw PersonalContentError.invalidProject }
        let projectID = record.id
        let ownerAuthority = try authority ?? environment.studioCoordinator.access.get()
        let permit: @Sendable (UUID) async throws -> MediaProjectWritePermit = { requested in
            guard requested == projectID else { throw FloeError.unauthorized }
            return try await WorkspaceVideoWritePermitFactory.acquire(workspaceID: workspaceID, projectID: projectID, environment: environment, authority: ownerAuthority)
        }
        let openingPermit = try await permit(projectID)
        defer { openingPermit.release() }
        try openingPermit.validate()
        let session = try await PersonalMediaFactory.session(id: projectID, directory: directory,
            acquireWritePermit: permit, writePermitIdentity: "workspace-video:\(workspaceID.uuidString):\(projectID.uuidString):\(ObjectIdentifier(ownerAuthority))")
        try openingPermit.validate()
        return session
    }

    static func create(title: String, coordinator: StudioCoordinator, context: ToolContext) async throws -> ToolExecutionOutput {
        guard context.approvalGrantID != nil, let call = context.toolCallID, !call.isEmpty else { throw FloeError.unauthorized }
        let scope = try await scope(coordinator: coordinator, context: context, creating: true)
        defer { scope.lease.release() }
        try verify(scope)
        let key = context.runID.uuidString + "/" + call
        let digest = StudioToolOutput.hash(try StudioToolOutput.data([scope.workspaceID.uuidString, scope.conversationID.uuidString, title]))
        let id = try await scope.authority.reserveCreation(operationKey: key, digest: digest)
        let previous = try await scope.authority.workspaceVideoBinding(conversationID: scope.conversationID, workspaceID: scope.workspaceID, projectID: id)
        let binding: StudioWorkspaceVideoBinding
        let directory: URL
        if let previous {
            let (_, existing) = try await resolve(id, scope: scope, editing: true)
            binding = previous; directory = existing
        } else {
            let cleaned = title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty, cleaned.utf8.count <= 180, !cleaned.contains("/"), !cleaned.contains("\\"),
                  !cleaned.contains(":"), !cleaned.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw PersonalContentError.invalidName }
            let parentFD = open(scope.container.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard parentFD >= 0 else { throw PersonalContentError.changedDocument }
            defer { close(parentFD) }
            guard try identity(parentFD) == scope.containerIdentity else { throw PersonalContentError.changedDocument }
            var intent = try await scope.authority.workspaceVideoProjectIntent(projectID: id)
            if intent == nil {
                let stagingName = ".floe-project-" + UUID().uuidString
                let finalName = cleaned + " " + String(id.uuidString.prefix(8)) + ".floeproject"
                guard mkdirat(parentFD, stagingName, mode_t(0o700)) == 0 else { throw PersonalContentError.storageUnavailable }
                let stageFD = openat(parentFD, stagingName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard stageFD >= 0 else { throw PersonalContentError.changedDocument }
                defer { close(stageFD) }
                let stageIdentity = try identity(stageFD)
                let stageURL = scope.container.appendingPathComponent(stagingName, isDirectory: true)
#if DEBUG
                try afterProjectStageOpenForTesting?(stageURL)
#endif
                // Construct the entire unpublished package relative to its
                // pinned directory, so replacing its workspace name cannot
                // redirect initialization to another location.
                guard mkdirat(stageFD, "Media", mode_t(0o700)) == 0 else { throw PersonalContentError.storageUnavailable }
                let mediaFD = openat(stageFD, "Media", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard mediaFD >= 0 else { throw PersonalContentError.changedDocument }
                defer { close(mediaFD) }
                guard mkdirat(mediaFD, "Assets", mode_t(0o700)) == 0,
                      mkdirat(mediaFD, "Projects", mode_t(0o700)) == 0 else { throw PersonalContentError.storageUnavailable }
                let storeFD = openat(mediaFD, "Projects", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard storeFD >= 0 else { throw PersonalContentError.changedDocument }
                defer { close(storeFD) }
                let finalMedia = scope.container.appendingPathComponent(finalName, isDirectory: true).appendingPathComponent("Media", isDirectory: true)
                let project = try PersonalMediaFactory.initialProject(kind: .video, title: cleaned, id: id, mediaRoot: finalMedia)
                let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
                let projectBytes = try encoder.encode(project)
                guard projectBytes.count <= MediaProjectStore.Limits().maximumDocumentBytes else { throw PersonalContentError.invalidProject }
                try writeNewFile(projectBytes, parent: storeFD, name: MediaProjectStore.projectFileName(id: id))
                try verify(scope)
                var current = stat(), opened = stat()
                guard fstat(stageFD, &opened) == 0,
                      fstatat(parentFD, stagingName, &current, AT_SYMLINK_NOFOLLOW) == 0,
                      opened.st_dev == current.st_dev, opened.st_ino == current.st_ino else { throw PersonalContentError.changedDocument }
                let record = PersonalContentRecord(id: id, kind: .video, title: cleaned, createdAt: Date(), modifiedAt: Date(), folders: [], relativePath: finalName)
                let bytes = try JSONEncoder().encode(record)
                try writeNewFile(bytes, parent: stageFD, name: "FloeProject.json")
                let children = (media: try identity(mediaFD), store: try identity(storeFD))
                let proposed = StudioWorkspaceVideoProjectIntent(projectID: id, conversationID: scope.conversationID,
                    workspaceID: scope.workspaceID, operationKey: key, digest: digest, rootIdentity: scope.rootIdentity,
                    containerIdentity: scope.containerIdentity, stagingName: stagingName, finalName: finalName,
                    projectIdentity: stageIdentity, mediaIdentity: children.media, storeIdentity: children.store)
                try await scope.authority.reserveWorkspaceVideoProject(proposed)
                intent = proposed
            }
            guard let intent, intent.projectID == id, intent.conversationID == scope.conversationID,
                  intent.workspaceID == scope.workspaceID, intent.operationKey == key, intent.digest == digest,
                  intent.rootIdentity == scope.rootIdentity, intent.containerIdentity == scope.containerIdentity else { throw PersonalContentError.changedDocument }
            let finalURL = scope.container.appendingPathComponent(intent.finalName, isDirectory: true)
            let existingFD = openat(parentFD, intent.finalName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if existingFD >= 0 {
                defer { close(existingFD) }
                guard try identity(existingFD) == intent.projectIdentity else { throw PersonalContentError.changedDocument }
            } else {
                guard errno == ENOENT else { throw PersonalContentError.changedDocument }
                let stageFD = openat(parentFD, intent.stagingName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard stageFD >= 0 else { throw PersonalContentError.changedDocument }
                defer { close(stageFD) }
                guard try identity(stageFD) == intent.projectIdentity else { throw PersonalContentError.changedDocument }
                try verify(scope); try Task.checkCancellation(); try context.cancellation.throwIfCancelled()
                guard renameatx_np(parentFD, intent.stagingName, parentFD, intent.finalName, UInt32(RENAME_EXCL)) == 0 else {
                    throw FloeError.validationFailed(WorkbenchText.t("无法在此位置创建视频工程。请确认文件夹可离线访问并重试，或改用本机工作区。", "Cannot create the video project here. Make the folder available offline and retry, or use a local workspace."))
                }
            }
            let children = try mediaIdentities(finalURL)
            guard try projectIdentity(finalURL, container: scope.container) == intent.projectIdentity,
                  children.media == intent.mediaIdentity, children.store == intent.storeIdentity else { throw PersonalContentError.changedDocument }
            binding = StudioWorkspaceVideoBinding(projectID: id, conversationID: scope.conversationID,
                workspaceID: scope.workspaceID, relativePath: scope.container.lastPathComponent + "/" + intent.finalName,
                rootIdentity: scope.rootIdentity, projectIdentity: intent.projectIdentity,
                mediaIdentity: intent.mediaIdentity, storeIdentity: intent.storeIdentity)
            directory = finalURL
            try await scope.authority.finishWorkspaceVideoCreation(binding, operationKey: key, digest: digest)
            NotificationCenter.default.post(name: .floeWorkspaceVideoDidChange, object: scope.workspaceID)
        }
        let mediaStore = MediaProjectStore(directory: directory.appendingPathComponent("Media/Projects", isDirectory: true))
        let project = try? await mediaStore.loadProject(id: id)
        let revision = project?.kind == .video ? project?.revision : nil
        struct Receipt: Encodable { let projectID: UUID; let relativePath: String; let revision: Int64?; let replayed: Bool; let readbackPending: Bool }
        return try StudioToolOutput.make(Receipt(projectID: id, relativePath: binding.relativePath, revision: revision,
            replayed: previous != nil, readbackPending: revision == nil))
    }

    static func read(id: UUID?, offset: Int, coordinator: StudioCoordinator, context: ToolContext) async throws -> ToolExecutionOutput {
        let scope = try await scope(coordinator: coordinator, context: context, creating: false)
        defer { scope.lease.release() }
        guard let id else {
            let bindings = try await scope.authority.workspaceVideoBindings(conversationID: scope.conversationID, workspaceID: scope.workspaceID)
            struct Item: Encodable { let projectID: UUID; let title: String; let relativePath: String }
            var items: [Item] = []
            for binding in bindings {
                let (record, _) = try await resolve(binding.projectID, scope: scope, editing: false)
                items.append(Item(projectID: binding.projectID, title: record.title, relativePath: binding.relativePath))
            }
            return try StudioToolOutput.make(items)
        }
        let (record, directory) = try await resolve(id, scope: scope, editing: false)
        guard let environment = coordinator.environment else { throw PersonalContentError.storageUnavailable }
        let session = try await sessionForNativeUI(record: record, directory: directory, workspaceID: scope.workspaceID, environment: environment, authority: scope.authority)
        let data = try StudioToolOutput.data(session.document)
        guard data.count <= 32 * 1_024 * 1_024 else { throw FloeError.validationFailed("Read a smaller project") }
        let text = String(decoding: data, as: UTF8.self)
        guard (0...text.count).contains(offset) else { throw FloeError.validationFailed("Invalid page offset") }
        let start = text.index(text.startIndex, offsetBy: offset)
        let end = text.index(start, offsetBy: min(12_000, text.distance(from: start, to: text.endIndex)))
        struct Receipt: Encodable { let projectID: UUID; let title: String; let relativePath: String; let revision: Int64; let contentJSON: String; let nextOffset: Int? }
        return try StudioToolOutput.make(Receipt(projectID: id, title: record.title,
            relativePath: scope.container.lastPathComponent + "/" + record.relativePath, revision: session.document.revision,
            contentJSON: String(text[start..<end]), nextOffset: end == text.endIndex ? nil : offset + 12_000))
    }

    private static func importPlacement(_ json: String) throws -> (payload: String, canonical: Data, placement: MediaV2Session.ImportPlacement) {
        struct Input: Decodable { let trackID: UUID; let startSeconds: Double }
        let data = Data(json.utf8)
        let selected = try JSONDecoder().decode(Input.self, from: data)
        guard selected.startSeconds.isFinite, selected.startSeconds >= 0,
              var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw PersonalContentError.invalidProject }
        let canonical = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        object.removeValue(forKey: "trackID"); object.removeValue(forKey: "startSeconds")
        let payload = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return (String(decoding: payload, as: UTF8.self), canonical,
                .init(trackID: selected.trackID, startSeconds: selected.startSeconds))
    }

    static func perform(id: UUID, action: String, toolID: String?, inputJSON: String,
                        coordinator: StudioCoordinator, context: ToolContext) async throws -> ToolExecutionOutput {
        guard context.approvalGrantID != nil else { throw FloeError.unauthorized }
        let scope = try await scope(coordinator: coordinator, context: context, creating: false)
        defer { scope.lease.release() }
        let (record, directory) = try await resolve(id, scope: scope, editing: true)
        guard let environment = coordinator.environment else { throw PersonalContentError.storageUnavailable }
        let session = try await sessionForNativeUI(record: record, directory: directory, workspaceID: scope.workspaceID, environment: environment, authority: scope.authority)
        if action == "edit", toolID == "video.importFrames" {
            let placement = try importPlacement(inputJSON)
            let input = try StudioMediaSourceContracts.decodeFrames(placement.payload)
            let source = try StudioMediaSourceContracts.workspaceURL(input.source.workspacePath, context: context)
            guard let sha = input.source.expectedSHA256, let call = context.toolCallID, !call.isEmpty else { throw FloeError.unauthorized }
            func uuid(_ data: Data) -> UUID {
                let bytes = Array(SHA256.hash(data: data).prefix(16))
                return UUID(uuid: (bytes[0],bytes[1],bytes[2],bytes[3],bytes[4],bytes[5],bytes[6],bytes[7],bytes[8],bytes[9],bytes[10],bytes[11],bytes[12],bytes[13],bytes[14],bytes[15]))
            }
            let group = uuid(Data((context.runID.uuidString + "/" + call).utf8))
            let identity = MediaV2Session.ImportIdentity(groupID: group,
                operationID: uuid(Data(group.uuidString.utf8) + placement.canonical))
            let imported: MediaV2Session.ImportedAsset
            if let replay = try await session.replayImport(identity, expectedRevision: input.expectedRevision) {
                imported = replay
            } else {
                guard session.document.revision == input.expectedRevision else { throw MediaPreparedCoreError.documentChanged }
                let spec = StudioFrameSequenceEncoder.Specification(width: input.width, height: input.height,
                    frameRate: input.frameRate, frameCount: input.frameCount, expectedSHA256: sha)
                let cancellation = context.cancellation
                let workspaceRoot = scope.root
                let work = Task.detached(priority: .userInitiated) {
                    try await StudioFrameSequenceEncoder.encode(source: source, workspaceRoot: workspaceRoot, spec: spec, cancellation: cancellation)
                }
                let encoded = try await withTaskCancellationHandler(operation: { try await work.value }, onCancel: { work.cancel() })
                imported = try await session.importAuthorizedFile(encoded.url, expectedRevision: input.expectedRevision,
                    expectedSHA256: encoded.outputSHA256, actor: .model, cancellation: cancellation, validateSource: {
                        let (_, current) = try await resolve(id, scope: scope, editing: true)
                        guard current == directory, try StudioMediaSourceContracts.workspaceURL(input.source.workspacePath, context: context) == source else {
                            throw PersonalContentError.changedDocument
                        }
                    }, identity: identity, placement: placement.placement)
            }
            struct Placement: Encodable { let trackID: UUID; let clipID: UUID; let timelineRange: MediaTimeRange }
            let saved = try? await session.store.loadProject(id: id)
            let placements: [Placement]? = saved?.preparedJournal?.entry(imported.commit.groupID)?.changes.compactMap { change in
                guard change.before == nil, case .clip(let trackID, let clip) = change.after,
                      clip.assetID == imported.asset.id else { return nil }
                return Placement(trackID: trackID, clipID: clip.id, timelineRange: clip.timelineRange)
            }
            struct Receipt: Encodable { let projectID: UUID; let revision: Int64; let groupID: UUID; let assetID: UUID; let sourceSHA256: String; let outputSHA256: String?; let replayed: Bool; let journalStatus: String; let sessionRefreshPending: Bool; let placements: [Placement]? }
            return try StudioToolOutput.make(Receipt(projectID: id, revision: imported.commit.revision,
                groupID: imported.commit.groupID, assetID: imported.asset.id, sourceSHA256: sha,
                outputSHA256: imported.asset.contentHash, replayed: imported.replayed,
                journalStatus: imported.journalStatus.rawValue, sessionRefreshPending: imported.refreshPending, placements: placements))
        }
        if action == "import" {
            let placement = try importPlacement(inputJSON)
            let input = try StudioMediaSourceContracts.decodeImport(placement.payload)
            let source = try StudioMediaSourceContracts.workspaceURL(input.source.workspacePath, context: context)
            guard let call = context.toolCallID, !call.isEmpty else { throw FloeError.unauthorized }
            func stableID(_ data: Data) -> UUID {
                let bytes = Array(SHA256.hash(data: data).prefix(16))
                return UUID(uuid: (bytes[0],bytes[1],bytes[2],bytes[3],bytes[4],bytes[5],bytes[6],bytes[7],bytes[8],bytes[9],bytes[10],bytes[11],bytes[12],bytes[13],bytes[14],bytes[15]))
            }
            let group = stableID(Data((context.runID.uuidString + "/" + call).utf8))
            let identity = MediaV2Session.ImportIdentity(groupID: group,
                operationID: stableID(Data(group.uuidString.utf8) + placement.canonical))
            let imported = try await session.importAuthorizedFile(source, expectedRevision: input.expectedRevision,
                expectedSHA256: input.source.expectedSHA256, actor: .model, cancellation: context.cancellation,
                validateSource: {
                    let (_, current) = try await resolve(id, scope: scope, editing: true)
                    guard current == directory, try StudioMediaSourceContracts.workspaceURL(input.source.workspacePath, context: context) == source else {
                        throw PersonalContentError.changedDocument
                    }
                }, identity: identity, placement: placement.placement)
            struct Placement: Encodable { let trackID: UUID; let clipID: UUID; let timelineRange: MediaTimeRange }
            let saved = try? await session.store.loadProject(id: id)
            let placements: [Placement]? = saved?.preparedJournal?.entry(imported.commit.groupID)?.changes.compactMap { change in
                guard change.before == nil, case .clip(let trackID, let clip) = change.after,
                      clip.assetID == imported.asset.id else { return nil }
                return Placement(trackID: trackID, clipID: clip.id, timelineRange: clip.timelineRange)
            }
            struct Receipt: Encodable { let projectID: UUID; let revision: Int64; let groupID: UUID; let assetID: UUID; let sha256: String?; let replayed: Bool; let journalStatus: String; let sessionRefreshPending: Bool; let placements: [Placement]? }
            return try StudioToolOutput.make(Receipt(projectID: id, revision: imported.commit.revision,
                groupID: imported.commit.groupID, assetID: imported.asset.id, sha256: imported.asset.contentHash,
                replayed: imported.replayed, journalStatus: imported.journalStatus.rawValue,
                sessionRefreshPending: imported.refreshPending, placements: placements))
        }
        if action == "edit" {
            let supported: Set<String> = ["video.remove-asset", "video.trim", "video.split", "video.slip", "video.speed",
                "video.transition", "video.pip", "video.video-mask", "video.video-feather", "video.video-transform",
                "video.keyframes", "video.easing", "video.caption", "video.caption-time", "video.mix", "video.fades",
                "video.ripple", "video.roll", "video.srt"]
            guard let toolID, supported.contains(toolID), MediaV2Session.localToolIDs.contains(toolID) else { throw PersonalContentError.invalidProject }
            let input = try StudioMediaToolContract.decode(inputJSON)
            guard input.compoundID == nil else { throw FloeError.validationFailed("Editing a nested clip is not available for this workspace project yet.") }
            let work = Task { @MainActor in
                try await session.performTool(toolID, input: input, actor: .model, validateOwner: {
                    try context.cancellation.throwIfCancelled(); try Task.checkCancellation()
                    let (_, current) = try await resolve(id, scope: scope, editing: true)
                    guard current == directory else { throw PersonalContentError.changedDocument }
                })
            }
            let monitor = Task {
                while !Task.isCancelled {
                    if context.cancellation.isCancelled { work.cancel(); return }
                    do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                }
            }
            defer { monitor.cancel() }
            let receipt = try await withTaskCancellationHandler(operation: { try await work.value }, onCancel: { work.cancel() })
            return try StudioToolOutput.make(receipt)
        }
        if let history = StudioMediaHistoryAction(rawValue: action), history.isMutation {
            let request = try StudioMediaHistory.decode(inputJSON, action: history)
            let commit = try await session.restoreManagedHistory(redo: history == .redo, groupID: request.groupID,
                expectedRevision: request.expectedRevision, cancellation: context.cancellation, validateOwner: {
                    let (_, current) = try await resolve(id, scope: scope, editing: true)
                    guard current == directory else { throw PersonalContentError.changedDocument }
                })
            struct Receipt: Encodable { let projectID: UUID; let revision: Int64; let groupID: UUID; let action: String }
            return try StudioToolOutput.make(Receipt(projectID: id, revision: commit.revision, groupID: commit.groupID, action: action))
        }
        throw PersonalContentError.invalidProject
    }
}

struct StudioWorkspaceVideoCreateTool: AgentTool {
    struct Arguments: Decodable, Sendable { let action: String; let title: String?; let projectID: UUID?; let toolID: String?; let inputJSON: String? }
    static let name = "studio.workspaceVideo"
    static let toolDescription = "Create or edit a native video project in this task's workspace, preserving source files. Read the project first for its revision and object IDs. Import uses inputJSON {expectedRevision,source:{workspacePath,expectedSHA256?},trackID,startSeconds}; video.importFrames uses the same placement plus its frame fields."
    static let parametersJSON = #"{"type":"object","properties":{"action":{"type":"string","enum":["create","import","edit","undo","redo"]},"title":{"type":"string","minLength":1,"maxLength":160},"projectID":{"type":"string","format":"uuid"},"toolID":{"type":"string"},"inputJSON":{"type":"string","maxLength":262144}},"required":["action"],"additionalProperties":false}"#
    static let riskLabels: Set<RiskLabel> = [.persistsPersonalData]
    static let isSideEffecting = true
    static let toolEffect: ToolEffect = .mutating
    let coordinator: StudioCoordinator
    func validate(_ args: Arguments) throws {
        if args.action == "create" {
            guard let title = args.title, (1...160).contains(title.count), args.projectID == nil,
                  args.toolID == nil, args.inputJSON == nil else { throw PersonalContentError.invalidName }
        } else {
            guard ["import", "edit", "undo", "redo"].contains(args.action), args.title == nil,
                  args.projectID != nil, let json = args.inputJSON, json.utf8.count <= 262_144,
                  (args.action == "edit") == (args.toolID != nil) else { throw PersonalContentError.invalidProject }
        }
    }
    @MainActor func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try validate(args)
        if args.action == "create" { return try await StudioWorkspaceVideoService.create(title: args.title!, coordinator: coordinator, context: context) }
        return try await StudioWorkspaceVideoService.perform(id: args.projectID!, action: args.action,
            toolID: args.toolID, inputJSON: args.inputJSON!, coordinator: coordinator, context: context)
    }
}

struct StudioWorkspaceVideoReadTool: AgentTool {
    struct Arguments: Decodable, Sendable { let projectID: UUID?; let offset: Int? }
    static let name = "studio.workspaceVideoRead"
    static let toolDescription = "List this task's bound workspace videos, or read one original's current revision, tracks and clips. Use nextOffset to read remaining pages."
    static let parametersJSON = #"{"type":"object","properties":{"projectID":{"type":"string","format":"uuid"},"offset":{"type":"integer","minimum":0}},"additionalProperties":false}"#
    static let riskLabels: Set<RiskLabel> = []
    static let isSideEffecting = false
    let coordinator: StudioCoordinator
    func validate(_ args: Arguments) throws {
        guard (args.offset ?? 0) >= 0, args.projectID != nil || args.offset == nil else { throw PersonalContentError.invalidProject }
    }
    @MainActor func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try validate(args)
        return try await StudioWorkspaceVideoService.read(id: args.projectID, offset: args.offset ?? 0, coordinator: coordinator, context: context)
    }
}
#endif
