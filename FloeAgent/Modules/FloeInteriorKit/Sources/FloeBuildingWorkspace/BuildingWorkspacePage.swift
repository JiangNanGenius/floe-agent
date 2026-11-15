// SPDX-License-Identifier: MPL-2.0
import Foundation

/// A bounded, revision-stamped page. requiresFilter explicitly signals results
/// beyond the listing budget; it never means the project contains no more data.
public struct BuildingWorkspacePage<Value: Sendable>: Sendable {
    public var items: [Value]
    public var nextOffset: Int?
    public var requiresFilter: Bool
    public var revision: Int
    public init(items: [Value], nextOffset: Int?, requiresFilter: Bool, revision: Int) {
        self.items=items; self.nextOffset=nextOffset; self.requiresFilter=requiresFilter; self.revision=revision
    }
}
