#include "gates.h"

#include "config.h"
#include "FakeSocket.hpp"

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstring>
#include <mutex>

namespace
{
struct Gate
{
    bool armed = false;
    bool entered = false;
    bool released = false;
};

std::mutex theGateMutex;
std::condition_variable theGateCV;
Gate theAfterPoll;
Gate theAfterAvailable;
Gate theBeforeRead;
std::atomic<long> thePollCount(0);

void holdOnce(Gate &gate)
{
    std::unique_lock<std::mutex> lock(theGateMutex);
    if (!gate.armed)
        return;
    gate.armed = false; // one-shot: later callers pass
    gate.entered = true;
    theGateCV.notify_all();
    theGateCV.wait(lock, [&] { return gate.released; });
}

void arm(Gate &gate)
{
    std::lock_guard<std::mutex> lock(theGateMutex);
    gate.armed = true;
    gate.entered = false;
    gate.released = false;
}

int waitEntered(Gate &gate, int timeoutMs)
{
    std::unique_lock<std::mutex> lock(theGateMutex);
    return theGateCV.wait_for(lock, std::chrono::milliseconds(timeoutMs),
                              [&] { return gate.entered; })
               ? 0
               : 1;
}

void release(Gate &gate)
{
    std::lock_guard<std::mutex> lock(theGateMutex);
    gate.released = true;
    theGateCV.notify_all();
}
}

extern "C" int floe_gate_poll(struct pollfd *fds, int nfds, int timeout)
{
    const int result = fakeSocketPoll(fds, nfds, timeout);
    thePollCount.fetch_add(1);
    holdOnce(theAfterPoll);
    return result;
}

extern "C" ssize_t floe_gate_available(int fd)
{
    const ssize_t result = fakeSocketAvailableDataLength(fd);
    holdOnce(theAfterAvailable);
    return result;
}

extern "C" ssize_t floe_gate_read(int fd, void *buf, size_t nbytes)
{
    holdOnce(theBeforeRead);
    return fakeSocketRead(fd, buf, nbytes);
}

void floeGateReset()
{
    std::lock_guard<std::mutex> lock(theGateMutex);
    theAfterPoll = Gate();
    theAfterAvailable = Gate();
    theBeforeRead = Gate();
    thePollCount.store(0);
}

void floeGateArm(const char *point)
{
    if (std::strcmp(point, "after_poll") == 0)
        arm(theAfterPoll);
    else if (std::strcmp(point, "after_available") == 0)
        arm(theAfterAvailable);
    else if (std::strcmp(point, "before_read") == 0)
        arm(theBeforeRead);
}

int floeGateWaitEntered(const char *point, int timeoutMs)
{
    if (std::strcmp(point, "after_poll") == 0)
        return waitEntered(theAfterPoll, timeoutMs);
    if (std::strcmp(point, "after_available") == 0)
        return waitEntered(theAfterAvailable, timeoutMs);
    if (std::strcmp(point, "before_read") == 0)
        return waitEntered(theBeforeRead, timeoutMs);
    return 1;
}

void floeGateRelease(const char *point)
{
    if (std::strcmp(point, "after_poll") == 0)
        release(theAfterPoll);
    else if (std::strcmp(point, "after_available") == 0)
        release(theAfterAvailable);
    else if (std::strcmp(point, "before_read") == 0)
        release(theBeforeRead);
}

long floeGatePollCount()
{
    return thePollCount.load();
}
