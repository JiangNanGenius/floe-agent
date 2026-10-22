// SPDX-License-Identifier: MPL-2.0
//
// PTY + fork/exec JNI bridge for the Floe Android Linux runtime launch
// transport. Bionic libc only; no third-party code. Each spawned child is
// owned by its PtySession; cancellation kills exactly the owned process group
// after a creation-identity check (no kill-by-name, no PID-reuse hazards).
//
// String discipline: jstrings cross as UTF-16 and are converted here to
// strict UTF-8 (real 4-byte encodings for non-BMP), never modified UTF-8.

#include <jni.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/resource.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <termios.h>
#include <unistd.h>

#ifndef TIOCSCTTY
#define TIOCSCTTY 0x540E
#endif
#ifndef TIOCSWINSZ
#define TIOCSWINSZ 0x5414
#endif
#ifndef ETIMEDOUT
#define ETIMEDOUT 110
#endif

// ---------------------------------------------------------------------------
// Strict UTF-8 conversion from UTF-16 (GetStringChars). Returns malloc'd
// buffer or NULL on failure; *ok set to 0 on invalid input.
// ---------------------------------------------------------------------------
static char *utf8_from_jstring(JNIEnv *env, jstring s, int *ok) {
    *ok = 1;
    if (!s) return NULL;
    jsize len = (*env)->GetStringLength(env, s);
    const jchar *u = (*env)->GetStringChars(env, s, NULL);
    if (!u) { *ok = 0; return NULL; }
    size_t cap = (size_t)len * 4 + 1;
    char *out = malloc(cap);
    if (!out) { (*env)->ReleaseStringChars(env, s, u); *ok = 0; return NULL; }
    size_t n = 0;
    for (jsize i = 0; i < len; i++) {
        unsigned c = (unsigned)u[i];
        if (c < 0x80) {
            out[n++] = (char)c;
        } else if (c < 0x800) {
            out[n++] = (char)(0xC0 | (c >> 6));
            out[n++] = (char)(0x80 | (c & 0x3F));
        } else if (c >= 0xD800 && c <= 0xDBFF && i + 1 < len &&
                   u[i + 1] >= 0xDC00 && u[i + 1] <= 0xDFFF) {
            unsigned cp = 0x10000u + ((c - 0xD800u) << 10) + ((unsigned)u[i + 1] - 0xDC00u);
            out[n++] = (char)(0xF0 | (cp >> 18));
            out[n++] = (char)(0x80 | ((cp >> 12) & 0x3F));
            out[n++] = (char)(0x80 | ((cp >> 6) & 0x3F));
            out[n++] = (char)(0x80 | (cp & 0x3F));
            i++;
        } else if (c >= 0xD800 && c <= 0xDFFF) {
            *ok = 0; // lone surrogate: refuse rather than replace
            break;
        } else {
            out[n++] = (char)(0xE0 | (c >> 12));
            out[n++] = (char)(0x80 | ((c >> 6) & 0x3F));
            out[n++] = (char)(0x80 | (c & 0x3F));
        }
    }
    out[n] = 0;
    (*env)->ReleaseStringChars(env, s, u);
    if (!*ok) { free(out); return NULL; }
    return out;
}

static jint throwErrno(JNIEnv *env, const char *what) {
    char msg[160];
    snprintf(msg, sizeof(msg), "%s: %s (%d)", what, strerror(errno), errno);
    jclass c = (*env)->FindClass(env, "java/io/IOException");
    if (c) (*env)->ThrowNew(env, c, msg);
    return -1;
}

static jint throwMsg(JNIEnv *env, const char *klass, const char *msg) {
    jclass c = (*env)->FindClass(env, klass);
    if (c) (*env)->ThrowNew(env, c, msg);
    return -1;
}

// Mark inherited non-stdio fds CLOEXEC so nothing
// the App runtime holds (DB, credentials, sockets) leaks into child code.
// Only fcntl after fork: no allocator/directory locks and no fdsan ownership
// violations from closing Java-owned App descriptors. Successful exec closes
// them; the error pipe remains writable until exec or _exit.
static int mark_inherited_fds_cloexec(int fdLimit) {
    for (int fd = STDERR_FILENO + 1; fd < fdLimit; fd++) {
        int result;
        do { result = fcntl(fd, F_SETFD, FD_CLOEXEC); }
        while (result < 0 && errno == EINTR);
        if (result < 0 && errno != EBADF) return -1;
    }
    return 0;
}

JNIEXPORT jintArray JNICALL
Java_com_floe_android_linuxruntime_PosixBridge_openPty(JNIEnv *env, jclass clazz) {
    (void)clazz;
    int master = posix_openpt(O_RDWR | O_NOCTTY | O_NONBLOCK | O_CLOEXEC);
    if (master < 0) { throwErrno(env, "posix_openpt"); return NULL; }
    if (grantpt(master) != 0) { throwErrno(env, "grantpt"); close(master); return NULL; }
    if (unlockpt(master) != 0) { throwErrno(env, "unlockpt"); close(master); return NULL; }
    char *slaveName = ptsname(master);
    if (!slaveName) { throwErrno(env, "ptsname"); close(master); return NULL; }
    int slave = open(slaveName, O_RDWR | O_NOCTTY);
    if (slave < 0) { throwErrno(env, "open(slave)"); close(master); return NULL; }
    jintArray out = (*env)->NewIntArray(env, 2);
    if (!out) { close(master); close(slave); return NULL; }
    jint vals[2] = { master, slave };
    (*env)->SetIntArrayRegion(env, out, 0, 2, vals);
    return out;
}

JNIEXPORT jstring JNICALL
Java_com_floe_android_linuxruntime_PosixBridge_ptsName(JNIEnv *env, jclass clazz, jint masterFd) {
    (void)clazz;
    char *name = ptsname(masterFd);
    if (!name) { throwErrno(env, "ptsname"); return NULL; }
    // ptsname is pure ASCII; a direct UTF-8 jstring is byte-accurate here.
    return (*env)->NewStringUTF(env, name);
}

// Spawn a child on the PTY slave. When stdinPipe is 1 the child's stdin is
// instead the READ end of a real pipe (stdout/stderr stay on the PTY): the
// parent receives the write end through *stdinWriteOut, nonblocking, and
// closing THAT descriptor delivers a REAL EOF to the child exactly after the
// bytes already written. An EOT byte over the PTY never stands in for that:
// in raw/no-VEOF processing it is ordinary data, and in canonical mode it is
// line-state-dependent. Returns pid >= 0 on success; -errno on a real
// launch/spawn failure (a pending Java exception may accompany the host-side
// precondition failures, exactly like spawnOnPty). stdinWriteOut is only set
// on success; every failure path owns and closes both pipe ends here.
static jint pty_spawn(
    JNIEnv *env,
    jint masterFd, jint slaveFd,
    jstring executable, jobjectArray argv, jobjectArray envp,
    jstring workingDir, jint timeoutMs,
    int stdinPipe, jint *stdinWriteOut) {
    if (stdinWriteOut) *stdinWriteOut = -1;

    struct rlimit fdLimit;
    if (getrlimit(RLIMIT_NOFILE, &fdLimit) != 0)
        return throwErrno(env, "getrlimit");
    if (fdLimit.rlim_cur > 1048576) {
        throwMsg(env, "java/lang/IllegalStateException", "Unbounded descriptor limit");
        return -1;
    }

    int ok = 1;
    const char *exe = utf8_from_jstring(env, executable, &ok);
    if (!ok) { throwMsg(env, "java/lang/IllegalArgumentException", "executable: invalid UTF-16"); return -1; }
    if (!exe) return -1;

    jsize argc = (*env)->GetArrayLength(env, argv);
    jsize envc = (*env)->GetArrayLength(env, envp);
    if (argc < 1) {
        free((void *)exe);
        throwMsg(env, "java/lang/IllegalArgumentException", "argv must include argv[0]");
        return -1;
    }
    int failure_errno = EINVAL;
    const char **cargv = calloc((size_t)argc + 1, sizeof(char *));
    const char **cenvp = calloc((size_t)envc + 1, sizeof(char *));
    jstring *jargv = calloc((size_t)argc, sizeof(jstring));
    jstring *jenvp = calloc((size_t)envc, sizeof(jstring));
    if (!cargv || !cenvp || !jargv || !jenvp) {
        free((void *)exe); free(cargv); free(cenvp); free(jargv); free(jenvp);
        throwMsg(env, "java/lang/OutOfMemoryError", "spawn arrays");
        return -1;
    }
    for (jsize i = 0; i < argc; i++) {
        jargv[i] = (jstring)(*env)->GetObjectArrayElement(env, argv, i);
        cargv[i] = jargv[i] ? utf8_from_jstring(env, jargv[i], &ok) : NULL;
        if (!ok) {
            throwMsg(env, "java/lang/IllegalArgumentException", "argv: invalid UTF-16");
            goto fail_release;
        }
    }
    cargv[argc] = NULL;
    for (jsize i = 0; i < envc; i++) {
        jenvp[i] = (jstring)(*env)->GetObjectArrayElement(env, envp, i);
        cenvp[i] = jenvp[i] ? utf8_from_jstring(env, jenvp[i], &ok) : NULL;
        if (!ok) {
            throwMsg(env, "java/lang/IllegalArgumentException", "envp: invalid UTF-16");
            goto fail_release;
        }
    }
    cenvp[envc] = NULL;

    const char *cwd = workingDir ? utf8_from_jstring(env, workingDir, &ok) : NULL;
    if (workingDir && !ok) {
        throwMsg(env, "java/lang/IllegalArgumentException", "workingDir: invalid UTF-16");
        goto fail_release;
    }

    int errPipe[2];
    if (pipe2(errPipe, O_CLOEXEC) != 0) {
        failure_errno = errno;
        // release everything
        if (workingDir && cwd) free((void *)cwd);
        goto fail_release;
    }

    // One-shot stdin pipe: O_CLOEXEC both ends, so the exec'd guest never
    // inherits the WRITE end; only fd 0 (the dup2'd read end) crosses exec.
    int stdinPipeFds[2] = { -1, -1 };
    if (stdinPipe && pipe2(stdinPipeFds, O_CLOEXEC) != 0) {
        failure_errno = errno;
        close(errPipe[0]); close(errPipe[1]);
        if (workingDir && cwd) free((void *)cwd);
        goto fail_release;
    }

    pid_t pid = fork();
    if (pid < 0) {
        failure_errno = errno;
        close(errPipe[0]); close(errPipe[1]);
        if (stdinPipe) { close(stdinPipeFds[0]); close(stdinPipeFds[1]); }
        if (workingDir && cwd) free((void *)cwd);
        goto fail_release;
    }

    if (pid == 0) {
        // ---- child. Only async-signal-safe calls from here until execve. ----
        close(errPipe[0]);
        if (setsid() < 0) goto child_fail;
        if (ioctl(slaveFd, TIOCSCTTY, 0) != 0) goto child_fail;
        // One-shot mode puts the pipe read end on fd 0; PTY mode keeps the
        // slave on all three stdio descriptors (unchanged interactive input,
        // resize and ISIG signal semantics ride the PTY as before).
        int stdinDup = stdinPipe
            ? dup2(stdinPipeFds[0], STDIN_FILENO)
            : dup2(slaveFd, STDIN_FILENO);
        if (stdinDup < 0) goto child_fail;
        if (dup2(slaveFd, STDOUT_FILENO) < 0) goto child_fail;
        if (dup2(slaveFd, STDERR_FILENO) < 0) goto child_fail;
        if (slaveFd > STDERR_FILENO) close(slaveFd);
        if (masterFd > STDERR_FILENO) close(masterFd);
        if (stdinPipe) {
            if (stdinPipeFds[0] > STDERR_FILENO) close(stdinPipeFds[0]);
            // Dropping the child's copy of the write end is what makes the
            // parent's close the ONLY EOF source: no in-guest holder can
            // keep stdin open past the supplied bytes.
            if (stdinPipeFds[1] > STDERR_FILENO) close(stdinPipeFds[1]);
        }
        if (mark_inherited_fds_cloexec((int)fdLimit.rlim_cur) != 0) goto child_fail;
        if (cwd && chdir(cwd) != 0) goto child_fail;
        execve(exe, (char *const *)cargv, (char *const *)cenvp);
        goto child_fail;
    child_fail: {
            int e = errno;
            (void)!write(errPipe[1], &e, sizeof(e));
            _exit(127);
        }
    }

    // ---- parent ----
    close(errPipe[1]);
    if (stdinPipe) close(stdinPipeFds[0]); // the read end belongs to the child
    int childErr = 0;
    ssize_t n = 0;
    struct pollfd pfd = { errPipe[0], POLLIN | POLLHUP, 0 };
    int pr;
    int remainingMs = timeoutMs < 0 ? 0 : timeoutMs;
    struct timespec pollStarted;
    if (clock_gettime(CLOCK_MONOTONIC, &pollStarted) != 0) {
        pr = -1;
    } else {
        const long long startedMs = (long long)pollStarted.tv_sec * 1000 + pollStarted.tv_nsec / 1000000;
        for (;;) {
            pr = poll(&pfd, 1, remainingMs);
            if (pr >= 0 || errno != EINTR) break;
            struct timespec current;
            if (clock_gettime(CLOCK_MONOTONIC, &current) != 0) break;
            const long long elapsedMs = (long long)current.tv_sec * 1000 + current.tv_nsec / 1000000 - startedMs;
            if (elapsedMs >= timeoutMs) { pr = 0; break; }
            remainingMs = timeoutMs - (int)elapsedMs;
        }
    }
    if (pr == 0) {
        // Common error cleanup below kills and reaps this still-owned PID
        // exactly once. Never signal it again after waitpid released it.
        n = -1;
        childErr = ETIMEDOUT;
    } else if (pr > 0) {
        do {
            n = read(errPipe[0], &childErr, sizeof(childErr));
        } while (n < 0 && errno == EINTR);
        if (n < 0) childErr = errno;
    } else {
        n = -1;
        childErr = errno;
    }
    close(errPipe[0]);

    if (workingDir && cwd) free((void *)cwd);
    // argv/envp strings were malloc'd by utf8_from_jstring, not JNI refs.
    for (jsize i = 0; i < argc; i++) free((void *)cargv[i]);
    for (jsize i = 0; i < envc; i++) free((void *)cenvp[i]);
    free(cargv); free(cenvp); free(jargv); free(jenvp);
    free((void *)exe);

    if (n > 0) {
        int status;
        // The child wrote this errno then immediately _exit'ed. Retain its
        // wait ownership through reap, just as startup-timeout cleanup does.
        while (waitpid(pid, &status, 0) < 0 && errno == EINTR) {}
        if (stdinPipe) close(stdinPipeFds[1]);
        return -childErr;
    }
    if (n < 0) {
        // Keep startup ownership through confirmed exit. A timeout bounds
        // the startup wait, not an uninterruptible kernel cleanup interval.
        kill(pid, SIGKILL);
        int status;
        while (waitpid(pid, &status, 0) < 0 && errno == EINTR) {}
        if (stdinPipe) close(stdinPipeFds[1]);
        return -(childErr ? childErr : EIO);
    }
    if (stdinPipe) {
        // Startup succeeded: hand the session a NONBLOCKING write end so a
        // pump page can never wedge the control thread waiting on a reader.
        // The flag lives on the write-side open file description only; the
        // child's fd 0 (read side) keeps blocking read semantics.
        int flags = fcntl(stdinPipeFds[1], F_GETFL, 0);
        if (flags < 0 || fcntl(stdinPipeFds[1], F_SETFL, flags | O_NONBLOCK) < 0) {
            int e = errno;
            kill(pid, SIGKILL);
            int status;
            while (waitpid(pid, &status, 0) < 0 && errno == EINTR) {}
            close(stdinPipeFds[1]);
            return -e;
        }
        if (stdinWriteOut) *stdinWriteOut = stdinPipeFds[1];
    }
    return (jint)pid;

fail_release:
    for (jsize i = 0; i < argc; i++) free((void *)cargv[i]);
    for (jsize i = 0; i < envc; i++) free((void *)cenvp[i]);
    free(cargv); free(cenvp); free(jargv); free(jenvp);
    free((void *)exe);
    return -failure_errno;
}

JNIEXPORT jint JNICALL
Java_com_floe_android_linuxruntime_PosixBridge_spawnOnPty(
    JNIEnv *env, jclass clazz,
    jint masterFd, jint slaveFd,
    jstring executable, jobjectArray argv, jobjectArray envp,
    jstring workingDir, jint timeoutMs) {
    (void)clazz;
    return pty_spawn(env, masterFd, slaveFd, executable, argv, envp,
                     workingDir, timeoutMs, 0, NULL);
}

// One-shot launch with a descriptor-owned stdin pipe. Returns a 2-int array:
// success {pid, stdinWriteFd} — the write end is nonblocking and its close is
// the ONLY EOF source for the child's stdin; failure {-errno, -1}. A pending
// Java exception (host-side precondition) yields NULL like spawnOnPty.
JNIEXPORT jintArray JNICALL
Java_com_floe_android_linuxruntime_PosixBridge_spawnOnPtyStdinPipe(
    JNIEnv *env, jclass clazz,
    jint masterFd, jint slaveFd,
    jstring executable, jobjectArray argv, jobjectArray envp,
    jstring workingDir, jint timeoutMs) {
    (void)clazz;
    jint stdinWriteFd = -1;
    jint r = pty_spawn(env, masterFd, slaveFd, executable, argv, envp,
                       workingDir, timeoutMs, 1, &stdinWriteFd);
    if ((*env)->ExceptionCheck(env)) {
        if (r >= 0 && stdinWriteFd >= 0) close(stdinWriteFd); // nothing can use it
        return NULL;
    }
    jintArray out = (*env)->NewIntArray(env, 2);
    if (!out) {
        if (r >= 0 && stdinWriteFd >= 0) close(stdinWriteFd);
        return NULL;
    }
    jint vals[2] = { r, stdinWriteFd };
    (*env)->SetIntArrayRegion(env, out, 0, 2, vals);
    return out;
}

// Bounded write into the one-shot stdin pipe's write end. EINTR is retried
// inside the syscall loop; a full pipe fails with -EAGAIN (never blocks the
// JNI thread). Returns bytes accepted (may be partial) or -errno if nothing
// was accepted: -11 EAGAIN, -32 EPIPE (child closed its stdin), -9 EBADF.
// EPIPE surfaces as an error, not a signal: the Android runtime process runs
// with SIGPIPE ignored by ART, so a reader-less write returns -32 here.
JNIEXPORT jint JNICALL
Java_com_floe_android_linuxruntime_PosixBridge_writeStdinPipe(
    JNIEnv *env, jclass clazz, jint fd, jbyteArray data, jint offset, jint length) {
    (void)clazz;
    if (fd < 0) return -EINVAL;
    jsize avail = (*env)->GetArrayLength(env, data);
    if (offset < 0 || length < 0 || offset > avail || length > avail - offset) return -EINVAL;
    if (length == 0) return 0;
    jbyte *buf = (*env)->GetByteArrayElements(env, data, NULL);
    if (!buf) return -ENOMEM;
    ssize_t total = 0;
    while (total < length) {
        ssize_t n = write(fd, (char *)buf + offset + total, (size_t)(length - total));
        if (n < 0) {
            if (errno == EINTR) continue;
            int e = errno;
            (*env)->ReleaseByteArrayElements(env, data, buf, JNI_ABORT);
            return total > 0 ? (jint)total : -e;
        }
        if (n == 0) break;
        total += n;
    }
    (*env)->ReleaseByteArrayElements(env, data, buf, JNI_ABORT);
    return (jint)total;
}

JNIEXPORT jint JNICALL
Java_com_floe_android_linuxruntime_PosixBridge_setWinsize(
    JNIEnv *env, jclass clazz, jint masterFd, jint rows, jint cols) {
    (void)env; (void)clazz;
    struct winsize ws;
    memset(&ws, 0, sizeof(ws));
    ws.ws_row = (unsigned short)rows;
    ws.ws_col = (unsigned short)cols;
    if (ioctl(masterFd, TIOCSWINSZ, &ws) != 0) return -errno;
    return 0;
}

static jintArray decodeWait(JNIEnv *env, pid_t r, int status, int err) {
    jintArray out = (*env)->NewIntArray(env, 3);
    if (!out) return NULL;
    jint v[3] = { 0, 0, 0 };
    if (r == 0) {
        v[0] = 0;
    } else if (r > 0) {
        if (WIFEXITED(status)) { v[0] = 1; v[1] = WEXITSTATUS(status); }
        else if (WIFSIGNALED(status)) { v[0] = 2; v[2] = WTERMSIG(status); }
        else { v[0] = 3; v[2] = EPROTO; }
    } else {
        v[0] = 3; v[2] = err;
    }
    (*env)->SetIntArrayRegion(env, out, 0, 3, v);
    return out;
}

JNIEXPORT jintArray JNICALL
Java_com_floe_android_linuxruntime_PosixBridge_pollWaitPid(JNIEnv *env, jclass clazz, jint pid) {
    (void)clazz;
    int status = 0;
    pid_t r;
    do {
        r = waitpid((pid_t)pid, &status, WNOHANG);
    } while (r < 0 && errno == EINTR);
    int err = (r < 0) ? errno : 0;
    return decodeWait(env, r, status, err);
}

JNIEXPORT jintArray JNICALL
Java_com_floe_android_linuxruntime_PosixBridge_waitPidTimeout(
    JNIEnv *env, jclass clazz, jint pid, jint timeoutMs) {
    (void)clazz;
    jlong deadline = 0;
    struct timespec ts;
    if (clock_gettime(CLOCK_MONOTONIC, &ts) == 0) {
        deadline = (jlong)ts.tv_sec * 1000 + ts.tv_nsec / 1000000 + timeoutMs;
    }
    for (;;) {
        int status = 0;
        pid_t r;
        do {
            r = waitpid((pid_t)pid, &status, WNOHANG);
        } while (r < 0 && errno == EINTR);
        int err = (r < 0) ? errno : 0;
        if (r != 0) return decodeWait(env, r, status, err);
        if (timeoutMs <= 0) return decodeWait(env, 0, 0, 0);
        struct timespec now;
        if (clock_gettime(CLOCK_MONOTONIC, &now) == 0) {
            jlong nowMs = (jlong)now.tv_sec * 1000 + now.tv_nsec / 1000000;
            if (nowMs >= deadline) return decodeWait(env, 0, 0, 0);
        }
        usleep(15 * 1000);
    }
}

JNIEXPORT jint JNICALL
Java_com_floe_android_linuxruntime_PosixBridge_kill(JNIEnv *env, jclass clazz, jint pid, jint sig) {
    (void)env; (void)clazz;
    if (kill((pid_t)pid, (int)sig) != 0) return -errno;
    return 0;
}

JNIEXPORT jint JNICALL
Java_com_floe_android_linuxruntime_PosixBridge_processGroup(JNIEnv *env, jclass clazz, jint pid) {
    (void)env; (void)clazz;
    pid_t group = getpgid((pid_t)pid);
    return group < 0 ? -errno : (jint)group;
}

JNIEXPORT jint JNICALL
Java_com_floe_android_linuxruntime_PosixBridge_exists(JNIEnv *env, jclass clazz, jint pid) {
    (void)env; (void)clazz;
    if (kill((pid_t)pid, 0) != 0) return -errno;
    return 0;
}

JNIEXPORT jbyteArray JNICALL
Java_com_floe_android_linuxruntime_PosixBridge_readMasterTimeout(
    JNIEnv *env, jclass clazz, jint masterFd, jint capacity, jint timeoutMs) {
    (void)clazz;
    if (capacity <= 0 || capacity > 1 << 20) capacity = 64 * 1024;
    struct pollfd pfd = { masterFd, POLLIN | POLLHUP, 0 };
    int pr;
    int remainingMs = timeoutMs < 0 ? 0 : timeoutMs;
    struct timespec pollStarted;
    if (clock_gettime(CLOCK_MONOTONIC, &pollStarted) != 0) {
        pr = -1;
    } else {
        const long long startedMs = (long long)pollStarted.tv_sec * 1000 + pollStarted.tv_nsec / 1000000;
        for (;;) {
            pr = poll(&pfd, 1, remainingMs);
            if (pr >= 0 || errno != EINTR) break;
            struct timespec current;
            if (clock_gettime(CLOCK_MONOTONIC, &current) != 0) break;
            const long long elapsedMs = (long long)current.tv_sec * 1000 + current.tv_nsec / 1000000 - startedMs;
            if (elapsedMs >= timeoutMs) { pr = 0; break; }
            remainingMs = timeoutMs - (int)elapsedMs;
        }
    }
    if (pr == 0) return (*env)->NewByteArray(env, 0); // no data yet, not EOF
    if (pr < 0) { throwErrno(env, "poll PTY"); return NULL; }
    char *buf = malloc((size_t)capacity);
    if (!buf) {
        throwMsg(env, "java/lang/OutOfMemoryError", "readMaster");
        return NULL;
    }
    ssize_t n;
    do {
        n = read(masterFd, buf, (size_t)capacity);
    } while (n < 0 && errno == EINTR);
    if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
        free(buf);
        return (*env)->NewByteArray(env, 0);
    }
    if (n <= 0) {
        int saved = errno;
        free(buf);
        if (n < 0 && saved != EIO) {
            errno = saved;
            throwErrno(env, "read PTY");
        }
        return NULL;
    }
    jbyteArray out = (*env)->NewByteArray(env, (jsize)n);
    if (out) (*env)->SetByteArrayRegion(env, out, 0, (jsize)n, (jbyte *)buf);
    free(buf);
    return out;
}

JNIEXPORT jint JNICALL
Java_com_floe_android_linuxruntime_PosixBridge_writeMaster(
    JNIEnv *env, jclass clazz, jint masterFd, jbyteArray data, jint offset, jint length) {
    (void)clazz;
    jsize avail = (*env)->GetArrayLength(env, data);
    if (offset < 0 || length < 0 || offset > avail || length > avail - offset) return -EINVAL;
    jbyte *buf = (*env)->GetByteArrayElements(env, data, NULL);
    if (!buf) return -ENOMEM;
    ssize_t total = 0;
    while (total < length) {
        ssize_t n = write(masterFd, (char *)buf + offset + total, (size_t)(length - total));
        if (n < 0) {
            if (errno == EINTR) continue;
            int e = errno;
            (*env)->ReleaseByteArrayElements(env, data, buf, JNI_ABORT);
            return total > 0 ? (jint)total : -e;
        }
        if (n == 0) break;
        total += n;
    }
    (*env)->ReleaseByteArrayElements(env, data, buf, JNI_ABORT);
    return (jint)total;
}

JNIEXPORT jint JNICALL
Java_com_floe_android_linuxruntime_PosixBridge_setFdNonBlocking(JNIEnv *env, jclass clazz, jint fd) {
    (void)env; (void)clazz;
    int flags = fcntl(fd, F_GETFL, 0);
    if (flags < 0) return -errno;
    if (fcntl(fd, F_SETFL, flags | O_NONBLOCK) < 0) return -errno;
    return 0;
}

JNIEXPORT jint JNICALL
Java_com_floe_android_linuxruntime_PosixBridge_closeFd(JNIEnv *env, jclass clazz, jint fd) {
    (void)env; (void)clazz;
    if (close(fd) != 0) return -errno;
    return 0;
}

JNIEXPORT jint JNICALL
Java_com_floe_android_linuxruntime_PosixBridge_hostPageSize(JNIEnv *env, jclass clazz) {
    (void)env; (void)clazz;
    long ps = sysconf(_SC_PAGESIZE);
    return (jint)ps;
}

JNIEXPORT jlong JNICALL
Java_com_floe_android_linuxruntime_PosixBridge_procStartTime(JNIEnv *env, jclass clazz, jint pid) {
    (void)env; (void)clazz;
    char path[64];
    snprintf(path, sizeof(path), "/proc/%d/stat", pid);
    int fd = open(path, O_RDONLY);
    if (fd < 0) return -1;
    char buf[1024];
    ssize_t n = read(fd, buf, sizeof(buf) - 1);
    close(fd);
    if (n <= 0) return -1;
    buf[n] = 0;
    // Field 3 is the process state (a letter), not an integer. Start time
    // is field 22; comm may contain spaces or closing parentheses.
    char *rp = strrchr(buf, ')');
    if (!rp) return -1;
    char *p = rp + 2;
    p = strchr(p, ' ');
    if (!p) return -1;
    p++;
    for (int field = 4; field <= 22; field++) {
        char *end = NULL;
        if (field == 22) {
            long long ticks = strtoll(p, &end, 10);
            return end && end != p ? (jlong)ticks : -1;
        }
        strtoll(p, &end, 10);
        if (!end || end == p) return -1;
        p = end + 1;
    }
    return -1;
}
