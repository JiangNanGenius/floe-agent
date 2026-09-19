// Host stub for the pinned ios_system engine symbols referenced by DashIOS.
//
// This is NOT ios_system. It exists so the real DashIOS sources — including
// the Floe interactive-stdin patch in src/input.c (basepf.fd = fileno(
// thread_stdin)) — can be built and exercised on the macOS host by
// FloeAgent/scripts/tests/run_feedback_dash_interactive_host.sh.
//
// ios_system declares thread_stdin/thread_stdout/thread_stderr as __thread
// (see ThirdParty/DashIOS/ios_error.h); the stub must match that storage class
// or the host binary mis-links the TLS references. The interactive test
// drives the shell through thread_stdin exactly like ios_system does on
// device: FLOE_DASH_STDIN_FD names the pipe read end to use as thread_stdin,
// while the process fd 0 stays whatever the harness gave it (usually
// /dev/null). A host build compiles the iOS branches with
// -DTARGET_OS_IPHONE=1 so the real patched INIT code is what runs.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/types.h>

__thread FILE *thread_stdin;
__thread FILE *thread_stdout;
__thread FILE *thread_stderr;
void *thread_context;

static char **empty_environment(void) {
    static char *empty[] = { NULL };
    return empty;
}

__attribute__((constructor)) static void floe_stub_set_streams(void) {
    const char *fd_text = getenv("FLOE_DASH_STDIN_FD");
    if (fd_text != NULL) {
        int fd = atoi(fd_text);
        if (fd >= 0) { thread_stdin = fdopen(fd, "r"); }
    }
    if (thread_stdin == NULL) { thread_stdin = stdin; }
    thread_stdout = stdout;
    thread_stderr = stderr;
}

char **environmentVariables(pid_t pid) { (void)pid; return empty_environment(); }
int ios_executable(const char *name) { (void)name; return 0; }
char *ios_getenv(const char *name) { (void)name; return NULL; }
int ios_isatty(int fd) { (void)fd; return 0; }
char *ios_expandtilde(const char *name) { return strdup(name); }
int ios_dup2(int oldfd, int newfd) { return dup2(oldfd, newfd); }
ssize_t ios_write(int fd, const void *buffer, size_t count) { return write(fd, buffer, count); }
void ios_activateChildStreams(FILE **old_in, FILE **old_out, FILE **old_err) { (void)old_in; (void)old_out; (void)old_err; }
void ios_stopInteractive(void) { }
pid_t ios_fork(void) { return getpid(); }
pid_t ios_currentPid(void) { return getpid(); }
int ios_waitpid(pid_t pid) { (void)pid; return 0; }
int ios_killpid(pid_t pid, int signal) { (void)pid; (void)signal; return -1; }
int ios_execv(const char *path, char *const argv[]) { (void)path; (void)argv; return -1; }
int ios_execve(const char *path, char *const argv[], char *const envp[]) { (void)path; (void)argv; (void)envp; return -1; }
void ios_exit(int status) { exit(status); }
int ios_getCommandStatus(void) { return 0; }
int ios_fflush(FILE *stream) { return fflush(stream); }
int ios_fputc(int c, FILE *stream) { return fputc(c, stream); }
int ios_fputs(const char *s, FILE *stream) { return fputs(s, stream); }
size_t ios_fwrite(const void *ptr, size_t size, size_t nmemb, FILE *stream) { return fwrite(ptr, size, nmemb, stream); }
