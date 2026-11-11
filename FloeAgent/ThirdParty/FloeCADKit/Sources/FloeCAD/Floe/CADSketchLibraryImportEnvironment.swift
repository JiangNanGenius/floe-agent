// SPDX-License-Identifier: MPL-2.0
import SwiftUI

public extension EnvironmentValues {
    /// App-owned library selection. Package-only hosts omit this entry.
    @Entry var cadImportSketchFromLibrary: (@MainActor @Sendable (CADSketchImportContext) -> Void)? = nil
}
