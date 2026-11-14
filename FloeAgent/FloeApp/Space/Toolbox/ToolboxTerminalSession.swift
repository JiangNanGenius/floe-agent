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
/// Adapter over the exact session closures below. It has no registry, host
/// lookup or fallback: a command can only reach this already-open terminal.
private nonisolated struct ToolboxTerminalAssistantHost: TerminalAssistantHost {
    let lease: SessionLease
    let target: MachineReference
    let isLive: @MainActor @Sendable () -> Bool
    let read: @MainActor @Sendable (Int) async throws -> Data
    let write: @MainActor @Sendable (Data) async throws -> Void
    func output(for lease: SessionLease, maximumBytes: Int) async throws -> Data {
        guard lease == self.lease, await MainActor.run(body: isLive) else { throw ToolboxError.staleSession }
        guard (1...32768).contains(maximumBytes) else { throw ToolboxError.limit("terminal output") }
        return try await read(maximumBytes)
    }
    func authorize(command: String, lease: SessionLease, target: MachineReference) async throws -> Bool {
        guard await MainActor.run(body: isLive) else { return false }
        guard lease == self.lease, target == self.target,
              !command.trimmingCharacters(in: .whitespaces).isEmpty,
              command.utf8.count <= TerminalAssistant.maximumCommandBytes, !command.contains("\0"),
              !command.contains("\n"), !command.contains("\r") else { return false }
        return true
    }
    func sendInput(_ bytes: Data, lease: SessionLease) async throws {
        guard lease == self.lease, bytes.count <= 8192 else { throw ToolboxError.staleSession }
        // `write` performs the ownership check and starts the input call in
        // one MainActor turn, so an expired assistant cannot slip a write in.
        try await write(bytes)
    }
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
    /// One assistant per frozen host; the host owns it, so pruning a completed
    /// run releases the actor with that binding instead of retaining every
    /// turn until disconnect. The host cannot select a different machine,
    /// spawn a shell or replay a command.
    private func makeAssistant(isLive: @escaping @MainActor @Sendable () -> Bool,
                               write: @escaping @MainActor @Sendable (Data) async throws -> Void) -> TerminalAssistant {
        let host = ToolboxTerminalAssistantHost(lease: lease, target: machine, isLive: isLive,
            read: { [weak self] maximumBytes in
                guard let self else { throw ToolboxError.staleSession }
                return try self.readOutput(maximumBytes: maximumBytes)
            }, write: write)
        return TerminalAssistant(lease: lease, target: machine, host: host, redactor: redactor)
    }
    private func readOutput(maximumBytes: Int) throws -> Data {
        guard active else { throw ToolboxError.staleSession }
        let current = output()
        return Data(current.bytes.suffix(min(maximumBytes, current.bytes.count)))
    }
    /// Ownership and the start of the PTY input call share one MainActor turn.
    private func sendAssistantInput(_ data: Data,
                                    isOwned: @escaping @MainActor @Sendable () -> Bool) async throws {
        guard active, isOwned() else { throw ToolboxError.staleSession }
        try await input(data)
    }
    func frozenHost(runID: UUID,
                    isOwned: @escaping @MainActor @Sendable () -> Bool = { true }) throws -> ToolboxAIHostContext {
        guard active, isOwned() else { throw ToolboxError.staleSession }
        let assistant = makeAssistant(isLive: { [weak self] in
            guard let self else { return false }
            return self.active && isOwned()
        }, write: { [weak self] data in
            guard let self else { throw ToolboxError.staleSession }
            try await self.sendAssistantInput(data, isOwned: isOwned)
        })
        return try .init(runID: runID, lease: lease, journal: journal, terminal: assistant, redactor: redactor,
            isCurrent: { [weak self] in
                guard let self else { return false }
                return await MainActor.run { self.active && isOwned() }
            })
    }
    func invalidate() {
        active = false; pump?.cancel(); pump = nil; preparingFiles?.cancel(); files?.invalidate()
    }
    func close() async {
        await retainOutput(whileClosing: true); invalidate()
        if let preparingFiles, let pending = try? await preparingFiles.value { await pending.close() }
        await files?.close(); files = nil
    }
}
#endif
