// Floe Mac M00 — task-owned fixture root identity.
//
// SPDX-License-Identifier: MPL-2.0
//
// A fixture root is never a caller-chosen arbitrary directory. It must be a
// direct mkdtemp-created child of the canonical per-user temporary directory,
// mode 0700, owned by the current user and identified by device/inode. All
// layout children are opened relative to the root with O_NOFOLLOW so a
// replaced ancestor or component fails instead of redirecting storage.

import Darwin
import Foundation

enum FixtureRootError: Error, LocalizedError, Sendable {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let text): text
        }
    }
}

struct FixtureRootLocation: Sendable, Equatable {
    static let namePrefix = "floe-mac-m00-fixture."
    static let victimPrefix = "floe-mac-m00-victim."
    static let layoutNames = ["Control", "service-home", "worker-home", "tmp"]

    let rootURL: URL
    let device: dev_t
    let inode: ino_t

    static var canonicalTemporaryDirectory: URL {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let length = buffer.withUnsafeMutableBufferPointer { pointer in
            confstr(_CS_DARWIN_USER_TEMP_DIR, pointer.baseAddress, pointer.count)
        }
        if length > 0, let raw = buffer.withUnsafeBufferPointer({ String(validatingUTF8: $0.baseAddress!) }) {
            let candidate = URL(fileURLWithPath: raw, isDirectory: true)
            if let canonical = try? canonicalDirectory(candidate, label: "temporary directory") {
                return URL(fileURLWithPath: canonical, isDirectory: true)
            }
        }
        return FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath()
            .standardizedFileURL
    }

    /// Creates a new task-owned root. This is the only supported way for a
    /// fixture consumer to obtain a root: the name, parent, owner and mode are
    /// all fixed here and rechecked by the helper before any sandboxed work.
    static func create(prefix: String = namePrefix, under base: URL? = nil) throws -> FixtureRootLocation {
        let baseURL = base ?? canonicalTemporaryDirectory
        let basePath = try canonicalDirectory(baseURL, label: "fixture base")
        guard basePath == canonicalTemporaryDirectory.path else {
            throw FixtureRootError.message("Fixture roots must be created directly in \(canonicalTemporaryDirectory.path).")
        }
        var template = Array("\(basePath)/\(prefix)XXXXXX".utf8CString)
        let created = template.withUnsafeMutableBufferPointer { pointer -> UnsafeMutablePointer<CChar>? in
            mkdtemp(pointer.baseAddress)
        }
        guard let created else {
            throw FixtureRootError.message("mkdtemp failed for \(basePath): \(String(cString: strerror(errno)))")
        }
        let path = String(cString: created)
        guard chmod(path, 0o700) == 0 else {
            _ = rmdir(path)
            throw FixtureRootError.message("Could not set fixture root mode 0700.")
        }
        let location = try validateExisting(URL(fileURLWithPath: path, isDirectory: true), prefix: prefix)
        try location.ensureLayout()
        return location
    }

    static func validateExisting(_ url: URL, prefix: String = namePrefix) throws -> FixtureRootLocation {
        var initial = stat()
        guard lstat(url.path, &initial) == 0 else {
            throw FixtureRootError.message("Fixture root can not be inspected: \(String(cString: strerror(errno)))")
        }
        guard (initial.st_mode & S_IFMT) != S_IFLNK else {
            throw FixtureRootError.message("The fixture root itself must not be a symbolic link.")
        }
        guard (initial.st_mode & S_IFMT) == S_IFDIR else {
            throw FixtureRootError.message("The fixture root is not a directory.")
        }
        let canonical = try canonicalDirectory(url, label: "fixture root")
        let base = canonicalTemporaryDirectory.path
        let parent = URL(fileURLWithPath: canonical, isDirectory: true).deletingLastPathComponent().path
        guard parent == base else {
            throw FixtureRootError.message("Fixture roots must be direct children of \(base).")
        }
        let name = URL(fileURLWithPath: canonical, isDirectory: true).lastPathComponent
        guard isMkdtempName(name, prefix: prefix) else {
            throw FixtureRootError.message("Fixture root name must be \(prefix) followed by six letters or digits.")
        }
        guard initial.st_uid == geteuid() else {
            throw FixtureRootError.message("The fixture root is not owned by the current user.")
        }
        guard (initial.st_mode & 0o777) == 0o700 else {
            throw FixtureRootError.message("The fixture root must have mode 0700.")
        }
        let descriptor = open(canonical, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw FixtureRootError.message("Could not open the fixture root without following links: \(String(cString: strerror(errno)))")
        }
        defer { close(descriptor) }
        var opened = stat()
        guard fstat(descriptor, &opened) == 0,
              opened.st_dev == initial.st_dev, opened.st_ino == initial.st_ino,
              (opened.st_mode & S_IFMT) == S_IFDIR, opened.st_uid == geteuid(),
              (opened.st_mode & 0o777) == 0o700 else {
            throw FixtureRootError.message("The fixture root identity changed while it was opened.")
        }
        return FixtureRootLocation(
            rootURL: URL(fileURLWithPath: canonical, isDirectory: true),
            device: initial.st_dev,
            inode: initial.st_ino
        )
    }

    var controlDirectory: URL { rootURL.appendingPathComponent("Control", isDirectory: true) }
    var serviceHome: URL { rootURL.appendingPathComponent("service-home", isDirectory: true) }
    var workerHome: URL { rootURL.appendingPathComponent("worker-home", isDirectory: true) }
    var tempDirectory: URL { rootURL.appendingPathComponent("tmp", isDirectory: true) }

    /// Creates or verifies every direct child with openat(O_NOFOLLOW). Modes
    /// are normalised to 0700; an existing symlink, foreign owner or non-directory
    /// makes the whole fixture fail closed.
    func ensureLayout() throws {
        let rootDescriptor = try openRootDescriptor()
        defer { close(rootDescriptor) }
        for name in Self.layoutNames {
            if mkdirat(rootDescriptor, name, 0o700) != 0 && errno != EEXIST {
                throw FixtureRootError.message("Could not create fixture component \(name): \(String(cString: strerror(errno)))")
            }
            let descriptor = openat(rootDescriptor, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard descriptor >= 0 else {
                throw FixtureRootError.message("Fixture component \(name) is not a real directory: \(String(cString: strerror(errno)))")
            }
            defer { close(descriptor) }
            var value = stat()
            guard fstat(descriptor, &value) == 0,
                  (value.st_mode & S_IFMT) == S_IFDIR,
                  value.st_uid == geteuid() else {
                throw FixtureRootError.message("Fixture component \(name) has an unexpected owner or type.")
            }
            if (value.st_mode & 0o777) != 0o700 {
                guard fchmod(descriptor, 0o700) == 0 else {
                    throw FixtureRootError.message("Could not set fixture component \(name) to mode 0700.")
                }
            }
        }
    }

    /// Rechecks the pinned root and every layout child. Called before ready
    /// reports and shutdown so a replacement after startup is observable even
    /// though the kernel sandbox remains the primary path authority.
    func verifyPinned() throws {
        let rootDescriptor = try openRootDescriptor()
        defer { close(rootDescriptor) }
        var value = stat()
        guard fstat(rootDescriptor, &value) == 0,
              value.st_dev == device, value.st_ino == inode,
              value.st_uid == geteuid(), (value.st_mode & 0o777) == 0o700 else {
            throw FixtureRootError.message("The fixture root identity was replaced.")
        }
        for name in Self.layoutNames {
            let descriptor = openat(rootDescriptor, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard descriptor >= 0 else {
                throw FixtureRootError.message("Fixture component \(name) is no longer a real directory.")
            }
            defer { close(descriptor) }
            var component = stat()
            guard fstat(descriptor, &component) == 0,
                  (component.st_mode & S_IFMT) == S_IFDIR,
                  component.st_uid == geteuid(),
                  (component.st_mode & 0o777) == 0o700 else {
                throw FixtureRootError.message("Fixture component \(name) changed identity.")
            }
        }
    }

    func controlFileURL(named name: String) throws -> URL {
        guard Self.isSafeBasename(name), name != "sandbox-profile.sb", name != "sandbox-report.json" else {
            throw FixtureRootError.message("A control file name is not allowed: \(name)")
        }
        return controlDirectory.appendingPathComponent(name, isDirectory: false)
    }

    static func isSafeBasename(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 64, name != ".", name != ".." else { return false }
        return name.utf8.allSatisfy { byte in
            (byte >= 0x30 && byte <= 0x39)
                || (byte >= 0x41 && byte <= 0x5A)
                || (byte >= 0x61 && byte <= 0x7A)
                || byte == 0x2E || byte == 0x5F || byte == 0x2D
        }
    }

    private func openRootDescriptor() throws -> Int32 {
        let descriptor = open(rootURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw FixtureRootError.message("Could not open the fixture root: \(String(cString: strerror(errno)))")
        }
        return descriptor
    }

    private static func isMkdtempName(_ name: String, prefix: String) -> Bool {
        guard name.hasPrefix(prefix) else { return false }
        let suffix = name.dropFirst(prefix.count)
        guard suffix.count == 6 else { return false }
        return suffix.utf8.allSatisfy { byte in
            (byte >= 0x30 && byte <= 0x39)
                || (byte >= 0x41 && byte <= 0x5A)
                || (byte >= 0x61 && byte <= 0x7A)
        }
    }

    static func canonicalDirectory(_ url: URL, label: String) throws -> String {
        var value = stat()
        guard lstat(url.path, &value) == 0 else {
            throw FixtureRootError.message("The \(label) does not exist: \(url.path)")
        }
        guard (value.st_mode & S_IFMT) != S_IFLNK else {
            throw FixtureRootError.message("The \(label) must not be a symbolic link: \(url.path)")
        }
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let resolved = buffer.withUnsafeMutableBufferPointer { pointer -> UnsafeMutablePointer<CChar>? in
            realpath(url.path, pointer.baseAddress)
        }
        guard let resolved, let canonical = String(validatingUTF8: resolved) else {
            throw FixtureRootError.message("The \(label) can not be resolved: \(url.path)")
        }
        var canonicalValue = stat()
        guard lstat(canonical, &canonicalValue) == 0,
              (canonicalValue.st_mode & S_IFMT) == S_IFDIR else {
            throw FixtureRootError.message("The \(label) is not a directory: \(canonical)")
        }
        return canonical
    }
}
