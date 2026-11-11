/* SPDX-License-Identifier: MPL-2.0 */
#define _GNU_SOURCE 1
#define main floe_runner_entry
#include "../runner/floe_exec.c"
#undef main
#include <assert.h>

static void events_write(const char *directory, const char *value) {
    char path[1024];
    snprintf(path, sizeof path, "%s/cgroup.events", directory);
    FILE *stream = fopen(path, "w");
    assert(stream && fputs(value, stream) >= 0 && fclose(stream) == 0);
}

int main(void) {
    char directory[] = "/tmp/floe-service-tree-XXXXXX";
    assert(mkdtemp(directory));
    events_write(directory, "populated 1\nfrozen 0\n");
    assert(spawned_cgroup_empty(directory) == 0);
    assert(spawned_record(91000001, directory) == 0);
    spawned_slot *slot = spawned_find(91000001);
    assert(slot);
    slot->leader_reaped = 1;
    assert(kills_schedule(slot->pid, directory) == 0);
    assert(kills_schedule(slot->pid, directory) == 0);
    int scheduled = 0;
    for (int i = 0; i < MAX_PENDING_KILLS; i++) scheduled += g_kills[i].used;
    assert(scheduled == 1);
    assert(spawned_record(91000001, directory) == -1);
    spawned_collect_finished();
    assert(spawned_contains(91000001));
    events_write(directory, "populated unknown\n");
    assert(spawned_cgroup_empty(directory) == -1);
    spawned_collect_finished();
    assert(spawned_contains(91000001));
    char path[1024];
    snprintf(path, sizeof path, "%s/cgroup.events", directory);
    assert(unlink(path) == 0);
    assert(spawned_cgroup_empty(directory) == -1);
    spawned_collect_finished();
    assert(spawned_contains(91000001));
    assert(symlink("/dev/null", path) == 0);
    assert(spawned_cgroup_empty(directory) == -1);
    assert(unlink(path) == 0);
    events_write(directory, "frozen 0\npopulated 0\n");
    assert(spawned_cgroup_empty(directory) == 1);
    spawned_collect_finished();
    assert(!spawned_contains(91000001));
    for (int i = 0; i < MAX_PENDING_KILLS; i++) assert(!g_kills[i].used);

    /* If positive/negative PID signals are accidentally sent after reaping,
     * this isolated test child dies and the parent reports a real failure. */
    pid_t child = fork();
    assert(child >= 0);
    if (child == 0) {
        assert(setsid() >= 0);
        events_write(directory, "populated 1\n");
        assert(spawned_record(getpid(), directory) == 0);
        spawned_find(getpid())->leader_reaped = 1;
        assert(kills_schedule(getpid(), directory) == 0);
        for (int i = 0; i < MAX_PENDING_KILLS; i++)
            if (g_kills[i].used) g_kills[i].deadline = 0;
        kills_enforce();
        _exit(0);
    }
    int status = 0;
    assert(waitpid(child, &status, 0) == child && WIFEXITED(status) && WEXITSTATUS(status) == 0);

    /* Deterministic control-only regression: no EXEC output or main-loop
     * tail is allowed to reap the already-exited service for ALIVE. */
    pid_t dead = fork();
    assert(dead >= 0);
    if (dead == 0) { assert(setsid() >= 0); _exit(0); }
    siginfo_t observed = {0};
    assert(waitid(P_PID, (id_t)dead, &observed, WEXITED | WNOWAIT) == 0);
    assert(spawned_record(dead, directory) == 0);
    int reply_pipe[2];
    assert(pipe(reply_pipe) == 0);
    int saved_stdout = dup(STDOUT_FILENO);
    assert(saved_stdout >= 0 && dup2(reply_pipe[1], STDOUT_FILENO) >= 0);
    close(reply_pipe[1]);
    char request[128];
    snprintf(request, sizeof request, "ALIVE direct-control %d", (int)dead);
    handle_frame((const unsigned char *)request, strlen(request));
    assert(dup2(saved_stdout, STDOUT_FILENO) >= 0);
    close(saved_stdout);
    char reply[256] = {0};
    assert(read(reply_pipe[0], reply, sizeof reply - 1) > 0);
    close(reply_pipe[0]);
    if (!spawned_find(dead)->leader_reaped) {
        assert(waitpid(dead, &status, 0) == dead);
        assert(unlink(path) == 0 && rmdir(directory) == 0);
        fputs("REPRO_ALIVE_STALE_UNREAPED\n", stderr);
        return 99;
    }
    assert(strstr(reply, "FLOE-END direct-control 0"));
    events_write(directory, "populated 0\n");
    assert(pipe(reply_pipe) == 0);
    saved_stdout = dup(STDOUT_FILENO);
    assert(saved_stdout >= 0 && dup2(reply_pipe[1], STDOUT_FILENO) >= 0);
    close(reply_pipe[1]);
    handle_frame((const unsigned char *)request, strlen(request));
    assert(dup2(saved_stdout, STDOUT_FILENO) >= 0);
    close(saved_stdout);
    memset(reply, 0, sizeof reply);
    assert(read(reply_pipe[0], reply, sizeof reply - 1) > 0);
    close(reply_pipe[0]);
    assert(strstr(reply, "FLOE-END direct-control 3") && !spawned_contains(dead));
    assert(unlink(path) == 0 && rmdir(directory) == 0);
    assert(spawned_cgroup_empty(directory) == 1);

    g_task_iso_active = 1;
    assert(strcmp(task_iso_service_capability(), "cgroup-v1") == 0);
    g_task_iso_active = 0;
    assert(strcmp(task_iso_service_capability(), "process-group-v1") == 0);
    g_task_iso_active = -1;
    assert(strcmp(task_iso_service_capability(), "unavailable") == 0);
    assert(strcmp(FLOE_RUNNER_VERSION, "2.2.0") == 0);
    puts("service-tree state/unknown/ownership/signal-guard checks passed; native fixture, not Linux cgroup acceptance");
    return 0;
}
