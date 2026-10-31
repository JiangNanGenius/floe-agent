// SPDX-License-Identifier: Apache-2.0
// Floe-authored stale-PID policy for the embedded ADB starter. See the header:
// Android erases the app_process argument block, so replacement is addressed by
// an exact PID the App verified through the binder describe identity.
#include "floe_starter_ownership.h"

#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

#include <cerrno>
#include <climits>
#include <csignal>
#include <cstdio>
#include <cstring>

namespace floe {

bool parse_pid(const std::string &value, pid_t &pid) {
    if (value.empty() || value.size() > 10) return false;
    long long parsed = 0;
    for (char c : value) {
        if (c < '0' || c > '9') return false;
        parsed = parsed * 10 + (c - '0');
        if (parsed > static_cast<long long>(INT_MAX)) return false;
    }
    if (parsed <= 1) return false;
    pid = static_cast<pid_t>(parsed);
    return true;
}

std::vector<std::string> split_cmdline(const char *data, size_t length) {
    std::vector<std::string> args;
    if (data == nullptr || length == 0 || length > kMaxCmdlineBytes) return args;
    if (data[length - 1] != '\0') return args;

    size_t start = 0;
    for (size_t i = 0; i < length; ++i) {
        if (data[i] != '\0') continue;
        if (i > start) {
            if (args.size() >= kMaxCmdlineArguments) {
                args.clear();
                return args;
            }
            args.emplace_back(data + start, i - start);
        }
        start = i + 1;
    }
    if (start != length) args.clear();
    return args;
}

bool is_replaceable_process_identity(pid_t pid, pid_t self_pid, uid_t uid,
                                     uid_t expected_uid,
                                     const std::vector<std::string> &args,
                                     const std::string &process_name) {
    if (pid <= 1 || pid == self_pid) return false;
    if (uid != expected_uid) return false;
    if (process_name.empty() || args.empty()) return false;
    // app_process --nice-name rewrites argv to exactly this single name, so
    // args[0] is the only stable token available for a PID-reuse check.
    return args[0] == process_name;
}

bool read_process_uid(pid_t pid, uid_t &uid) {
    char path[64];
    int written = snprintf(path, sizeof(path), "/proc/%ld", (long) pid);
    if (written <= 0 || static_cast<size_t>(written) >= sizeof(path)) return false;
    struct stat info {};
    if (stat(path, &info) != 0) return false;
    uid = info.st_uid;
    return true;
}

bool read_process_cmdline(pid_t pid, std::vector<std::string> &args) {
    char path[64];
    int written = snprintf(path, sizeof(path), "/proc/%ld/cmdline", (long) pid);
    if (written <= 0 || static_cast<size_t>(written) >= sizeof(path)) return false;

    int fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0) return false;
    char buffer[kMaxCmdlineBytes + 1];
    size_t used = 0;
    for (;;) {
        ssize_t read_size = read(fd, buffer + used, sizeof(buffer) - used);
        if (read_size < 0) {
            if (errno == EINTR) continue;
            close(fd);
            return false;
        }
        if (read_size == 0) break;
        used += static_cast<size_t>(read_size);
        if (used == sizeof(buffer)) break;
    }
    close(fd);
    if (used == 0 || used > kMaxCmdlineBytes) return false;
    args = split_cmdline(buffer, used);
    return !args.empty();
}

char process_state_from_stat(const char *data, size_t length) {
    if (data == nullptr || length == 0) return '\0';
    const char *end = data + length;
    const char *close = nullptr;
    for (const char *p = data; p < end; ++p) {
        if (*p == ')') close = p;
    }
    if (close == nullptr) return '\0';
    const char *p = close + 1;
    while (p < end && (*p == ' ' || *p == '\t')) ++p;
    if (p >= end) return '\0';
    return *p;
}

bool read_process_state(pid_t pid, char &state) {
    char path[64];
    int written = snprintf(path, sizeof(path), "/proc/%ld/stat", (long) pid);
    if (written <= 0 || static_cast<size_t>(written) >= sizeof(path)) return false;
    int fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0) return false;
    char buffer[1024];
    ssize_t size = read(fd, buffer, sizeof(buffer));
    close(fd);
    if (size <= 0) return false;
    state = process_state_from_stat(buffer, static_cast<size_t>(size));
    return state != '\0';
}

ReplacementResult replace_verified_process(pid_t pid, const std::string &process_name,
                                           uid_t expected_uid) {
    if (pid <= 1 || process_name.empty()) return ReplacementResult::not_owned;
    if (kill(pid, 0) != 0) {
        return errno == ESRCH ? ReplacementResult::already_gone
                              : ReplacementResult::failed;
    }
    uid_t uid = 0;
    std::vector<std::string> args;
    if (!read_process_uid(pid, uid)) return ReplacementResult::not_owned;
    if (!read_process_cmdline(pid, args) || args.empty()) {
        // A server that has already exited may linger as a zombie with an empty
        // cmdline until init reaps it; that is already stopped, not a conflict.
        char state = '\0';
        if (read_process_state(pid, state) && state == 'Z') {
            return ReplacementResult::already_gone;
        }
        return ReplacementResult::not_owned;
    }
    if (!is_replaceable_process_identity(pid, getpid(), uid, expected_uid, args,
                                         process_name)) {
        return ReplacementResult::not_owned;
    }
    if (kill(pid, SIGKILL) == 0) return ReplacementResult::replaced;
    return errno == ESRCH ? ReplacementResult::already_gone
                          : ReplacementResult::failed;
}

}  // namespace floe
