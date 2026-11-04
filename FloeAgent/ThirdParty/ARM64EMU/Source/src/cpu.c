/* SPDX-License-Identifier: Apache-2.0 */
/* Floe P2 host-parallel changes, 2026 Floe contributors. */
/* Copyright 2026 Sylirre */
/* CPU core: reset, single-step driver, condition codes, dump. */
#include "cpu.h"
#include "mmu.h"
#include "machine.h"
#include "sysreg.h"
#include "jit/predecode.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int g_trace = 0;
int g_singlestep = 0;
int g_dbg = 0;
int g_rtrace = 0;
int g_prof = 0;
u64 g_tpc = 0;       /* env AETPC: dump state whenever pc == this (debug) */
int g_ring = 0;      /* env AERING: record a ring buffer of recent steps */
u64 g_watch = 0;     /* env AEWATCH: log writes to [g_watch, g_watch+8) */
int g_iabort_log = 0;/* env AEIABORT: log instruction aborts (debug) */
int g_rtclock = 1;   /* env AE_RTCLOCK: host-clock timer (default); 0 = deterministic (debug) */
u64 g_vawatch = 0;   /* env AEVAW: log writes whose range covers this VA (debug) */
int g_systrace = 0;  /* env AESYS: trace mm syscalls (mmap/brk/munmap/...) (debug) */

/* One-shot record of an in-flight mm syscall, logged with its result when EL0
 * resumes. Lets us see musl's heap/mmap layout around the /init corruption. */
static _Thread_local struct { int active; u64 num, a0, a1, a2, a3, ic; } g_sysp;
static const char *sysname(u64 n) {
    switch (n) {
        case 214: return "brk";    case 215: return "munmap"; case 216: return "mremap";
        case 220: return "clone";  case 221: return "execve"; case 222: return "mmap";
        case 226: return "mprotect"; default: return "?";
    }
}
/* Dump a NUL-terminated user string via non-faulting peek (for execve tracing). */
static void dump_ustr(CPU *c, u64 va) {
    if (!va) { fprintf(stderr, "(null)"); return; }
    u64 b; if (!mem_peek(c, va, 1, &b)) { fprintf(stderr, "<UNMAPPED 0x%llx>", (unsigned long long)va); return; }
    fprintf(stderr, "\"");
    for (int i = 0; i < 80; i++) {
        if (!mem_peek(c, va + i, 1, &b)) { fprintf(stderr, "<FAULT@+%d>", i); break; }
        if (!b) break;
        fputc((b >= 32 && b < 127) ? (int)b : '.', stderr);
    }
    fprintf(stderr, "\"");
}

/* Dump a NULL-terminated user pointer array (argv/envp), flagging bad pointers. */
static void dump_uptrarr(CPU *c, const char *tag, u64 arr) {
    fprintf(stderr, "  %s@0x%llx:\n", tag, (unsigned long long)arr);
    for (int i = 0; i < 40; i++) {
        u64 p;
        if (!mem_peek(c, arr + (u64)i * 8, 8, &p)) { fprintf(stderr, "   [%d] <array UNMAPPED>\n", i); break; }
        if (!p) break;
        u64 b; bool mapped = mem_peek(c, p, 1, &b);
        fprintf(stderr, "   [%d] 0x%llx %s ", i, (unsigned long long)p, mapped ? "->" : "-> *** UNMAPPED ***");
        if (mapped) dump_ustr(c, p);
        fprintf(stderr, "\n");
    }
}

void systrace_svc(CPU *c) {
    if (!g_systrace || c->el != 0) return;
    u64 n = c->x[8];
    if (n != 214 && n != 215 && n != 216 && n != 220 && n != 221 && n != 222 && n != 226)
        return;
    g_sysp.active = 1; g_sysp.num = n;
    g_sysp.a0 = c->x[0]; g_sysp.a1 = c->x[1]; g_sysp.a2 = c->x[2]; g_sysp.a3 = c->x[3];
    g_sysp.ic = c->icount;
    if (n == 221) {                          /* execve: dump path/argv/envp now */
        fprintf(stderr, "[execve] ic=%llu ttbr0=0x%llx path=",
                (unsigned long long)c->icount, (unsigned long long)c->ttbr0[1]);
        dump_ustr(c, c->x[0]); fprintf(stderr, "\n");
        dump_uptrarr(c, "argv", c->x[1]);
        dump_uptrarr(c, "envp", c->x[2]);
    }
}

/* ---- musl mallocng double-allocation detector (env AEHEAP=1) ----------------
 * The line-438 execve EFAULT is heap corruption: in the /init shell, ash's
 * string-stack output block aliases the live `environ` array (both base
 * 0xffff9c9ca180), so ash's lexer writes "in\0" over environ[0]. This tracker
 * pinpoints the allocation that hands out the live environ block.
 *
 * musl's public malloc/free/realloc are 4-byte position-independent branch
 * wrappers; ALL user allocations funnel through them (calloc/realloc call
 * malloc@plt). We match them by (pc & 0xfff) + the exact instruction word, so no
 * load base is needed, and we compute each call's musl base = pc - file_offset.
 * Allocations are tracked PER PROCESS, keyed by TTBR0 table base (so re-exec'd
 * children and the unrelated first EL0 process do not confuse one another).
 * We fire when an allocation returns either (A) the address __environ currently
 * points at (the live environ array handed back out), or (B) a base already live
 * in the same process (a plain double-alloc). __environ is at musl file offset
 * 0xc2008 (from the .so dynsym).                                                */
int g_heaptrack = 0;
#define HT_MALLOC_OFF   0x834
#define HT_MALLOC_INS   0x14000584u
#define HT_FREE_OFF     0x73c
#define HT_FREE_INS     0x14000271u
#define HT_REALLOC_OFF  0x9a4
#define HT_REALLOC_INS  0x17fffef4u
#define HT_MALLOC_FOFF  0x28834
#define HT_FREE_FOFF    0x2873c
#define HT_REALLOC_FOFF 0x2a9a4
#define HT_ENVIRON_FOFF 0xc2008

#define HT_BUCKETS (1u << 20)
#define HT_NODES   (1 << 21)     /* signed: compared against int ht_node_top */
static _Thread_local int *ht_bucket;                 /* head node index, or -1 */
struct htnode { u64 ttbr, base, size, site; int next; };
static _Thread_local struct htnode *ht_node;
static _Thread_local int ht_free_head = -1, ht_node_top = 0;
static _Thread_local long ht_live = 0;
/* one outstanding top-level alloc, timed for its return value */
static _Thread_local struct { int active, is_realloc; u64 old, size, lr, sp, callpc, ic, ttbr, musl; } ht_call;
static _Thread_local int ht_fires = 0;
static _Thread_local long ht_nmalloc = 0, ht_nfree = 0, ht_nrealloc = 0;
u64 g_heap_at = 0;          /* env AEHEAP_AT: log every alloc/free touching this VA */
/* TTBR0 carries the ASID in the high bits; key on the table base only so an
 * ASID change for the same process does not split it into two identities. */
static inline u64 ht_pgbase(u64 t) { return t & 0x0000FFFFFFFFF000ULL; }
void heaptrack_report(void) {
    fprintf(stderr, "[HEAP] report: malloc=%ld free=%ld realloc=%ld live=%ld nodes=%d fires=%d\n",
            ht_nmalloc, ht_nfree, ht_nrealloc, ht_live, ht_node_top, ht_fires);
}

static inline unsigned ht_hash(u64 ttbr, u64 base) {
    return (unsigned)((((base >> 4) ^ (ttbr >> 12)) * 0x9E3779B97F4A7C15ULL) >> 44) & (HT_BUCKETS - 1);
}
static int ht_find(u64 ttbr, u64 base, u64 *size, u64 *site) {
    for (int n = ht_bucket[ht_hash(ttbr, base)]; n >= 0; n = ht_node[n].next)
        if (ht_node[n].base == base && ht_node[n].ttbr == ttbr) {
            if (size) *size = ht_node[n].size;
            if (site) *site = ht_node[n].site;
            return 1;
        }
    return 0;
}
static void ht_insert(u64 ttbr, u64 base, u64 size, u64 site) {
    int n = ht_free_head;
    if (n >= 0) ht_free_head = ht_node[n].next;
    else if (ht_node_top < HT_NODES) n = ht_node_top++;
    else { fprintf(stderr, "[HEAP] node pool exhausted (live=%ld)\n", ht_live); g_heaptrack = 0; return; }
    ht_node[n].ttbr = ttbr; ht_node[n].base = base; ht_node[n].size = size; ht_node[n].site = site;
    unsigned b = ht_hash(ttbr, base);
    ht_node[n].next = ht_bucket[b]; ht_bucket[b] = n; ht_live++;
}
static void ht_remove(u64 ttbr, u64 base) {
    unsigned b = ht_hash(ttbr, base);
    int prev = -1;
    for (int n = ht_bucket[b]; n >= 0; prev = n, n = ht_node[n].next)
        if (ht_node[n].base == base && ht_node[n].ttbr == ttbr) {
            if (prev < 0) ht_bucket[b] = ht_node[n].next; else ht_node[prev].next = ht_node[n].next;
            ht_node[n].base = 0;
            ht_node[n].next = ht_free_head; ht_free_head = n; ht_live--;
            return;
        }
}
/* Which live block of the current process (if any) contains `va`? (write-watch) */
void heaptrack_query(CPU *c, u64 va) {
    if (!g_heaptrack) return;
    u64 ttbr = ht_pgbase(c->ttbr0[1]);
    for (int n = 0; n < ht_node_top; n++) {
        u64 b = ht_node[n].base;
        if (b && ht_node[n].ttbr == ttbr && va >= b && va < b + ht_node[n].size) {
            fprintf(stderr, "[HEAP] va 0x%llx is INSIDE live block base=0x%llx size=%llu (+0x%llx) site=0x%llx\n",
                    (unsigned long long)va, (unsigned long long)b, (unsigned long long)ht_node[n].size,
                    (unsigned long long)(va - b), (unsigned long long)ht_node[n].site);
            return;
        }
    }
    fprintf(stderr, "[HEAP] va 0x%llx is NOT inside any live tracked block of this proc (live=%ld)\n",
            (unsigned long long)va, ht_live);
}
static u64 ht_read_environ(CPU *c, u64 musl) {     /* value of __environ for a process */
    u64 v;
    if (!mem_peek(c, musl + HT_ENVIRON_FOFF, 8, &v)) return 0;
    return v;
}
static void ht_dump_words(CPU *c, u64 va, int n) {
    for (int i = 0; i < n; i++) {
        u64 w;
        if (!mem_peek(c, va + (u64)i * 8, 8, &w)) { fprintf(stderr, "   [+%d] <unmapped>\n", i * 8); break; }
        fprintf(stderr, "   [+%-3d] 0x%016llx\n", i * 8, (unsigned long long)w);
    }
}
static void heaptrack_step(CPU *c, u32 insn) {
    u64 ttbr = ht_pgbase(c->ttbr0[1]);
    /* capture the return value of a timed top-level alloc */
    if (ht_call.active) {
        if (c->pc == ht_call.lr && ttbr == ht_call.ttbr && *cpu_cur_sp(c) >= ht_call.sp) {
            u64 ret = c->x[0];
            if (ht_call.is_realloc && ret) ht_remove(ht_call.ttbr, ht_call.old);
            if (ret) {
                u64 env = ht_read_environ(c, ht_call.musl);
                u64 vsz = 0, vsite = 0;
                int hit_env = (env && ret == env);
                int hit_live = ht_find(ht_call.ttbr, ret, &vsz, &vsite);
                if ((hit_env || hit_live) && ht_fires < 30) {
                    ht_fires++;
                    fprintf(stderr,
                        "\n[HEAP] *** DOUBLE-ALLOC #%d *** %s returned %s\n"
                        "   ret=0x%llx size=%llu callsite=0x%llx ic=%llu ttbr=0x%llx musl=0x%llx\n"
                        "   __environ=0x%llx (ret==environ? %s)  prior-live-block? %s (size=%llu site=0x%llx)\n",
                        ht_fires, ht_call.is_realloc ? "realloc" : "malloc",
                        hit_env ? "the LIVE __environ array" : "an already-live block",
                        (unsigned long long)ret, (unsigned long long)ht_call.size,
                        (unsigned long long)ht_call.callpc, (unsigned long long)ht_call.ic,
                        (unsigned long long)ht_call.ttbr, (unsigned long long)ht_call.musl,
                        (unsigned long long)env, hit_env ? "YES" : "no",
                        hit_live ? "YES" : "no", (unsigned long long)vsz, (unsigned long long)vsite);
                    ht_dump_words(c, ret, 6);
                    ring_dump();
                }
                if (g_heap_at && ret <= g_heap_at && g_heap_at < ret + (ht_call.size ? ht_call.size : 1))
                    fprintf(stderr, "[AT] %s ret=0x%llx size=%llu (AT +0x%llx) callsite=0x%llx ic=%llu ttbr=0x%llx __environ=0x%llx\n",
                            ht_call.is_realloc ? "realloc" : "malloc", (unsigned long long)ret,
                            (unsigned long long)ht_call.size, (unsigned long long)(g_heap_at - ret),
                            (unsigned long long)ht_call.callpc, (unsigned long long)ht_call.ic,
                            (unsigned long long)ht_call.ttbr, (unsigned long long)env);
                if (hit_live) ht_remove(ht_call.ttbr, ret);
                ht_insert(ht_call.ttbr, ret, ht_call.size, ht_call.callpc);
            }
            ht_call.active = 0;
        }
        return;                                /* ignore hooks nested inside the timed call */
    }
    u32 off = (u32)(c->pc & 0xfff);
    if (insn == HT_MALLOC_INS && off == HT_MALLOC_OFF) {
        ht_nmalloc++;
        ht_call.active = 1; ht_call.is_realloc = 0; ht_call.old = 0; ht_call.size = c->x[0];
        ht_call.lr = c->x[30]; ht_call.sp = *cpu_cur_sp(c); ht_call.callpc = c->x[30];
        ht_call.ic = c->icount; ht_call.ttbr = ttbr; ht_call.musl = c->pc - HT_MALLOC_FOFF;
    } else if (insn == HT_REALLOC_INS && off == HT_REALLOC_OFF) {
        ht_nrealloc++;
        ht_call.active = 1; ht_call.is_realloc = 1; ht_call.old = c->x[0]; ht_call.size = c->x[1];
        ht_call.lr = c->x[30]; ht_call.sp = *cpu_cur_sp(c); ht_call.callpc = c->x[30];
        ht_call.ic = c->icount; ht_call.ttbr = ttbr; ht_call.musl = c->pc - HT_REALLOC_FOFF;
    } else if (insn == HT_FREE_INS && off == HT_FREE_OFF) {
        ht_nfree++;
        if (c->x[0]) {
            u64 env = ht_read_environ(c, c->pc - HT_FREE_FOFF);
            if (c->x[0] == env)
                fprintf(stderr, "[HEAP] free() of the LIVE __environ array 0x%llx ic=%llu callsite=0x%llx ttbr=0x%llx\n",
                        (unsigned long long)c->x[0], (unsigned long long)c->icount,
                        (unsigned long long)c->x[30], (unsigned long long)ttbr);
            if (g_heap_at) {
                u64 fsz = 0;
                int known = ht_find(ttbr, c->x[0], &fsz, 0);
                if (c->x[0] == g_heap_at || (known && c->x[0] <= g_heap_at && g_heap_at < c->x[0] + (fsz ? fsz : 1)))
                    fprintf(stderr, "[AT] free   ptr=0x%llx size=%llu (AT +0x%llx) callsite=0x%llx ic=%llu ttbr=0x%llx __environ=0x%llx\n",
                            (unsigned long long)c->x[0], (unsigned long long)fsz,
                            (unsigned long long)(g_heap_at - c->x[0]), (unsigned long long)c->x[30],
                            (unsigned long long)c->icount, (unsigned long long)ttbr, (unsigned long long)env);
            }
            ht_remove(ttbr, c->x[0]);
        }
    }
}
void heaptrack_init(void) {
    ht_bucket = malloc(HT_BUCKETS * sizeof(int));
    ht_node = malloc(HT_NODES * sizeof *ht_node);
    for (unsigned i = 0; i < HT_BUCKETS; i++) ht_bucket[i] = -1;
}

/* Coverage-divergence finder (env AECOV=file): a sorted set of PCs QEMU is known
 * to execute. The first PC our run executes that is NOT in this set marks where
 * we left QEMU's path — i.e. at/just after the first control-flow divergence. */
static u64 *g_cov;
static size_t g_cov_n;
static int cmp_u64(const void *a, const void *b) {
    u64 x = *(const u64 *)a, y = *(const u64 *)b;
    return (x > y) - (x < y);
}
void cov_load(const char *path) {
    FILE *f = fopen(path, "r");
    if (!f) { fprintf(stderr, "cov: cannot open %s\n", path); return; }
    size_t cap = 4096; g_cov = malloc(cap * sizeof(u64)); g_cov_n = 0;
    char line[64];
    while (fgets(line, sizeof line, f)) {
        u64 v = strtoull(line, NULL, 16);
        if (g_cov_n == cap) { cap *= 2; g_cov = realloc(g_cov, cap * sizeof(u64)); }
        g_cov[g_cov_n++] = v;
    }
    fclose(f);
    qsort(g_cov, g_cov_n, sizeof(u64), cmp_u64);
    fprintf(stderr, "cov: loaded %zu PCs from %s\n", g_cov_n, path);
}
static bool cov_has(u64 pc) {
    return bsearch(&pc, g_cov, g_cov_n, sizeof(u64), cmp_u64) != NULL;
}

/* Recent-instruction ring buffer: records (pc, insn, x-snapshot) so a fault can
 * be explained by the basic block that led to it. */
#define RING_N 96
static _Thread_local struct { u64 pc; u32 insn; u64 x0, x1, x2; } g_ringbuf[RING_N];
static _Thread_local unsigned g_ringpos;
static void ring_record(CPU *c, u32 insn) {
    unsigned i = g_ringpos++ & (RING_N - 1);
    g_ringbuf[i].pc = c->pc; g_ringbuf[i].insn = insn;
    g_ringbuf[i].x0 = c->x[0]; g_ringbuf[i].x1 = c->x[1]; g_ringbuf[i].x2 = c->x[2];
}
void ring_dump(void) {
    if (!g_ring) return;
    fprintf(stderr, "[ring] last %d instructions (oldest first):\n", RING_N);
    for (int k = 0; k < RING_N; k++) {
        unsigned i = (g_ringpos + k) & (RING_N - 1);
        if (g_ringbuf[i].pc == 0) continue;
        fprintf(stderr, "  pc=0x%llx insn=0x%08x x0=0x%llx x1=0x%llx x2=0x%llx\n",
                (unsigned long long)g_ringbuf[i].pc, g_ringbuf[i].insn,
                (unsigned long long)g_ringbuf[i].x0, (unsigned long long)g_ringbuf[i].x1,
                (unsigned long long)g_ringbuf[i].x2);
    }
}

/* Lightweight hot-PC profiler (env AEPROF=1). A direct-mapped histogram that
 * tells whether the CPU is spinning in a tight loop vs. making broad progress.
 * Off by default; one predictable branch in the step loop when enabled. */
#define PROF_SLOTS 65536
struct ProfEntry { u64 pc,hits; };
static _Thread_local struct ProfEntry *g_prof_tab;
static void prof_record(u64 pc) {
    if(!g_prof_tab){g_prof_tab=calloc(PROF_SLOTS,sizeof(*g_prof_tab));if(!g_prof_tab)return;}
    unsigned i = (unsigned)((pc >> 2) & (PROF_SLOTS - 1));
    /* linear probe a few slots to limit collisions */
    for (int k = 0; k < 8; k++) {
        unsigned j = (i + k) & (PROF_SLOTS - 1);
        if (g_prof_tab[j].hits == 0 || g_prof_tab[j].pc == pc) {
            g_prof_tab[j].pc = pc; g_prof_tab[j].hits++; return;
        }
    }
    g_prof_tab[i].hits++;   /* collision overflow: still counts */
}
void prof_dump(void) {
    if (!g_prof||!g_prof_tab) return;
    /* selection of the top 25 by hits */
    for (int n = 0; n < 25; n++) {
        unsigned best = 0; u64 bh = 0;
        for (unsigned j = 0; j < PROF_SLOTS; j++)
            if (g_prof_tab[j].hits > bh) { bh = g_prof_tab[j].hits; best = j; }
        if (bh == 0) break;
        fprintf(stderr, "[prof] pc=0x%llx hits=%llu\n",
                (unsigned long long)g_prof_tab[best].pc, (unsigned long long)bh);
        g_prof_tab[best].hits = 0;   /* consume */
    }
}

/* Worker exit, after guest execution and before thread destruction. Debug
 * controls/coverage are configured only while the public owner is quiet. */
void cpu_debug_release(void){free(ht_bucket);ht_bucket=NULL;free(ht_node);ht_node=NULL;free(g_prof_tab);g_prof_tab=NULL;}
__attribute__((weak,visibility("hidden"),noinline))
void *ae_exec_cache_alloc(size_t bytes) { return calloc(1,bytes); }
__attribute__((weak,visibility("hidden"),noinline))
void ae_exec_cache_free(void *p) { free(p); }
void cpu_exec_reset(CPU *c) {
    ae_mmu_reset_cpu(c);ae_pd_reset_cpu(c);c->exec.fp_pending=0;
}
void cpu_exec_destroy(CPU *c) {
    ae_fp_unbind_cpu(c);ae_mmu_destroy_cpu(c);ae_pd_destroy_cpu(c);
    c->exec.fp_pending=0;
}
size_t cpu_exec_cache_bytes(const CPU *c) {
    return ae_mmu_cache_bytes(c)+ae_pd_cache_bytes(c);
}
void cpu_reset(CPU *c, u64 entry, unsigned reset_el) {
    struct Machine *m = c->m;
    unsigned hart_id=c->hart_id;
    memory_monitor_clear(c); /* target is quiescent; shared monitor lives outside memset */
    CPUExecContext owned=c->exec;
    if(++owned.reset_generation==0)owned.reset_generation=1;
    memset(c, 0, sizeof(*c));
    c->exec=owned;cpu_exec_reset(c);
    c->m = m;
    c->hart_id=hart_id;c->power=CPU_POWER_ON;
    c->pc = entry;
    c->el = reset_el;
    c->sp_sel = 1;                       /* SPSel=1 at reset (use SP_ELx) */
    c->daif = PS_D | PS_A | PS_I | PS_F; /* all masked at reset */
    c->nzcv = 0;
    c->cntfrq = 24000000ULL;             /* 24 MHz, matches virt DTB */
    /* MPIDR_EL1: bit31 RES1, single core affinity 0. */
    c->mpidr = (1ULL << 31)|hart_id;
    if (sysreg_init) sysreg_init(c);
}

void cpu_sleep(CPU *c,CPUSleep kind) { c->sleep=kind;c->halted=true; }
void cpu_wake(CPU *c) {
    if(c->power!=CPU_POWER_ON)return;
    c->sleep=CPU_SLEEP_NONE;c->halted=false;
}

bool cond_holds(CPU *c, unsigned cond) {
    bool N = (c->nzcv & PS_N) != 0;
    bool Z = (c->nzcv & PS_Z) != 0;
    bool C = (c->nzcv & PS_C) != 0;
    bool V = (c->nzcv & PS_V) != 0;
    bool r;
    switch (cond >> 1) {
        case 0: r = Z; break;                 /* EQ/NE */
        case 1: r = C; break;                 /* CS/CC */
        case 2: r = N; break;                 /* MI/PL */
        case 3: r = V; break;                 /* VS/VC */
        case 4: r = C && !Z; break;           /* HI/LS */
        case 5: r = (N == V); break;          /* GE/LT */
        case 6: r = (N == V) && !Z; break;    /* GT/LE */
        default: r = true; break;             /* AL/NV */
    }
    if ((cond & 1) && cond != 0xf) r = !r;
    return r;
}

/* Set whenever any per-instruction debug facility is active (trace/rtrace/prof/
 * ring/cov/tpc). Keeps the step hot path to a single predictable branch when no
 * debugging is enabled, preserving interpreter throughput. */
int g_debug_hooks = 0;

/* Run the active per-instruction debug facilities. Returns true if execution
 * should stop (the coverage divergence finder hit a foreign PC). Only ever
 * called when g_debug_hooks is set. */
static bool step_debug(CPU *c, u32 insn) {
    if (g_rtrace) {
        fprintf(stderr, "P%llx", (unsigned long long)c->pc);
        for (int i = 0; i < 31; i++) fprintf(stderr, " %llx", (unsigned long long)c->x[i]);
        fprintf(stderr, " S%llx\n", (unsigned long long)*cpu_cur_sp(c));
    }
    if (g_trace) {
        fprintf(stderr, "%016llx: %08x  [el%u nzcv=%c%c%c%c]\n",
                (unsigned long long)c->pc, insn, c->el,
                (c->nzcv & PS_N) ? 'N' : '.', (c->nzcv & PS_Z) ? 'Z' : '.',
                (c->nzcv & PS_C) ? 'C' : '.', (c->nzcv & PS_V) ? 'V' : '.');
    }
    if (g_prof) prof_record(c->pc);
    if (g_heaptrack && c->el == 0) heaptrack_step(c, insn);
    if (g_ring) ring_record(c, insn);
    if (g_cov_n && c->icount > 1000 && !cov_has(c->pc)) {
        fprintf(stderr, "[cov] FIRST FOREIGN PC=0x%llx insn=0x%08x icount=%llu el=%u\n",
                (unsigned long long)c->pc, insn, (unsigned long long)c->icount, c->el);
        ring_dump();
        c->stop = true;
        return true;
    }
    if (g_tpc && c->pc == g_tpc) {
        fprintf(stderr, "[tpc] pc=0x%llx insn=0x%08x el=%u sp=0x%llx\n",
                (unsigned long long)c->pc, insn, c->el,
                (unsigned long long)*cpu_cur_sp(c));
        for (int i = 0; i < 31; i++)
            fprintf(stderr, " x%d=0x%llx", i, (unsigned long long)c->x[i]);
        fprintf(stderr, "\n");
    }
    return false;
}

StepResult cpu_step(CPU *c) {
    if(machine_parallel_poll(c))return STEP_OK;
    if (c->stop) return STEP_HALT;
    if (c->owner_yield) return STEP_OK;

    if (g_systrace && g_sysp.active && c->el == 0) {     /* mm syscall returned */
        fprintf(stderr, "[sys] %-7s(0x%llx, 0x%llx, 0x%llx, 0x%llx) = 0x%llx  ic=%llu\n",
                sysname(g_sysp.num), (unsigned long long)g_sysp.a0,
                (unsigned long long)g_sysp.a1, (unsigned long long)g_sysp.a2,
                (unsigned long long)g_sysp.a3, (unsigned long long)c->x[0],
                (unsigned long long)g_sysp.ic);
        g_sysp.active = 0;
    }

    /* Pending IRQ delivery (single-CPU). FIQ handled the same way. */
    if (c->fiq_line && !(c->daif & PS_F)) {
        exception_take(c, EXC_FIQ, 0, 0, c->pc);
        return STEP_OK;
    }
    if (c->irq_line && !(c->daif & PS_I)) {
        exception_take(c, EXC_IRQ, 0, 0, c->pc);
        return STEP_OK;
    }

    if (c->halted) return STEP_OK;   /* WFI/WFE: caller waits for an event */

    /* Record the current instruction address BEFORE the fetch: if the fetch
     * faults (instruction abort), the synchronous exception's ELR/FAR must point
     * at the faulting address, not the previously executed instruction. */
    c->cur_insn_pc = c->pc;
    c->instruction_partial=false;

    u32 insn;
    if (!mem_ifetch(c, c->pc, &insn)) return STEP_OK;  /* fetch raised an abort */

    if (g_debug_hooks && step_debug(c, insn)) return STEP_HALT;

    c->pc += 4;
    exec_a64(c, insn);
    if(!c->instruction_partial)c->icount++;

    return c->stop ? STEP_HALT : STEP_OK;
}

void cpu_dump(CPU *c) {
    for (int i = 0; i < 31; i++) {
        fprintf(stderr, "x%-2d=%016llx%s", i, (unsigned long long)c->x[i],
                (i % 4 == 3) ? "\n" : "  ");
    }
    fprintf(stderr, "\nsp =%016llx  pc =%016llx  el=%u  spsel=%u\n",
            (unsigned long long)*cpu_cur_sp(c), (unsigned long long)c->pc,
            c->el, c->sp_sel);
    fprintf(stderr, "nzcv=%c%c%c%c daif=%c%c%c%c  icount=%llu\n",
            (c->nzcv & PS_N) ? 'N' : '.', (c->nzcv & PS_Z) ? 'Z' : '.',
            (c->nzcv & PS_C) ? 'C' : '.', (c->nzcv & PS_V) ? 'V' : '.',
            (c->daif & PS_D) ? 'D' : '.', (c->daif & PS_A) ? 'A' : '.',
            (c->daif & PS_I) ? 'I' : '.', (c->daif & PS_F) ? 'F' : '.',
            (unsigned long long)c->icount);
}
