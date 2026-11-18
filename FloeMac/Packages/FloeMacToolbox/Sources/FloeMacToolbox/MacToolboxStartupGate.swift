import Foundation

/// Single-flight, one-way host lifecycle. Callbacks are injected so the
/// sequencing can be exercised without filesystem or system services.
/// Fences later stages after every suspension; it cannot cancel side effects
/// already executing inside a dependency that ignores task cancellation.
@MainActor
final class MacToolboxStartupGate {
    private(set) var terminated = false
    private var startTask: Task<Void, Never>?

    func start(prepare: @escaping @MainActor () async -> Void,
               load: @escaping @MainActor () async -> Void,
               activate: @escaping @MainActor () -> Void) async {
        guard !terminated, !Task.isCancelled else { return }
        if let startTask {
            await startTask.value
            return
        }
        let task = Task { @MainActor [weak self] in
            guard let self, !self.terminated, !Task.isCancelled else { return }
            await prepare()
            guard !self.terminated, !Task.isCancelled else { return }
            await load()
            guard !self.terminated, !Task.isCancelled else { return }
            activate()
        }
        startTask = task
        await task.value
    }

    func shutdown() {
        guard !terminated else { return }
        terminated = true
        startTask?.cancel()
    }
}
