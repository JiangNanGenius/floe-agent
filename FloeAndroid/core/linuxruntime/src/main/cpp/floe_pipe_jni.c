// SPDX-License-Identifier: MPL-2.0
//
// No-PTY separated-stdio process bridge for the Floe Android Linux runtime.
//
// This is the C01 managed-service stdio transport primitive. It spawns ONE
// owned child inside the already-resolved guest launch (the caller passes the
// exact PRoot executable/argv/env/cwd; nothing is resolved here) with THREE
// distinct byte streams:
//
//   fd 0  <- parent-owned stdin PIPE write end   (data + real descriptor EOF)
//   fd 1  -> parent-owned stdout PIPE read end   (newline JSON-RPC)
//   fd 2  -> parent-owned stderr PIPE read end   (diagnostics only)
//
// There is deliberately NO PTY: no line discipline, no echo, no input
// canonicalization and no merged stderr. The parent ends are nonblocking so a
// bounded pump can never wedge the control thread. Closing the parent's stdin
// write end is the ONLY EOF source: the child drops its inherited copy before
// exec, so no in-guest process can keep stdin open past the supplied bytes.
//
// Failure discipline (partial fork/exec):
// * Every pipe is created with O_CLOEXEC; only the three dup2'd descriptors
//   cross execve.
// * The child reports exec/chdir failure through a CLOEXEC error pipe and
//   _exit(127); the parent kills and reaps the half-spawned child before
//   returning a real -errno, and every fd is closed on every failure path.
// * On success the parent returns {pid, stdinWriteFd, stdoutReadFd,
//   stderrReadFd}; ownership (kill group / reap / close) belongs to the
//   caller's session object.
//
// Bionic libc only; no third-party code.

#ifndef _GNU_SOURCE
#define _GNU_SOURCE 1
#endif

#include <jni.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <pthread.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#ifndef ETIMEDOUT
#define ETIMEDOUT 110
#endif

// ---------------------------------------------------------------------------
// Strict UTF-8 conversion from UTF-16 (duplicated from floe_pty_jni.c so the
// two translation units stay independently linkable; both are the same frozen
// conversion with lone-surrogate refusal).
// ---------------------------------------------------------------------------
static char *pipe_utf8_from_jstring(JNIEnv *env, jstring s, int *ok) {
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

static jint pipe_throw_errno(JNIEnv *env, const char *what) {
    char msg[160];
    snprintf(msg, sizeof(msg), "%s: %s (%d)", what, strerror(errno), errno);
    jclass c = (*env)->FindClass(env, "java/io/IOException");
    if (c) (*env)->ThrowNew(env, c, msg);
    return -1;
}

static jint pipe_throw_msg(JNIEnv *env, const char *klass, const char *msg) {
    jclass c = (*env)->FindClass(env, klass);
    if (c) (*env)->ThrowNew(env, c, msg);
    return -1;
}

// Mark inherited non-stdio fds CLOEXEC after fork: no allocator locks, no
// fdsan ownership violations. Successful exec closes them; the error pipe
// remains writable until exec or _exit.
static int pipe_mark_inherited_fds_cloexec(int fdLimit) {
    for (int fd = STDERR_FILENO + 1; fd < fdLimit; fd++) {
        int result;
        do { result = fcntl(fd, F_SETFD, FD_CLOEXEC); }
        while (result < 0 && errno == EINTR);
        if (result < 0 && errno != EBADF) return -1;
    }
    return 0;
}

static long long pipe_monotonic_ms(void) {
    struct timespec ts;
    if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0) return 0;
    return (long long)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

/**
 * Spawn one child with three dedicated pipes and no controlling terminal.
 * Returns a 4-int array: success {pid, stdinWriteFd, stdoutReadFd,
 * stderrReadFd}; failure {-errno, -1, -1, -1}. A pending Java exception
 * (host-side precondition failure) yields NULL, exactly like spawnOnPty.
 */
JNIEXPORT jintArray JNICALL
Java_com_floe_android_linuxruntime_PosixBridge_spawnPipeProcess(
    JNIEnv *env, jclass clazz,
    jstring executable, jobjectArray argv, jobjectArray envp,
    jstring workingDir, jint timeoutMs) {
    (void)clazz;

    struct rlimit fdLimit;
    if (getrlimit(RLIMIT_NOFILE, &fdLimit) != 0)
        return pipe_throw_errno(env, "getrlimit"), NULL;
    if (fdLimit.rlim_cur > 1048576) {
        pipe_throw_msg(env, "java/lang/IllegalStateException", "Unbounded descriptor limit");
        return NULL;
    }

    int ok = 1;
    const char *exe = pipe_utf8_from_jstring(env, executable, &ok);
    if (!ok) { pipe_throw_msg(env, "java/lang/IllegalArgumentException", "executable: invalid UTF-16"); return NULL; }
    if (!exe) return NULL;

    jsize argc = (*env)->GetArrayLength(env, argv);
    jsize envc = (*env)->GetArrayLength(env, envp);
    if (argc < 1) {
        free((void *)exe);
        pipe_throw_msg(env, "java/lang/IllegalArgumentException", "argv must include argv[0]");
        return NULL;
    }
    int failure_errno = EINVAL;
    const char **cargv = calloc((size_t)argc + 1, sizeof(char *));
    const char **cenvp = calloc((size_t)envc + 1, sizeof(char *));
    jstring *jargv = calloc((size_t)argc, sizeof(jstring));
    jstring *jenvp = calloc((size_t)envc, sizeof(jstring));
    if (!cargv || !cenvp || !jargv || !jenvp) {
        free((void *)exe); free(cargv); free(cenvp); free(jargv); free(jenvp);
        pipe_throw_msg(env, "java/lang/OutOfMemoryError", "spawn arrays");
        return NULL;
    }
    for (jsize i = 0; i < argc; i++) {
        jargv[i] = (jstring)(*env)->GetObjectArrayElement(env, argv, i);
        cargv[i] = jargv[i] ? pipe_utf8_from_jstring(env, jargv[i], &ok) : NULL;
        if (!ok) {
            pipe_throw_msg(env, "java/lang/IllegalArgumentException", "argv: invalid UTF-16");
            goto fail_release;
        }
    }
    cargv[argc] = NULL;
    for (jsize i = 0; i < envc; i++) {
        jenvp[i] = (jstring)(*env)->GetObjectArrayElement(env, envp, i);
        cenvp[i] = jenvp[i] ? pipe_utf8_from_jstring(env, jenvp[i], &ok) : NULL;
        if (!ok) {
            pipe_throw_msg(env, "java/lang/IllegalArgumentException", "envp: invalid UTF-16");
            goto fail_release;
        }
    }
    cenvp[envc] = NULL;

    const char *cwd = workingDir ? pipe_utf8_from_jstring(env, workingDir, &ok) : NULL;
    if (workingDir && !ok) {
        pipe_throw_msg(env, "java/lang/IllegalArgumentException", "workingDir: invalid UTF-16");
        goto fail_release;
    }

    int errPipe[2] = { -1, -1 };
    int stdinPipe[2] = { -1, -1 };
    int stdoutPipe[2] = { -1, -1 };
    int stderrPipe[2] = { -1, -1 };

    if (pipe2(errPipe, O_CLOEXEC) != 0) { failure_errno = errno; goto fail_close; }
    if (pipe2(stdinPipe, O_CLOEXEC) != 0) { failure_errno = errno; goto fail_close; }
    if (pipe2(stdoutPipe, O_CLOEXEC) != 0) { failure_errno = errno; goto fail_close; }
    if (pipe2(stderrPipe, O_CLOEXEC) != 0) { failure_errno = errno; goto fail_close; }

    pid_t pid = fork();
    if (pid < 0) { failure_errno = errno; goto fail_close; }

    if (pid == 0) {
        // ---- child. Only async-signal-safe calls from here until execve. ----
        close(errPipe[0]);
        // Own session/process group: the parent can address EXACTLY this
        // process tree with kill(-pid, ...) and no other workload.
        if (setsid() < 0) goto child_fail;
        if (dup2(stdinPipe[0], STDIN_FILENO) < 0) goto child_fail;
        if (dup2(stdoutPipe[1], STDOUT_FILENO) < 0) goto child_fail;
        if (dup2(stderrPipe[1], STDERR_FILENO) < 0) goto child_fail;
        // Close every other pipe end (including our copy of the parent ends,
        // which is what makes the parent's stdin close the only EOF source).
        int childOwned[] = { stdinPipe[0], stdinPipe[1], stdoutPipe[0], stdoutPipe[1],
                             stderrPipe[0], stderrPipe[1] };
        for (size_t i = 0; i < sizeof(childOwned) / sizeof(childOwned[0]); i++) {
            if (childOwned[i] > STDERR_FILENO) close(childOwned[i]);
        }
        if (pipe_mark_inherited_fds_cloexec((int)fdLimit.rlim_cur) != 0) goto child_fail;
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
    close(stdinPipe[0]);   // read end belongs to the child
    close(stdoutPipe[1]);  // write end belongs to the child
    close(stderrPipe[1]);  // write end belongs to the child

    int childErr = 0;
    ssize_t n = 0;
    struct pollfd pfd = { errPipe[0], POLLIN | POLLHUP, 0 };
    int pr = -1;
    int remainingMs = timeoutMs < 0 ? 0 : timeoutMs;
    const long long startedMs = pipe_monotonic_ms();
    for (;;) {
        pr = poll(&pfd, 1, remainingMs);
        if (pr >= 0 || errno != EINTR) break;
        if (startedMs == 0) break;
        long long elapsedMs = pipe_monotonic_ms() - startedMs;
        if (elapsedMs >= timeoutMs) { pr = 0; break; }
        remainingMs = timeoutMs - (int)elapsedMs;
    }
    if (pr == 0) {
        n = -1;
        childErr = ETIMEDOUT;
    } else if (pr > 0) {
        do {
            n = read(errPipe[0], &childErr, sizeof(childErr));
        } while (n < 0 && errno == EINTR);
        if (n < 0) childErr = errno;
    } else {
        n = -1;
        childErr = errno ? errno : EIO;
    }
    close(errPipe[0]);

    if (workingDir && cwd) free((void *)cwd);
    for (jsize i = 0; i < argc; i++) free((void *)cargv[i]);
    for (jsize i = 0; i < envc; i++) free((void *)cenvp[i]);
    free(cargv); free(cenvp); free(jargv); free(jenvp);
    free((void *)exe);

    if (n != 0) {
        // Real exec/chdir failure OR startup timeout: this still-owned PID is
        // killed and reaped exactly once, and every pipe end is closed.
        int status;
        if (n < 0) kill(pid, SIGKILL);
        while (waitpid(pid, &status, 0) < 0 && errno == EINTR) {}
        close(stdinPipe[1]); close(stdoutPipe[0]); close(stderrPipe[0]);
        failure_errno = childErr ? childErr : EIO;
        jintArray out = (*env)->NewIntArray(env, 4);
        if (out) {
            jint vals[4] = { -failure_errno, -1, -1, -1 };
            (*env)->SetIntArrayRegion(env, out, 0, 4, vals);
        }
        return out;
    }

    // Startup succeeded. Every parent end becomes nonblocking so the bounded
    // pump can never block the runtime control thread on a slow reader/writer.
    int flags = fcntl(stdinPipe[1], F_GETFL, 0);
    if (flags < 0 || fcntl(stdinPipe[1], F_SETFL, flags | O_NONBLOCK) < 0) {
        int e = errno;
        kill(pid, SIGKILL);
        int status;
        while (waitpid(pid, &status, 0) < 0 && errno == EINTR) {}
        close(stdinPipe[1]); close(stdoutPipe[0]); close(stderrPipe[0]);
        failure_errno = e;
        goto fail_result;
    }
    for (int i = 0; i < 2; i++) {
        int fd = i == 0 ? stdoutPipe[0] : stderrPipe[0];
        flags = fcntl(fd, F_GETFL, 0);
        if (flags < 0 || fcntl(fd, F_SETFL, flags | O_NONBLOCK) < 0) {
            int e = errno;
            kill(pid, SIGKILL);
            int status;
            while (waitpid(pid, &status, 0) < 0 && errno == EINTR) {}
            close(stdinPipe[1]); close(stdoutPipe[0]); close(stderrPipe[0]);
            failure_errno = e;
            goto fail_result;
        }
    }

    {
        jintArray out = (*env)->NewIntArray(env, 4);
        if (!out) {
            kill(pid, SIGKILL);
            int status;
            while (waitpid(pid, &status, 0) < 0 && errno == EINTR) {}
            close(stdinPipe[1]); close(stdoutPipe[0]); close(stderrPipe[0]);
            return NULL;
        }
        jint vals[4] = { (jint)pid, stdinPipe[1], stdoutPipe[0], stderrPipe[0] };
        (*env)->SetIntArrayRegion(env, out, 0, 4, vals);
        return out;
    }

fail_close:
    if (errPipe[0] >= 0) close(errPipe[0]);
    if (errPipe[1] >= 0) close(errPipe[1]);
    if (stdinPipe[0] >= 0) close(stdinPipe[0]);
    if (stdinPipe[1] >= 0) close(stdinPipe[1]);
    if (stdoutPipe[0] >= 0) close(stdoutPipe[0]);
    if (stdoutPipe[1] >= 0) close(stdoutPipe[1]);
    if (stderrPipe[0] >= 0) close(stderrPipe[0]);
    if (stderrPipe[1] >= 0) close(stderrPipe[1]);
    if (workingDir && cwd) free((void *)cwd);
    goto fail_release;

fail_result: {
        jintArray out = (*env)->NewIntArray(env, 4);
        if (out) {
            jint vals[4] = { -failure_errno, -1, -1, -1 };
            (*env)->SetIntArrayRegion(env, out, 0, 4, vals);
        }
        return out;
    }

fail_release:
    for (jsize i = 0; i < argc; i++) free((void *)cargv[i]);
    for (jsize i = 0; i < envc; i++) free((void *)cenvp[i]);
    free(cargv); free(cenvp); free(jargv); free(jenvp);
    free((void *)exe);
    // A host-side precondition failure already threw; a real pipe/fork setup
    // failure has no exception yet, so surface its errno instead of returning
    // a bare NULL (the Kotlin session must never read that as success).
    if (!(*env)->ExceptionCheck(env)) {
        errno = failure_errno != 0 ? failure_errno : EIO;
        pipe_throw_errno(env, "spawnPipeProcess");
    }
    return NULL;
}

/**
 * Nonblocking read from one owned stdio pipe.
 * Returns an EMPTY byte array on timeout (no data yet), NULL on real EOF.
 * Other read failures throw with the real errno. Capacity is capped at 1 MiB.
 */
JNIEXPORT jbyteArray JNICALL
Java_com_floe_android_linuxruntime_PosixBridge_readPipeTimeout(
    JNIEnv *env, jclass clazz, jint fd, jint capacity, jint timeoutMs) {
    (void)clazz;
    if (fd < 0) { pipe_throw_msg(env, "java/lang/IllegalArgumentException", "readPipe: invalid fd"); return NULL; }
    if (capacity <= 0 || capacity > 1 << 20) capacity = 64 * 1024;
    struct pollfd pfd = { fd, POLLIN | POLLHUP, 0 };
    int pr = 0;
    int remainingMs = timeoutMs < 0 ? 0 : timeoutMs;
    const long long startedMs = pipe_monotonic_ms();
    for (;;) {
        pr = poll(&pfd, 1, remainingMs);
        if (pr >= 0 || errno != EINTR) break;
        if (startedMs == 0) break;
        long long elapsedMs = pipe_monotonic_ms() - startedMs;
        if (elapsedMs >= timeoutMs) { pr = 0; break; }
        remainingMs = timeoutMs - (int)elapsedMs;
    }
    if (pr == 0) return (*env)->NewByteArray(env, 0); // timeout, not EOF
    if (pr < 0) { pipe_throw_errno(env, "poll stdio pipe"); return NULL; }

    char *buf = malloc((size_t)capacity);
    if (!buf) {
        pipe_throw_msg(env, "java/lang/OutOfMemoryError", "readPipe");
        return NULL;
    }
    ssize_t n;
    do {
        n = read(fd, buf, (size_t)capacity);
    } while (n < 0 && errno == EINTR);
    if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
        free(buf);
        return (*env)->NewByteArray(env, 0); // raced to empty: still a timeout
    }
    if (n < 0) {
        int saved = errno;
        free(buf);
        errno = saved;
        pipe_throw_errno(env, "read stdio pipe");
        return NULL;
    }
    if (n == 0) {
        free(buf);
        return NULL; // real EOF: the child closed this stream
    }
    jbyteArray out = (*env)->NewByteArray(env, (jsize)n);
    if (out) (*env)->SetByteArrayRegion(env, out, 0, (jsize)n, (jbyte *)buf);
    free(buf);
    return out;
}

/**
 * Bounded write into the owned stdio stdin pipe. EINTR is retried inside the
 * syscall loop; a full pipe returns the bytes accepted so far (or -EAGAIN when
 * none), never blocking. -32 EPIPE means the child closed stdin.
 */
static ssize_t pipe_write_without_sigpipe(int fd, const void *bytes, size_t count) {
    sigset_t blocked, previous, pending;
    sigemptyset(&blocked);
    sigaddset(&blocked, SIGPIPE);
    int mask_error = pthread_sigmask(SIG_BLOCK, &blocked, &previous);
    if (mask_error != 0) { errno = mask_error; return -1; }
    if (sigpending(&pending) != 0) {
        int saved = errno;
        pthread_sigmask(SIG_SETMASK, &previous, NULL);
        errno = saved;
        return -1;
    }
    int already_pending = sigismember(&pending, SIGPIPE);
    ssize_t result = write(fd, bytes, count);
    int saved = errno;
    if (result < 0 && saved == EPIPE && !already_pending) {
        const struct timespec now = {0, 0};
        while (sigtimedwait(&blocked, NULL, &now) < 0 && errno == EINTR) {}
    }
    pthread_sigmask(SIG_SETMASK, &previous, NULL);
    errno = saved;
    return result;
}

JNIEXPORT jint JNICALL
Java_com_floe_android_linuxruntime_PosixBridge_writePipe(
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
        ssize_t n = pipe_write_without_sigpipe(fd, (char *)buf + offset + total, (size_t)(length - total));
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
