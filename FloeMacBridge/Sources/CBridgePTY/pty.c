#include "CBridgePTY.h"
#include <util.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <stdlib.h>
#include <errno.h>
pid_t floe_spawn_pty(int *master, const char *cwd, char *const argv[], char *const envp[], unsigned short columns, unsigned short rows) {
    struct winsize size = { .ws_row = rows, .ws_col = columns };
    pid_t pid = forkpty(master, NULL, NULL, &size);
    if (pid == 0) {
        /* Only async-signal-safe C calls between fork and exec. */
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
