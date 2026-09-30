// Deterministic driver for the extracted pinned poll/callback lifetime logic
// (test_office_kit_lifecycle.py). Thread roles mirror the production iOS
// model:
//   app-main  = this main thread (VCL main: CallbackFlushHandler::invoke site)
//   kit       = the one lokit_runloop servicing thread (pollCallback site);
//               polls adopt it as owner via checkAndReThread on first service,
//               and pollCallback records it as the shared kitThreadId
//   poll owner= creator threads (lokit_main_N construction site)
// The callback entry points and session work below are labeled mocks; the
// push/queue decision and the poll queue are the extracted production logic.
//
// Completion discipline: a scenario NEVER treats a fixed sleep window as
// completion. The kit start is released through an explicit one-shot gate and
// the driver waits on bounded condition-variable rendezvous for the intended
// callback bodies / drain batches before stopping the kit thread, so the
// result is independent of when the OS schedules the kit thread (the cloud
// runner may delay its first service by well over the old 85 ms window).
//
// The intentional original-variant cross-thread overlap (S2) is proven by an
// explicit bounded release/ack handshake (OverlapGate), not by two 30 ms parks
// crossing by luck: the kit thread parks inside a unit of document work, a
// foreign-thread (app-main) session delivery meets it exactly once, and the
// serialized patched path (delivery only on the kit thread) can never enter
// the partner side, so it ends the window with zero overlaps deterministically.
//
// S9 forces a delayed first service with a hard gate and proves the old
// timing-as-completion STOP loses the queued work, then shows the corrected
// bounded rendezvous drains the held batch plus two later batches, each in its
// own service turn, exactly once on the kit thread.
#include "extracted.h"
#include <cstdio>

static constexpr auto HANDSHAKE_BOUND = std::chrono::milliseconds(10000);
static constexpr auto KIT_WAIT = std::chrono::milliseconds(10000);

namespace mock {

Evidence g_ev;

// Pinned kit/Kit.cpp:3419-3431 static definitions.
KitSocketPoll* KitSocketPoll::mainPoll = nullptr;
std::mutex KitSocketPoll::KSPollsMutex;
std::condition_variable KitSocketPoll::KSPollsCV;
std::vector<std::weak_ptr<KitSocketPoll>> KitSocketPoll::KSPolls;
std::atomic<ProcUtil::ThreadId> KitSocketPoll::kitThreadId{0};

// Verbatim pinned kit/Kit.cpp:3412-3417 (free-function shim used by Document).
bool pushToMainThread(COKitCallback cb, COKitCallbackType eType, const char* p, void* data)
{
    return KitSocketPoll::pushToMainThread(cb, eType, p, data);
}

// The one shared kit servicing thread, recorded exactly where the patched
// pollCallback records it (extraction is a comment for the original variant,
// which has no shared-thread identity).
void recordKitThreadIdentity()
{
#include "kit_identity.inc.h"
}

// Mock bodies of the two registered callback entry points. The push-first
// control flow mirrors pinned kit/Kit.cpp Document::GlobalCallback (including
// the STATUS_INDICATOR all-session broadcast) and Document::ViewCallback (the
// descriptor's document and view); the engine/kit session work is mocked.
/* static */ void Document::GlobalCallback(COKitCallbackType eType, const char* p, void* data)
{
    if (pushToMainThread(GlobalCallback, eType, p, data))
        return;

    const std::string payload = p ? p : "(nil)";
    Document* self = static_cast<Document*>(data);

    g_ev.bumpBodies();
    for (auto& it : self->_sessions)
    {
        const std::shared_ptr<ChildSession>& session = it.second;
        if (!session->isCloseFrame())
            session->loKitCallback(eType, payload);
    }
}

/* static */ void Document::ViewCallback(COKitCallbackType eType, const char* p, void* data)
{
    if (pushToMainThread(ViewCallback, eType, p, data))
        return;

    CallbackDescriptor* descriptor = static_cast<CallbackDescriptor*>(data);
    g_ev.bumpBodies();
    Document* doc = descriptor->getDoc();
    for (auto& it : doc->_sessions)
    {
        const std::shared_ptr<ChildSession>& session = it.second;
        if (session->getViewId() == descriptor->getViewId() && !session->isCloseFrame())
            session->loKitCallback(eType, p ? p : "(nil)");
    }
}

void ChildSession::loKitCallback(COKitCallbackType, const std::string&)
{
    const ProcUtil::ThreadId tid = ProcUtil::getThreadId();
    if (tid == g_ev.kitThread)
        g_ev.callbacksOnKitThread++;
    else if (tid == g_ev.appMainThread)
    {
        g_ev.callbacksInlineOnAppMain++;
        g_ev.callbacksOnForeignThread++;
    }
    else
        g_ev.callbacksOnForeignThread++;

    // Only a delivery on a thread OTHER than the kit servicing thread may meet
    // the kit work window. Kit-thread delivery is serialized and can never
    // overlap itself, so it never enters the handshake and can never create a
    // false overlap count.
    if (g_ev.overlapGate != nullptr && tid != g_ev.kitThread)
        g_ev.overlapGate->partnerArrive(HANDSHAKE_BOUND);
}

} // namespace mock

using namespace mock;

static std::atomic<bool> g_kitRunning{false};

// One-shot start gate: the kit servicing thread blocks here until the driver
// releases it, letting a scenario force a delayed first service instead of
// hoping the OS delays it.
struct StartGate
{
    std::mutex mutex;
    std::condition_variable cv;
    bool open = false;
    void wait()
    {
        std::unique_lock<std::mutex> lk(mutex);
        cv.wait(lk, [&] { return open; });
    }
    void release()
    {
        {
            std::lock_guard<std::mutex> lk(mutex);
            open = true;
        }
        cv.notify_all();
    }
};

// One-shot "kit reached a defined point" flag with a bounded wait.
struct ReadyFlag
{
    std::mutex mutex;
    std::condition_variable cv;
    bool flag = false;
    void set()
    {
        {
            std::lock_guard<std::mutex> lk(mutex);
            flag = true;
        }
        cv.notify_all();
    }
    bool waitFor(std::chrono::milliseconds bound)
    {
        std::unique_lock<std::mutex> lk(mutex);
        return cv.wait_for(lk, bound, [&] { return flag; });
    }
};

// The kit servicing thread: records itself as the shared kitThreadId exactly
// where production's pollCallback runs, waits an optional start gate, then
// round-robins every live poll plus bounded units of "kit document work". The
// first work unit opens the explicit overlap handshake (S2): the thread parks
// inside document work until a foreign-thread delivery meets it or the driver
// closes the firing window, so the overlap is release/ack-proven rather than
// timed.
static void kitThreadLoop(Document* workDoc, int workUnits, StartGate* startGate = nullptr,
                          OverlapGate* overlap = nullptr, ReadyFlag* identityReady = nullptr)
{
    g_ev.kitThread = ProcUtil::getThreadId();
    recordKitThreadIdentity();
    if (identityReady)
        identityReady->set();
    if (startGate)
        startGate->wait();

    int worked = 0;
    while (g_kitRunning)
    {
        std::vector<std::shared_ptr<KitSocketPoll>> live;
        {
            std::unique_lock<std::mutex> lock(KitSocketPoll::KSPollsMutex);
            for (const auto& weak : KitSocketPoll::KSPolls)
                if (auto p = weak.lock())
                    live.push_back(std::move(p));
        }
        for (const auto& p : live)
            p->drainCallbacksOnPollThread();

        if (workDoc && worked < workUnits)
        {
            worked++;
            if (overlap != nullptr && worked == 1)
            {
                // Parked inside a unit of unsynchronized document work
                // (render/socket churn on workDoc, mocked by the handshake
                // window). Exactly one foreign delivery can meet it.
                overlap->armAndWait(HANDSHAKE_BOUND);
                g_ev.overlaps.store(overlap->meetings);
            }
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
}

static void resetEvidence()
{
    g_ev.callbackBodies = 0;
    g_ev.callbacksOnKitThread = 0;
    g_ev.callbacksOnForeignThread = 0;
    g_ev.callbacksInlineOnAppMain = 0;
    g_ev.dropLogs = 0;
    g_ev.overlaps = 0;
    g_ev.pendingDroppedWithPoll = 0;
    g_ev.nonemptyDrains = 0;
    g_ev.overlapGate = nullptr;
}

// g_kitRunning is cleared before join in every scenario; start gates are
// always released first, so no kit thread is ever orphaned.
static void stopKit(std::thread& kit)
{
    g_kitRunning = false;
    kit.join();
}

// Create a poll on its own creator thread (production: the lokit_main_N
// thread constructs it, so a never-serviced poll's owner is neither app-main
// nor kit; first service re-threads it via checkAndReThread).
static std::shared_ptr<KitSocketPoll> createPollOnOwnerThread(
    const std::shared_ptr<Document>& doc)
{
    std::shared_ptr<KitSocketPoll> out;
    std::thread creator([&] {
        out = KitSocketPoll::create();
        out->setDocument(doc);
    });
    creator.join();
    return out;
}

// The driver-held shared_ptr mirrors the KitWebSocketHandler::_document
// reference: a Document can outlive its poll.
static std::shared_ptr<Document> makeDoc(unsigned id, int sessions)
{
    auto doc = std::make_shared<Document>(id);
    for (int i = 0; i < sessions; ++i)
        doc->_sessions[i] = std::make_shared<ChildSession>();
    return doc;
}

int main()
{
    g_ev.appMainThread = ProcUtil::getThreadId();
    int failures = 0;
    auto expect = [&](bool ok, const char* name) {
        std::printf("%s %s\n", ok ? "PASS" : "FAIL", name);
        if (!ok)
            failures++;
    };

#if FLOE_KIT_VARIANT == 0
    std::printf("variant=original (pinned 27b21dc1)\n");
#else
    std::printf("variant=patched (kit-push-mainthread-lifecycle-v3)\n");
#endif

    // ---- S1+S2: preview->edit second-open window, then the race -------------
    {
        resetEvidence();
        auto doc1 = makeDoc(1, 2);
        auto doc2 = makeDoc(2, 3);
        auto poll1 = createPollOnOwnerThread(doc1);
        auto poll2 = createPollOnOwnerThread(doc2);

        // poll2 is built while poll1 lives (broker spawn outruns kit1
        // teardown), so the static tracks the second document's poll.
        expect(KitSocketPoll::mainPoll == poll2.get(), "S1 mainPoll tracks last-built poll");

        // First document closes: its poll is destroyed AFTER the second poll
        // was created — the device ordering.
        poll1.reset();
#if FLOE_KIT_VARIANT == 0
        expect(KitSocketPoll::mainPoll == nullptr && poll2 != nullptr,
               "S1 DEFECT null mainPoll with live sibling poll");
#else
        expect(poll2 != nullptr, "S1 sibling poll survives first-document teardown");
#endif

        // S2: the edit session renders; the VCL main thread flushes callbacks
        // for the live second document while the kit thread is parked inside
        // document work. The overlap is proven by a bounded release/ack
        // handshake, not by two timed parks crossing.
        StartGate startGate;
        OverlapGate overlap;
        g_ev.overlapGate = &overlap;
        g_kitRunning = true;
        std::thread kit(kitThreadLoop, doc2.get(), 40, &startGate, &overlap, nullptr);
        startGate.release();
        expect(overlap.waitParked(HANDSHAKE_BOUND),
               "S2 kit thread parked inside its first document-work unit");

        for (int i = 0; i < 20; ++i)
            Document::GlobalCallback(COKitCallbackType::STATUS_INDICATOR_START, "go", doc2.get());

        // Close the firing window and wait for the kit side to leave the park.
        // Original: the first inline app-main delivery already met it. Patched:
        // no foreign delivery can run, so the park ends with zero meetings.
        overlap.firingComplete();
        expect(overlap.waitReleased(HANDSHAKE_BOUND), "S2 overlap handshake released");
#if FLOE_KIT_VARIANT == 0
        // Null mainPoll: all bodies run inline on app-main synchronously.
        expect(g_ev.callbackBodies == 20, "S2 all callback bodies executed inline");
#else
        // Queued to poll2: rendezvous every body drained on the kit thread.
        expect(g_ev.waitForBodies(20, KIT_WAIT), "S2 completion rendezvous reached 20 bodies");
#endif
        // Join before clearing the gate: the bodies rendezvous fires when a
        // body starts, but its session broadcast still reads overlapGate, so
        // clearing here would race the kit thread's last delivery.
        stopKit(kit);
        g_ev.overlapGate = nullptr;

        std::printf("S2 evidence bodies=%d kit=%d foreign=%d inlineAppMain=%d overlaps=%d dropped=%d\n",
                    g_ev.callbackBodies.load(), g_ev.callbacksOnKitThread.load(),
                    g_ev.callbacksOnForeignThread.load(), g_ev.callbacksInlineOnAppMain.load(),
                    g_ev.overlaps.load(), g_ev.dropLogs.load());
#if FLOE_KIT_VARIANT == 0
        expect(g_ev.callbackBodies == 20 && g_ev.callbacksInlineOnAppMain == 60,
               "S2 DEFECT callback body executed inline on app-main thread");
        expect(g_ev.callbacksOnKitThread == 0,
               "S2 DEFECT no callback reached the kit thread");
        expect(g_ev.overlaps == 1,
               "S2 DEFECT handshake-proven overlap with kit-thread document work");
#else
        expect(g_ev.callbackBodies == 20 && g_ev.callbacksOnKitThread == 60,
               "S2 all callback bodies executed, on the kit thread");
        expect(g_ev.callbacksInlineOnAppMain == 0 && g_ev.callbacksOnForeignThread == 0,
               "S2 no inline execution on app-main while a poll is live");
        expect(g_ev.overlaps == 0,
               "S2 no unsynchronized overlap");
#endif
        poll2.reset();
    }

    // ---- S3: healthy path, every poll live (parity, no regression) ----------
    {
        resetEvidence();
        auto docA = makeDoc(10, 2);
        auto docB = makeDoc(11, 2);
        auto pollA = createPollOnOwnerThread(docA);
        auto pollB = createPollOnOwnerThread(docB);
        ReadyFlag kitUp;
        g_kitRunning = true;
        std::thread kit(kitThreadLoop, nullptr, 0, nullptr, nullptr, &kitUp);
        expect(kitUp.waitFor(KIT_WAIT), "S3 kit thread recorded its identity");
        Document::GlobalCallback(COKitCallbackType::INVALIDATE_TILES, "1", docB.get());
        expect(g_ev.waitForBodies(1, KIT_WAIT), "S3 completion rendezvous reached 1 body");
        stopKit(kit);
        expect(g_ev.callbackBodies == 1 && g_ev.callbacksOnKitThread == 2,
               "S3 live-poll callback body ran exactly once, on the kit thread");
        expect(g_ev.callbacksInlineOnAppMain == 0, "S3 no inline execution while polls live");
        pollA.reset();
        pollB.reset();
    }

    // ---- S4: exactly-once on the owner thread (re-entry regression) ----------
    {
        resetEvidence();
        auto docF = makeDoc(40, 1);
        auto pollF = createPollOnOwnerThread(docF);
        g_kitRunning = true;
        ReadyFlag entered;
        std::thread kit([&] {
            g_ev.kitThread = ProcUtil::getThreadId();
            recordKitThreadIdentity();
            // Service once so the poll adopts this thread (checkAndReThread).
            pollF->drainCallbacksOnPollThread();
            entered.set();
            // Engine invokes the callback ON the kit servicing thread.
            Document::GlobalCallback(COKitCallbackType::STATE_CHANGED, "k", docF.get());
            while (g_kitRunning)
            {
                pollF->drainCallbacksOnPollThread();
                std::this_thread::sleep_for(std::chrono::milliseconds(1));
            }
        });
        expect(entered.waitFor(KIT_WAIT), "S4 kit thread serviced the poll");
        expect(g_ev.waitForBodies(1, KIT_WAIT), "S4 completion rendezvous reached 1 body");
        stopKit(kit);
        // Body must have executed exactly once: a requeue-on-kit-thread bug
        // would starve it (0) or storm the queue.
        expect(g_ev.callbackBodies == 1,
               "S4 callback invoked on kit thread executed exactly once, no requeue");
        expect(g_ev.callbacksOnKitThread == 1, "S4 body ran on the kit thread");
        expect(g_ev.callbacksInlineOnAppMain == 0, "S4 no wrong-thread execution");
        pollF.reset();
    }

    // ---- S5: teardown with pending callbacks + reentrant queueing ------------
    {
        resetEvidence();
        auto docD = makeDoc(30, 1);
        auto pollD = createPollOnOwnerThread(docD);
        // Queue three callbacks, never drain them.
        for (int i = 0; i < 3; ++i)
            KitSocketPoll::pushToMainThread(Document::GlobalCallback,
                                            COKitCallbackType::INVALIDATE_TILES, "p", docD.get());
        expect(pollD->hasPending(), "S5 callbacks pending in the poll queue");
        pollD.reset(); // poll dies with its queue
        expect(g_ev.pendingDroppedWithPoll == 3,
               "S5 pending callbacks die with their poll, never executed");
        expect(g_ev.callbackBodies == 0,
               "S5 no callback body executed after its poll died");

        // Reentrancy: a callback executing on the kit thread invokes another
        // engine callback; its push returns false on the kit thread, so the
        // body runs inline there - no deadlock, exactly once.
        auto docE = makeDoc(31, 1);
        auto pollE = createPollOnOwnerThread(docE);
        g_kitRunning = true;
        std::thread kit(kitThreadLoop, nullptr, 0, nullptr, nullptr, nullptr);
        static Document* s_docE = docE.get();
        pollE->addCallback([] {
            Document::GlobalCallback(COKitCallbackType::STATE_CHANGED, "s", s_docE);
        });
        expect(g_ev.waitForBodies(1, KIT_WAIT), "S5 reentrant completion rendezvous reached 1 body");
        stopKit(kit);
        expect(g_ev.callbackBodies == 1 && g_ev.callbacksOnKitThread == 1,
               "S5 reentrant queueing executed exactly once, no deadlock");
        pollE.reset();
    }

    // ---- S6: callback for a document whose poll is already gone --------------
    {
        resetEvidence();
        auto docG = makeDoc(50, 2);
        {
            auto pollG = createPollOnOwnerThread(docG);
            pollG.reset(); // document's poll dies; docG outlives it (handler ref)
        }
        Document::GlobalCallback(COKitCallbackType::STATE_CHANGED, "s", docG.get());
        CallbackDescriptor descr(docG.get(), 0);
        Document::ViewCallback(COKitCallbackType::INVALIDATE_TILES, "t", &descr);
#if FLOE_KIT_VARIANT == 0
        // GlobalCallback and ViewCallback both broadcast to the 2 sessions.
        expect(g_ev.callbackBodies == 2 && g_ev.callbacksInlineOnAppMain == 4 &&
                   g_ev.callbacksOnKitThread == 0,
               "S6 DEFECT orphan-document callbacks ran inline on a foreign thread");
#else
        expect(g_ev.callbackBodies == 0 && g_ev.dropLogs == 2,
               "S6 orphan-document callbacks dropped, never run unsynchronized");
        expect(g_ev.callbacksInlineOnAppMain == 0,
               "S6 no inline execution for orphan document");
#endif
    }

    // ---- S7: unserviced new poll beside a serviced document ------------------
    // A never-serviced poll still carries its creator thread as owner. Inline
    // authority must never be derived from that: a callback arriving on the
    // creator thread is a foreign thread and must not run the body there.
    {
        resetEvidence();
        auto docA = makeDoc(60, 1);
        auto pollA = createPollOnOwnerThread(docA);
        ReadyFlag kitUp;
        g_kitRunning = true;
        std::thread kit(kitThreadLoop, nullptr, 0, nullptr, nullptr, &kitUp);
        expect(kitUp.waitFor(KIT_WAIT), "S7 kit thread recorded its identity");

        auto docB = makeDoc(61, 1);
        std::shared_ptr<KitSocketPoll> pollB;
        ReadyFlag creatorReady;
        std::atomic<bool> creatorFire{false};
        std::thread creator([&] {
            pollB = KitSocketPoll::create();
            pollB->setDocument(docB);
            pollB->serviceEnabled.store(false); // not yet serviced by the kit thread
            creatorReady.set();
            // Stay alive: callbacks can still arrive on this thread.
            while (!creatorFire.load())
                std::this_thread::sleep_for(std::chrono::milliseconds(1));
            // A foreign-thread engine callback arriving on the creator thread
            // while its poll is still unserviced (owner == this thread).
            Document::GlobalCallback(COKitCallbackType::STATE_CHANGED, "c", docB.get());
        });
        expect(creatorReady.waitFor(KIT_WAIT), "S7 creator built the unserviced poll");

        // App-main callback for the not-yet-serviced document: must queue to
        // its own poll and wait, never run inline here. Because service is
        // disabled, non-execution is structural (no sleep needed as proof).
        Document::GlobalCallback(COKitCallbackType::INVALIDATE_TILES, "a", docB.get());
        expect(g_ev.callbackBodies == 0 && pollB->hasPending(),
               "S7 callbacks for an unserviced document queue and wait");
        expect(g_ev.callbacksInlineOnAppMain == 0,
               "S7 no inline execution on app-main for unserviced document");

        // The creator thread fires while the poll is STILL unserviced.
        creatorFire = true;
        creator.join();
#if FLOE_KIT_VARIANT == 0
        // Original: mainPoll == pollB whose owner is the creator thread; the
        // creator-thread callback runs the body INLINE there (foreign thread).
        expect(g_ev.callbackBodies == 1 && g_ev.callbacksOnForeignThread >= 1,
               "S7 DEFECT creator-owner authorized inline execution on a foreign thread");
#else
        // v3: identity is the kit thread alone; the creator callback queues.
        expect(g_ev.callbackBodies == 0 && g_ev.callbacksOnForeignThread == 0,
               "S7 creator-owner not mistaken for the kit thread");
#endif

        pollB->serviceEnabled.store(true); // first service: re-thread + drain
        // Wait until both callbacks (app-main's and creator's) have drained.
        expect(g_ev.waitForBodies(2, KIT_WAIT), "S7 completion rendezvous reached 2 bodies");
        stopKit(kit);
        expect(g_ev.callbackBodies == 2 && g_ev.callbacksOnKitThread >= 1,
               "S7 queued callbacks executed exactly once each, on the kit thread");
#if FLOE_KIT_VARIANT != 0
        expect(g_ev.callbacksOnKitThread == 2 && g_ev.callbacksOnForeignThread == 0 &&
                   g_ev.callbacksInlineOnAppMain == 0,
               "S7 no foreign-thread inline execution from unserviced owner");
#endif
        pollA.reset();
        pollB.reset();
    }

    // ---- S8: concurrent first-service/rethread and a pushed callback ---------
    {
        resetEvidence();
        auto docC = makeDoc(70, 1);
        auto pollC = createPollOnOwnerThread(docC);
        pollC->serviceEnabled.store(false);
        constexpr int N = 30;
        g_kitRunning = true;
        std::thread kit([&] {
            g_ev.kitThread = ProcUtil::getThreadId();
            recordKitThreadIdentity();
            pollC->serviceEnabled.store(true); // first service starts now
            while (g_kitRunning)
            {
                pollC->drainCallbacksOnPollThread();
                std::this_thread::sleep_for(std::chrono::milliseconds(1));
            }
        });
        // Push while the first service/rethread may still be in flight. The
        // completion rendezvous makes scheduling irrelevant.
        for (int i = 0; i < N; ++i)
            Document::GlobalCallback(COKitCallbackType::INVALIDATE_TILES, "n", docC.get());
        expect(g_ev.waitForBodies(N, KIT_WAIT), "S8 completion rendezvous reached 30 bodies");
        stopKit(kit);
        std::printf("S8 evidence bodies=%d kit=%d inlineAppMain=%d\n",
                    g_ev.callbackBodies.load(), g_ev.callbacksOnKitThread.load(),
                    g_ev.callbacksInlineOnAppMain.load());
        expect(g_ev.callbackBodies == N && g_ev.callbacksOnKitThread == N,
               "S8 exactly-once on kit thread across first-service race");
        expect(g_ev.callbacksInlineOnAppMain == 0,
               "S8 no inline execution during first-service window");
        pollC.reset();
    }

    // ---- S9: forced delayed first service; old STOP loses, rendezvous wins ---
    // The kit servicing thread is held behind a hard start gate (a forced,
    // scheduler-independent delay, not a hoped-for OS hiccup). Phase 1
    // reproduces the cloud completion flaw exactly: callbacks are queued while
    // first service is impossible, and the OLD timing-as-completion driver
    // STOPS the kit thread (g_kitRunning=false, then releases the gate and
    // joins) before it ever services a poll - so the queued work is
    // permanently lost (bodies==0). Phase 2 starts a fresh gated kit thread,
    // releases first service and rendezvous the held batch plus two later
    // batches, each forced into its own drain turn, all exactly once on the
    // kit thread. This guards harness completion discipline for either
    // extraction; it introduces no new production behavior.
    {
        resetEvidence();
        auto docS = makeDoc(80, 1);
        auto pollS = createPollOnOwnerThread(docS);

        // ---- Phase 1: old fixed-window stop before first service ----------
        StartGate gate1;
        g_kitRunning = true;
        std::thread kit1(kitThreadLoop, nullptr, 0, &gate1, nullptr, nullptr);
        for (int i = 0; i < 7; ++i)
            Document::GlobalCallback(COKitCallbackType::INVALIDATE_TILES, "a", docS.get());
        expect(pollS->hasPending() && g_ev.callbackBodies == 0,
               "S9 batch A queued while first service is gated off");
        // Old completion shape: a fixed window, then STOP before releasing the
        // gate. The gate (not the clock) guarantees zero service, so this
        // deterministically loses the queued work exactly as the cloud runner's
        // delayed first service made its 85 ms fixed-window stop miss.
        std::this_thread::sleep_for(std::chrono::milliseconds(2));
        g_kitRunning = false;
        gate1.release();
        kit1.join();
        expect(g_ev.callbackBodies == 0 && pollS->hasPending(),
               "S9 old fixed-window stop before first service loses queued work");

        // ---- Phase 2: corrected bounded rendezvous, three drain batches ---
        resetEvidence();
        StartGate gate2;
        ReadyFlag kit2Up;
        g_kitRunning = true;
        std::thread kit2(kitThreadLoop, nullptr, 0, &gate2, nullptr, &kit2Up);
        gate2.release();
        expect(kit2Up.waitFor(KIT_WAIT), "S9 corrected kit thread recorded its identity");
        // Batch A's 7 callbacks survived in pollS's queue; first service now
        // drains them in their own turn.
        expect(g_ev.waitForBodies(7, KIT_WAIT) && g_ev.waitForDrains(1, KIT_WAIT),
               "S9 corrected first service drains the held batch in its own turn");

        for (int i = 0; i < 8; ++i)
            Document::GlobalCallback(COKitCallbackType::STATUS_INDICATOR_START, "b", docS.get());
        expect(g_ev.waitForBodies(15, KIT_WAIT) && g_ev.waitForDrains(2, KIT_WAIT),
               "S9 batch B drained in a second service turn");

        for (int i = 0; i < 5; ++i)
            Document::GlobalCallback(COKitCallbackType::STATE_CHANGED, "c", docS.get());
        expect(g_ev.waitForBodies(20, KIT_WAIT) && g_ev.waitForDrains(3, KIT_WAIT),
               "S9 batch C drained in a third service turn");
        stopKit(kit2);

        std::printf("S9 evidence bodies=%d kit=%d foreign=%d inlineAppMain=%d drains=%d\n",
                    g_ev.callbackBodies.load(), g_ev.callbacksOnKitThread.load(),
                    g_ev.callbacksOnForeignThread.load(), g_ev.callbacksInlineOnAppMain.load(),
                    g_ev.nonemptyDrains.load());
        expect(g_ev.callbackBodies == 20 && g_ev.callbacksOnKitThread == 20 &&
                   g_ev.callbacksOnForeignThread == 0 && g_ev.callbacksInlineOnAppMain == 0,
               "S9 strict rendezvous drains all batches exactly once on the kit thread");
        expect(g_ev.nonemptyDrains >= 3, "S9 queued work crossed multiple drain batches");
        pollS.reset();
    }

#if FLOE_KIT_VARIANT == 0
    std::printf("result=DEFECT-DEMONSTRATED failures=%d\n", failures);
    return failures == 0 ? 0 : 1;
#else
    std::printf("result=%s failures=%d\n", failures == 0 ? "REPAIR-VERIFIED" : "REPAIR-FAILED",
                failures);
    return failures == 0 ? 0 : 1;
#endif
}
