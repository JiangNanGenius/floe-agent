/* SPDX-License-Identifier: MPL-2.0 */
#include "cpu.h"
#include "virtio_gpu_backend.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

FloeVirtioGPUBackend *floe_virtual_gpu_backend_create(char *error, size_t size) {
    (void)error;
    (void)size;
    abort();
}

FloeVirtioGPUBackend *floe_virtual_gpu_backend_create_in_app_group(
    const char *group, char *error, size_t size
) {
    (void)group;
    (void)error;
    (void)size;
    abort();
}

void exec_fpsimd(CPU *cpu, u32 instruction);

static u64 next(u64 *state) {
    *state ^= *state << 13;
    *state ^= *state >> 7;
    *state ^= *state << 17;
    return *state;
}

static u32 crc_reference(u32 acc, u64 data, unsigned width, u32 polynomial) {
    for (unsigned bit = 0; bit < width; ++bit) {
        const u32 feedback = (acc ^ (u32)data) & 1;
        acc = (acc >> 1) ^ (feedback ? polynomial : 0);
        data >>= 1;
    }
    return acc;
}

static u32 crc_instruction(unsigned variant, unsigned rd, unsigned rn, unsigned rm) {
    return 0x1ac04000U | ((variant & 3) == 3 ? 0x80000000U : 0) |
           (rm << 16) | (variant << 10) | (rn << 5) | rd;
}

static void check_crc(CPU *cpu, u64 *seed) {
    for (unsigned op = 0; op < 8; ++op) {
        const unsigned width = 8U << (op & 3);
        const u32 polynomial = op < 4 ? 0xedb88320U : 0x82f63b78U;
        for (unsigned i = 0; i < 10000; ++i) {
            const u64 acc = i < 2 ? (i == 0 ? 0 : ~0ULL) : next(seed);
            const u64 data = i < 2 ? (i == 0 ? ~0ULL : 0) : next(seed);
            const unsigned rn = i % 5 == 0 ? 31 : 5;
            const unsigned rm = i % 7 == 0 ? 31 : 6;
            const unsigned rd = i % 11 == 0 ? 31 : (i % 2 ? 5 : 6);
            cpu->x[5] = acc;
            cpu->x[6] = data;
            cpu->nzcv = 0xa0000000U;
            cpu->sp_el[0] = 0xfedcba9876543210ULL;
            exec_a64(cpu, crc_instruction(op, rd, rn, rm));
            const u32 result = crc_reference(rn == 31 ? 0 : (u32)acc, rm == 31 ? 0 : data,
                                             width, polynomial);
            assert(cpu->x[5] == (rd == 5 ? result : acc));
            assert(cpu->x[6] == (rd == 6 ? result : data));
            assert(cpu->nzcv == 0xa0000000U && cpu->sp_el[0] == 0xfedcba9876543210ULL);
        }
    }
}

static void emit_sha(CPU *cpu, u64 *seed) {
    static const u32 instructions[] = {0x5e024020, 0x5e025020, 0x5e282820, 0x5e026020};
    for (unsigned op = 0; op < sizeof(instructions) / sizeof(instructions[0]); ++op) {
        for (unsigned i = 0; i < 10000; ++i) {
            for (unsigned v = 0; v < 3; ++v) {
                cpu->v[v].d[0] = next(seed);
                cpu->v[v].d[1] = next(seed);
            }
            const V128 input1 = cpu->v[1], input2 = cpu->v[2];
            exec_fpsimd(cpu, instructions[op]);
            assert(cpu->v[1].d[0] == input1.d[0] && cpu->v[1].d[1] == input1.d[1]);
            assert(cpu->v[2].d[0] == input2.d[0] && cpu->v[2].d[1] == input2.d[1]);
            assert(fwrite(&cpu->v[0], sizeof(cpu->v[0]), 1, stdout) == 1);
        }
    }
}

static void emit_aes_and_pmull(CPU *cpu, u64 *seed) {
    static const u32 ops[] = {
        0x4e284800, 0x4e285800, 0x4e286800, 0x4e287800,
        0x0ee0e000, 0x4ee0e000, 0x0e20e000, 0x4e20e000
    };
    for (unsigned op = 0; op < sizeof(ops) / sizeof(ops[0]); ++op) {
        for (unsigned i = 0; i < 10000; ++i) {
            for (unsigned r = 0; r < 3; ++r) {
                for (unsigned lane = 0; lane < 2; ++lane) {
                    cpu->v[r].d[lane] = i < 8 && (i & (1u << r))
                        ? (i & 1 ? 0 : ~0ULL) : next(seed);
                }
            }
            const unsigned dn = i % 5 == 0 ? 1 : (op >= 4 && i % 3 == 0 ? 2 : 0);
            const V128 before1 = cpu->v[1], before2 = cpu->v[2];
            cpu->nzcv = 0x90000000;
            exec_fpsimd(cpu, ops[op] | (1u << 5) | dn | (op >= 4 ? 2u << 16 : 0));
            if (dn != 1) assert(!memcmp(&before1, &cpu->v[1], sizeof(V128)));
            if (dn != 2) assert(!memcmp(&before2, &cpu->v[2], sizeof(V128)));
            assert(cpu->nzcv == 0x90000000);
            assert(fwrite(&cpu->v[dn], sizeof(cpu->v[dn]), 1, stdout) == 1);
        }
    }
}

int main(void) {
    CPU cpu = {0};
    u64 seed = 0x4f1bbcdc4eaf3b93ULL;
    check_crc(&cpu, &seed);
    emit_sha(&cpu, &seed);
    emit_aes_and_pmull(&cpu, &seed);
    fprintf(stderr, "ARM64_CHECKSUM_OK crc=80000 sha=40000 aes_pmull=80000\n");
    return 0;
}
