// SPDX-License-Identifier: MPL-2.0
import FloeGameCore

/// Independent, reusable Web adapters for RPG Maker MV CoreScript, love.js and
/// the official Ren'Py Web (Beta) route. App/UI, WebKit, jobs and release
/// wiring remain owned by the host.
public enum FloeGamePortableKit {
    public static let version = "0.1.0"
    public static func registry() throws -> GamePortableRegistry {
        try .init([GamePortableMVAdapter(), GamePortableLoveAdapter(), GamePortableRenPyAdapter()])
    }
    public static var supportedEngines: [GameEngineID] { [.rpgMakerMV, .love, .renpy] }
}
