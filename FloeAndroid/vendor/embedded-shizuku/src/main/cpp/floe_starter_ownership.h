// SPDX-License-Identifier: Apache-2.0
// Floe-authored stale-PID policy for the embedded ADB starter.
//
// Android's app_process rewrites the entire argv block when it applies
// --nice-name: AndroidRuntime::setArgv0() memsets the whole block and writes
// only the nice name. Therefore /proc/<pid>/cmdline for a running Floe server
// contains only "floe_adb_server"; it does not contain the package, caller UID,
// server class or token. A command-line identity match is impossible and a
// process-name scan is not ownership.
//
// Replacement is instead driven by the App's verified binder identity: the App
// calls describe() on the existing binder, requires the same package, signing,
// protocol and ADB mode with server UID 2000 and the exact published PID, then
// asks that server to stop. Only if that exact PID is still present may the App
// pass it as --replace-pid. This module rechecks only that PID's current shell
// UID and nice-name before killing it, so PID reuse cannot hit an unrelated
// process. There is no /proc scan, no name-only selection, no pkill/killall.
#ifndef FLOE_STARTER_OWNERSHIP_H
#define FLOE_STARTER_OWNERSHIP_H

#include <sys/types.h>

#include <string>
#include <vector>

namespace floe {

constexpr size_t kMaxCmdlineBytes = 4096;
constexpr size_t kMaxCmdlineArguments = 16;

enum class ReplacementResult {
    replaced,
    already_gone,
    not_owned,
    failed,
};

// Strict decimal PID parser: only 2..2^31-1 are accepted.
bool parse_pid(const std::string &value, pid_t &pid);

// Split a NUL-separated /proc/<pid>/cmdline buffer. Empty fields are skipped.
// An empty, unterminated or oversized buffer yields an empty vector.
std::vector<std::string> split_cmdline(const char *data, size_t length);

// Pure stale-PID sanity policy. `args` is the candidate's current cmdline,
// which on Android contains only the nice name. Ownership of the PID comes from
// the App's verified binder describe result, not from this name; this function
// only rejects self, PID <= 1, non-shell UID and a reused PID whose current
// process name no longer matches the fixed Floe ADB server name.
bool is_replaceable_process_identity(pid_t pid, pid_t self_pid, uid_t uid,
                                     uid_t expected_uid,
                                     const std::vector<std::string> &args,
                                     const std::string &process_name);

bool read_process_uid(pid_t pid, uid_t &uid);
bool read_process_cmdline(pid_t pid, std::vector<std::string> &args);

// Extract the process state character from /proc/<pid>/stat. The comm field may
// contain spaces and parentheses, so the last ')' delimits it.
char process_state_from_stat(const char *data, size_t length);
bool read_process_state(pid_t pid, char &state);

// Recheck the exact PID and replace it. The caller must already have verified
// the PID through the binder describe identity and must not use this to scan
// for processes.
ReplacementResult replace_verified_process(pid_t pid, const std::string &process_name,
                                           uid_t expected_uid);

}  // namespace floe

#endif  // FLOE_STARTER_OWNERSHIP_H
