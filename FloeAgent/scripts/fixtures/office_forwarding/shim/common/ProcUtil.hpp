// Harness shim for the pinned upstream <common/ProcUtil.hpp>. Only the two
// entry points used by net/FakeSocket.cpp and the forwarding loop are
// provided; behavior is a no-op thread label plus a numeric thread id.
#pragma once

#include <pthread.h>
#include <sstream>
#include <string>

namespace ProcUtil
{
inline void setThreadName(const char *) {}
inline std::string getThreadId()
{
    std::ostringstream ss;
    ss << pthread_mach_thread_np(pthread_self());
    return ss.str();
}
}
