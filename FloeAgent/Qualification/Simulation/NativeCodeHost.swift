import SwiftUI

/// Empty XCTest host. The test bundle owns one copy of the native kernels;
/// the production App and the workbench qualification host do not load here.
@main struct SimulationNativeCodeHost: App {
    var body: some Scene { WindowGroup { ProgressView() } }
}
