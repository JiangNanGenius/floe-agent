// FloePersistence — Schema v48: converge canonical task policies for
// conversations whose canonical workspace ownership exists WITHOUT a
// task_policies row. Ownership writers that pre-date a launch (terminal-first
// ensureWorkspace, keep promotion, workspace move) bind ownership only; the
// launch-time establish path then took the existing-ownership reuse branch and
// never materialized the policy row. Without the row, WorkspaceStore.taskPolicy
// synthesizes a default with a fresh Date() on EVERY read, so the
// run.policy.update CAS identity (taskPolicyVersion(updatedAt:)) changes per
// read and every typed permission update is deterministically refused
// (staleRevision/revisionMismatch behind the generic ordinaryRuntimeBlocked
// outer code). Evidence: device probe 2026-10-29 — zero task_policies rows
// against five real runs and pre-first-run ownership.
//
// This migration repairs ONLY the missing-row case: INSERT-if-absent for
// ordinary conversations that own a canonical workspace. Every existing
// policy row (approval mode, allowedToolNames, ceilings, file grants,
// timestamps) is preserved byte-for-byte by the NOT EXISTS guard. Unowned,
// notes-purpose and temporary conversations stay unpersisted — the
// fail-closed synthesis semantics of the read path are unchanged.
import GRDB

enum V48TaskPolicyConvergence {
    static func register(into migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v48_task_policy_convergence") { db in
            try db.execute(sql: """
                INSERT INTO task_policies (
                    conversation_id, approval_mode, recovery_policy,
                    notification_policy, updated_at
                )
                SELECT o.conversation_id, 'ask', 'safePoint', 'stages',
                       strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
                FROM conversation_workspace_ownership o
                JOIN conversations c ON c.id = o.conversation_id
                WHERE c.purpose = 'ordinary'
                  AND NOT EXISTS (
                      SELECT 1 FROM task_policies p
                      WHERE p.conversation_id = o.conversation_id
                  );
                PRAGMA user_version = 48;
                """)
        }
    }
}
