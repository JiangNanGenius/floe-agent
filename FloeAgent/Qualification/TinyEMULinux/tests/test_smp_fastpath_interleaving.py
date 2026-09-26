#!/usr/bin/env python3
"""Deterministic regression for the TinyEMU SMP store fast-path flaw.

Context (2026-09-26).  An experimental engine patch replaced the global
atomic lock around ordinary guest-RAM stores with a counter fast path:
the store SEQ_CST-loads a machine-wide count of live LR reservations and
skips the lock while the count is zero; an LR SEQ_CST-publishes its
reservation.  Cloud run 36240219437 (cancelled) exercised this candidate.

The design is incorrect under this forced schedule (the "stale SC"):

  1. hart A fast-store step 1: SEQ_CST load of the counter -> observes 0
  2. hart B LR: loads the OLD memory word, SEQ_CST publishes counter = 1
  3. hart A fast-store step 2: executes the (unlocked) store of a NEW word
  4. hart B SC: its reservation is still marked valid, so it SUCCEEDS,
     even though another hart wrote the reserved word after its LR load.

SEQ_CST orders only the *counter* operations.  It does not order hart A's
later data write against hart B's LR/reservation establishment, so the
write is never linearized against the LR/SC pair.  On real hardware (and
under the shipping locked protocol) a store hitting the reservation grain
after LR invalidates the reservation and SC fails.  A mutex built on such
an LR/SC could then be held by two harts or lose a wakeup.

This module models BOTH protocols with the same forced interleaving and
asserts:

  * the candidate fast path really reproduces the violation (SC succeeds
    after a conflicting store following the LR load);
  * the shipping locked protocol rejects that SC;
  * the reservation-count invariant (never negative; zero when every
    modeled sequence has finished) holds for every modeled schedule.

A second regression records the companion data-race finding from patch
review: the candidate also emitted two *plain* counter decrements from
invalidation paths while the fast path reads the counter atomically.
Plain writes mixed with atomic reads are a C11 data race (UB).  The model
tags every counter mutation and the audit asserts an unlocked protocol
must never publish a mutation without atomic ordering.

Run:  python3 test_smp_fastpath_interleaving.py

Evidence boundary: this is a deterministic *protocol model* — a design
counterexample in Python. It is NOT executable TinyEMU C; it cannot count
among C-engine correctness gates and does not prove the shipping
implementation. Real engine evidence comes from the native smp_host_test;
release qualification comes from the cloud S0–S5 contract.
"""

import unittest


class GuestMachine:
    """Minimal model of the two-hart reservation protocol.

    Memory is one word at address 0.  `lock` is the global atomic lock
    (held/not held).  `fast_path` selects the candidate counter fast path
    vs the shipping locked protocol; `atomic_counter` is False to model
    the candidate's plain decrement data race.
    """

    ADDR = 0

    def __init__(self, fast_path, atomic_counter=True):
        self.fast_path = fast_path
        self.atomic_counter = atomic_counter
        self.memory = 0
        self.lock_held = False
        self.live = 0                 # live LR reservations
        # reservation of hart B: (valid, address, loaded value)
        self.res_valid = False
        self.res_addr = None
        self.res_value = None
        self.plain_counter_writes = 0
        # Per-fast-store split state, so the test can force interleaving
        # between the counter check and the data write.
        self._store_observed_live = None

    # ---- counter accounting -------------------------------------------

    def _publish(self, delta):
        """Mutate the reservation counter. A plain mutation is UB when
        another hart can read the counter atomically outside the lock."""
        if not self.atomic_counter:
            self.plain_counter_writes += 1
        self.live += delta
        assert self.live >= 0, "reservation counter went negative"

    # ---- hart B: LR / SC ----------------------------------------------

    def lr(self):
        """Hart B loads with reservation. Returns the loaded word."""
        self.lock_held = True
        value = self.memory
        self.res_valid = True
        self.res_addr = self.ADDR
        self.res_value = value
        # candidate: SEQ_CST publication of the live reservation.
        self._publish(1)
        self.lock_held = False
        return value

    def sc(self, new_value):
        """Hart B store-conditional. Returns 0 on success, 1 on failure."""
        self.lock_held = True
        status = 1
        if self.res_valid and self.res_addr == self.ADDR:
            self.memory = new_value
            status = 0
        if self.res_valid:
            self.res_valid = False
            self._publish(-1)
        self.lock_held = False
        return status

    # ---- hart A: store, split into check / commit ----------------------

    def fast_store_check(self, new_value):
        """Store step 1. The candidate decides on a counter snapshot; the
        locked protocol has no unlocked decision to make."""
        self._store_new_value = new_value
        self._store_observed_live = self.live  # SEQ_CST load in the C patch
        self._store_commit_unlocked = (
            self.fast_path and self._store_observed_live == 0
        )
        return self._store_commit_unlocked

    def fast_store_commit(self):
        """Candidate fast store step 2: write, possibly invalidating no
        reservation because the earlier check skipped the lock."""
        assert self._store_observed_live is not None
        if self._store_commit_unlocked:
            # THE FLAW: the write is not ordered against an LR that was
            # established after the counter check, and invalidates nothing.
            self.memory = self._store_new_value
            return "unlocked"
        self.locked_store(self._store_new_value)
        return "locked"

    def locked_store(self, new_value):
        """Shipping protocol: lock, invalidate overlapping reservations,
        write, unlock -- every store total-ordered with LR/SC."""
        assert not self.lock_held
        self.lock_held = True
        if self.res_valid and self.res_addr == self.ADDR:
            self.res_valid = False
            self._publish(-1)
        self.memory = new_value
        self.lock_held = False


class SMPFastPathInterleavingTests(unittest.TestCase):
    def forced_stale_sc_schedule(self, machine):
        """The exact LR->store->SC schedule from review, independent of
        protocol. Returns (lr_loaded_value, sc_status, final_memory)."""
        # 1. hart A begins an ordinary store to the reservation word; its
        #    counter check runs BEFORE hart B's LR.
        machine.fast_store_check(100)
        # 2. hart B establishes its reservation and loads the old word.
        loaded = machine.lr()
        # 3. hart A commits the store after the LR.
        machine.fast_store_commit()
        # 4. hart B attempts the SC.
        status = machine.sc(200)
        return loaded, status, machine.memory

    def test_candidate_fast_path_reproduces_the_stale_sc(self):
        machine = GuestMachine(fast_path=True)
        loaded, status, memory = self.forced_stale_sc_schedule(machine)

        # The LR loaded the old word; the conflicting store then landed;
        # a correct protocol MUST have invalidated the reservation.
        self.assertEqual(loaded, 0, "LR must load the pre-store word")
        self.assertEqual(
            status, 0,
            "CANDIDATE REGRESSION: SC succeeded (status=0) even though a "
            "store wrote the reserved word after the LR load; the counter "
            "fast path cannot invalidate this reservation")
        self.assertEqual(
            memory, 200,
            "the wrongly-successful SC then overwrote hart A's stored word "
            "(100) with its own value -- a mutex on this LR/SC could be "
            "held by two harts")

    def test_shipping_locked_protocol_rejects_the_same_sc(self):
        machine = GuestMachine(fast_path=False)
        loaded, status, memory = self.forced_stale_sc_schedule(machine)

        self.assertEqual(loaded, 0)
        self.assertEqual(memory, 100, "hart A's conflicting store must land")
        self.assertEqual(
            status, 1,
            "the locked protocol must invalidate the reservation and make "
            "SC fail after a conflicting post-LR store")

    def test_lr_after_locked_store_sees_the_new_word(self):
        # The other valid interleaving: store completes before LR.
        machine = GuestMachine(fast_path=False)
        machine.locked_store(100)
        self.assertEqual(machine.lr(), 100,
                         "an LR after the store must observe the new word")

    def test_counter_invariant_ends_at_zero(self):
        for fast_path in (True, False):
            machine = GuestMachine(fast_path=fast_path)
            self.forced_stale_sc_schedule(machine)
            self.assertEqual(
                machine.live, 0,
                "every consumed reservation must be accounted exactly once")

    def test_plain_counter_decrements_are_flagged(self):
        # Model the companion review finding: two invalidation paths in
        # the candidate patch used plain `live_reservations--` writes, a
        # data race against the fast path's atomic counter load.
        machine = GuestMachine(fast_path=True, atomic_counter=False)
        machine.lr()
        machine.sc(1)
        self.assertGreater(
            machine.plain_counter_writes, 0,
            "this model intentionally tags plain counter mutations")
        # Audit requirement for any future fast path: every counter write
        # reachable outside the global lock must use __atomic_* ordering.
        safe = GuestMachine(fast_path=True, atomic_counter=True)
        safe.lr()
        safe.sc(1)
        self.assertEqual(safe.plain_counter_writes, 0)


if __name__ == "__main__":
    unittest.main()
