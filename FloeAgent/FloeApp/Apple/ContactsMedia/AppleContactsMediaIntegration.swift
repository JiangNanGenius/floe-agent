// FloeApp — Contacts and local-media registration.
//
// SPDX-License-Identifier: MPL-2.0
//
// PRIMARY INTEGRATION (one call from AppEnvironment.bootstrap, immediately
// after registerAppleSystemTools):
//
//     registerAppleContactsMediaTools(
//         audioBusyReason: { [weak self] in
//             guard let self else { return nil }
//             return await MainActor.run {
//                 if self.voiceInput.state.hasSession { return "recording" }
//                 if self.speechService.isSpeaking { return "speech" }
//                 if self.pipAudioService.holdsSharedAudioSession
//                     || self.pipAudioService.state != .stopped {
//                     return "taskAudio"
//                 }
//                 if self.backgroundVideoService.audioSessionActivationOwned
//                     || self.backgroundVideoService.isPiPActive {
//                     return "video"
//                 }
//                 return nil
//             }
//         }
//     )
//
// The capability settings gate remains AppleCapabilityPreferences; this
// helper only registers the compiled tools. No entitlement is required for
// Contacts or the local media library; the primary adds the two Info.plist
// purpose strings from the handoff.

#if canImport(UIKit) && canImport(Contacts) && canImport(MediaPlayer)
import Foundation
import FloeTools

@MainActor
enum AppleContactsMediaServices {
    static let contacts: any ContactsDirectoryProviding = SystemContactsDirectory()
    static let contactsMonitor = ContactsAuthorizationMonitor()
    static let snapshots = ContactsMediaSnapshotStore.shared
    static let media = SystemMediaPlaybackService(
        library: SystemMediaLibrary(),
        player: ApplicationQueueMediaPlayer(),
        audioCoordination: .shared
    )
}

@MainActor
func registerAppleContactsMediaTools(
    registry: ToolRunnerRegistry = .shared,
    contactsService: (any ContactsDirectoryProviding)? = nil,
    mediaService: SystemMediaPlaybackService? = nil,
    audioBusyReason: @escaping @Sendable () async -> String?,
    isForeground: @escaping @Sendable () async -> Bool = {
        await ContactsMediaForeground.isActive()
    }
) {
    SystemMediaAudioCoordination.shared.update(probe: audioBusyReason)
    let contacts = contactsService ?? AppleContactsMediaServices.contacts
    let media = mediaService ?? AppleContactsMediaServices.media
    let store = AppleContactsMediaServices.snapshots

    ToolCatalog.register(AppleContactsListTool.self)
    var contactsList = AnyAgentTool(AppleContactsListTool(
        service: contacts,
        monitor: AppleContactsMediaServices.contactsMonitor,
        store: store,
        isForeground: isForeground
    ))
    contactsList.isAvailable = { contacts.isAvailable }
    registry.register(contactsList)

    ToolCatalog.register(AppleMediaSearchTool.self)
    registry.register(AppleMediaSearchTool(
        service: media,
        store: store,
        isForeground: isForeground
    ))

    ToolCatalog.register(AppleMediaNowPlayingTool.self)
    registry.register(AppleMediaNowPlayingTool(
        service: media,
        isForeground: isForeground
    ))

    ToolCatalog.register(AppleMediaPlayTool.self)
    registry.register(AppleMediaPlayTool(
        service: media,
        isForeground: isForeground
    ))

    ToolCatalog.register(AppleMediaControlTool.self)
    registry.register(AppleMediaControlTool(
        service: media,
        isForeground: isForeground
    ))
}
#endif
