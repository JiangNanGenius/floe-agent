// FloeLocalModels — classify a failed MLX container construction.
//
// SPDX-License-Identifier: MPL-2.0
//
// A "MLX container initialization failed … code 0" message told the user
// nothing: the generic engine code covers damaged weights, a missing file, an
// unsupported architecture and a Metal allocation failure alike. The runtime
// now checks the snapshot deterministically before asking MLX to load, and
// this classifier maps the remaining failure to a user-actionable kind:
//
//   - `corruptSnapshot`      re-download the model (damaged/missing files)
//   - `insufficientMemory`   free memory / stop the Linux guest / smaller model
//   - `unknown`              keep the honest class + code diagnostic
//
// It is a pure function so it can be unit tested without a GPU, weights or a
// device.

import Foundation
import FloeLocalModelCatalog

public enum LocalModelLoadFailure: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case corruptSnapshot(String)
        case insufficientMemory(required: UInt64, physical: UInt64)
        case unknown(String)
    }

    /// Lowercased fragments that identify an allocation failure in the
    /// bounded diagnostics MLX/CoreML surface. Kept deliberately specific:
    /// a false "memory" verdict would send the user to the wrong repair.
    static let memoryHints: [String] = [
        "out of memory",
        "outofmemory",
        "insufficient memory",
        "cannot allocate",
        "failed to allocate",
        "allocation failed",
        "resource limit",
        "exc_resource",
        "memory pressure",
        "kIOGPUCommandBufferCallbackErrorOutOfMemory".lowercased()
    ]

    public static func classify(
        error: Error,
        snapshotProblems: [LocalModelSnapshotIntegrity.Problem] = [],
        mappedBytes: UInt64 = 0,
        headroomBytes: UInt64 = 0
    ) -> Kind {
        if let problem = snapshotProblems.first {
            return .corruptSnapshot(problem.summary)
        }
        let nsError = error as NSError
        let description = ([nsError.localizedDescription] + (nsError.userInfo.values.compactMap { $0 as? String }))
            .joined(separator: " ")
            .lowercased()
        let looksLikeMemory = memoryHints.contains { description.contains($0) }
            || (mappedBytes > 0 && headroomBytes > 0 && mappedBytes > headroomBytes)
        if looksLikeMemory {
            return .insufficientMemory(required: mappedBytes, physical: headroomBytes)
        }
        return .unknown("domain \(nsError.domain), code \(nsError.code)")
    }
}
