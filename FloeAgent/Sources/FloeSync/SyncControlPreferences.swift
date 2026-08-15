import Foundation

/// Device-local switches controlling whether Floe participates in iCloud
/// synchronization. These switches are intentionally not synchronized: a
/// device that opts out must not be re-enabled by another device.
public struct SyncControlPreferences: Sendable, Equatable {
    public static let overallKey = "org.floeagent.sync.overall-enabled"
    public static let configurationKey = "org.floeagent.sync.configuration-enabled"

    public var overallEnabled: Bool
    public var configurationEnabled: Bool

    public init(overallEnabled: Bool = true, configurationEnabled: Bool = true) {
        self.overallEnabled = overallEnabled
        self.configurationEnabled = configurationEnabled
    }

    public static func load(from defaults: UserDefaults = .standard) -> Self {
        Self(
            overallEnabled: defaults.object(forKey: overallKey) == nil
                ? true : defaults.bool(forKey: overallKey),
            configurationEnabled: defaults.object(forKey: configurationKey) == nil
                ? true : defaults.bool(forKey: configurationKey)
        )
    }

    public func save(to defaults: UserDefaults = .standard) {
        defaults.set(overallEnabled, forKey: Self.overallKey)
        defaults.set(configurationEnabled, forKey: Self.configurationKey)
    }
}
