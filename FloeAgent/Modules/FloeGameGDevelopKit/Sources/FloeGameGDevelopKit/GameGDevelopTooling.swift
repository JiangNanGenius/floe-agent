// SPDX-License-Identifier: MPL-2.0
import Foundation

/// Locations of checked host scripts that accompany this component. They are
/// build recipes run by the existing Linux/CI execution service; they are not
/// App tools, general interpreters or downloaded native modules.
public enum GameGDevelopTooling {
    public static var exportScriptURL: URL? {
        Bundle.module.url(forResource: "gdevelop-export", withExtension: "py")
    }
}
