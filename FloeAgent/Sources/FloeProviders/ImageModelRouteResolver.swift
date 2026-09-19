import Foundation
import FloeCore

/// Resolves a public image-model selection name (the provider's remote model
/// ID or its display name, as printed by `image.models`) to one configured
/// `ModelProfile`. This mirrors `VideoModelRegistry.resolve` so that
/// `image.generate` accepts a public candidate exactly like `video.generate`:
/// the user is never required to know the per-install internal UUID, and an
/// ambiguous or unknown selection fails with the public candidate list instead
/// of silently choosing a different, possibly paid, route.
public enum ImageModelRouteResolver {
    /// Match rules, in priority order: exact remote model ID or display name
    /// (case-insensitive), normalized equality, unique prefix, then unique
    /// containment. The first tier with exactly one match wins; a tier with
    /// more than one match is an ambiguity error.
    public static func resolve(
        selection: String,
        models: [ModelProfile]
    ) throws -> ModelProfile {
        guard !models.isEmpty else {
            throw FloeError.invalidConfiguration(
                "No configured, enabled image model is available. Configure an image provider with an image model and API key, then inspect image.models."
            )
        }
        let trimmed = selection.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw FloeError.validationFailed(
                "Image model selection is empty. Available public candidates: \(publicCandidates(models))."
            )
        }
        // A user or model may still pass the internal UUID spelling.
        if let asUUID = UUID(uuidString: trimmed),
           let match = models.first(where: { $0.id == asUUID }) {
            return match
        }
        let needle = normalizedIdentifier(trimmed)
        guard !needle.isEmpty else {
            throw FloeError.validationFailed(
                "Image model selection is empty. Available public candidates: \(publicCandidates(models))."
            )
        }
        let tiers: [() -> [ModelProfile]] = [
            { models.filter { model in
                model.remoteModelID.caseInsensitiveCompare(trimmed) == .orderedSame
                    || model.displayName.caseInsensitiveCompare(trimmed) == .orderedSame
            } },
            { models.filter { model in
                normalizedIdentifier(model.remoteModelID) == needle
                    || normalizedIdentifier(model.displayName) == needle
            } },
            { models.filter { model in
                normalizedIdentifier(model.remoteModelID).hasPrefix(needle)
                    || normalizedIdentifier(model.displayName).hasPrefix(needle)
            } },
            { models.filter { model in
                normalizedIdentifier(model.remoteModelID).contains(needle)
                    || normalizedIdentifier(model.displayName).contains(needle)
            } }
        ]
        for tier in tiers {
            let matches = tier()
            if matches.count == 1 { return matches[0] }
            if matches.count > 1 {
                throw FloeError.validationFailed(
                    "Image model selection \"\(trimmed)\" matches several candidates. Choose one public candidate: \(publicCandidates(matches))."
                )
            }
        }
        throw FloeError.validationFailed(
            "Unknown image model \"\(trimmed)\". Available public candidates: \(publicCandidates(models))."
        )
    }

    /// Public, secret-free candidate list. Internal UUIDs are intentionally
    /// omitted so agents and users only need the public name.
    public static func publicCandidates(_ models: [ModelProfile]) -> String {
        models.map { model in
            model.displayName.caseInsensitiveCompare(model.remoteModelID) == .orderedSame
                ? model.remoteModelID
                : "\(model.displayName) (\(model.remoteModelID))"
        }.joined(separator: ", ")
    }

    /// Case- and separator-insensitive spelling of one identifier, shared with
    /// the video resolver so both surfaces treat provider catalogues the same.
    static func normalizedIdentifier(_ value: String) -> String {
        value.lowercased().filter { $0.isLetter || $0.isNumber }
    }
}
