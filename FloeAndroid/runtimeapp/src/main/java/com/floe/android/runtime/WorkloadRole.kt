// SPDX-License-Identifier: MPL-2.0
package com.floe.android.runtime

/**
 * G07.3A — the closed workload-role vocabulary of the runtime service.
 *
 * The approved default is TWO interactive tabs + ONE execution slot: [AGENT]
 * and [RUN] SHARE one execution slot (`isExecution`), so the engine admits at
 * most 3 workloads overall. Roles come ONLY
 * from the trusted peer-verified host (`shell.start.leaseRole`); a model,
 * command, environment variable or file can never select one. An absent role
 * (legacy callers) is [AGENT], which preserves the historical single-slot
 * behaviour for every path that has not opted into the multi-session surface.
 *
 * The names are the wire values and are echoed in start replies/status so the
 * host can prove what was actually admitted.
 */
internal enum class WorkloadRole(val wireName: String, val maximumConcurrent: Int) {
    /** Human-owned interactive PTY (terminal tabs). Two independent sessions. */
    INTERACTIVE("interactive", 2),

    /** The Agent's one-shot `exec.shell` command. Exactly one. */
    AGENT("agent", 1),

    /** Language run / LSP service session (editor run-draft, language servers). */
    RUN("run", 1);

    /** Agent and run share the ONE execution slot; interactive is separate. */
    val isExecution: Boolean get() = this == AGENT || this == RUN

    companion object {
        fun fromWire(raw: String): WorkloadRole? = when (raw) {
            INTERACTIVE.wireName -> INTERACTIVE
            AGENT.wireName -> AGENT
            RUN.wireName -> RUN
            else -> null
        }
    }
}
