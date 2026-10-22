// SPDX-License-Identifier: MPL-2.0
package com.floe.android.linuxruntime.supervision

import com.floe.android.linuxruntime.ExitResult
import com.floe.android.linuxruntime.LaunchSpec
import com.floe.android.linuxruntime.LinuxRuntimeBackend
import com.floe.android.linuxruntime.PtySession
import com.floe.android.linuxruntime.RunOwnership
import com.floe.android.linuxruntime.SpawnError
import com.floe.android.linuxruntime.SpawnOutcome
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/**
 * Hand-written fakes for the supervision fixtures. They model kernel-visible
 * facts (proc entries, signal answers, transport behaviour) so the census,
 * quiescence and PTY lifecycle logic can be checked on the host JVM.
 *
 * Honesty limit: these are logic fixtures only. They prove no device exit, no
 * real PRoot/PTY behaviour and no Android PackageManager result; those remain
 * Main's integrated batch check on the runtime APK.
 */

/** One scripted `/proc` entry. */
class FakeProcEntry(
    val pid: Int,
    var uid: Int,
    var state: Char = 'S',
    var ppid: Int = 1,
    var tgid: Int = pid,
    var startTicks: Long = 1_000L + pid,
    var name: String = "p$pid",
    var statusUnreadable: Boolean = false,
    var birthUnreadable: Boolean = false,
    var pgid: Int = pid,
    var sid: Int = pid,
    var gid: Int = uid,
) {
    fun status(): List<String> = listOf(
        "Name:\t$name",
        "State:\t$state (sleeping)",
        "Tgid:\t$tgid",
        "Pid:\t$pid",
        "PPid:\t$ppid",
        "TracerPid:\t0",
        "Uid:\t$uid\t$uid\t$uid\t$uid",
        "Gid:\t$gid\t$gid\t$gid\t$gid",
    )

    /**
     * `/proc/<pid>/stat`: 19 tokens after the parenthesised comm (state …
     * itrealvalue), then starttime as index 19, i.e. the 22nd overall field.
     */
    fun stat(): String {
        val afterComm = mutableListOf(
            "$state", "$ppid", "$pgid", "$sid",
            "0", "0", "0", "0", "0", "0", "0", "0", "0",
            "0", "0", "0", "0", "1", "0",
        )
        afterComm += "$startTicks"
        afterComm += listOf("0", "0", "0")
        return "$pid ($name) " + afterComm.joinToString(" ")
    }
}

class FakeProcReader : ProcReader {
    val entries = LinkedHashMap<Int, FakeProcEntry>()
    var listFailure: String? = null
    var throwOnList: Exception? = null
    var directoryOwner: (Int) -> Int? = { entries[it]?.uid }
    override fun directoryOwnerUid(pid: Int): Int? = directoryOwner(pid)

    /** Number of sweeps performed; lets a fixture change the world between rounds. */
    var listCount = 0
    var onList: (Int) -> Unit = {}

    fun put(entry: FakeProcEntry): FakeProcEntry {
        entries[entry.pid] = entry
        return entry
    }

    fun remove(pid: Int) {
        entries.remove(pid)
    }

    override fun procPids(): ProcListOutcome {
        throwOnList?.let { throw it }
        listFailure?.let { return ProcListOutcome.Failed(it) }
        listCount++
        onList(listCount)
        return ProcListOutcome.Available(entries.keys.toList())
    }

    override fun statusLines(pid: Int): List<String>? =
        entries[pid]?.takeIf { !it.statusUnreadable }?.status()

    override fun statFields(pid: Int): String? =
        entries[pid]?.takeIf { !it.birthUnreadable }?.stat()
}

class FakeSignals(
    private val reader: FakeProcReader,
    var selfPid: Int = SERVICE_PID,
    var selfUid: Int = RUNTIME_UID,
) : SignalBoundary {
    /** Recorded (pid, signal) pairs, in call order. */
    val kills = mutableListOf<Pair<Int, Int>>()
    val probes = mutableListOf<Int>()
    var probeOverrides: Map<Int, ProbeOutcome> = emptyMap()
    var killResult: (Int) -> Int = { 0 }

    /** Hook fired at the identity re-check, i.e. between census and signal (PID reuse). */
    var beforeUidOf: (Int) -> Unit = {}

    override fun selfPid(): Int = selfPid
    override fun selfUid(): Int = selfUid

    override fun probe(pid: Int): ProbeOutcome {
        probes += pid
        probeOverrides[pid]?.let { return it }
        val entry = reader.entries[pid] ?: return ProbeOutcome.Gone
        return when {
            entry.uid == selfUid -> ProbeOutcome.Alive
            else -> ProbeOutcome.MayNotSignal
        }
    }

    override fun uidOf(pid: Int): Int? {
        beforeUidOf(pid)
        return reader.entries[pid]?.takeIf { !it.statusUnreadable }?.uid
    }

    override fun startTimeOf(pid: Int): Long? =
        reader.entries[pid]?.takeIf { !it.birthUnreadable }?.startTicks

    override fun kill(pid: Int, sig: Int): Int {
        kills += pid to sig
        return killResult(pid)
    }
}

/** Clock that never sleeps; records the sleeps so boundedness is assertable. */
class FakeClock : SupervisorClock {
    var now: Long = 0L
    val sleeps = mutableListOf<Long>()
    override fun nowMs(): Long = now
    override fun sleep(ms: Long) {
        sleeps += ms
        now += ms
    }
}

class FakePackageReader(
    private val packages: Map<String, PackageMetadata> = emptyMap(),
    private val uidOwners: Map<Int, List<String>> = emptyMap(),
    private val throwOn: Set<String> = emptySet(),
) : PackageMetadataReader {
    override fun read(packageName: String): PackageMetadata? {
        if (packageName in throwOn) throw IllegalStateException("pm failure for $packageName")
        return packages[packageName]
    }

    override fun packagesForUid(uid: Int): List<String>? = uidOwners[uid]
}

/** Scripted PTY transport handle. */
class FakePty(
    override val pid: Int,
    override val creationIdentity: String,
    override val executable: String,
    override val argv: List<String>,
    override val ownership: RunOwnership,
) : PtySession {
    sealed class ReadStep {
        data class Data(val bytes: ByteArray) : ReadStep()
        object Eof : ReadStep()
        data class Throw(val error: String) : ReadStep()
        object BlockUntilCancelled : ReadStep()
    }

    val reads = ArrayDeque<ReadStep>()
    val readCapacities = mutableListOf<Int>()
    val writeCalls = mutableListOf<Int>()
    val polls = ArrayDeque<ExitResult?>()
    val writes = ArrayDeque<Int>()
    var cancelResult: ExitResult? = ExitResult(137, signaled = true, termSig = 9)
    var lastWaitErrno = 0
    var cancelCalls = 0
    var closeMasterCalls = 0
    var resizeCalls = 0
    val cancelled = CountDownLatch(1)

    private var repeatPoll: ExitResult? = null

    /** Queue-driven: once the script is exhausted the stream is closed (EOF). */
    override fun read(capacity: Int, timeoutMs: Long): ByteArray? {
        readCapacities += capacity
        val step = if (reads.isNotEmpty()) reads.removeFirst() else ReadStep.Eof
        return when (step) {
            is ReadStep.Data -> step.bytes.copyOf(minOf(capacity, step.bytes.size))
            ReadStep.Eof -> null
            is ReadStep.Throw -> throw IllegalStateException(step.error)
            ReadStep.BlockUntilCancelled -> {
                cancelled.await(2, TimeUnit.SECONDS)
                ByteArray(0)
            }
        }
    }

    override fun write(data: ByteArray, offset: Int, length: Int): Int {
        writeCalls += length
        val scripted = if (writes.isEmpty()) length else writes.removeFirst()
        return if (scripted < 0) scripted else minOf(scripted, length)
    }

    override fun resize(rows: Int, cols: Int): Boolean {
        resizeCalls++
        return true
    }

    override fun pollExit(): ExitResult? =
        if (polls.isNotEmpty()) polls.removeFirst().also { repeatPoll = it } else repeatPoll

    override fun awaitExit(timeoutMs: Long): ExitResult? = cancelResult

    override fun cancel(): ExitResult? {
        cancelCalls++
        cancelled.countDown()
        return cancelResult
    }

    override fun closeMaster() {
        closeMasterCalls++
    }

    override fun lastWaitErrno(): Int = lastWaitErrno
}

/** Scripted launch backend. */
class FakeBackend(
    var spawnBehaviour: () -> SpawnOutcome = { error("no spawn scripted") },
) : LinuxRuntimeBackend {
    val spawned = mutableListOf<FakePty>()
    var spawnCalls = 0

    override val identity: com.floe.android.linuxruntime.BackendIdentity =
        com.floe.android.linuxruntime.BackendIdentity(
            name = "fake", version = "test", abi = "arm64-v8a", pageSizeLink = 4096,
            note = "fixture",
        )

    override fun spawn(spec: LaunchSpec, timeoutMs: Long): SpawnOutcome {
        spawnCalls++
        val outcome = spawnBehaviour()
        val session = (outcome as? SpawnOutcome.Spawned)?.session as? FakePty
        if (session != null) spawned += session
        return outcome
    }

    fun spawnSucceededSession(): FakePty = spawned.last()
}

fun spawnFailure(errno: Int): SpawnOutcome =
    SpawnOutcome.Failed(SpawnError(errno, "fixture-$errno"))

const val CORE_UID = 10123
const val RUNTIME_UID = 10456
const val SERVICE_PID = 4000
const val CORE_PKG = "com.floe.agent.full"
const val RUNTIME_PKG = "com.floe.agent.runtime.full"
const val CORE_SIG = "aa11bb22cc33dd44ee55ff66aa11bb22cc33dd44ee55ff66aa11bb22cc33dd44"
const val RUNTIME_SIG = "11223344556677889900aabbccddeeff11223344556677889900aabbccddeeff"

fun acceptedBoundary(selfPid: Int = SERVICE_PID, runtimeUid: Int = RUNTIME_UID): RuntimeUidBoundary {
    val reader = FakePackageReader(
        packages = mapOf(
            CORE_PKG to PackageMetadata(CORE_PKG, CORE_UID, listOf(CORE_SIG)),
            RUNTIME_PKG to PackageMetadata(RUNTIME_PKG, runtimeUid, listOf(RUNTIME_SIG)),
        ),
        uidOwners = mapOf(CORE_UID to listOf(CORE_PKG), runtimeUid to listOf(RUNTIME_PKG)),
    )
    val check = RuntimeUidBoundary.validate(
        corePackageName = CORE_PKG,
        coreSignatureSha256 = CORE_SIG,
        runtimePackageName = RUNTIME_PKG,
        runtimeSignatureSha256 = RUNTIME_SIG,
        selfUid = runtimeUid,
        selfPid = selfPid,
        reader = reader,
        clock = FakeClock(),
    )
    return (check as BoundaryCheck.Accepted).boundary
}

fun ownership(taskId: String = "task-1") = RunOwnership(
    environmentId = "env-1", taskId = taskId, projectId = "proj-1", writeLayer = "session",
)

fun launchSpec(taskId: String = "task-1") = LaunchSpec(
    executable = "/system/bin/sh",
    argv = listOf("/system/bin/sh", "-p"),
    env = mapOf("PATH" to "/usr/bin"),
    workingDir = null,
    ownership = ownership(taskId),
)

fun fakePty(pid: Int = 5100, ticks: Long = 900_000L, task: String = "task-1"): FakePty = FakePty(
    pid = pid,
    creationIdentity = "$pid:$ticks",
    executable = "/system/bin/sh",
    argv = listOf("/system/bin/sh", "-p"),
    ownership = ownership(task),
)

/** Builds a job the way the supervisor would, for focused lifecycle checks. */
fun jobFor(
    pty: FakePty,
    boundary: RuntimeUidBoundary,
    census: ProcCensus,
    quiescer: RuntimeUidQuiescer,
    lease: LeaseToken = LeaseToken("lease-1", "holder-1"),
    spec: LaunchSpec = launchSpec(),
    policy: PtyJobPolicy = PtyJobPolicy(),
    clock: SupervisorClock = FakeClock(),
    onTerminal: (WorkloadTerminal) -> Unit,
): SupervisedPtyJob = SupervisedPtyJob(
    session = pty,
    boundary = boundary,
    quiescer = quiescer,
    census = census,
    lease = lease,
    ownership = spec.ownership,
    spec = spec,
    policy = policy,
    clock = clock,
    onTerminal = onTerminal,
)

fun quiescerFor(
    boundary: RuntimeUidBoundary,
    reader: FakeProcReader,
    signals: FakeSignals,
    clock: FakeClock,
    policy: QuiescePolicy = QuiescePolicy(),
): Pair<ProcCensus, RuntimeUidQuiescer> {
    val census = ProcCensus(boundary, reader, signals)
    return census to RuntimeUidQuiescer(boundary, census, signals, clock, policy)
}
