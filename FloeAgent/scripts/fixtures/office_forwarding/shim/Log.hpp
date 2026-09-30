// Harness shim for the pinned upstream "Log.hpp" macro surface used by the
// extracted forwarding code: LOG_ERR (stream expression). LOG_TRC/LOG_DBG are
// compiled out. Errors are counted and echoed so scenario assertions can
// prove the patched code logged and retired instead of crashing.
#pragma once

#include <sstream>
#include <string>

void floeHarnessLogError(const std::string &line);
int floeHarnessErrorLogCount();
void floeHarnessResetErrorLog();

#define LOG_ERR(arg)                                                        \
    do {                                                                    \
        std::ostringstream floeLogStream;                                   \
        floeLogStream << arg;                                               \
        floeHarnessLogError(floeLogStream.str());                           \
    } while (false)

#define LOG_TRC(arg) do { } while (false)
#define LOG_DBG(arg) do { } while (false)
