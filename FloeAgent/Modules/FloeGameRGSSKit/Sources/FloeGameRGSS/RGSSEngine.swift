// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeGameCore

/// RGSS generation implemented by the selected engine adapter. The raw values
/// match the RGSS runtime version (not a game build number).
public enum RGSSVersion: Int, Codable, CaseIterable, Hashable, Sendable {
    case rgss1 = 1
    case rgss2 = 2
    case rgss3 = 3

    public var displayName: String {
        switch self {
        case .rgss1: "RPG Maker XP (RGSS1)"
        case .rgss2: "RPG Maker VX (RGSS2)"
        case .rgss3: "RPG Maker VX Ace (RGSS3)"
        }
    }
}

/// Project-format facts that are true independently of an installed engine.
public struct RGSSEngineProfile: Equatable, Sendable {
    public let engine: GameEngineID
    public let version: RGSSVersion
    public let markerExtension: String
    public let dataExtension: String
    public let scriptsPath: String
    public let systemDataPath: String
    public let screenWidth: Int
    public let screenHeight: Int

    public init(engine: GameEngineID, version: RGSSVersion, markerExtension: String,
                dataExtension: String, scriptsPath: String, systemDataPath: String,
                screenWidth: Int, screenHeight: Int) {
        self.engine = engine
        self.version = version
        self.markerExtension = markerExtension
        self.dataExtension = dataExtension
        self.scriptsPath = scriptsPath
        self.systemDataPath = systemDataPath
        self.screenWidth = screenWidth
        self.screenHeight = screenHeight
    }
}

public enum RGSSEngineProfiles {
    public static let xp = RGSSEngineProfile(
        engine: .rpgMakerXP, version: .rgss1, markerExtension: "rxproj",
        dataExtension: "rxdata", scriptsPath: "Data/Scripts.rxdata",
        systemDataPath: "Data/System.rxdata", screenWidth: 640, screenHeight: 480)

    public static let vx = RGSSEngineProfile(
        engine: .rpgMakerVX, version: .rgss2, markerExtension: "rvproj",
        dataExtension: "rvdata", scriptsPath: "Data/Scripts.rvdata",
        systemDataPath: "Data/System.rvdata", screenWidth: 544, screenHeight: 416)

    public static let vxAce = RGSSEngineProfile(
        engine: .rpgMakerVXAce, version: .rgss3, markerExtension: "rvproj2",
        dataExtension: "rvdata2", scriptsPath: "Data/Scripts.rvdata2",
        systemDataPath: "Data/System.rvdata2", screenWidth: 544, screenHeight: 416)

    public static let all: [RGSSEngineProfile] = [xp, vx, vxAce]

    public static func profile(for engine: GameEngineID) throws -> RGSSEngineProfile {
        guard let profile = all.first(where: { $0.engine == engine }) else {
            throw RGSSRuntimeError.invalidEngine(engine.rawValue)
        }
        return profile
    }

    public static func isRGSS(_ engine: GameEngineID) -> Bool {
        all.contains(where: { $0.engine == engine })
    }
}

/// The exact Web availability of the reviewed engine resource. This is a
/// support statement for the pinned pack, not a claim about arbitrary games.
public enum RGSSWebAvailability: Codable, Equatable, Sendable {
    /// A real WebAssembly engine exists and was exercised with an original
    /// fixture. Imported scripts may still require porting.
    case verifiedAsyncify(pinID: String)
    /// A complete source pin/build recipe exists, but no engine binary was
    /// produced or executed. WebKit API presence is not engine acceptance.
    case sourceRecipeOnly(forkID: String, reason: String)
    /// No reviewed Web engine is pinned for this generation.
    case unavailable(reason: String)
}

public enum RGSSGuestAvailability: Codable, Equatable, Sendable {
    /// An existing Linux guest can host the pinned native engine through an
    /// explicit display/job service. This package does not create a VM.
    case typedAdapterAvailable(engineID: String)
    case unavailable(reason: String)
}

public struct RGSSRuntimeSupport: Equatable, Sendable {
    public let engine: GameEngineID
    public let version: RGSSVersion
    public let web: RGSSWebAvailability
    public let guest: RGSSGuestAvailability
    /// Imported games may need a project-specific port (event loop, MRI-only
    /// syntax, Win32API, custom plugins, RTP/fonts). Never silently translated.
    public let requiresProjectReview: Bool
    public let notes: [String]

    public init(engine: GameEngineID, version: RGSSVersion, web: RGSSWebAvailability,
                guest: RGSSGuestAvailability, requiresProjectReview: Bool, notes: [String]) {
        self.engine = engine
        self.version = version
        self.web = web
        self.guest = guest
        self.requiresProjectReview = requiresProjectReview
        self.notes = notes
    }
}

public enum RGSSRuntimeMatrix {
    public static let asyncifyPinID = "mkxp-web-asyncify-e0437fd"
    /// The Tapir source pin used by the private guest build. No binary is
    /// bundled and no runtime is claimed by this package.
    public static let linuxPinID = "tapir-a56b1946-linux-aarch64"

    public static let all: [RGSSRuntimeSupport] = [
        .init(engine: .rpgMakerXP, version: .rgss1,
              web: .verifiedAsyncify(pinID: asyncifyPinID),
              guest: .typedAdapterAvailable(engineID: linuxPinID),
              requiresProjectReview: true,
              notes: [
                "Reviewed mkxp-web Asyncify WASM engine (RGSS1/mruby), GPL-2.0-or-later.",
                "The upstream Asyncify engine expects a main_update_loop callback; an unported blocking loop will not yield.",
                "Linux guest route: Tapir source pin, separately built; typed host binding in this package.",
                "Some scripts use MRI-only syntax, Win32API, custom DLLs, RTP or fonts and cannot run unchanged.",
                "Native Windows EXE/DLLs are preserved in the repository and never executed."
              ]),
        .init(engine: .rpgMakerVX, version: .rgss2,
              web: .sourceRecipeOnly(
                forkID: RGSSWebRuntimeRecipes.mkxpWebJSPI.id,
                reason: "WebKit Safari 27 beta adds WebAssembly JSPI, but actual isolated-world API/engine execution is unverified. The pinned JSPI fork is source-recipe-only; no binary is included."),
              guest: .typedAdapterAvailable(engineID: linuxPinID),
              requiresProjectReview: true,
              notes: [
                "The reviewed RGSS2 Web fork (Dim145/mkxp-web-jspi) is JSPI-only, pinned at source 65a31be; its source archive/build recipe is retained, but no engine was built or executed.",
                "WebKit Safari 27 beta adds WebAssembly JSPI; API presence is not engine acceptance, and Root owns the canonical iPad probe.",
                "Linux guest route: Tapir source pin, separately built; typed host binding in this package.",
                "Original data/scripts and project markers are preserved; no automatic conversion of VX data to RGSS1."
              ]),
        .init(engine: .rpgMakerVXAce, version: .rgss3,
              web: .unavailable(reason: "No reviewed iOS-compatible RGSS3 Web engine resource is pinned."),
              guest: .typedAdapterAvailable(engineID: linuxPinID),
              requiresProjectReview: true,
              notes: [
                "Linux guest route: Tapir source pin, separately built; typed host binding in this package.",
                "The typed Linux guest adapter is delivered without executing an imported game in this lane.",
                "No RTP, Enterbrain DLL or proprietary font is bundled."
              ])
    ]

    public static func support(for engine: GameEngineID) throws -> RGSSRuntimeSupport {
        guard let support = all.first(where: { $0.engine == engine }) else {
            throw RGSSRuntimeError.invalidEngine(engine.rawValue)
        }
        return support
    }
}
