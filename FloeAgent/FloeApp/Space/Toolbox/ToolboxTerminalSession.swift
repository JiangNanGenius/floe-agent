// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import SwiftUI
import FloeCore
import FloeModels
import FloePersistence
import FloeSSH
import FloeToolboxCore
import FloeToolboxHost

nonisolated struct ToolboxTerminalOutput: Sendable {
    let bytes: Data
    let byteEnd: Int
    let generation: UUID
}
/// Retains capture and file jobs outside the terminal/inspector view lifetime.
@MainActor final class ToolboxTerminalSession: ObservableObject, Identifiable {
    let lease: SessionLease
    let machine: MachineReference
    let title: String
    let journal: CaptureJournal
    let redactor: CaptureRedactor
    let workingRoot: URL
    let savedHostID: UUID?
    nonisolated let id: UUID
    @Published private(set) var active = true
    @Published private(set) var captureFailure: String?
    @Published private(set) var files: ToolboxRemoteFilesOwner?
    private let environment: AppEnvironment
    private let output: @MainActor () -> ToolboxTerminalOutput
    private let input: @MainActor (Data) async throws -> Void
    private let sshHandle: @MainActor () -> SSHSessionHandle?
    private var pump: Task<Void, Never>?
    private var preparingFiles: Task<ToolboxRemoteFilesOwner, Error>?
    private var consumedEnd = 0
    private var outputGeneration: UUID?

    private init(environment: AppEnvironment, lease: SessionLease, machine: MachineReference, title: String,
                 journal: CaptureJournal, redactor: CaptureRedactor, workingRoot: URL, savedHostID: UUID?,
                 output: @escaping @MainActor () -> ToolboxTerminalOutput,
                 input: @escaping @MainActor (Data) async throws -> Void,
                 sshHandle: @escaping @MainActor () -> SSHSessionHandle?) {
        self.id = lease.ownerID
        self.environment = environment; self.lease = lease; self.machine = machine; self.title = title
        self.journal = journal; self.redactor = redactor; self.workingRoot = workingRoot; self.savedHostID = savedHostID
        self.output = output; self.input = input; self.sshHandle = sshHandle
    }
    static func open(environment: AppEnvironment, machine: MachineReference, title: String,
                     workingRoot: URL, savedHostID: UUID? = nil, knownSecrets: [Data] = [],
                     output: @escaping @MainActor () -> ToolboxTerminalOutput,
                     input: @escaping @MainActor (Data) async throws -> Void,
                     sshHandle: @escaping @MainActor () -> SSHSessionHandle? = { nil }) async throws -> ToolboxTerminalSession {
        let lease = SessionLease(ownerID: UUID()), root = try ToolboxCaptureStore.exportsRoot()
        let repository = ToolboxCaptureStore(database: environment.database, exportRoot: root)
        let redactor = CaptureRedactor(knownSecrets: knownSecrets)
        let journal = try await CaptureJournal(ownerID: lease.ownerID, captureID: lease.sessionID,
            repository: repository, limits: CaptureLimits(), redactor: redactor)
        try await repository.describe(captureID: lease.sessionID, ownerID: lease.ownerID, title: title, kind: "terminal")
        let owner = ToolboxTerminalSession(environment: environment, lease: lease, machine: machine, title: title,
            journal: journal, redactor: redactor, workingRoot: workingRoot, savedHostID: savedHostID,
            output: output, input: input, sshHandle: sshHandle)
        owner.pump = Task { [weak owner] in
            while !Task.isCancelled, let owner, owner.active {
                await owner.retainOutput()
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            }
        }
        return owner
    }
    private func retainOutput(whileClosing: Bool = false) async {
        guard active || whileClosing else { return }
        let current = output()
        if outputGeneration != current.generation { outputGeneration = current.generation; consumedEnd = 0 }
        guard current.byteEnd >= consumedEnd else { consumedEnd = 0; return }
        guard current.byteEnd > consumedEnd else { return }
        let retainedStart = current.byteEnd - current.bytes.count
        let available = Data(current.bytes.suffix(min(current.bytes.count, current.byteEnd - consumedEnd)))
        let gap = max(0, retainedStart - consumedEnd)
        do {
            var events: [CaptureEvent] = []
            if gap > 0 { events.append(.init(bytes: Data(), direction: .observation, notes: ["Terminal output omitted before capture: \(gap) bytes"])) }
            if !available.isEmpty {
                var event = redactor.sanitize(available, wireProtocol: .raw); event.direction = .received
                events.append(event)
            }
            if !events.isEmpty { try await journal.append(events) }
            consumedEnd = current.byteEnd; captureFailure = nil
        } catch { captureFailure = IDELanguageRunText.t("记录未能保存，请稍后重试。", "Unable to save the capture. Try again later.") }
    }
    func flush() async { await retainOutput() }
    func fillCommand(_ command: String) async throws {
        guard active, !command.isEmpty, command.utf8.count <= 8_192, !command.contains("\0"), !command.contains("\n"), !command.contains("\r") else { throw ToolboxError.denied }
        // Explicit native Fill action only; no newline is sent and no model tool bypasses approvals.
        try await input(Data(command.utf8))
    }
    func fileOwner() async throws -> ToolboxRemoteFilesOwner {
        guard active else { throw ToolboxError.staleSession }
        if let files { return files }
        if let preparingFiles { return try await preparingFiles.value }
        let task = Task { [self] in
            try await ToolboxRemoteFilesOwner.open(environment: environment, terminal: self,
                sshHandle: sshHandle)
        }
        preparingFiles = task; defer { preparingFiles = nil }
        let value = try await task.value
        guard active else { await value.close(); throw ToolboxError.staleSession }
        files = value; return value
    }
    func frozenHost(runID: UUID) throws -> ToolboxAIHostContext {
        guard active else { throw ToolboxError.staleSession }
        return try .init(runID: runID, lease: lease, journal: journal, redactor: redactor,
            isCurrent: { [weak self] in await MainActor.run { self?.active == true } })
    }
    func invalidate() { active = false; pump?.cancel(); pump = nil; preparingFiles?.cancel(); files?.invalidate() }
    func close() async {
        await retainOutput(whileClosing: true); invalidate()
        if let preparingFiles, let pending = try? await preparingFiles.value { await pending.close() }
        await files?.close(); files = nil
    }
}
#endif
