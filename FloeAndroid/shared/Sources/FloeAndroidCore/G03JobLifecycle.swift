// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeCore
import FloePersistence
import FloeAndroidJobTools

private final class G03JobServiceBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: BackgroundJobService?
    func set(_ service: BackgroundJobService) { lock.lock(); value = service; lock.unlock() }
    func get() -> BackgroundJobService? { lock.lock(); defer { lock.unlock() }; return value }
    func clear() { lock.lock(); value = nil; lock.unlock() }
}
private final class G03JobLifecycleBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: G03JobLifecycle?
    func get() -> G03JobLifecycle? { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ owner: G03JobLifecycle?) { lock.lock(); value = owner; lock.unlock() }
    func clear(epoch: UInt64) { lock.lock(); defer { lock.unlock() }; if value?.epoch == epoch { value = nil } }
}

/// Root/service ownership only. Original BackgroundJobStore/Service remain authority.
public actor G03JobLifecycle: JobProcessorOwnershipDelegate {
    private static let installed = G03JobLifecycleBox()
    public nonisolated let epoch: UInt64
    private let service = G03JobServiceBox()
    private var tokens: [UUID: RuntimeOwnedWorkToken] = [:]
    private var conversations: [UUID: UUID] = [:]
    private var stopRequested: Set<UUID> = []

    public init(epoch: UInt64) { self.epoch = epoch }
    public nonisolated static var current: G03JobLifecycle? { installed.get() }
    public nonisolated static func install(_ owner: G03JobLifecycle) { installed.set(owner) }
    public nonisolated static func uninstall(epoch: UInt64) { installed.clear(epoch: epoch) }
    public nonisolated func bind(_ service: BackgroundJobService) { self.service.set(service) }

    public func jobProcessorStarted(jobID: UUID, targetTool: String) async throws {
        try Task.checkCancellation()
        guard let service = service.get(), let row = try await service.job(id: jobID),
              row.state == .running || row.state == .queued else {
            throw NativeJobSafetyFailure(reason: "Job processor has no current durable owner.")
        }
        let conversation = row.conversationID
        guard G02NativeRootEpoch.readback() == epoch else {
            throw NativeJobSafetyFailure(reason: "Job root generation retired before processor admission.")
        }
        if let domain = RunDomainFacade.current(epoch: epoch)?.0,
           await domain.fenceGuardState(conversation) != nil {
            throw NativeJobSafetyFailure(reason: "Job conversation is being removed; target was not started.")
        }
        if tokens[jobID] == nil {
            guard case let .attached(token) = RuntimeOwnedWorkRegistry.shared.attach(
                epoch: epoch, kind: .tool, ownerID: "job-" + jobID.uuidString) else {
                throw NativeJobSafetyFailure(reason: "Job root refused processor ownership.")
            }
            tokens[jobID] = token
            conversations[jobID] = conversation
        }
        // Await actual foreground protection BEFORE running the target.
        guard await hostOwnership(jobID: jobID, acquire: true) else {
            throw NativeJobSafetyFailure(reason: "Background task protection was not available; target was not started.")
        }
        guard G02NativeRootEpoch.readback() == epoch else { throw CancellationError() }
        if let domain = RunDomainFacade.current(epoch: epoch)?.0,
           await domain.fenceGuardState(conversation) != nil { throw CancellationError() }
    }

    public func jobProcessorSettled(jobID: UUID) async {
        // The processor returned, but original output spooling, durable
        // terminal CAS and dependency resolution may still be outstanding.
        // The ORIGINAL service onTerminal callback releases this ownership.
    }

    public func terminal(_ job: BackgroundJob) async {
        await release(job.id)
    }

    private func release(_ jobID: UUID) async {
        guard let token = tokens[jobID] else { return }
        guard await hostOwnership(jobID: jobID, acquire: false) else { return }
        tokens.removeValue(forKey: jobID)
        conversations.removeValue(forKey: jobID)
        stopRequested.remove(jobID)
        RuntimeOwnedWorkRegistry.shared.detach(token)
    }

    private func hostOwnership(jobID: UUID, acquire: Bool) async -> Bool {
        let epoch = self.epoch
        return await Task.detached {
            do {
                let payload = try JSONSerialization.data(withJSONObject: [
                    "epoch": epoch, "jobID": jobID.uuidString,
                    "action": acquire ? "acquire" : "release",
                ])
                let response = try await LinuxShellMailbox.shared.submit(operation: "host.jobOwnership",
                    payload: payload, timeoutMillis: 15_000)
                let value = try JSONSerialization.jsonObject(with: response) as? [String: Any]
                return value?["accepted"] as? Bool == true
            } catch { return false }
        }.value
    }

    /// Stop original service-owned tasks, then await their real completion.
    /// Token release is after original final writes, never just processor EOF.
    public func stopAndDrain(timeoutMillis: Int) async -> Bool {
        guard let service = service.get() else { return tokens.isEmpty }
        await service.requestStopOwnedProcessors()
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(max(0, timeoutMillis)) * 1_000_000
        repeat {
            let active = await service.ownedProcessorIDs()
            if active.isEmpty {
                for id in Array(tokens.keys) { await release(id) }
                if tokens.isEmpty { return true }
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        } while DispatchTime.now().uptimeNanoseconds < deadline
        return false
    }

    public func requestCancel(jobID: UUID) async {
        guard let service = service.get() else { return }
        _ = try? await service.cancel(id: jobID)
    }

    public func requestStopAll() async {
        await service.get()?.requestStopOwnedProcessors()
    }

    public func disconnectAfterDrain() async -> Bool {
        guard tokens.isEmpty else { return false }
        if let service = service.get(), !(await service.ownedProcessorIDs()).isEmpty { return false }
        service.clear() // break the service onTerminal -> owner -> service cycle
        return true
    }

    public func tokensForConversation(_ conversationID: UUID) -> [RuntimeOwnedWorkToken] {
        tokens.compactMap { conversations[$0.key] == conversationID ? $0.value : nil }
    }

    /// Called under the ORIGINAL conversation deletion fence. Other
    /// conversations' processors, tokens and output are untouched.
    public func drainConversationTick(_ conversationID: UUID) async -> Bool {
        guard let service = service.get() else { return true }
        let active = await service.ownedProcessorIDs()
        var targetActive = false
        for id in active {
            var belongs = conversations[id] == conversationID
            if !belongs { belongs = (try? await service.job(id: id))?.conversationID == conversationID }
            if belongs {
                targetActive = true
                if stopRequested.insert(id).inserted { _ = try? await service.cancel(id: id) }
            }
        }
        for id in tokens.keys.filter({ conversations[$0] == conversationID && !active.contains($0) }) {
            await release(id)
        }
        return !targetActive && !conversations.values.contains(conversationID)
    }
}

/// Exact-root private notification ingress, never a model/public IPC operation.
@_cdecl("floe_jobs_cancel_owned")
public func floeJobsCancelOwned(_ epoch: UInt64, _ jobID: UnsafePointer<CChar>?) -> Int32 {
    guard let owner = G03JobLifecycle.current, owner.epoch == epoch,
          let jobID, let id = UUID(uuidString: String(cString: jobID)) else { return -105 }
    Task.detached { await owner.requestCancel(jobID: id) }
    return 0 // stop requested, never a terminal/lease-release claim
}
