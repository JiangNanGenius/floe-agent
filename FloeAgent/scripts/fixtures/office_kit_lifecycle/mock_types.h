// Labeled mock substrate for the pinned 27b21dc1 kit-side poll and callback
// lifetime logic. Only the code under test is production-extracted by
// test_office_kit_lifecycle.py (KitSocketPoll::pushToMainThread from
// kit/Kit.cpp and SocketPoll::addCallback from net/Socket.hpp); every other
// declaration here is a labeled mock, so this harness is not an engine,
// render, cloud or device reproduction.
#pragma once

#include <algorithm>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstring>
#include <deque>
#include <functional>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

namespace mock {

// ---- COKit ABI surface (pinned engine/include/COKit/COKit.h) ----------------
enum class COKitCallbackType : std::int32_t
{
    INVALIDATE_TILES = 0,
    STATUS_INDICATOR_START = 1,
    STATE_CHANGED = 2,
};
typedef void (*COKitCallback)(COKitCallbackType type, const char* payload, void* data);

// ---- ProcUtil (pinned common/ProcUtil.hpp: ThreadId is long) ----------------
struct ProcUtil
{
    using ThreadId = long;
    static ThreadId getThreadId()
    {
        thread_local ThreadId id = nextId();
        return id;
    }
    static ThreadId nextId()
    {
        static std::atomic<long> n{1};
        return n++;
    }
};

// ---- Explicit cross-thread overlap handshake (labeled mock) -----------------
// Replaces timing-based "park 30 ms and hope a concurrent partner arrives"
// overlap detection. The kit thread ARMS once it is parked inside document
// work and stays parked (bounded) until either a foreign-thread delivery
// arrives (a real overlap, counted exactly once) or the driver declares the
// firing window complete (serialized/queued path: no foreign delivery can meet
// it, so the wait ends with zero overlaps instead of a scheduler gamble).
struct OverlapGate
{
    std::mutex mutex;
    std::condition_variable cv;
    bool armed = false;     // kit thread is parked inside document work
    bool partner = false;   // a foreign-thread session delivery arrived
    bool fired = false;     // driver finished pushing/firing callbacks
    bool released = false;  // meeting (or the empty window) is closed
    int meetings = 0;

    // Kit side: arm the window, signal parked, and wait bounded for a foreign
    // partner or for end-of-firing. Exactly one meeting is recorded.
    void armAndWait(std::chrono::milliseconds bound)
    {
        std::unique_lock<std::mutex> lk(mutex);
        armed = true;
        partner = false;
        fired = false;
        released = false;
        cv.notify_all();
        cv.wait_for(lk, bound, [&] { return partner || fired; });
        if (partner)
            ++meetings;
        armed = false;
        released = true;
        cv.notify_all();
    }
    // Driver side: block bounded until the kit thread has armed/parked.
    bool waitParked(std::chrono::milliseconds bound)
    {
        std::unique_lock<std::mutex> lk(mutex);
        return cv.wait_for(lk, bound, [&] { return armed; });
    }
    // Foreign-thread delivery side: enter only while armed, then block bounded
    // until the kit side closes the meeting. Same-thread (kit) callers must
    // never enter: serialized delivery cannot overlap itself.
    void partnerArrive(std::chrono::milliseconds bound)
    {
        std::unique_lock<std::mutex> lk(mutex);
        if (!armed)
            return;
        partner = true;
        cv.notify_all();
        cv.wait_for(lk, bound, [&] { return released; });
    }
    // Driver side: the callback firing window is over.
    void firingComplete()
    {
        std::lock_guard<std::mutex> lk(mutex);
        fired = true;
        cv.notify_all();
    }
    // Driver side: wait until the kit side has left the parked window.
    bool waitReleased(std::chrono::milliseconds bound)
    {
        std::unique_lock<std::mutex> lk(mutex);
        return cv.wait_for(lk, bound, [&] { return released; });
    }
};

// ---- Overlap/thread evidence collected by the harness -----------------------
struct Evidence
{
    std::atomic<int> callbackBodies{0};  // Document callback body executions
    std::atomic<int> callbacksOnKitThread{0};
    std::atomic<int> callbacksOnForeignThread{0};
    std::atomic<int> callbacksInlineOnAppMain{0};
    // The production drop paths log instead of running the body; the mock
    // LOG_* macros route exactly those statements to counters.
    std::atomic<int> dropLogs{0};              // LOG_DBG "poll is gone"
    std::atomic<int> unresolvableDropLogs{0};  // LOG_ERR "unresolvable document"
    // Handshake-proven concurrent meetings (OverlapGate::meetings, mirrored).
    std::atomic<int> overlaps{0};
    std::atomic<int> pendingDroppedWithPoll{0};
    // Count of poll-service turns that actually invoked >=1 queued callback
    // (mock-only drain accounting; lets a scenario prove callbacks crossed
    // more than one drain batch rather than a single swapped turn).
    std::atomic<int> nonemptyDrains{0};
    ProcUtil::ThreadId kitThread{0};
    ProcUtil::ThreadId appMainThread{0};
    // Set only by the scenario that arms an explicit overlap window (S2).
    OverlapGate* overlapGate = nullptr;
    // Bounded completion rendezvous: signaled after every callback body runs,
    // so a scenario waits for the intended work instead of sleeping a fixed
    // window and hoping the scheduler drained the queue in time.
    std::mutex completionMutex;
    std::condition_variable completionCv;
    void bumpBodies()
    {
        {
            std::lock_guard<std::mutex> lk(completionMutex);
            callbackBodies.fetch_add(1, std::memory_order_relaxed);
        }
        completionCv.notify_all();
    }
    // Wait until callbackBodies >= target or the bound elapses. Returns true
    // iff the target was reached; never waits past an explicit bounded time.
    bool waitForBodies(int target, std::chrono::milliseconds bound)
    {
        std::unique_lock<std::mutex> lk(completionMutex);
        return completionCv.wait_for(lk, bound, [&] {
            return callbackBodies.load(std::memory_order_acquire) >= target;
        });
    }
    // Bounded rendezvous on nonempty drain batches (mock-only accounting).
    std::mutex drainMutex;
    std::condition_variable drainCv;
    void bumpDrain()
    {
        {
            std::lock_guard<std::mutex> lk(drainMutex);
            nonemptyDrains.fetch_add(1, std::memory_order_relaxed);
        }
        drainCv.notify_all();
    }
    bool waitForDrains(int target, std::chrono::milliseconds bound)
    {
        std::unique_lock<std::mutex> lk(drainMutex);
        return drainCv.wait_for(lk, bound, [&] {
            return nonemptyDrains.load(std::memory_order_acquire) >= target;
        });
    }
};
extern Evidence g_ev;

// The production logging macros are mocked: LOG_TRC is discarded, and the two
// drop paths increment counters so the harness can observe that the callback
// was dropped rather than executed on a foreign thread.
#define LOG_TRC(x) ((void)0)
#define LOG_DBG(x) (void)(++mock::g_ev.dropLogs)
#define LOG_ERR(x) (void)(++mock::g_ev.unresolvableDropLogs)

// ---- ChildSession (pinned kit/ChildSession.hpp, behavior mocked) ------------
struct ChildSession
{
    bool _closeFrame = false;
    int _viewId = 0;
    bool isCloseFrame() const { return _closeFrame; }
    int getViewId() const { return _viewId; }
    // Stands in for ChildSession::loKitCallback -> sendTextFrame ->
    // WebSocketHandler::sendMessage: kit-thread-affined, unsynchronized.
    void loKitCallback(COKitCallbackType eType, const std::string& payload);
};

// ---- Document (pinned kit/Kit.hpp class Document, state mocked) -------------
struct Document
{
    std::map<int, std::shared_ptr<ChildSession>> _sessions;
    unsigned _mobileAppDocId;
    explicit Document(unsigned id) : _mobileAppDocId(id) {}
    unsigned getMobileAppDocId() const { return _mobileAppDocId; }
    // The two registered callback entry points. Their signatures and
    // push-first control flow mirror pinned kit/Kit.cpp Document::GlobalCallback
    // and Document::ViewCallback; the bodies (mock) only broadcast to sessions.
    static void GlobalCallback(COKitCallbackType eType, const char* p, void* data);
    static void ViewCallback(COKitCallbackType eType, const char* p, void* data);
};

// ---- CallbackDescriptor (pinned kit/Kit.hpp:60-80) ---------------------------
struct CallbackDescriptor
{
    Document* _doc;
    int _viewId;
    CallbackDescriptor(Document* doc, int viewId) : _doc(doc), _viewId(viewId) {}
    Document* getDoc() const { return _doc; }
    int getViewId() const { return _viewId; }
};

// ---- SocketPoll (pinned net/Socket.hpp:1054 + net/Socket.cpp) ---------------
// The addCallback definition is mechanically extracted from pinned
// net/Socket.hpp into add_callback.inc.h by the test. The drain sequence
// mirrors pinned SocketPoll::poll's checkAndReThread + swap-under-lock-then-
// invoke-unlocked order; the poll's queued callbacks die with it.
struct SocketPoll
{
    using CallbackFn = std::function<void()>;

    std::mutex _mutex;
    std::vector<CallbackFn> _newCallbacks;
    std::atomic<bool> _runOnClientThread{true}; // kit polls set this (Kit.cpp:4577)
    ProcUtil::ThreadId _owner;
    bool _dead = false;
    std::atomic<bool> serviceEnabled{true}; // harness gate: models "not yet serviced"

    SocketPoll() : _owner(ProcUtil::getThreadId()) {}
    virtual ~SocketPoll()
    {
        // Queued callbacks are owned by the poll's queue and die with it,
        // never executed afterwards (pinned net/Socket.cpp:364
        // SocketPoll::~SocketPoll; stop() clearing at net/Socket.cpp:844-850).
        _dead = true;
        g_ev.pendingDroppedWithPoll += static_cast<int>(_newCallbacks.size());
    }

    bool isAlive() const { return _runOnClientThread; } // net/Socket.hpp:865

    ProcUtil::ThreadId getThreadOwner() const { return _owner; } // net/Socket.hpp:388

    // Mechanical extraction of pinned net/Socket.hpp addCallback.
#include "add_callback.inc.h"

    void wakeup() {} // labeled mock (pinned wakeup writes the wakeup pipe)
    bool taskQueuesEmpty() const { return _newCallbacks.empty(); } // mock: callbacks only

    // Mirrors pinned SocketPoll::poll: checkAndReThread first
    // (net/Socket.cpp:517-519 -> 376-386, the poll adopts its servicing
    // thread), then swap under lock and invoke unlocked with each callback
    // exception-contained (net/Socket.cpp:627-653).
    void drainCallbacksOnPollThread()
    {
        if (!serviceEnabled.load())
            return;
        // checkAndReThread: the poll adopts the thread that services it.
        _owner = ProcUtil::getThreadId();

        std::vector<CallbackFn> invoke;
        {
            std::lock_guard<std::mutex> lock(_mutex);
            std::swap(_newCallbacks, invoke);
        }
        if (!invoke.empty())
            g_ev.bumpDrain();
        for (const auto& callback : invoke)
        {
            try
            {
                callback();
            }
            catch (const std::exception&)
            {
            }
        }
    }

    bool hasPending() const
    {
        std::lock_guard<std::mutex> lock(const_cast<std::mutex&>(_mutex));
        return !_newCallbacks.empty();
    }
};

// ---- KitSocketPoll (pinned kit/Kit.hpp:143-216 and kit/Kit.cpp) --------------
// The ctor/dtor mainPoll statements are the pinned 27b21dc1 lines; the
// termination/poll machinery is mocked away. create() carries the pinned
// registry insert. pushToMainThread is extracted from the variant's Kit.cpp.
struct KitSocketPoll final : public SocketPoll
{
    std::shared_ptr<Document> _document;

    static KitSocketPoll* mainPoll;
    static std::mutex KSPollsMutex;
    static std::condition_variable KSPollsCV;
    static std::vector<std::weak_ptr<KitSocketPoll>> KSPolls;
    // v3 only: stable shared servicing-thread identity (Kit.hpp addition).
    static std::atomic<ProcUtil::ThreadId> kitThreadId;

    KitSocketPoll() : SocketPoll()
    {
        mainPoll = this; // pinned kit/Kit.cpp:3202-3214
    }

    ~KitSocketPoll()
    {
        // Just to make it easier to set a breakpoint
        mainPoll = nullptr; // pinned kit/Kit.cpp:3202-3214 (unconditional clear)
    }

    void setDocument(std::shared_ptr<Document> document) { _document = std::move(document); }
    const std::shared_ptr<Document>& getDocument() const { return _document; }

    // Pinned kit/Kit.cpp:3259-3274 registry insert on create.
    static std::shared_ptr<KitSocketPoll> create()
    {
        std::shared_ptr<KitSocketPoll> result(new KitSocketPoll());
        {
            std::unique_lock<std::mutex> lock(KSPollsMutex);
            KSPolls.push_back(result);
        }
        KitSocketPoll::KSPollsCV.notify_all();
        return result;
    }

    // The function under test; extracted verbatim from the variant source.
    static bool pushToMainThread(COKitCallback callback, COKitCallbackType eType,
                                 const char* p, void* data);
};

// Verbatim pinned kit/Kit.cpp:3412-3417 (free-function shim used by Document).
bool pushToMainThread(COKitCallback cb, COKitCallbackType eType, const char* p, void* data);

} // namespace mock
