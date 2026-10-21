// SPDX-License-Identifier: MPL-2.0
//
// floe-probe: synthetic self-test child for the Floe Android Linux runtime
// qualification host. Pure bionic, statically linked, no network, no model,
// no credentials. It only reports what the kernel/SELinux actually allow.
//
// Modes:
//   identity  - JSON identity block (uid/pid/ppid/exe/argv/uname/page size/
//               selinux context/tty), then exit 0.
//   seccomp   - prctl(PR_GET_SECCOMP), prctl(PR_GET_NO_NEW_PRIVS), then ONE
//               landlock_create_ruleset(NULL,0,LANDLOCK_CREATE_RULESET_VERSION)
//               syscall. That syscall runs only inside this owned short-lived
//               child: if the platform answers SIGSYS this child dies with
//               SIGSYS and the host reports the waitpid signal — never the
//               Activity/JNI process.
//   echo      - copy stdin to stdout; SIGINT handler prints SIGINT; SIGWINCH
//               prints WINSZ; EOF prints EOF and exits 0.
//   sleep N   - sleep N seconds, exit 0.
//   flood N   - write N deterministic bytes to stdout, exit 0.

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/prctl.h>
#include <sys/ioctl.h>
#include <sys/syscall.h>
#include <sys/utsname.h>
#include <sys/wait.h>
#include <termios.h>
#include <unistd.h>

#ifndef TIOCGWINSZ
#define TIOCGWINSZ 0x5413
#endif

#ifndef __NR_landlock_create_ruleset
#define __NR_landlock_create_ruleset 444
#endif
#ifndef LANDLOCK_CREATE_RULESET_VERSION
#define LANDLOCK_CREATE_RULESET_VERSION (1U << 4)
#endif
#ifndef PR_GET_SECCOMP
#define PR_GET_SECCOMP 21
#endif
#ifndef PR_GET_NO_NEW_PRIVS
#define PR_GET_NO_NEW_PRIVS 38
#endif

static void print_file(const char *label, const char *path) {
    int fd = open(path, O_RDONLY);
    if (fd < 0) {
        printf("\"%s\":\"<open-errno:%d>\",\n", label, errno);
        return;
    }
    char buf[512];
    ssize_t n = read(fd, buf, sizeof(buf) - 1);
    close(fd);
    if (n < 0) {
        printf("\"%s\":\"<read-errno:%d>\",\n", label, errno);
        return;
    }
    buf[n] = 0;
    for (ssize_t i = 0; i < n; i++) {
        if (buf[i] == '\n' || buf[i] == '"') buf[i] = ' ';
    }
    // trim trailing spaces
    while (n > 0 && buf[n - 1] == ' ') buf[--n] = 0;
    printf("\"%s\":\"%s\",\n", label, buf);
}

static void identity_mode(int argc, char **argv) {
    struct utsname uts;
    memset(&uts, 0, sizeof(uts));
    uname(&uts);

    char exe[512];
    ssize_t exen = readlink("/proc/self/exe", exe, sizeof(exe) - 1);
    if (exen < 0) exen = 0;
    exe[exen] = 0;

    char tty[128] = "";
    if (isatty(0)) {
        snprintf(tty, sizeof(tty), "%s", ttyname(0) ? ttyname(0) : "?");
    }

    struct winsize ws;
    memset(&ws, 0, sizeof(ws));
    if (ioctl(0, TIOCGWINSZ, &ws) != 0) {
        ws.ws_row = 0; ws.ws_col = 0;
    }

    long page = sysconf(_SC_PAGESIZE);

    printf("{");
    printf("\"mode\":\"identity\",");
    printf("\"uid\":%d,\"gid\":%d,\"pid\":%d,\"ppid\":%d,", getuid(), getgid(), getpid(), getppid());
    printf("\"exe\":\"%s\",", exe);
    printf("\"argv\":[");
    for (int i = 0; i < argc; i++) {
        printf("%s\"%s\"", i ? "," : "", argv[i]);
    }
    printf("],");
    printf("\"uname\":{\"sys\":\"%s\",\"release\":\"%s\",\"machine\":\"%s\"},", uts.sysname, uts.release, uts.machine);
    printf("\"pageSize\":%ld,", page);
    printf("\"tty\":\"%s\",\"winsz\":{\"rows\":%d,\"cols\":%d},", tty, ws.ws_row, ws.ws_col);

    struct termios tio;
    if (tcgetattr(0, &tio) == 0) {
        printf("\"termios\":{\"isig\":%d,\"icanon\":%d,\"echo\":%d},",
               !!(tio.c_lflag & ISIG), !!(tio.c_lflag & ICANON), !!(tio.c_lflag & ECHO));
    } else {
        printf("\"termios\":\"<errno:%d>\",", errno);
    }

    print_file("seContext", "/proc/self/attr/current");
    print_file("cmdline0", "/proc/self/cmdline");
    printf("\"backend\":\"floe-probe-static-bionic\"}\n");
    fflush(stdout);
}

static void seccomp_mode(void) {
    int seccomp_mode = (int)prctl(PR_GET_SECCOMP, 0, 0, 0, 0);
    int nnp = (int)prctl(PR_GET_NO_NEW_PRIVS, 0, 0, 0, 0);
    printf("{\"mode\":\"seccomp\",\"prGetSeccomp\":%d,\"prGetNoNewPrivs\":%d}\n", seccomp_mode, nnp);
    fflush(stdout);
    printf("{\"mode\":\"seccomp\",\"landlock\":\"invoking\"}\n");
    fflush(stdout);
    errno = 0;
    long abi = (long)syscall(__NR_landlock_create_ruleset, NULL, 0, LANDLOCK_CREATE_RULESET_VERSION);
    int e = errno;
    printf("{\"mode\":\"seccomp\",\"landlockAbi\":%ld,\"errno\":%d}\n", abi, abi < 0 ? e : 0);
    fflush(stdout);
}

static volatile sig_atomic_t got_sigint = 0;
static volatile sig_atomic_t got_winch = 0;

static void on_sigint(int sig) { (void)sig; got_sigint = 1; }
static void on_winch(int sig) { (void)sig; got_winch = 1; }

static void echo_mode(void) {
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = on_sigint;
    sigaction(SIGINT, &sa, NULL);
    sa.sa_handler = on_winch;
    sigaction(SIGWINCH, &sa, NULL);

    char buf[4096];
    for (;;) {
        if (got_sigint) {
            got_sigint = 0;
            printf("PROBE-SIGINT\n");
            fflush(stdout);
        }
        if (got_winch) {
            got_winch = 0;
            struct winsize ws;
            memset(&ws, 0, sizeof(ws));
            if (ioctl(0, TIOCGWINSZ, &ws) == 0) {
                printf("PROBE-WINSZ %d %d\n", ws.ws_col, ws.ws_row);
                fflush(stdout);
            }
        }
        ssize_t n = read(0, buf, sizeof(buf));
        if (n < 0) {
            if (errno == EINTR) continue;
            printf("PROBE-READ-ERR %d\n", errno);
            fflush(stdout);
            return;
        }
        if (n == 0) {
            printf("PROBE-EOF\n");
            fflush(stdout);
            return;
        }
        ssize_t off = 0;
        while (off < n) {
            ssize_t w = write(1, buf + off, (size_t)(n - off));
            if (w < 0) {
                if (errno == EINTR) continue;
                return;
            }
            off += w;
        }
    }
}

static void flood_mode(long nbytes) {
    char block[8192];
    for (size_t i = 0; i < sizeof(block); i++) block[i] = (char)('A' + (i % 26));
    long remaining = nbytes;
    while (remaining > 0) {
        ssize_t chunk = remaining > (long)sizeof(block) ? (long)sizeof(block) : remaining;
        ssize_t w = write(1, block, (size_t)chunk);
        if (w < 0) {
            if (errno == EINTR) continue;
            printf("PROBE-FLOOD-ERR %d\n", errno);
            return;
        }
        remaining -= w;
    }
}

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: floe-probe <identity|seccomp|echo|sleep|flood> [args]\n");
        return 2;
    }
    const char *mode = argv[1];
    if (strcmp(mode, "identity") == 0) {
        identity_mode(argc - 1, argv + 1);
        return 0;
    }
    if (strcmp(mode, "seccomp") == 0) {
        seccomp_mode();
        return 0;
    }
    if (strcmp(mode, "echo") == 0) {
        echo_mode();
        return 0;
    }
    if (strcmp(mode, "sleep") == 0 && argc >= 3) {
        sleep((unsigned)atoi(argv[2]));
        return 0;
    }
    if (strcmp(mode, "flood") == 0 && argc >= 3) {
        flood_mode(atol(argv[2]));
        return 0;
    }
    fprintf(stderr, "unknown mode\n");
    return 2;
}
