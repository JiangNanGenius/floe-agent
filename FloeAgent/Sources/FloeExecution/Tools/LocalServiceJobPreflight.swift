// FloeExecution — Submit-time preflight for exec.localService background jobs.
// The service runner historically discovered a missing entry script or
// working directory only after the durable job record was created and the
// detached runner started — an asynchronous failure the caller could no
// longer act on. This check runs synchronously inside jobs.submit, before
// persistence, and reports exactly which path is wrong and how to fix it.
// Tools without workspace-path arguments simply never register a preflight;
// their submission semantics are unchanged.

import Foundation
import FloeCore
import FloeTools
import FloeWorkspace

public enum LocalServiceJobPreflight {
    /// Mirrors the executable fields of the app-side `LocalServiceTool.Arguments`.
    /// Kept independent so the check stays testable from this module.
    struct Payload: Decodable, Sendable {
        var runtime: String
        var entry: String
        var cwd: String?
        var port: Int
    }

    /// Validates the payload against the resolved workspace root. `root` is
    /// the same workspace the job's ToolContext will authorize against; a nil
    /// root means the submission has no workspace to check against, which is
    /// itself an actionable error for this target.
    public static func validate(payloadJSON: Data, workspaceRootURL: URL?) throws {
        let payload: Payload
        do {
            payload = try JSONDecoder().decode(Payload.self, from: payloadJSON)
        } catch let error as DecodingError {
            throw FloeError.validationFailed(AnyAgentTool.describeDecodingError(error, toolName: "exec.localService"))
        } catch {
            throw FloeError.validationFailed("Invalid exec.localService arguments: \(error.localizedDescription)")
        }
        guard ["node", "python"].contains(payload.runtime) else {
            throw FloeError.validationFailed("exec.localService runtime must be 'node' or 'python', got '\(payload.runtime)'")
        }
        guard (1024...65535).contains(payload.port) else {
            throw FloeError.validationFailed("exec.localService port must be in 1024...65535, got \(payload.port)")
        }
        guard let root = workspaceRootURL else {
            throw FloeError.validationFailed("exec.localService needs a workspace to resolve '\(payload.entry)'; submit the job from a task with a saved workspace")
        }
        // Resolve with the same guard the runner will use, so a submission
        // that passes here cannot fail the same way at execution time.
        let guardPaths = WorkspacePathGuard(rootURL: root)
        let entry: URL
        do { entry = try guardPaths.resolve(payload.entry) }
        catch {
            throw FloeError.validationFailed("exec.localService entry '\(payload.entry)' is not inside the workspace: \(error.localizedDescription)")
        }
        let cwd: URL
        do { cwd = try guardPaths.resolve(payload.cwd ?? ".") }
        catch {
            throw FloeError.validationFailed("exec.localService cwd '\(payload.cwd ?? ".")' is not inside the workspace: \(error.localizedDescription)")
        }
        let values = try? entry.resourceValues(forKeys: [.isRegularFileKey, .isReadableKey])
        guard values?.isRegularFile == true else {
            throw FloeError.validationFailed("exec.localService entry '\(payload.entry)' does not exist or is not a file under the workspace; pass a workspace-relative path to an existing \(payload.runtime) entry script")
        }
        guard values?.isReadable != false else {
            throw FloeError.validationFailed("exec.localService entry '\(payload.entry)' is not readable; check its permissions")
        }
        guard (try? cwd.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else {
            throw FloeError.validationFailed("exec.localService cwd '\(payload.cwd ?? ".")' does not exist or is not a directory under the workspace")
        }
    }
}
