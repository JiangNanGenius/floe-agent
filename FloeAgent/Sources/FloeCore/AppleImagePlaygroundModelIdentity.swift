// SPDX-License-Identifier: MPL-2.0
import Foundation

/// An image-only system model. Its automatic-routing preference is separate
/// from both Foundation Models and the explicit image.playground capability.
public enum AppleImagePlaygroundModelIdentity {
    public static let profileID = UUID(uuidString: "F10E0000-1A6E-4000-8000-000000000001")!
    public static let remoteModelID = "apple-image-playground"
    public static let automaticDefaultsKey = "floe.appleImagePlayground.automaticRouting"
    public static func automaticRoutingEnabled(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: automaticDefaultsKey) as? Bool ?? true
    }
    public static func matches(_ selection: String) -> Bool {
        let normalized = selection.lowercased().filter { $0.isLetter || $0.isNumber }
        return ["appleimageplayground", "imageplayground", "图乐园"].contains(normalized)
    }
    public static func shouldUse(explicitNative: Bool, explicitOther: Bool, preferredNative: Bool,
        hasCloud: Bool, automaticEnabled: Bool, systemAvailable: Bool) -> Bool {
        if explicitNative { return true }
        if explicitOther { return false }
        guard automaticEnabled, systemAvailable else { return false }
        return preferredNative || !hasCloud
    }
    public static func profile(providerID: UUID, available: Bool, supportsEditing: Bool) -> ModelProfile {
        var capabilities: ModelCapabilities = [.imageGeneration]
        if supportsEditing { capabilities.insert(.imageEditing) }
        return ModelProfile(id: profileID, providerID: providerID, remoteModelID: remoteModelID,
            displayName: "Image Playground", limits: .init(contextTokens: 4096, maxOutputTokens: 1),
            capabilities: capabilities, useSurfaces: [.imageGeneration],
            isEnabled: available && automaticRoutingEnabled(), isHiddenFromPrimaryPicker: true)
    }
}
