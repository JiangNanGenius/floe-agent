// Floe Mac M00 — independent kernel-confinement probe.
//
// SPDX-License-Identifier: MPL-2.0
//
// This binary is copied into the task-owned fixture root and launched by
// /usr/bin/sandbox-exec with the exact profile the helper wrote. It observes
// raw checks from a fork/exec child. Network, path-write, Mach and Keychain
// probes below are disabled and explicitly return unverified. This is not an
// isolation acceptance tool until the missing boundaries are implemented.
//
// No released port or caller-supplied Unix socket is bound, connected or
// unlinked. Safe owned sentinels and inherited-descriptor tests remain work.
//
// Modes:
//   sandbox        run the negative checks under the profile (default)
//   control        run the matching positive checks without a profile, so a
//                  denial result is not confused with an absent service
//   child          fork/exec child checks under the profile
//   child-control  fork/exec child checks without a profile
//
// A Keychain OSStatus alone is never evidence of Seatbelt denial. Mach and
// Keychain checks remain unverified; this tool does not query those services.
//
// Usage:
//   fixture_sandbox_probe <root> <victim> <home> <bridge> <keychain>
//     <controlSocket> <allowedHTTPPort> <sentinelPort> <deniedBindPort>
//     [sandbox|control|child|child-control]

#include <arpa/inet.h>
#include <bootstrap.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <mach/mach.h>
#include <netinet/in.h>
#include <poll.h>
#include <signal.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>
#include <Security/Security.h>

static int failures = 0;

enum probe_mode {
    MODE_SANDBOX,
    MODE_CONTROL,
    MODE_CHILD_SANDBOX,
    MODE_CHILD_CONTROL
};

static void report(const char *name, bool passed, const char *detail) {
    if (!passed) failures++;
    printf("RESULT|%s|%s|%s\n", name, passed ? "true" : "false", detail);
}

static bool denied_errno(int error) {
    return error == EPERM || error == EACCES;
}

static void check_dir_denied(const char *name, const char *path) {
    struct stat value;
    if (lstat(path, &value) != 0) {
        if (errno == ENOENT) {
            report(name, false, "path absent; sandbox denial unverified");
        } else {
            char detail[128];
            snprintf(detail, sizeof detail, "lstat errno %d", errno);
            report(name, denied_errno(errno), detail);
        }
        return;
    }
    int fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW);
    if (fd >= 0) {
        close(fd);
        report(name, false, "directory open unexpectedly succeeded");
        return;
    }
    char detail[128];
    snprintf(detail, sizeof detail, "open errno %d", errno);
    report(name, denied_errno(errno), detail);
}

// Disabled until every probe endpoint has a live task-owned positive control,
// paths are anchored and inherited descriptors/IPC have been audited. Never
// connect to historical ports, bind a released reservation, unlink a socket,
// write a caller-supplied victim path or access the real Keychain here.
static void check_write(const char *name, const char *directory, bool should_succeed) {
    (void)directory; (void)should_succeed;
    report(name, false, "unverified: anchored fixture-owned path required");
}

static void check_connect(const char *name, const char *host, unsigned short port,
                          bool should_be_denied) {
    (void)host; (void)port; (void)should_be_denied;
    report(name, false, "unverified: live owned endpoint and inherited descriptors required");
}

static void check_tcp_listener(const char *name, unsigned short port, bool should_succeed) {
    (void)port; (void)should_succeed;
    report(name, false, "unverified: released port cannot establish listener ownership");
}

static void check_unix_listener(const char *name, const char *path, bool should_succeed) {
    (void)path; (void)should_succeed;
    report(name, false, "unverified: owned Unix socket sentinel required");
}

static void check_keychain(void) {
    // No OSStatus alone proves Seatbelt denial. Do not perform an actual query.
    report("keychain_query_denied", false, "unverified: Keychain status does not prove sandbox denial");
}

static void check_mach_lookup(const char *name, const char *service, bool should_be_denied) {
    (void)service; (void)should_be_denied;
    report(name, false, "unverified: complete Mach and inherited-rights boundary not established");
}

static void check_symlink_escape(const char *root, const char *victim) {
    (void)root; (void)victim;
    report("symlink_escape_denied", false, "unverified: fixture child identities are not anchored");
}

static void child_checks(const char *home, const char *root, const char *control,
                         unsigned short allowedPort, unsigned short sentinelPort,
                         bool expectDenied) {
    (void)home; (void)root; (void)control; (void)allowedPort; (void)sentinelPort;
    report(expectDenied ? "child_inherits_sandbox" : "child_control_reachable", false,
           "unverified: inherited descriptors, Mach rights and owned endpoints require independent checks");
    fflush(stdout);
    _exit(1);
}

// Never wait indefinitely for a probe descendant. A timed-out child remains a
// failure even if the owned cleanup signal causes it to exit afterwards.
static void wait_child_bounded(pid_t child) {
    int status = 0;
    struct timespec interval = { .tv_sec = 0, .tv_nsec = 100000000 };
    for (int attempt = 0; attempt < 50; ++attempt) {
        pid_t result = waitpid(child, &status, WNOHANG);
        if (result == child) {
            report("child_process_exit", WIFEXITED(status) && WEXITSTATUS(status) == 0,
                   WIFEXITED(status) ? "child exit checked" : "child did not exit normally");
            return;
        }
        if (result < 0 && errno != EINTR) {
            report("child_process_exit", false, "waitpid failed; child outcome unknown");
            return;
        }
        nanosleep(&interval, NULL);
    }
    report("child_process_exit", false, "child timed out; owned cleanup requested");
    if (kill(child, SIGKILL) != 0 && errno != ESRCH) return;
    for (int attempt = 0; attempt < 10; ++attempt) {
        pid_t result = waitpid(child, &status, WNOHANG);
        if (result == child || (result < 0 && errno == ECHILD)) return;
        if (result < 0 && errno != EINTR) return;
        nanosleep(&interval, NULL);
    }
}

int main(int argc, char **argv) {
    if (argc < 10) {
        fprintf(stderr,
                "usage: %s <root> <victim> <home> <bridge> <keychain> <controlSocket>"
                " <allowedHTTPPort> <sentinelPort> <deniedBindPort>"
                " [sandbox|control|child|child-control]\n",
                argv[0]);
        return 2;
    }
    const char *root = argv[1];
    const char *victim = argv[2];
    const char *home = argv[3];
    const char *bridge = argv[4];
    const char *keychain = argv[5];
    const char *controlSocket = argv[6];
    unsigned short allowedPort = (unsigned short)strtoul(argv[7], NULL, 10);
    unsigned short sentinelPort = (unsigned short)strtoul(argv[8], NULL, 10);
    unsigned short deniedBindPort = (unsigned short)strtoul(argv[9], NULL, 10);
    const char *modeName = argc > 10 ? argv[10] : "sandbox";
    enum probe_mode mode = MODE_SANDBOX;
    if (strcmp(modeName, "control") == 0) mode = MODE_CONTROL;
    else if (strcmp(modeName, "child") == 0) mode = MODE_CHILD_SANDBOX;
    else if (strcmp(modeName, "child-control") == 0) mode = MODE_CHILD_CONTROL;
    else if (strcmp(modeName, "sandbox") != 0) {
        fprintf(stderr, "unknown mode: %s\n", modeName);
        return 2;
    }

    if (mode == MODE_CHILD_SANDBOX) {
        child_checks(home, root, controlSocket, allowedPort, sentinelPort, true);
    }
    if (mode == MODE_CHILD_CONTROL) {
        child_checks(home, root, controlSocket, allowedPort, sentinelPort, false);
    }

    char otherUnix[PATH_MAX];
    snprintf(otherUnix, sizeof otherUnix, "%s/tmp/.not-the-control-socket", root);

    if (mode == MODE_CONTROL) {
        check_connect("sentinel_loopback_control_reachable", "127.0.0.1", sentinelPort, false);
        check_tcp_listener("reserved_tcp_bind_control", allowedPort, true);
        check_tcp_listener("other_tcp_bind_control", deniedBindPort, true);
        check_unix_listener("control_unix_bind_control", controlSocket, true);
        check_unix_listener("other_unix_bind_control", otherUnix, true);
        check_mach_lookup("securityd_mach_lookup_control", "com.apple.securityd", false);
        check_mach_lookup("trustd_mach_lookup_control", "com.apple.trustd", false);
        check_mach_lookup("pasteboard_mach_lookup_control", "com.apple.pasteboard.1", false);
        check_mach_lookup("tccd_mach_lookup_control", "com.apple.tccd", false);
    } else {
        check_dir_denied("home_directory_denied", home);
        check_dir_denied("real_bridge_data_denied", bridge);
        check_dir_denied("keychain_directory_denied", keychain);
        check_dir_denied("victim_root_denied", victim);
        check_write("fixture_root_write", root, true);
        check_write("victim_root_write_denied", victim, false);
        check_connect("external_network_denied", "1.1.1.1", 80, true);
        check_connect("real_bridge_port_denied", "127.0.0.1", 43871, true);
        check_connect("sentinel_loopback_denied", "127.0.0.1", sentinelPort, true);
        check_connect("fixture_own_endpoint_outbound_denied", "127.0.0.1", allowedPort, true);
        check_tcp_listener("reserved_tcp_bind", allowedPort, true);
        check_tcp_listener("other_tcp_bind_denied", deniedBindPort, false);
        check_unix_listener("control_unix_bind", controlSocket, true);
        check_unix_listener("other_unix_bind_denied", otherUnix, false);
        check_symlink_escape(root, victim);
        check_keychain();
        check_mach_lookup("securityd_mach_lookup_denied", "com.apple.securityd", true);
        check_mach_lookup("trustd_mach_lookup_denied", "com.apple.trustd", true);
        check_mach_lookup("pasteboard_mach_lookup_denied", "com.apple.pasteboard.1", true);
        check_mach_lookup("tccd_mach_lookup_denied", "com.apple.tccd", true);
    }

    if (mode == MODE_SANDBOX) {
        pid_t child = fork();
        if (child == 0) {
            char *args[] = {
                argv[0], argv[1], argv[2], argv[3], argv[4], argv[5], argv[6],
                argv[7], argv[8], argv[9], "child", NULL
            };
            execv(argv[0], args);
            fflush(stdout);
            _exit(127);
        }
        if (child > 0) {
            wait_child_bounded(child);
        } else {
            report("child_process_exit", false, "fork failed");
        }
    }

    printf("SUMMARY|%d\n", failures);
    return failures == 0 ? 0 : 1;
}
