// SPDX-License-Identifier: MPL-2.0
import Foundation

public enum RGSSWebEvidenceStatus: String, Codable, Equatable, Sendable {
    /// The real engine was executed by this lane with an original fixture.
    case executed
    /// Complete source/pin/build recipe exists, but no engine binary was
    /// produced or executed. API presence alone is not engine acceptance.
    case sourceRecipeOnly
    /// No reviewed source or binary is pinned.
    case notAvailable
}

/// A source-only engine recipe. It is data for a host build, never a command
/// executor or a model tool. No binary is implied by this value.
public struct RGSSWebEngineRecipe: Codable, Equatable, Sendable {
    public let id: String
    public let upstreamRepository: URL
    public let sourceCommit: String
    public let license: String
    public let supportedVersions: [RGSSVersion]
    public let sourceArchiveFileName: String
    public let sourceArchiveSHA256: String
    public let sourceArchiveBytes: Int
    public let sourceArchiveURL: URL
    public let buildRecipe: String
    public let requiresJSPI: Bool
    public let supportsAsyncify: Bool
    public let hasBinaryPack: Bool
    public let evidenceStatus: RGSSWebEvidenceStatus
    public let notes: [String]

    public init(id: String, upstreamRepository: URL, sourceCommit: String, license: String,
                supportedVersions: [RGSSVersion], sourceArchiveFileName: String,
                sourceArchiveSHA256: String, sourceArchiveBytes: Int,
                sourceArchiveURL: URL, buildRecipe: String, requiresJSPI: Bool,
                supportsAsyncify: Bool, hasBinaryPack: Bool,
                evidenceStatus: RGSSWebEvidenceStatus, notes: [String]) {
        self.id = id; self.upstreamRepository = upstreamRepository; self.sourceCommit = sourceCommit
        self.license = license; self.supportedVersions = supportedVersions
        self.sourceArchiveFileName = sourceArchiveFileName
        self.sourceArchiveSHA256 = sourceArchiveSHA256; self.sourceArchiveBytes = sourceArchiveBytes
        self.sourceArchiveURL = sourceArchiveURL; self.buildRecipe = buildRecipe
        self.requiresJSPI = requiresJSPI; self.supportsAsyncify = supportsAsyncify
        self.hasBinaryPack = hasBinaryPack; self.evidenceStatus = evidenceStatus
        self.notes = notes
    }
}

public enum RGSSWebRuntimeRecipes {
    /// Dim145/mkxp-web-jspi, pinned at the reviewed source commit. The source
    /// archive and build recipe are retained privately as a sealed resource.
    /// No compiled engine is included; real WebKit/engine execution is unverified.
    public static let mkxpWebJSPI = RGSSWebEngineRecipe(
        id: "mkxp-web-jspi-65a31be",
        upstreamRepository: URL(string: "https://github.com/Dim145/mkxp-web-jspi")!,
        sourceCommit: "65a31be926b1f6b01cee9b6ebde229f288c421af",
        license: "GPL-2.0-or-later",
        supportedVersions: [.rgss1, .rgss2],
        sourceArchiveFileName: "mkxp-web-jspi-65a31be-source.tar.gz",
        sourceArchiveSHA256: "1975684f5cc28ab830a6426a99a51ae9dbb8f890fcb948b377df8b09f249edc8",
        sourceArchiveBytes: 776_450,
        sourceArchiveURL: URL(string: "https://codeload.github.com/Dim145/mkxp-web-jspi/tar.gz/65a31be926b1f6b01cee9b6ebde229f288c421af")!,
        buildRecipe: "Build from the pinned mkxp-web JSPI source archive with the host WebAssembly toolchain; no build recipe or runtime is bundled.",
        requiresJSPI: true,
        supportsAsyncify: false,
        hasBinaryPack: false,
        evidenceStatus: .sourceRecipeOnly,
        notes: [
            "Upstream fork targets RGSS1/XP and RGSS2/VX using mruby and a JSPI frame yield; it does not target RGSS3/VX Ace.",
            "WebKit Safari 27 beta adds WebAssembly JavaScript Promise Integration, so the old upstream no-mobile README is not a current iOS capability claim.",
            "API presence (WebAssembly.Suspending/promising) is not engine acceptance; no binary was built or executed and no iPad WebKit claim is made.",
            "The source archive, COPYING, NOTICE, CHANGES and build recipe are pinned in the private artifact; no RTP/DLL/font/game content is bundled."
        ])

    public static let all: [RGSSWebEngineRecipe] = [mkxpWebJSPI]
}
