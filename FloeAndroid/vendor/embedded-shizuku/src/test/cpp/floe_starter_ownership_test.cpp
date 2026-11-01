// SPDX-License-Identifier: Apache-2.0
// Host-side unit test for the Floe-owned stale-PID policy. It links the same
// floe_starter_ownership.cpp compiled into libfloe_starter.so. The tests model
// the real Android command-line shape: app_process setArgv0() memsets the whole
// argument block, so a running server's /proc/<pid>/cmdline contains only the
// nice name. Ownership of a stale PID therefore comes from the App's verified
// binder describe identity, and this policy only rechecks the exact PID's shell
// UID and current process name before a kill.
#include "floe_starter_ownership.h"

#include <cstdio>
#include <string>
#include <vector>

namespace {

int failures = 0;
int checks = 0;

void check(bool condition, const char *name) {
    ++checks;
    if (condition) {
        printf("ok %d - %s\n", checks, name);
    } else {
        printf("not ok %d - %s\n", checks, name);
        ++failures;
    }
}

std::vector<std::string> nice_name_only_cmdline() {
    // The actual /proc/<pid>/cmdline of app_process --nice-name: one token.
    return {"floe_adb_server"};
}

void test_pid_parser() {
    pid_t pid = -1;
    check(floe::parse_pid("1234", pid) && pid == 1234,
          "decimal PID is parsed");
    check(!floe::parse_pid("", pid), "empty PID is rejected");
    check(!floe::parse_pid("0", pid), "PID 0 is rejected");
    check(!floe::parse_pid("1", pid), "PID 1 is rejected");
    check(!floe::parse_pid("-2", pid), "negative PID is rejected");
    check(!floe::parse_pid("+2", pid), "signed PID is rejected");
    check(!floe::parse_pid("12a", pid), "non-decimal PID is rejected");
    check(!floe::parse_pid("99999999999", pid), "overflowing PID is rejected");
}

void test_actual_nice_name_only_identity() {
    const auto args = nice_name_only_cmdline();
    check(args.size() == 1 && args[0] == "floe_adb_server",
          "actual app_process nice-name cmdline has only the process name");
    check(floe::is_replaceable_process_identity(
                  1234, 999, 2000, 2000, args, "floe_adb_server"),
          "exact verified PID with shell UID and nice name is replaceable");
    check(floe::is_replaceable_process_identity(
                  1234, 999, 2000, 2000, {"floe_adb_server", "--old"}, "floe_adb_server"),
          "extra erased/current tokens do not weaken the exact-PID check");
}

void test_rejects_self_wrong_uid_and_wrong_name() {
    const auto args = nice_name_only_cmdline();
    check(!floe::is_replaceable_process_identity(
                  1234, 1234, 2000, 2000, args, "floe_adb_server"),
          "the starter never replaces itself");
    check(!floe::is_replaceable_process_identity(
                  1234, 999, 1000, 2000, args, "floe_adb_server"),
          "a non-shell candidate UID is rejected");
    check(!floe::is_replaceable_process_identity(
                  1234, 999, 2000, 2000, {"shizuku_server"}, "floe_adb_server"),
          "another manager process name is rejected");
    check(!floe::is_replaceable_process_identity(
                  1234, 999, 2000, 2000, {}, "floe_adb_server"),
          "an unreadable/empty cmdline is rejected");
    check(!floe::is_replaceable_process_identity(
                  1, 999, 2000, 2000, args, "floe_adb_server"),
          "PID 1 is never replaceable");
    check(!floe::is_replaceable_process_identity(
                  0, 999, 2000, 2000, args, "floe_adb_server"),
          "PID 0 is never replaceable");
}

void test_cmdline_split() {
    {
        const char raw[] = {'f', 'l', 'o', 'e', '_', 'a', 'd', 'b', '_',
                            's', 'e', 'r', 'v', 'e', 'r', 0};
        auto args = floe::split_cmdline(raw, sizeof(raw));
        check(args.size() == 1 && args[0] == "floe_adb_server",
              "actual nice-name-only cmdline is a single token");
    }
    {
        const char raw[] = {'a', 0, 'b', 0, 0};
        auto args = floe::split_cmdline(raw, sizeof(raw));
        check(args.size() == 2 && args[0] == "a" && args[1] == "b",
              "NUL separated cmdline is split and empty fields skipped");
    }
    {
        const char raw[] = {'a', 'b'};
        check(floe::split_cmdline(raw, sizeof(raw)).empty(),
              "non-terminated cmdline is rejected");
    }
}

void test_process_state() {
    const char running[] = "1234 (floe_adb_server) S 1 1234 0 0 -1";
    check(floe::process_state_from_stat(running, sizeof(running) - 1) == 'S',
          "running process state is parsed");
    const char zombie[] = "1234 (floe_adb_server) Z 1 1234 0 0 -1";
    check(floe::process_state_from_stat(zombie, sizeof(zombie) - 1) == 'Z',
          "zombie process state is parsed");
    const char paren[] = "1234 (a) b) R 1 1234 0 0 -1";
    check(floe::process_state_from_stat(paren, sizeof(paren) - 1) == 'R',
          "parentheses in comm do not confuse the state parser");
    check(floe::process_state_from_stat("", 0) == '\0',
          "empty stat buffer has no state");
}

}  // namespace

int main() {
    test_pid_parser();
    test_actual_nice_name_only_identity();
    test_rejects_self_wrong_uid_and_wrong_name();
    test_cmdline_split();
    test_process_state();
    if (failures == 0) {
        printf("PASS %d/%d stale-PID policy checks\n", checks, checks);
        return 0;
    }
    printf("FAIL %d/%d stale-PID policy checks\n", failures, checks);
    return 1;
}
