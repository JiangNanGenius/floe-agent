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
#include "extracted.h"
#include <cstdio>

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

    g_ev.callbackBodies++;
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
    g_ev.callbackBodies++;
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

    // Rendezvous overlap proof: deterministic iff another thread can be inside
    // kit work at the same time (30 ms timeout keeps serialized runs fast).
    std::unique_lock<std::mutex> lk(g_ev.rendezvousMutex);
    g_ev.rendezvousInside++;
    g_ev.rendezvousCv.notify_all();
    g_ev.rendezvousCv.wait_for(lk, std::chrono::milliseconds(30),
                               [] { return g_ev.rendezvousInside >= 2; });
    if (g_ev.rendezvousInside >= 2)
        g_ev.overlaps++;
    g_ev.rendezvousInside--;
}

} // namespace mock

using namespace mock;

static std::atomic<bool> g_kitRunning{false};

// The kit servicing thread: records itself as the shared kitThreadId exactly
// where production's pollCallback runs, then round-robins every live poll,
// plus one unit of "kit work" (render/socket churn on a document) per turn.
static void kitThreadLoop(Document* workDoc, int workUnits)
{
    g_ev.kitThread = ProcUtil::getThreadId();
    recordKitThreadIdentity();
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
            {
                std::unique_lock<std::mutex> lk(g_ev.rendezvousMutex);
                g_ev.rendezvousInside++;
                g_ev.rendezvousCv.notify_all();
                g_ev.rendezvousCv.wait_for(lk, std::chrono::milliseconds(30),
                                           [] { return g_ev.rendezvousInside >= 2; });
                if (g_ev.rendezvousInside >= 2)
                    g_ev.overlaps++;
                g_ev.rendezvousInside--;
            }
            // Unsynchronized session churn standing in for
            // renderTiles/postMessage/socket work on the same Document.
            workDoc->_sessions.erase(workDoc->_sessions.begin());
            workDoc->_sessions[1000 + worked] = std::make_shared<ChildSession>();
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
    std::unique_lock<std::mutex> lk(g_ev.rendezvousMutex);
    g_ev.rendezvousInside = 0;
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

        // S2: the edit session renders; the VCL main thread flushes a callback
        // for the live second document while the kit thread works on it.
        g_kitRunning = true;
        std::thread kit(kitThreadLoop, doc2.get(), 40);
        std::this_thread::sleep_for(std::chrono::milliseconds(5));
        for (int i = 0; i < 20; ++i)
            Document::GlobalCallback(COKitCallbackType::STATUS_INDICATOR_START, "go", doc2.get());
        std::this_thread::sleep_for(std::chrono::milliseconds(80));
        g_kitRunning = false;
        kit.join();

        std::printf("S2 evidence bodies=%d kit=%d foreign=%d inlineAppMain=%d overlaps=%d dropped=%d\n",
                    g_ev.callbackBodies.load(), g_ev.callbacksOnKitThread.load(),
                    g_ev.callbacksOnForeignThread.load(), g_ev.callbacksInlineOnAppMain.load(),
                    g_ev.overlaps.load(), g_ev.dropLogs.load());
#if FLOE_KIT_VARIANT == 0
        expect(g_ev.callbacksInlineOnAppMain > 0,
               "S2 DEFECT callback body executed inline on app-main thread");
        expect(g_ev.callbacksOnKitThread == 0,
               "S2 DEFECT no callback reached the kit thread");
        expect(g_ev.overlaps > 0,
               "S2 DEFECT unsynchronized overlap with kit-thread document work");
#else
        expect(g_ev.callbackBodies == 20 && g_ev.callbacksOnKitThread > 0,
               "S2 all callback bodies executed, on the kit thread");
        expect(g_ev.callbacksInlineOnAppMain == 0,
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
        g_kitRunning = true;
        std::thread kit(kitThreadLoop, nullptr, 0);
        std::this_thread::sleep_for(std::chrono::milliseconds(5));
        Document::GlobalCallback(COKitCallbackType::INVALIDATE_TILES, "1", docB.get());
        std::this_thread::sleep_for(std::chrono::milliseconds(50));
        g_kitRunning = false;
        kit.join();
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
        std::atomic<bool> entered{false};
        std::thread kit([&] {
            g_ev.kitThread = ProcUtil::getThreadId();
            recordKitThreadIdentity();
            // Service once so the poll adopts this thread (checkAndReThread).
            pollF->drainCallbacksOnPollThread();
            entered = true;
            // Engine invokes the callback ON the kit servicing thread.
            Document::GlobalCallback(COKitCallbackType::STATE_CHANGED, "k", docF.get());
            while (g_kitRunning)
            {
                pollF->drainCallbacksOnPollThread();
                std::this_thread::sleep_for(std::chrono::milliseconds(1));
            }
        });
        while (!entered)
            std::this_thread::sleep_for(std::chrono::milliseconds(1));
        std::this_thread::sleep_for(std::chrono::milliseconds(120));
        g_kitRunning = false;
        kit.join();
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
        std::thread kit(kitThreadLoop, nullptr, 0);
        std::this_thread::sleep_for(std::chrono::milliseconds(5));
        static Document* s_docE = docE.get();
        pollE->addCallback([] {
            Document::GlobalCallback(COKitCallbackType::STATE_CHANGED, "s", s_docE);
        });
        std::this_thread::sleep_for(std::chrono::milliseconds(60));
        g_kitRunning = false;
        kit.join();
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
        g_kitRunning = true;
        std::thread kit(kitThreadLoop, nullptr, 0);
        std::this_thread::sleep_for(std::chrono::milliseconds(5)); // kitThreadId set

        auto docB = makeDoc(61, 1);
        std::shared_ptr<KitSocketPoll> pollB;
        ProcUtil::ThreadId creatorT{0};
        std::atomic<bool> creatorReady{false};
        std::atomic<bool> creatorFire{false};
        std::thread creator([&] {
            creatorT = ProcUtil::getThreadId();
            pollB = KitSocketPoll::create();
            pollB->setDocument(docB);
            pollB->serviceEnabled.store(false); // not yet serviced by the kit thread
            creatorReady = true;
            // Stay alive: callbacks can still arrive on this thread.
            while (!creatorFire)
                std::this_thread::sleep_for(std::chrono::milliseconds(1));
            // A foreign-thread engine callback arriving on the creator thread
            // while its poll is still unserviced (owner == this thread).
            Document::GlobalCallback(COKitCallbackType::STATE_CHANGED, "c", docB.get());
        });
        while (!creatorReady)
            std::this_thread::sleep_for(std::chrono::milliseconds(1));

        // App-main callback for the not-yet-serviced document: must queue to
        // its own poll and wait, never run inline here.
        Document::GlobalCallback(COKitCallbackType::INVALIDATE_TILES, "a", docB.get());
        std::this_thread::sleep_for(std::chrono::milliseconds(20));
        expect(g_ev.callbackBodies == 0 && pollB->hasPending(),
               "S7 callbacks for an unserviced document queue and wait");
        expect(g_ev.callbacksInlineOnAppMain == 0,
               "S7 no inline execution on app-main for unserviced document");

        // The creator thread fires while the poll is STILL unserviced.
        creatorFire = true;
        creator.join();
        std::this_thread::sleep_for(std::chrono::milliseconds(40));
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
        for (int i = 0; i < 300 && g_ev.callbackBodies < 2; ++i)
            std::this_thread::sleep_for(std::chrono::milliseconds(10));
        g_kitRunning = false;
        kit.join();
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
        // Push while the first service/rethread may still be in flight.
        for (int i = 0; i < N; ++i)
            Document::GlobalCallback(COKitCallbackType::INVALIDATE_TILES, "n", docC.get());
        // Wait for all bodies (rendezvous timeouts pace the drain).
        for (int i = 0; i < 500 && g_ev.callbackBodies < N; ++i)
            std::this_thread::sleep_for(std::chrono::milliseconds(10));
        g_kitRunning = false;
        kit.join();
        std::printf("S8 evidence bodies=%d kit=%d inlineAppMain=%d\n",
                    g_ev.callbackBodies.load(), g_ev.callbacksOnKitThread.load(),
                    g_ev.callbacksInlineOnAppMain.load());
        expect(g_ev.callbackBodies == N && g_ev.callbacksOnKitThread == N,
               "S8 exactly-once on kit thread across first-service race");
        expect(g_ev.callbacksInlineOnAppMain == 0,
               "S8 no inline execution during first-service window");
        pollC.reset();
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
