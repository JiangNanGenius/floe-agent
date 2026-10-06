/* Regression: the embedding process retains SIGPIPE's default disposition.
 * Broken preview connections must return EPIPE, never terminate the app. */
#include "slirp.h"

int main(void)
{
    int pair[2];
    char received = 0;
    struct socket so = {0};
    if (socketpair(AF_UNIX, SOCK_STREAM, 0, pair)) return 2;
    signal(SIGPIPE, SIG_DFL);
    so.s = pair[0];
    if (slirp_send(&so, "x", 1, 0) != 1 ||
        recv(pair[1], &received, 1, 0) != 1 || received != 'x') return 3;
    close(pair[1]);
    for (int i = 0; i < 100; ++i) {
        errno = 0;
        ssize_t sent = slirp_send(&so, "x", 1, 0);
        if (sent != -1 || (errno != EPIPE && errno != ENOTCONN)) { fprintf(stderr, "iteration=%d sent=%ld errno=%d\n", i, (long)sent, errno); return 4; }
    }
    errno = 0;
    ssize_t probe = os_send(pair[0], "", 0, 0);
    /* Kernels may accept an empty write even after peer close. */
    if (probe != 0 && !(probe == -1 && (errno == EPIPE || errno == ENOTCONN))) return 5;
    close(pair[0]);
    errno = 0;
    if (os_send(-1, "x", 1, 0) != -1 || errno != EBADF) return 6;
    return 0;
}
