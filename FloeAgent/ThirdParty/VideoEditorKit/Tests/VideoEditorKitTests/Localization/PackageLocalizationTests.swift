import Foundation
import Testing

@testable import VideoEditorKit

@Suite("PackageLocalizationTests")
struct PackageLocalizationTests {

    // MARK: - Public Methods

    @Test
    func toolTitlesResolveFromThePackageLocalizationLayer() {
        #expect(ToolEnum.cut.title == "Cut")
        #expect(ToolEnum.speed.title == "Speed")
        #expect(ToolEnum.presets.title == "Presets")
        #expect(ToolEnum.audio.title == "Audio")
        #expect(ToolEnum.transcript.title == "Transcript")
        #expect(ToolEnum.adjusts.title == "Adjusts")
    }

    @Test
    func exportQualityMetadataUsesLocalizedTitlesAndSubtitles() {
        #expect(VideoQuality.original.title == "Original")
        #expect(VideoQuality.low.title == "qHD - 480")
        #expect(VideoQuality.medium.title == "HD - 720p")
        #expect(VideoQuality.high.title == "Full HD - 1080p")
        #expect(VideoQuality.original.subtitle == "Preserves the source resolution and frame rate")
        #expect(VideoQuality.low.subtitle == "Fast loading and small size, low quality")
        #expect(VideoQuality.medium.subtitle == "Optimal size to quality ratio")
        #expect(VideoQuality.high.subtitle == "Ideal for publishing on social networks")
    }

    @Test
    func transcriptOverlayEnumsResolveLocalizedLabels() {
        #expect(TranscriptOverlayPosition.top.title == "Top")
        #expect(TranscriptOverlayPosition.center.title == "Center")
        #expect(TranscriptOverlayPosition.bottom.title == "Bottom")
        #expect(TranscriptOverlaySize.small.title == "Small")
        #expect(TranscriptOverlaySize.medium.title == "Medium")
        #expect(TranscriptOverlaySize.large.title == "Large")
    }

    @Test
    func safeAreaProfilesUseLocalizedPackageCopy() {
        #expect(SafeAreaGuideProfile.universalSocial.title == "Universal Social Safe Zone")
        #expect(SocialPlatform.instagram.title == "Instagram Reels & Stories")
        #expect(SocialPlatform.tiktok.title == "TikTok")
        #expect(SocialPlatform.youtubeShorts.title == "YouTube Shorts")
    }

    @Test
    func packageResourceBundleExposesLocalizedResourcesForSupportedLanguages() throws {
        let bundle = try moduleResourceBundle()
        let expectedLocalizations = ["pt-BR", "es", "ja", "zh-Hans", "fr", "de"]

        for localization in expectedLocalizations {
            #expect(bundle.localizations.contains(localization))
            #expect(bundle.path(forResource: localization, ofType: "lproj") != nil)
        }
    }

    @Test
    func localizedCatalogResolvesRepresentativeTranslations() throws {
        let bundle = try moduleResourceBundle()
        let ptBRBundle = try localizedBundle(for: "pt-BR", in: bundle)
        let esBundle = try localizedBundle(for: "es", in: bundle)
        let jaBundle = try localizedBundle(for: "ja", in: bundle)
        let zhHansBundle = try localizedBundle(for: "zh-Hans", in: bundle)
        let frBundle = try localizedBundle(for: "fr", in: bundle)
        let deBundle = try localizedBundle(for: "de", in: bundle)

        #expect(ptBRBundle.localizedString(forKey: "common.apply", value: nil, table: "Localizable") == "Aplicar")
        #expect(
            ptBRBundle.localizedString(forKey: "editor.export.title", value: nil, table: "Localizable")
                == "Exportar vídeo"
        )

        #expect(esBundle.localizedString(forKey: "common.cancel", value: nil, table: "Localizable") == "Cancelar")
        #expect(
            esBundle.localizedString(forKey: "editor.transcript.idle.title", value: nil, table: "Localizable")
                == "Crear una transcripción"
        )

        #expect(jaBundle.localizedString(forKey: "common.export", value: nil, table: "Localizable") == "書き出し")
        #expect(
            jaBundle.localizedString(forKey: "editor.tool.presets.custom-crop", value: nil, table: "Localizable")
                == "カスタムクロップ"
        )

        #expect(
            zhHansBundle.localizedString(forKey: "common.not-selected", value: nil, table: "Localizable") == "未选择"
        )
        #expect(
            zhHansBundle.localizedString(forKey: "editor.safe-area.universal.title", value: nil, table: "Localizable")
                == "通用社交安全区"
        )

        #expect(frBundle.localizedString(forKey: "common.retry", value: nil, table: "Localizable") == "Réessayer")
        #expect(
            frBundle.localizedString(forKey: "editor.tool.adjusts.title", value: nil, table: "Localizable")
                == "Réglages"
        )

        #expect(deBundle.localizedString(forKey: "common.close", value: nil, table: "Localizable") == "Schließen")
        #expect(deBundle.localizedString(forKey: "common.save", value: nil, table: "Localizable") == "Speichern")
        #expect(
            deBundle.localizedString(forKey: "editor.tool.speed.title", value: nil, table: "Localizable")
                == "Geschwindigkeit"
        )
    }

    @Test
    func localizationCatalogContainsTranslatedEntriesForEverySupportedLanguage() throws {
        let expectedLocalizations = ["de", "en", "es", "fr", "ja", "pt-BR", "zh-Hans"]
        let strings = try localizationCatalogStrings()
        var missingEntries: [String] = []
        var pendingEntries: [String] = []

        for (key, entry) in strings {
            guard let localizations = entry["localizations"] as? [String: Any] else {
                missingEntries.append("\(key):<all>")
                continue
            }

            for localization in expectedLocalizations {
                guard let localizedEntry = localizations[localization] as? [String: Any] else {
                    missingEntries.append("\(key):\(localization)")
                    continue
                }

                let stringUnit = localizedEntry["stringUnit"] as? [String: Any]
                let state = stringUnit?["state"] as? String

                if state != "translated" {
                    pendingEntries.append("\(key):\(localization):\(state ?? "missing-state")")
                }
            }
        }

        #expect(missingEntries.isEmpty)
        #expect(pendingEntries.isEmpty)
    }

    // MARK: - Private Methods

    private func moduleResourceBundle() throws -> Bundle {
        let bundle = VideoEditorKitModuleBundle.resourceBundle

        return try #require(bundle)
    }

    private func localizedBundle(
        for localization: String,
        in bundle: Bundle
    ) throws -> Bundle {
        let path = try #require(bundle.path(forResource: localization, ofType: "lproj"))
        let localizedBundle = Bundle(path: path)

        return try #require(localizedBundle)
    }

    private func localizationCatalogStrings() throws -> [String: [String: Any]] {
        let catalogURL = try repositoryRootURL()
            .appending(path: "Sources/VideoEditorKit/Resources/Localizable.xcstrings")
        let data = try Data(contentsOf: catalogURL)
        let jsonObject = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let strings = try #require(jsonObject["strings"] as? [String: [String: Any]])

        return strings
    }

    private func repositoryRootURL() throws -> URL {
        var candidateURL = URL(filePath: #filePath)
            .deletingLastPathComponent()

        while candidateURL.path(percentEncoded: false) != "/" {
            let packageURL = candidateURL.appending(path: "Package.swift")

            if FileManager.default.fileExists(atPath: packageURL.path(percentEncoded: false)) {
                return candidateURL
            }

            candidateURL.deleteLastPathComponent()
        }

        throw NSError(domain: "PackageLocalizationTests", code: 1)
    }

}
