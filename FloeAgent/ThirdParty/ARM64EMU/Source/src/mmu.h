/* SPDX-License-Identifier: Apache-2.0 */
/* Floe P2 host-parallel changes, 2026 Floe contributors. */
/* Copyright 2026 Sylirre */
/* Virtual memory translation + typed guest memory access.
 * M0/M1: flat (MMU off). M2 extends mmu_translate for SCTLR.M=1. */
#ifndef A64_MMU_H
#define A64_MMU_H

#include "cpu.h"
#include "memory_sync.h"

typedef enum { ACC_READ, ACC_WRITE, ACC_EXEC } AccType;
/* Per-hart cache ownership. Binding ensures this CPU has a lazy cache;
 * switching harts never flushes another hart's translations. */
bool mmu_bind_cpu(CPU *c);
void ae_mmu_reset_cpu(CPU *c);
void ae_mmu_destroy_cpu(CPU *c);
size_t ae_mmu_cache_bytes(const CPU *c);
void mem_store_host_notify(CPU *c,const void *host,unsigned length);
bool mem_atomic_check(CPU *c,u64 va,unsigned size);
bool mem_reserve(CPU *c,u64 va,unsigned size);
bool mem_exclusive_check(CPU *c,u64 va,unsigned size,bool *success);
/* Translation/permission precede the physical transaction. No PT walk, MMIO
 * or coordinator wait is permitted while the guard is held. */
typedef struct MemoryTxn { CPU *cpu;u64 pa;unsigned size;u8 *host;MemoryGuard guard; } MemoryTxn;
bool mem_transaction_begin(CPU *c,u64 va,unsigned size,bool write,MemoryTxn *txn);
void mem_transaction_store(MemoryTxn *txn,const void *bytes);
void mem_transaction_end(MemoryTxn *txn);

/* Translate VA->PA for the current EL/state. On fault, raises the appropriate
 * synchronous exception (data/instruction abort) and returns false. */
bool mmu_translate(CPU *c, u64 va, AccType acc, u64 *pa_out);

/* Typed accesses. Return false if a fault was raised (caller must abort the
 * instruction and let the exception take effect). On success, *out holds data. */
bool mem_read(CPU *c, u64 va, unsigned size, u64 *out);
bool mem_write(CPU *c, u64 va, unsigned size, u64 val);

/* Non-faulting translate+read for diagnostics (false if VA doesn't translate). */
bool mem_peek(CPU *c, u64 va, unsigned size, u64 *out);

/* Non-faulting VA->PA probe (no TLB fill, no abort, permissions ignored).
 * Used by the JIT's IC IVAU handling to find the physical page whose
 * translations to drop. */
bool mmu_probe_pa(CPU *c, u64 va, u64 *pa_out);

/* AT S1E1R/W + S1E0R/W probe: returns the PAR_EL1 value for va (never faults,
 * never fills the TLB). is_write selects the W check, as_el0 the EL0 view. */
u64 mmu_at_s1(CPU *c, u64 va, bool is_write, bool as_el0);

/* Instruction-fetch translation cache, with a private byte-page snapshot.
 * Every instruction still checks the original translation predicate and an
 * atomic physical-page write version. A miss refills bytes AND version under
 * the existing RAM read guard; MMIO, nested transactions, absent metadata and
 * saturated versions retain live reads. TLBI/ISB clear host, forcing ACC_EXEC
 * revalidation before any snapshot can be reused. No native code is generated.
 * Two entries indexed by (el == 0) retain the original privilege separation. */
typedef struct {
    u64  page;   /* VA page base of the cached translation */
    u64  pa_page;/* physical page of the translation (JIT block identity) */
    u8  *host;   /* host pointer to that guest page (RAM/flash); NULL = invalid */
    u8   mmu;    /* SCTLR_EL1.M of the cached translation */
    MemoryCodeEpoch *epoch; /* immutable Machine-owned physical page metadata */
    u64 snapshot_version,snapshot_pa; /* version 0 is invalid, MAX is never cached */
    u16 active_slot; /* hint only: slot PA/epoch/version/generation revalidated */
} FetchCache;

/* Slow path: translate, refresh the fetch cache, read. Used on a cache miss. */
bool mem_ifetch_slow(CPU *c, u64 va, u32 *insn_out);
bool mem_ifetch_refill(CPU *c,FetchCache *f,u64 va,u32 *insn_out);
/* Block helpers for SIMD 128-bit and pair accesses (two 64-bit halves). */
bool mem_read128(CPU *c, u64 va, V128 *out);
bool mem_write128(CPU *c, u64 va, const V128 *val);

/* Invalidate the software TLB (called on TLBI / TTBR / context changes). */
void tlb_flush_all(CPU *c);
void tlb_flush_machine(struct Machine *m);
void tlb_flush_machine_page(struct Machine *m,u64 va);

/* Single-page invalidation for the VA-form TLBIs (VAE1/VAAE1/VALE1/VAALE1):
 * clears the page's TLB/D-TLB slots and the fetch cache without bumping the
 * flush generation, so every other cached translation survives. Escalates to
 * tlb_flush_all when va falls inside the recorded large-page (block-mapped)
 * range — the TLB fragments 2 MB/1 GB blocks into 4 KB entries, and one
 * block-VA TLBI must not leave sibling fragments alive. */
void tlb_flush_page(CPU *c,u64 va);

/* Bumped by every tlb_flush_page: the JIT dispatcher purges its VA-keyed
 * indirect-branch jcache when this moves (its blocks/D-TLB need nothing —
 * blocks are PA-keyed and re-verified at dispatch, D-TLB slots are cleared
 * above). */
/* The VA invalidation sequence is private in each MMUCache. */

/* ---------------- data-access fast path: host-pointer D-TLB ----------------
 * Direct-mapped cache of VA page -> host RAM page, probed by mem_read/mem_write
 * before the full translate+bus path. RAM pages only: flash (CFI command state)
 * and MMIO (side effects) are never inserted, so they always take the bus path.
 * The entry layout is an ABI shared with the JIT backends (which emit this
 * probe inline) — do not change it without updating them.
 *
 * tag: VA page | flush-generation (bits 11:2) | SCTLR.M (bit 1) | EL0 (bit 0).
 *      Folding the generation into the tag makes tlb_flush_all O(1): bumping
 *      this hart's tlb_gen invalidates every entry without touching the array. The
 *      10-bit slice aliases every 1024 flushes; tlb_flush_all memsets then.
 * pte: 4 KB-aligned host page pointer | write-allowed (bit 1) | read (bit 0).
 *      A zeroed entry has no permission bits, so it can never fast-path. */
#define DTLB_BITS 12
#define DTLB_SIZE (1u << DTLB_BITS)
#define DTLB_R    1u
#define DTLB_W    2u
typedef struct { u64 tag; u64 pte; } DTlbEnt;
_Static_assert(sizeof(DTlbEnt) == 16, "DTlbEnt layout is a JIT backend ABI");
#define TLB_ENTRIES 4096
typedef struct {
    u64 va_page,pa_page;
    u32 gen;
    u8 valid,ap,uxn,pxn,el0;
} TLBEntry;
/* Physical byte working set. These are data snapshots, never host code.
 * Lookup scans only four ways on an active miss; the per-instruction active
 * path checks one indexed slot. A slot is owned by exactly one hart, shared by
 * that hart's two permission-separated translation entries. */
#define IFETCH_BANK_SETS 16u
#define IFETCH_BANK_WAYS 4u
#define IFETCH_BANK_PAGES (IFETCH_BANK_SETS*IFETCH_BANK_WAYS)
typedef struct IFetchBytePage {
    u64 pa_page;
    MemoryCodeEpoch *epoch;
    u64 version; /* 0 invalid; UINT64_MAX is never installed */
    u32 generation;
    u8 bytes[4096];
} IFetchBytePage;
typedef struct MMUCache {
    TLBEntry tlb[TLB_ENTRIES];
    FetchCache fcache[2];
    DTlbEnt dtlb[DTLB_SIZE];
    u32 tlb_gen,tlbi_va_seq;
    u64 lp_base,lp_mask;
    u32 ifetch_generation; /* TLBI/ISB invalidates metadata, not 256KiB of bytes */
    u8 ifetch_next[IFETCH_BANK_SETS]; /* deterministic per-set round-robin fill */
    IFetchBytePage ifetch_bank[IFETCH_BANK_PAGES];
} MMUCache;

/* The shared bus retains this compatibility hook. This library has no native
 * translations and its bitmap is immutable NULL; PD validates live words. */
extern const u8 *const g_jit_code_bitmap; /* immutable NULL in this library */
void jit_invalidate_phys_range(u64 pa, u64 len);   /* no_native_jit.c */

/* The EL0 bit is the *effective* access privilege: an LDTR/STTR at EL1
 * (c->ldst_unpriv, set transiently by decode.c) tags as EL0, so it misses
 * EL1-filled entries and shares the EL0-view entries — whose cached R/W were
 * computed with exactly the EL0 permission check it needs. The JIT's inline
 * probe precomputes these bits (dtlb_ctxgen) with ldst_unpriv always 0: the
 * fast engines never execute LDTR/STTR natively (predecode leaves them
 * GENERIC), so compiled code only ever probes at its real EL. */
static inline u64 dtlb_tag(const CPU *c, u64 va) {
    return (va & ~0xfffULL) | ((u64)(c->exec.mmu->tlb_gen & 0x3ff) << 2)
         | ((c->sctlr[1] & 1) ? 2u : 0u)
         | ((c->el == 0 || c->ldst_unpriv) ? 1u : 0u);
}
static inline DTlbEnt *dtlb_ent(CPU *c,u64 va) {
    return &c->exec.mmu->dtlb[(va >> 12) & (DTLB_SIZE - 1)];
}

/* PD scalar loads pass a constant 1/2/4/8-byte width here. Only a proven
 * same-page RAM D-TLB read hit bypasses mem_read; all other accesses retain
 * its allocation, page split, permission, bus and exception semantics.
 * The reference mem_read has no separate SCTLR.A check; preserve that
 * behavior without adding a new fault or an extra hot-path gate. */
static inline bool mem_read_pd(CPU *c, u64 va, unsigned size, u64 *out) {
    if ((size != 1 && size != 2 && size != 4 && size != 8) || !c->exec.mmu)
        return mem_read(c, va, size, out);
    u64 off = va & 0xfffULL;
    if (off + size > 0x1000)
        return mem_read(c, va, size, out);
    DTlbEnt *de = dtlb_ent(c, va);
    if (de->tag != dtlb_tag(c, va) || !(de->pte & DTLB_R))
        return mem_read(c, va, size, out);
    return memory_read_small(c->m,(const u8 *)(uintptr_t)(de->pte & ~0xfffULL)+off,size,out);
}

/* Only called after the original VA/EL/MMU/ACC_EXEC translation predicate.
 * Permission is never inferred from a physical working-set hit. */
bool mem_ifetch_bank_lookup(CPU *c,FetchCache *f,u64 va,u64 version,u32 *insn_out);
static inline bool mem_ifetch_page(CPU *c,FetchCache *f,u64 va,u32 *insn_out) {
    /* Nested transactions never reuse or install snapshots. */
    if(f->epoch&&!memory_guard_held) {
        u64 version=atomic_load_explicit(&f->epoch->version,memory_order_acquire);
        if(version!=UINT64_MAX) {
            MMUCache *m=c->exec.mmu;
            if(version&&f->snapshot_version==version&&f->snapshot_pa==f->pa_page&&
               f->active_slot<IFETCH_BANK_PAGES) {
                IFetchBytePage *slot=&m->ifetch_bank[f->active_slot];
                /* Another EL can replace this slot with an equal version on a
                 * different PA. The active index/mirrors alone are never valid. */
                if(slot->generation==m->ifetch_generation&&slot->version==version&&
                   slot->pa_page==f->pa_page&&slot->epoch==f->epoch) {
                    __builtin_memcpy(insn_out,slot->bytes+(va&0xfffULL),4);
                    return true;
                }
            }
            if(version)return mem_ifetch_bank_lookup(c,f,va,version,insn_out);
            return mem_ifetch_refill(c,f,va,insn_out); /* inactive 0 cannot hit */
        }
    }
    /* Original live-word path: nested, missing metadata, or sticky MAX. */
    MemoryGuard guard;
    if(!memory_guard_host(&guard,c->m,f->host+(va&0xfffULL),4,false))return false;
    __builtin_memcpy(insn_out,f->host+(va&0xfffULL),4);
    memory_guard_end(&guard);
    return true;
}

static inline bool mem_ifetch(CPU *c, u64 va, u32 *insn_out) {
    if(!mmu_bind_cpu(c))return false;
    u64 page = va & ~0xfffULL;
    FetchCache *f = &c->exec.mmu->fcache[c->el == 0];
    /* A misaligned PC (only reachable via a bad indirect branch) takes the slow
     * path, which raises a PC-alignment fault instead of fetching rotated bytes. */
    if (f->host && f->page == page && !(va & 3) &&
        f->mmu == (u8)(c->sctlr[1] & 1)) {
        return mem_ifetch_page(c,f,va,insn_out);
    }
    return mem_ifetch_slow(c, va, insn_out);
}

#endif /* A64_MMU_H */

/* Private synchronous PD stack-view chain. Canonical callers above, including
 * decode/GENERIC, DMA and direct component calls, retain their original APIs.
 * No entry here constructs a view from a CPU or retains/reuses one. */
#if defined(AE_PD_GUARD_SLOT_PRIVATE) && !defined(AE_PD_MMU_GUARD_SLOT_PRIVATE_H)
#define AE_PD_MMU_GUARD_SLOT_PRIVATE_H
#include "memory_sync.h"
__attribute__((visibility("hidden")))
bool mem_ifetch_bank_lookup_unheld(CPU *c,FetchCache *f,u64 va,u64 version,u32 *out);
__attribute__((visibility("hidden")))
bool mem_ifetch_refill_unheld(CPU *c,FetchCache *f,u64 va,u32 *out);

static inline bool mem_read_pd_slot(CPU *c,u64 va,unsigned size,u64 *out,
                                    const PDGuardSlotView *view) {
    if((size!=1&&size!=2&&size!=4&&size!=8)||!c->exec.mmu)
        return mem_read(c,va,size,out);
    u64 off=va&0xfffULL;
    if(off+size>0x1000)return mem_read(c,va,size,out);
    DTlbEnt *de=dtlb_ent(c,va);
    if(de->tag!=dtlb_tag(c,va)||!(de->pte&DTLB_R))return mem_read(c,va,size,out);
    const u8 *host=(const u8 *)(uintptr_t)(de->pte&~0xfffULL)+off;
    /* Reload the pointer VALUE for this access, never hoist a NULL snapshot
     * across instructions or GENERIC. A real nested guard keeps its old path. */
    if(*view->slot)return memory_read_small(c->m,host,size,out);
    return memory_read_small_pd_unheld(c->m,host,size,out);
}

static inline bool mem_ifetch_page_slot(CPU *c,FetchCache *f,u64 va,u32 *out,
                                        const PDGuardSlotView *view) {
    if(f->epoch&&!*view->slot) {
        u64 version=atomic_load_explicit(&f->epoch->version,memory_order_acquire);
        if(version!=UINT64_MAX) {
            MMUCache *m=c->exec.mmu;
            if(version&&f->snapshot_version==version&&f->snapshot_pa==f->pa_page&&
               f->active_slot<IFETCH_BANK_PAGES) {
                IFetchBytePage *slot=&m->ifetch_bank[f->active_slot];
                if(slot->generation==m->ifetch_generation&&slot->version==version&&
                   slot->pa_page==f->pa_page&&slot->epoch==f->epoch) {
                    __builtin_memcpy(out,slot->bytes+(va&0xfffULL),4);return true;
                }
            }
            if(version)return mem_ifetch_bank_lookup_unheld(c,f,va,version,out);
            return mem_ifetch_refill_unheld(c,f,va,out);
        }
    }
    MemoryGuard guard;
    if(!memory_guard_host(&guard,c->m,f->host+(va&0xfffULL),4,false))return false;
    __builtin_memcpy(out,f->host+(va&0xfffULL),4);
    memory_guard_end(&guard);return true;
}
static inline bool mem_ifetch_slot(CPU *c,u64 va,u32 *out,const PDGuardSlotView *view) {
    if(!mmu_bind_cpu(c))return false;
    u64 page=va&~0xfffULL;FetchCache *f=&c->exec.mmu->fcache[c->el==0];
    if(f->host&&f->page==page&&!(va&3)&&f->mmu==(u8)(c->sctlr[1]&1))
        return mem_ifetch_page_slot(c,f,va,out,view);
    return mem_ifetch_slow(c,va,out);
}
#endif
