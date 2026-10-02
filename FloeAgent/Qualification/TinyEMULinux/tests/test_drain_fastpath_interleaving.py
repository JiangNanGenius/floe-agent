#!/usr/bin/env python3
"""Deterministic protocol model for the TinyEMU SMP arm/drain fast store.

Models the arm/drain handshake shipped in the engine's FLOE-SMP path
(patches 0010-smp-dual-hart + the arm/drain fast store):

  fast store  hart A: check armed; if 0 -> mark in_store=1; re-check
                      armed; if still 0 -> data write; unmark;
                      if armed -> unmark and take the locked store
  LR/SC/AMO   hart B: take lock; armed=1; spin until every other hart's
                      in_store is 0; then read/reserve/write; disarm when
                      the last reservation is consumed
  arm + exit  any locked, arming critical section that publishes no
              reservation (SC without a valid reservation, page-walk
              update that hit a replaced mapping) MUST disarm before
              releasing the lock, otherwise plain stores stay on the
              locked path forever

Every memory event is appended to one global sequence, so a test can ask
the only question that matters for LR/SC: after B's LR read and before
its SC, did another hart write the reserved word?  The shipping locked
protocol must fail that SC; the rejected counter-only fast path let the
SC succeed (stale SC); the drain handshake must either fail the SC or
order the store before the LR read.

Evidence boundary: deterministic protocol model, not executable TinyEMU
C. Real engine evidence comes from smp_host_test and the TSan run;
release qualification still requires the cloud S0-S5 contract.

Run: python3 test_drain_fastpath_interleaving.py
"""

import unittest


class Machine:
    ADDR = 0

    def __init__(self, protocol):
        assert protocol in ("locked", "counter", "drain")
        self.protocol = protocol
        self.memory = 0
        self.armed = 0
        self.in_store = [0, 0]
        self.res_valid = False
        self.seq = []          # (hart, kind, value)
        self.drain_waited = False

    # ---- sequencing ----------------------------------------------------
    def ev(self, hart, kind, value=None):
        self.seq.append((hart, kind, value))

    def last_write_between(self, hart, t0, t1):
        """index of a write by another hart with t0 < index < t1, or None."""
        for i, (h, kind, _v) in enumerate(self.seq):
            if t0 < i < t1 and h != hart and kind == "write":
                return i
        return None

    # ---- arm/drain, split into observe + pass --------------------------
    def drain_observe(self):
        """What B's drain does before it may proceed: record whether any
        other hart is inside a fast store."""
        self.drain_waited = self.drain_waited or any(self.in_store)
        return self.drain_waited

    def drain_pass(self):
        """The spin completed: every other in_store mark is clear. With a
        release/acquire pair this also publishes the stores made before the
        clear."""
        assert not any(self.in_store), "drain passed with a live mark"

    # ---- hart A: fast/locked store, explicit steps ---------------------
    def store_check1(self):
        if self.protocol == "locked":
            return "locked"
        if self.armed:
            return "locked"
        if self.protocol == "drain":
            self.in_store[0] = 1
        return "fast"

    def store_check2(self):
        if self.protocol == "locked":
            return "locked"
        if self.protocol == "counter":
            # the rejected patch decided at check1 (counter snapshot) and
            # wrote later without any second check
            return "fast"
        if self.armed:
            if self.protocol == "drain":
                self.in_store[0] = 0
            return "locked"
        return "fast"

    def store_write(self, value):
        self.memory = value
        self.ev(0, "write", value)

    def store_unmark(self):
        if self.protocol == "drain":
            self.in_store[0] = 0

    def locked_store(self, value):
        self.armed = 1
        self.drain_observe()
        self.drain_pass()
        self.store_write(value)
        if self.res_valid:              # invalidate overlapping reservation
            self.res_valid = False
            self.armed = 0

    # ---- hart B: LR / SC, explicit steps -------------------------------
    def lr(self, honor_drain=True):
        self.armed = 1
        if honor_drain:
            self.drain_observe()
            self.drain_pass()
        v = self.memory
        self.ev(1, "lr_read", v)
        self.res_valid = True
        return v

    def sc(self, value):
        self.armed = 1
        self.drain_observe()
        self.drain_pass()
        status = 1
        if self.res_valid:
            self.memory = value
            self.ev(1, "write", value)
            status = 0
        self.res_valid = False
        self.armed = 0
        return status

    # ---- arm-and-exit (SC without reservation / PTE conflict) ----------
    def arm_and_leave(self, publish_reservation=False, disarm=True):
        """A locked, arming critical section that publishes no reservation
        and does not touch RAM (an SC attempt on a consumed reservation,
        or a page-walk update that found its PTE replaced).  The shipped
        engine calls riscv_smp_maybe_disarm on every such exit; this model
        parameterizes it so the regression below can show the difference."""
        self.armed = 1
        self.drain_observe()
        self.drain_pass()
        if publish_reservation:
            self.res_valid = True
        if disarm and not self.res_valid:
            self.armed = 0


class TestDrainProtocol(unittest.TestCase):
    def lr_index(self, m):
        return [i for i, e in enumerate(m.seq) if e[1] == "lr_read"][0]

    def sc_write_index(self, m):
        idx = [i for i, e in enumerate(m.seq) if e[1] == "write" and e[0] == 1]
        return idx[-1] if idx else None

    def test_counter_path_has_stale_sc(self):
        """Rejected counter path: check -> LR -> write -> SC succeeds with
        a conflicting write between the LR read and the SC."""
        m = Machine("counter")
        self.assertEqual(m.store_check1(), "fast")
        m.lr(honor_drain=False)
        self.assertEqual(m.store_check2(), "fast")
        m.store_write(0xBEEF)
        self.assertEqual(m.sc(0xCAFE), 0, "counter path SC unexpectedly failed")
        t0, t1 = self.lr_index(m), self.sc_write_index(m)
        self.assertIsNotNone(m.last_write_between(1, t0, t1),
                             "model did not schedule the conflicting write")

    def test_drain_rejects_the_same_schedule(self):
        """Same schedule with the drain handshake: A's re-check sees armed=1,
        takes the locked store, invalidates B's reservation, SC fails."""
        m = Machine("drain")
        self.assertEqual(m.store_check1(), "fast")     # mark set
        # B arms and starts its drain: it must observe A's mark.
        m.armed = 1
        m.drain_observe()
        self.assertTrue(m.drain_waited, "drain missed A's in-flight store")
        # A's re-check sees armed=1, clears the mark, goes locked.
        self.assertEqual(m.store_check2(), "locked")
        self.assertEqual(m.in_store[0], 0)
        m.drain_pass()                                 # B's spin completes
        m.ev(1, "lr_read", m.memory)                   # B reads the old word
        m.res_valid = True
        m.locked_store(0xBEEF)                         # A's locked write
        self.assertEqual(m.sc(0xCAFE), 1, "SC must fail")
        self.assertEqual(m.memory, 0xBEEF)

    def test_drain_orders_store_before_later_lr(self):
        """A's re-check reads 0, then writes and unmarks; B's drain passes
        and reads the NEW value: the write is before the LR read."""
        m = Machine("drain")
        self.assertEqual(m.store_check1(), "fast")
        self.assertEqual(m.store_check2(), "fast")
        m.store_write(0x1111)
        m.store_unmark()
        v = m.lr()
        self.assertEqual(v, 0x1111)
        self.assertEqual(m.sc(0x2222), 0)
        t0 = self.lr_index(m)
        t1 = self.sc_write_index(m)
        self.assertIsNone(m.last_write_between(1, t0, t1))

    def test_drain_cannot_pass_a_live_mark(self):
        """While A's mark is set, drain_pass must fail: the mark clears
        only after A's data write, so the later LR read is ordered after
        that write."""
        m = Machine("drain")
        self.assertEqual(m.store_check1(), "fast")
        self.assertEqual(m.in_store[0], 1)
        m.armed = 1
        self.assertTrue(m.drain_observe())
        with self.assertRaises(AssertionError):
            m.drain_pass()
        m.store_write(0x3333)
        m.store_unmark()
        m.drain_pass()
        self.assertEqual(m.memory, 0x3333)

    def test_arm_without_reservation_disarms(self):
        """SC without a live reservation and a PTE-conflict exit both arm
        and publish nothing; each must return armed to 0 so later plain
        stores keep the fast path."""
        m = Machine("drain")
        self.assertEqual(m.sc(0xCAFE), 1)      # no reservation: no store
        self.assertEqual(m.armed, 0, "SC exit left armed set")
        self.assertEqual(m.store_check1(), "fast")
        m.store_unmark()
        m.arm_and_leave(publish_reservation=False, disarm=True)
        self.assertEqual(m.armed, 0, "PTE-conflict exit left armed set")
        self.assertEqual(m.store_check1(), "fast")
        m.store_unmark()

    def test_missing_disarm_pins_the_locked_path(self):
        """Regression for the reviewed defect: an arm-and-exit path that
        forgot the disarm leaves armed=1 and every later plain store on
        the locked path (correctness kept, performance lost). The shipped
        engine calls riscv_smp_maybe_disarm on all such exits."""
        m = Machine("drain")
        m.arm_and_leave(publish_reservation=False, disarm=False)
        self.assertEqual(m.armed, 1)
        self.assertEqual(m.store_check1(), "locked")
        self.assertEqual(m.in_store[0], 0)

    def test_reservation_keeps_armed_until_consumed(self):
        """A live reservation must keep every plain store on the locked
        path; only consuming/invalidating it may disarm."""
        m = Machine("drain")
        m.lr()
        self.assertEqual(m.armed, 1)
        self.assertEqual(m.store_check1(), "locked")
        m.locked_store(0xBEEF)                 # invalidates the reservation
        self.assertEqual(m.armed, 0)
        self.assertFalse(m.res_valid)


if __name__ == "__main__":
    unittest.main(verbosity=2)
