// SPDX-License-Identifier: Apache-2.0
// Adapted from RikkaApps/Shizuku manager/src/main/jni/starter.cpp at
// b844bc491f1790c72328e1a8e5b2349f8978f0ea.
//
// Modification record for Floe:
//  - only the ADB (shell UID 2000) mode is accepted; the root backend is
//    launched by the App through its existing libsu grant instead;
//  - package name, server class, process name, token, caller UID, signing
//    digest and app version are explicit validated arguments;
//  - the child receives a strict whitelist of arguments, never raw argv;
//  - app_process --nice-name rewrites the entire argument block, so a running
//    server's /proc/<pid>/cmdline contains only the nice name. This starter
//    therefore never scans /proc and never replaces by process name. The App
//    first verifies the old server through binder describe() (same package,
//    signing, protocol, ADB mode, server UID 2000 and exact PID) and asks it to
//    stop; only then may it pass that exact PID as --replace-pid. The starter
//    rechecks the PID's shell UID and current nice name before killing it, so
//    PID reuse cannot hit an unrelated process and other Floe variants,
//    Android users or an external manager are never touched;
//  - token values are never printed;
//  - the upstream cgroup/SELinux root-only startup path is intentionally not
//    copied: this executable refuses UID 0 instead of pretending to validate
//    a root superuser/binder policy that it does not own.
#include <cstdio>
#include <cstdlib>
#include <csignal>
#include <cstring>
#include <cerrno>
#include <climits>
#include <fcntl.h>
#include <unistd.h>
#include <string>
#include <vector>

#include "floe_starter_ownership.h"
#include "upstream/misc.h"

#define PACKAGE_NAME_DEFAULT "com.floe.agent"

#define EXIT_FATAL_CLASSPATH 3
#define EXIT_FATAL_FORK 4
#define EXIT_FATAL_APP_PROCESS 5
#define EXIT_FATAL_UID 6
#define EXIT_FATAL_PM_PATH 7
#define EXIT_FATAL_ARGUMENT 8
#define EXIT_FATAL_REPLACE 9

static bool is_hex(const char *value, size_t length) {
    if (strlen(value) != length) return false;
    for (size_t i = 0; i < length; ++i) {
        char c = value[i];
        if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'))) return false;
    }
    return true;
}

static bool is_digits(const char *value) {
    if (*value == '\0') return false;
    for (const char *p = value; *p; ++p) {
        if (*p < '0' || *p > '9') return false;
    }
    return true;
}

static bool is_package_name(const char *value) {
    size_t len = strlen(value);
    if (len < 3 || len > 127) return false;
    bool segment_start = true;
    int segments = 0;
    for (size_t i = 0; i < len; ++i) {
        char c = value[i];
        if (segment_start) {
            if (!((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z'))) return false;
            segment_start = false;
        } else if (c == '.') {
            segment_start = true;
            segments++;
        } else if (!((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') ||
                     (c >= '0' && c <= '9') || c == '_')) {
            return false;
        }
    }
    return !segment_start && segments >= 1;
}

static bool is_process_name(const char *value) {
    size_t len = strlen(value);
    if (len == 0 || len > 64) return false;
    for (size_t i = 0; i < len; ++i) {
        char c = value[i];
        if (!((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') ||
              (c >= '0' && c <= '9') || c == '_' || c == '.')) {
            return false;
        }
    }
    return true;
}

static bool is_server_class(const char *value) {
    size_t len = strlen(value);
    if (len < 3 || len > 200) return false;
    for (size_t i = 0; i < len; ++i) {
        char c = value[i];
        if (!((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') ||
              (c >= '0' && c <= '9') || c == '_' || c == '.')) {
            return false;
        }
    }
    return true;
}

static bool is_absolute_safe_path(const char *value) {
    size_t len = strlen(value);
    if (len < 2 || len > PATH_MAX - 1 || value[0] != '/') return false;
    for (size_t i = 0; i < len; ++i) {
        if (value[i] == '\n' || value[i] == '\r' || value[i] == '\0') return false;
    }
    return true;
}

static std::string arg_value(int argc, char *argv[], const char *prefix) {
    size_t prefix_len = strlen(prefix);
    for (int i = 1; i < argc; ++i) {
        if (strncmp(argv[i], prefix, prefix_len) == 0) {
            return std::string(argv[i] + prefix_len);
        }
    }
    return std::string();
}

// Replacement is addressed by the exact PID the App verified through the
// server's binder describe() identity. This function never scans /proc.
static void replace_verified_stale_server(pid_t pid, const char *process_name) {
    switch (floe::replace_verified_process(pid, process_name, 2000)) {
        case floe::ReplacementResult::replaced:
            printf("info: replaced verified stale service %d\n", pid);
            break;
        case floe::ReplacementResult::already_gone:
            printf("info: verified stale service %d already exited\n", pid);
            break;
        case floe::ReplacementResult::not_owned:
            fprintf(stderr,
                    "fatal: stale service PID %d is not the verified Floe service\n",
                    pid);
            exit(EXIT_FATAL_REPLACE);
        case floe::ReplacementResult::failed:
            fprintf(stderr, "fatal: cannot replace verified stale service %d\n", pid);
            exit(EXIT_FATAL_REPLACE);
    }
}

static std::string resolve_apk(const std::string &provided, const char *package_name) {
    if (!provided.empty() && access(provided.c_str(), R_OK) == 0) return provided;
    if (!is_package_name(package_name)) return std::string();

    std::string command = "/system/bin/pm path ";
    command += package_name;
    FILE *pipe = popen(command.c_str(), "r");
    if (!pipe) return std::string();
    char line[PATH_MAX]{0};
    std::string result;
    while (fgets(line, sizeof(line), pipe) != nullptr) {
        trim(line);
        if (strncmp(line, "package:", 8) == 0) {
            result = std::string(line + 8);
            break;
        }
    }
    pclose(pipe);
    return result;
}

static void run_server(const std::string &apk_path, const char *server_class,
                       const char *process_name, int argc, char *argv[]) {
    char classpath[PATH_MAX];
    snprintf(classpath, sizeof(classpath), "%s", apk_path.c_str());
    if (setenv("CLASSPATH", classpath, 1) != 0) {
        fprintf(stderr, "fatal: cannot set CLASSPATH\n");
        exit(EXIT_FATAL_CLASSPATH);
    }

    std::vector<std::string> args;
    args.emplace_back("/system/bin/app_process");
    args.emplace_back("-Djava.class.path=" + apk_path);
    args.emplace_back("/system/bin");
    args.emplace_back(std::string("--nice-name=") + process_name);
    args.emplace_back(server_class);
    args.emplace_back("--mode=adb");
    args.emplace_back("--apk=" + apk_path);
    for (const char *key : {"--package=", "--token=", "--caller-uid=",
                            "--signing-sha256=", "--app-version="}) {
        std::string value = arg_value(argc, argv, key);
        if (!value.empty()) args.push_back(std::string(key) + value);
    }

    std::vector<char *> raw;
    raw.reserve(args.size() + 1);
    for (auto &arg : args) raw.push_back(const_cast<char *>(arg.c_str()));
    raw.push_back(nullptr);

    execv(raw[0], raw.data());
    fprintf(stderr, "fatal: app_process exec failed: %s\n", strerror(errno));
    exit(EXIT_FATAL_APP_PROCESS);
}

static void start_server(const std::string &apk_path, const char *server_class,
                         const char *process_name, int argc, char *argv[]) {
    pid_t pid = fork();
    switch (pid) {
        case -1:
            fprintf(stderr, "fatal: cannot fork\n");
            exit(EXIT_FATAL_FORK);
        case 0: {
            setsid();
            chdir("/");
            int fd = open("/dev/null", O_RDWR);
            if (fd != -1) {
                dup2(fd, STDIN_FILENO);
                dup2(fd, STDOUT_FILENO);
                dup2(fd, STDERR_FILENO);
                if (fd > 2) close(fd);
            }
            run_server(apk_path, server_class, process_name, argc, argv);
        }
        default:
            printf("info: %s pid is %d\n", process_name, pid);
            printf("info: floe_starter exit with 0\n");
            fflush(stdout);
            exit(EXIT_SUCCESS);
    }
}

int main(int argc, char *argv[]) {
    uid_t uid = getuid();
    if (uid != 2000) {
        fprintf(stderr, "fatal: embedded ADB starter requires the shell UID (uid=%d)\n", uid);
        return EXIT_FATAL_UID;
    }

    std::string apk_arg = arg_value(argc, argv, "--apk=");
    std::string package = arg_value(argc, argv, "--package=");
    if (package.empty()) package = PACKAGE_NAME_DEFAULT;
    std::string token = arg_value(argc, argv, "--token=");
    std::string caller_uid = arg_value(argc, argv, "--caller-uid=");
    std::string signing = arg_value(argc, argv, "--signing-sha256=");
    std::string version = arg_value(argc, argv, "--app-version=");
    std::string server_class = arg_value(argc, argv, "--server-class=");
    std::string process_name = arg_value(argc, argv, "--process-name=");
    std::string mode = arg_value(argc, argv, "--mode=");
    std::string replace_pid_arg = arg_value(argc, argv, "--replace-pid=");
    pid_t replace_pid = -1;

    if (!is_package_name(package.c_str())) {
        fprintf(stderr, "fatal: invalid package argument\n");
        return EXIT_FATAL_ARGUMENT;
    }
    if (!is_hex(token.c_str(), 64)) {
        fprintf(stderr, "fatal: invalid launch token\n");
        return EXIT_FATAL_ARGUMENT;
    }
    if (!is_digits(caller_uid.c_str()) || atoi(caller_uid.c_str()) <= 0) {
        fprintf(stderr, "fatal: invalid caller uid\n");
        return EXIT_FATAL_ARGUMENT;
    }
    if (!is_hex(signing.c_str(), 64)) {
        fprintf(stderr, "fatal: invalid signing digest\n");
        return EXIT_FATAL_ARGUMENT;
    }
    if (!is_digits(version.c_str()) || atoll(version.c_str()) <= 0) {
        fprintf(stderr, "fatal: invalid app version\n");
        return EXIT_FATAL_ARGUMENT;
    }
    if (!is_server_class(server_class.c_str())) {
        fprintf(stderr, "fatal: invalid server class\n");
        return EXIT_FATAL_ARGUMENT;
    }
    if (!is_process_name(process_name.c_str())) {
        fprintf(stderr, "fatal: invalid process name\n");
        return EXIT_FATAL_ARGUMENT;
    }
    // Fixed Floe ADB process identity; the root backend has a separate name and
    // never goes through this starter.
    if (process_name != "floe_adb_server") {
        fprintf(stderr, "fatal: unexpected process name\n");
        return EXIT_FATAL_ARGUMENT;
    }
    // This executable only implements the ADB (shell UID 2000) backend. Root
    // is launched separately through the App's existing libsu grant.
    if (mode != "adb") {
        fprintf(stderr, "fatal: invalid starter mode\n");
        return EXIT_FATAL_ARGUMENT;
    }
    if (!replace_pid_arg.empty() && !floe::parse_pid(replace_pid_arg, replace_pid)) {
        fprintf(stderr, "fatal: invalid replace pid\n");
        return EXIT_FATAL_ARGUMENT;
    }
    if (!apk_arg.empty() && !is_absolute_safe_path(apk_arg.c_str())) {
        fprintf(stderr, "fatal: invalid apk path\n");
        return EXIT_FATAL_ARGUMENT;
    }

    std::string apk_path = resolve_apk(apk_arg, package.c_str());
    if (apk_path.empty() || !is_absolute_safe_path(apk_path.c_str()) ||
        access(apk_path.c_str(), R_OK) != 0) {
        fprintf(stderr, "fatal: cannot resolve the Floe APK\n");
        return EXIT_FATAL_PM_PATH;
    }

    // Only the exact PID the App verified through binder describe() can be
    // replaced. There is no scan for a process name.
    if (replace_pid > 1) {
        replace_verified_stale_server(replace_pid, process_name.c_str());
    }
    printf("info: starting embedded ADB service\n");
    fflush(stdout);

    // Note: the child receives validated arguments only; argv[0..] is not forwarded.
    start_server(apk_path, server_class.c_str(), process_name.c_str(), argc, argv);
    return EXIT_SUCCESS;
}
