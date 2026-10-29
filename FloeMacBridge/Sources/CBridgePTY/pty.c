#include "CBridgePTY.h"
#include <util.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <stdlib.h>
#include <errno.h>
#include <signal.h>
pid_t floe_spawn_pty(int *master, const char *cwd, char *const argv[], char *const envp[], unsigned short columns, unsigned short rows) {
    struct winsize size = { .ws_row = rows, .ws_col = columns };
    pid_t pid = forkpty(master, NULL, NULL, &size);
    if (pid == 0) {
        /* Only async-signal-safe C calls between fork and exec. Dispatch and
           Swift-concurrency threads block SIGTERM/SIGINT; forkpty children
           inherit that mask across exec, so termination and interrupt would
           stay pending forever. Reset the inherited mask and dispositions so
           an interactive terminal behaves like a normal login shell. */
        sigset_t empty;
        sigemptyset(&empty);
        sigprocmask(SIG_SETMASK, &empty, NULL);
        signal(SIGTERM, SIG_DFL);
        signal(SIGINT, SIG_DFL);
        signal(SIGQUIT, SIG_DFL);
        signal(SIGHUP, SIG_DFL);
        signal(SIGPIPE, SIG_DFL);
        signal(SIGTSTP, SIG_DFL);
        signal(SIGTTIN, SIG_DFL);
        signal(SIGTTOU, SIG_DFL);
        if (chdir(cwd) != 0) _exit(126);
        execve("/bin/zsh", argv, envp);
        _exit(127);
    }
    return pid;
}
int floe_resize_pty(int master, unsigned short columns, unsigned short rows) {
    struct winsize size = { .ws_row = rows, .ws_col = columns };
    return ioctl(master, TIOCSWINSZ, &size);
}
