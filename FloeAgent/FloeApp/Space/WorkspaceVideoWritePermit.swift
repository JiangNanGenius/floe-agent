// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Darwin
import Foundation
import FloeCore
import FloePersistence
import FloeWorkbench

/// A write permit owns its own security-scoped workspace lease and an
/// anchored descriptor for every directory involved in the project store.
/// It carries no authority from a manifest or from a model-supplied path.
@MainActor enum WorkspaceVideoWritePermitFactory {
    static func acquire(workspaceID: UUID, projectID: UUID,
                        environment: AppEnvironment, authority suppliedAuthority: StudioDocumentAccess? = nil) async throws -> MediaProjectWritePermit {
        try Task.checkCancellation()
        let authority = try suppliedAuthority ?? environment.studioCoordinator.access.get()
        guard let rootBinding = try await authority.workspaceVideoRoot(workspaceID: workspaceID) else {
            throw PersonalContentError.changedDocument
        }
        let bindings = try await authority.workspaceVideoBindingsForNativeUI(workspaceID: workspaceID)
            .filter { $0.projectID == projectID }
        guard bindings.count == 1, let binding = bindings.first,
              binding.workspaceID == workspaceID, binding.rootIdentity == rootBinding.rootIdentity,
              !binding.mediaIdentity.isEmpty, !binding.storeIdentity.isEmpty else {
            throw PersonalContentError.changedDocument
        }
        let components = binding.relativePath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard components.count == 2,
              rootBinding.relativePath == "Floe Studio " + String(workspaceID.uuidString.prefix(8)),
              components[0] == rootBinding.relativePath, !components[1].isEmpty,
              components[1] != ".", components[1] != "..", !components[1].contains("\\"),
              !components[1].unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              (components[1] as NSString).pathExtension.lowercased() == "floeproject" else {
            throw PersonalContentError.invalidProject
        }
        let store = SQLiteWorkspaceStore(database: environment.database)
        guard let workspace = try await store.workspace(id: workspaceID) else {
            throw PersonalContentError.changedDocument
        }
        // Project workspaces outlive the task that created a document. A
        // native user opening the bound workspace does not need that old
        // conversation; model calls independently check their current grant.
        if workspace.kind == .privateTask {
            guard try await store.workspaceID(conversationID: binding.conversationID) == workspaceID else {
                throw PersonalContentError.changedDocument
            }
        }
        let lease = try await environment.workspaceCenter.acquireDocumentRootOnly(
            workspace, ownerConversationID: binding.conversationID)
        var descriptors: [Int32] = []
        var transferred = false
        defer {
            if !transferred {
                for fd in descriptors.reversed() { close(fd) }
                lease.release()
            }
        }
        try Task.checkCancellation()
        let root = lease.url.standardizedFileURL.resolvingSymlinksInPath()
        let rootFD = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard rootFD >= 0 else { throw PersonalContentError.changedDocument }
        descriptors.append(rootFD)
        func openDirectory(_ parent: Int32, _ name: String) throws -> Int32 {
            let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw PersonalContentError.changedDocument }
            descriptors.append(fd)
            return fd
        }
        let containerFD = try openDirectory(rootFD, components[0])
        let projectFD = try openDirectory(containerFD, components[1])
        let mediaFD = try openDirectory(projectFD, "Media")
        let storeFD = try openDirectory(mediaFD, "Projects")
        func identity(_ fd: Int32) throws -> String {
            var value = stat()
            guard fstat(fd, &value) == 0, (value.st_mode & S_IFMT) == S_IFDIR else {
                throw PersonalContentError.changedDocument
            }
            return "\(value.st_dev):\(value.st_ino)"
        }
        guard try identity(rootFD) == rootBinding.rootIdentity,
              try identity(containerFD) == rootBinding.containerIdentity,
              try identity(projectFD) == binding.projectIdentity,
              try identity(mediaFD) == binding.mediaIdentity,
              try identity(storeFD) == binding.storeIdentity else { throw PersonalContentError.changedDocument }
        // A concurrent unlink/rebind is not made valid by the initial read.
        guard let currentRoot = try await authority.workspaceVideoRoot(workspaceID: workspaceID),
              currentRoot.relativePath == rootBinding.relativePath,
              currentRoot.rootIdentity == rootBinding.rootIdentity,
              currentRoot.containerIdentity == rootBinding.containerIdentity,
              try await authority.workspaceVideoBinding(conversationID: binding.conversationID,
                  workspaceID: workspaceID, projectID: projectID) == binding else {
            throw PersonalContentError.changedDocument
        }
        if workspace.kind == .privateTask {
            guard try await store.workspaceID(conversationID: binding.conversationID) == workspaceID else {
                throw PersonalContentError.changedDocument
            }
        }
        try Task.checkCancellation()
        let owner = WorkspaceVideoPermitOwner(rootPath: root.path, components: [components[0], components[1], "Media", "Projects"],
                                               descriptors: descriptors, lease: lease)
        // From this point the owner, including its deinit, exclusively owns
        // both the descriptors and the scope lease, even if validation fails.
        transferred = true
        try owner.validate()
        let permit = MediaProjectWritePermit(validate: { try owner.validate() }, release: { owner.release() })
        return permit
    }
}

/// Serializes validation against release: a closing view cannot invalidate
/// descriptors underneath an already running synchronous commit check.
private final class WorkspaceVideoPermitOwner: @unchecked Sendable {
    private let lock = NSLock()
    private var released = false
    private let rootPath: String
    private let components: [String]
    private let descriptors: [Int32]
    private let lease: WorkspaceCenter.TaskRootLease

    init(rootPath: String, components: [String], descriptors: [Int32], lease: WorkspaceCenter.TaskRootLease) {
        self.rootPath = rootPath; self.components = components; self.descriptors = descriptors; self.lease = lease
    }

    func validate() throws {
        lock.lock(); defer { lock.unlock() }
        guard !released, descriptors.count == components.count + 1 else { throw PersonalContentError.changedDocument }
        var openedRoot = stat(), currentRoot = stat()
        guard fstat(descriptors[0], &openedRoot) == 0, lstat(rootPath, &currentRoot) == 0,
              (openedRoot.st_mode & S_IFMT) == S_IFDIR, (currentRoot.st_mode & S_IFMT) == S_IFDIR,
              openedRoot.st_dev == currentRoot.st_dev, openedRoot.st_ino == currentRoot.st_ino else {
            throw PersonalContentError.changedDocument
        }
        for index in components.indices {
            var opened = stat(), current = stat()
            guard fstat(descriptors[index + 1], &opened) == 0,
                  fstatat(descriptors[index], components[index], &current, AT_SYMLINK_NOFOLLOW) == 0,
                  (opened.st_mode & S_IFMT) == S_IFDIR, (current.st_mode & S_IFMT) == S_IFDIR,
                  opened.st_dev == current.st_dev, opened.st_ino == current.st_ino else {
                throw PersonalContentError.changedDocument
            }
        }
    }

    func release() {
        lock.lock()
        guard !released else { lock.unlock(); return }
        released = true
        for fd in descriptors.reversed() { close(fd) }
        lock.unlock()
        lease.release()
    }

    deinit { release() }
}
#endif
