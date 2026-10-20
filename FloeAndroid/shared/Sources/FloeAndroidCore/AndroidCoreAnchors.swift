// SPDX-License-Identifier: MPL-2.0
import Foundation
import Crypto
import GRDB
import ZIPFoundation
import FloeCore
import FloeModels
import FloeProviders
import FloeSecurity
import FloeTools
import FloeSkills
import FloePersistence
import FloeAgentRuntime

/// Real (not shallow) dependency anchors for libFloeAndroidCore.so.
///
/// These names reference the ACTUAL current single-authority iOS types so
/// the linker carries their real graph into the product library — the same
/// anchors the grdb probe proved (ConversationRunService, HarnessEvent,
/// HarnessEventChannel, DatabaseManager) extended with the value-layer
/// anchors from the bizcore probe. Anchors are type/constant references only:
/// no service instantiation, no network, no Keystore and no device behavior
/// is claimed here. Instantiation and live flows arrive with packages P2/P3.
public enum FloeAndroidCore {
    /// Persistence authority: DatabaseManager + the 46-migration chain.
    public static let schemaVersion: Int = DatabaseManager.currentSchemaVersion
    public static func openInMemoryStore() throws -> DatabaseManager {
        try DatabaseManager.inMemory()
    }
    public static let migratorType: DatabaseMigrator.Type = DatabaseMigrator.self
    public static let conversationStoreType: SQLiteConversationStore.Type =
        SQLiteConversationStore.self
    public static let runStoreType: SQLiteRunStore.Type = SQLiteRunStore.self
    public static let modelConfigurationStoreType: ModelConfigurationStore.Type =
        ModelConfigurationStore.self
    public static let childRunStoreType: SQLiteChildRunStore.Type = SQLiteChildRunStore.self

    // Current runtime authority (the same actor/loop iOS runs today).
    public static let runServiceType: ConversationRunService.Type = ConversationRunService.self
    public static let harnessEventType: HarnessEvent.Type = HarnessEvent.self
    public static let harnessEventChannelType: HarnessEventChannel.Type =
        HarnessEventChannel.self
    // The dispatch actor is `FloeAgentRuntime` (AgentRuntime.swift:345).
    public static let agentRuntimeType: FloeAgentRuntime.Type = FloeAgentRuntime.self
    public static let subagentRegistryType: SubagentRunnerRegistry.Type =
        SubagentRunnerRegistry.self

    // Authority/security policy layer (host-authored grants only).
    public static let approvalGrantStoreType: ApprovalGrantStore.Type =
        ApprovalGrantStore.self
    public static let secretIngressScannerType: SecretIngressScanner.Type =
        SecretIngressScanner.self
    public static let ordinaryDocumentProfileType: OrdinaryDocumentActionProfile.Type =
        OrdinaryDocumentActionProfile.self

    // Temporary-session layer implements the SAME protocols — no second truth.
    public static let ephemeralConversationStoreType: EphemeralConversationStore.Type =
        EphemeralConversationStore.self
    public static let ephemeralRunStoreType: EphemeralRunStore.Type = EphemeralRunStore.self
    public static let conversationPromoterType: ConversationPromoter.Type =
        ConversationPromoter.self
    public static let temporaryChatToolPolicyType: TemporaryChatToolPolicy.Type =
        TemporaryChatToolPolicy.self

    // Provider transport/parser surface (shared SSE parser is the future
    // streaming authority; Android incremental adapter is package P3).
    public static let sseParserType: SSEParser.Type = SSEParser.self
    public static let providerAdapterFactoryType: ProviderAdapterFactory.Type =
        ProviderAdapterFactory.self

    // Value/skills layer.
    public static let draftTaskPolicyType: DraftTaskPolicy.Type = DraftTaskPolicy.self
    public static let officialSkillHubType: OfficialSkillHub.Type = OfficialSkillHub.self
    public static let contentCodecType: ContentPackageCodec.Type = ContentPackageCodec.self
    public static let signedContentArchiveType: SignedContentArchive.Type =
        SignedContentArchive.self
    public static let archiveType: Archive.Type = Archive.self
    public static let sha256Type: SHA256.Type = SHA256.self
}
