// SPDX-License-Identifier: MPL-2.0
//
// G02 production composition — owned store cluster DTO + trusted access
// contract.
//
// Authority (job-7cd349b4cd6d4b55 spec): "If RB1 exposes only stores, propose
// and implement ONLY the narrow in-module trusted root/epoch checked
// database/store access hook plus before/after delta; never open a second
// DatabaseManager by the same URL, use host directories from models, access
// first project/temp fallback, write through shared symlinks, or expose
// native root/owner tokens to public wire."
//
// RB1's `AndroidRuntimeStoreOwner` keeps `identity`, `lifecycleToken` and
// `database` file-private, and every store reference `private(set)`. The ONE
// narrow additive hook is therefore delivered INSIDE the owner actor as the
// reviewed delta patch
// `app-deltas/RuntimeFacadeStores.g02-owned-cluster-hook.patch`:
//
//     func g02OwnedCluster(expected identity: RuntimeOwnerIdentity)
//         -> G02OwnedStoreCluster?
//
// It re-validates, on the owner actor, the EXACT accepted identity
// (normalized root path + full token + epoch — RB1-M1 equality), the current
// lifecycle token, and `phase == .ready` before returning the immutable
// cluster. Any drift returns nil: fail-closed, never a second DB.
//
// This file declares the cluster value the hook returns. Every G02 domain
// service receives stores from ONE cluster, so the whole service graph
// shares exactly one original `DatabaseManager`.
//
// This source is authored for the serialized Main qualification lane: it is
// NOT compiled/executed by the authoring package (grammar-only evidence).
import Foundation
import FloePersistence
import FloeAgentRuntime

/// Immutable snapshot of the ONE original store cluster owned by the live
/// generation. Retained by the G02 composition for the generation lifetime.
public struct G02OwnedStoreCluster: Sendable {
    /// The exact accepted identity (full root path + token live only inside
    /// the process; the public wire/UI ever sees the short fingerprint).
    public let identity: RuntimeOwnerIdentity
    public let database: DatabaseManager
    public let conversationStore: SQLiteConversationStore
    public let runStore: SQLiteRunStore
    public let runningInputStore: SQLiteRunningInputStore
    public let childRunStore: SQLiteChildRunStore
    public let runLaunchStore: SQLiteRunLaunchStore
    public let modelConfigurationStore: ModelConfigurationStore
    public let workspaceStore: SQLiteWorkspaceStore
    public let settingsStore: SQLiteSettingsStore
    public let skillStore: SQLiteSkillStore
    public let checkpointStore: FileCheckpointStore

    public init(identity: RuntimeOwnerIdentity, database: DatabaseManager,
                conversationStore: SQLiteConversationStore,
                runStore: SQLiteRunStore,
                runningInputStore: SQLiteRunningInputStore,
                childRunStore: SQLiteChildRunStore,
                runLaunchStore: SQLiteRunLaunchStore,
                modelConfigurationStore: ModelConfigurationStore,
                workspaceStore: SQLiteWorkspaceStore,
                settingsStore: SQLiteSettingsStore,
                skillStore: SQLiteSkillStore,
                checkpointStore: FileCheckpointStore) {
        self.identity = identity
        self.database = database
        self.conversationStore = conversationStore
        self.runStore = runStore
        self.runningInputStore = runningInputStore
        self.childRunStore = childRunStore
        self.runLaunchStore = runLaunchStore
        self.modelConfigurationStore = modelConfigurationStore
        self.workspaceStore = workspaceStore
        self.settingsStore = settingsStore
        self.skillStore = skillStore
        self.checkpointStore = checkpointStore
    }
}
