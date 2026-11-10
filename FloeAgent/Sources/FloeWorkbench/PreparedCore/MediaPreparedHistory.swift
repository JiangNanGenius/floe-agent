// SPDX-License-Identifier: MPL-2.0
import Foundation

extension MediaPreparedEngine {
    /// Reverse the successful history transition using actual generations and
    /// structural positions. Reversing order preserves parent/asset dependencies.
    static func inverseChanges(_ changes: [MediaPreparedObjectChange], before: MediaPreparedDocument,
                               after: MediaPreparedDocument) -> [MediaPreparedObjectChange] {
        changes.reversed().map { change in
            let target = currentState(of: change.ref, in: before)
            let expected = currentState(of: change.ref, in: after)
            let structural = change.position != nil || change.before == nil || change.after == nil
            var container = change.containerID
            var position: Int?
            switch change.ref.kind {
            case .captionStyle, .canvas: break
            case .asset: if structural { position = before.assets.firstIndex { $0.id == change.ref.id } }
            case .layer: if structural { position = before.layers.firstIndex { $0.id == change.ref.id } }
            case .track: if structural { position = before.trackGraph.tracks.firstIndex { $0.id == change.ref.id } }
            case .clip:
                if let match = before.trackGraph.clip(id: change.ref.id) {
                    container = match.track.id
                    if structural { position = match.track.clips.firstIndex { $0.id == change.ref.id } }
                }
            }
            return .init(ref: change.ref, containerID: container, position: position ?? (structural ? change.position : nil),
                         before: target, after: expected)
        }
    }
    /// Used only after a successful gated undo/redo to advance the immediately
    /// adjacent history boundary, never after an ordinary edit or file reload.
    static func sameHistoryContent(_ lhs: MediaPreparedObjectState?, _ rhs: MediaPreparedObjectState?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): return true
        case (.canvas(let a)?,.canvas(let b)?): return a.canvas == b.canvas
        case (.captionStyle(let a)?, .captionStyle(let b)?): return a.style == b.style
        case (.asset(let a)?, .asset(let b)?): return a.reference == b.reference
        case (.layer(var a)?, .layer(var b)?): a.revision = 0; b.revision = 0; return a == b
        case (.track(var a)?, .track(var b)?): a.revision = 0; b.revision = 0; return a == b
        case (.clip(let ta, var a)?, .clip(let tb, var b)?): a.revision = 0; b.revision = 0; return ta == tb && a == b
        default: return false
        }
    }
}

extension MediaPreparedJournal {
    mutating func rebaseUndoBoundary(changed: Set<MediaPreparedObjectRef>, document: MediaPreparedDocument, excluding: UUID) {
        for ref in changed {
            guard let index = entries.indices.filter({ entries[$0].id != excluding && entries[$0].status == .committed && entries[$0].touched.contains(ref) })
                .max(by: { entries[$0].committedRevision < entries[$1].committedRevision }),
                  let change = entries[index].changes.firstIndex(where: { $0.ref == ref }) else { continue }
            let actual = MediaPreparedEngine.currentState(of: ref, in: document)
            if MediaPreparedEngine.sameHistoryContent(entries[index].changes[change].after, actual) {
                entries[index].changes[change].after = actual
            }
        }
    }
    mutating func rebaseRedoBoundary(changed: Set<MediaPreparedObjectRef>, document: MediaPreparedDocument, excluding: UUID) {
        for ref in changed {
            guard let index = entries.indices.filter({ entries[$0].id != excluding && entries[$0].status == .undone && entries[$0].redoChanges?.contains(where: { $0.ref == ref }) == true })
                .max(by: { (entries[$0].undoneRevision ?? -1) < (entries[$1].undoneRevision ?? -1) }),
                  let change = entries[index].redoChanges?.firstIndex(where: { $0.ref == ref }) else { continue }
            let actual = MediaPreparedEngine.currentState(of: ref, in: document)
            if MediaPreparedEngine.sameHistoryContent(entries[index].redoChanges?[change].after, actual) {
                entries[index].redoChanges?[change].after = actual
            }
        }
    }
}
