/* SPDX-License-Identifier: MPL-2.0 */
/* Board input/entropy adaptation; immutable possible topology is selected by
 * platform.c before this one per-boot private, fresh-seeded copy is made. */
#include "boot_entropy.h"
#include "fdt/fdt.h"
#include <Security/SecRandom.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>

typedef int (*RandomSource)(unsigned char *, size_t, void *);
struct SeedSlots { size_t rng, kaslr; };

static uint32_t be32(const unsigned char *p) {
    return (uint32_t)p[0]<<24 | (uint32_t)p[1]<<16 | (uint32_t)p[2]<<8 | p[3];
}
static void erase(void *buffer, size_t count) {
    volatile unsigned char *p = buffer;
    while (count--) *p++ = 0;
}

/* Locate exactly one /chosen with the pinned, existing 32/8-byte properties.
 * Validate the complete structure before any output or entropy request. */
static int seed_slots(const unsigned char *b, size_t length, struct SeedSlots *slots) {
    if (!b || length < 40 || be32(b) != 0xd00dfeed) return -1;
    size_t total=be32(b+4), start=be32(b+8), strings=be32(b+12);
    size_t string_size=be32(b+32), struct_size=be32(b+36);
    if (total < 40 || total > length || start > total || struct_size > total-start ||
        strings > total || string_size > total-strings) return -1;
    size_t p=start, end=start+struct_size;int depth=0, chosen_depth=-1, chosen_count=0;
    slots->rng=slots->kaslr=SIZE_MAX;
    while (p <= end && end-p >= 4) {
        uint32_t token=be32(b+p);p+=4;
        if (token==4) continue;
        if (token==1) {
            size_t available=end-p, n=strnlen((const char *)b+p,available);
            if (n==available || n>SIZE_MAX-4) return -1;
            size_t padded=(n+4)&~(size_t)3;
            if (padded>available) return -1;
            ++depth;
            if (depth==2 && !strcmp((const char *)b+p,"chosen")) {
                if (++chosen_count!=1) return -1;
                chosen_depth=depth;
            }
            p+=padded;
        } else if (token==2) {
            if (depth<=0) return -1;
            if (depth==chosen_depth) chosen_depth=-1;
            --depth;
        } else if (token==3) {
            if (depth<=0 || end-p<8) return -1;
            size_t n=be32(b+p), name_offset=be32(b+p+4);p+=8;
            if (n>end-p || n>SIZE_MAX-3) return -1;
            size_t padded=(n+3)&~(size_t)3;
            if (padded>end-p || name_offset>=string_size) return -1;
            const char *name=(const char *)b+strings+name_offset;
            if (strnlen(name,string_size-name_offset)==string_size-name_offset) return -1;
            if (depth==chosen_depth) {
                if (!strcmp(name,"rng-seed")) {
                    if (n!=32 || slots->rng!=SIZE_MAX) return -1;
                    slots->rng=p;
                } else if (!strcmp(name,"kaslr-seed")) {
                    if (n!=8 || slots->kaslr!=SIZE_MAX) return -1;
                    slots->kaslr=p;
                }
            }
            p+=padded;
        } else if (token==9) {
            return depth==0 && chosen_count==1 && slots->rng!=SIZE_MAX && slots->kaslr!=SIZE_MAX ? 0 : -1;
        } else return -1;
    }
    return -1;
}

static int apple_random(unsigned char *output, size_t count, void *unused) {
    (void)unused;
    return SecRandomCopyBytes(kSecRandomDefault,count,output)==errSecSuccess ? 0 : -1;
}

static int prepare(const void *source, size_t length, uint64_t base, uint64_t size,
                    unsigned char **result, RandomSource random, void *context) {
    if (!result) return 1;
    *result=NULL;
    struct SeedSlots slots;
    if (!random || seed_slots(source,length,&slots)) return 1;
    unsigned char *tree=malloc(length);
    if (!tree) return 2;
    memcpy(tree,source,length);
    if (fdt_set_memory(tree,length,base,size)) {
        qualification_boot_dtb_release(tree,length);return 1;
    }
    unsigned char fresh[40]={0};
    if (random(fresh,sizeof(fresh),context)) {
        erase(fresh,sizeof(fresh));qualification_boot_dtb_release(tree,length);return 3;
    }
    memcpy(tree+slots.rng,fresh,32);
    memcpy(tree+slots.kaslr,fresh+32,8);
    erase(fresh,sizeof(fresh));
    *result=tree;
    return 0;
}

int qualification_boot_dtb_copy(const void *source, size_t length, uint64_t base,
                                uint64_t size, unsigned char **result) {
    return prepare(source,length,base,size,result,apple_random,NULL);
}
void qualification_boot_dtb_release(unsigned char *tree, size_t length) {
    if (tree) { erase(tree,length);free(tree); }
}
int qualification_place_boot_dtb(Machine *machine, const void *source, size_t length) {
    unsigned char *tree=NULL;
    int error=qualification_boot_dtb_copy(source,length,machine->ram_base,machine->ram_size,&tree);
    if (error) {
        fprintf(stderr,"[boot-entropy] rejected: input/allocation/entropy error=%d; guest not entered\n",error);
        return error;
    }
    phys_write_blk(machine,RAM_BASE,tree,length);
    qualification_boot_dtb_release(tree,length);
    if(machine_bus_status(machine)!=BUS_OK)return 1;
    machine->boot_dtb_placements++;
    fprintf(stderr,"[boot-entropy] source=SecRandomCopyBytes rng_seed_bytes=32 kaslr_seed_bytes=8 fresh-per-placement\n");
    return 0;
}
#ifdef QUALIFICATION_ENTROPY_TESTING
int qualification_test_boot_dtb(const void *source, size_t length, uint64_t base,
                                uint64_t size, unsigned char **result,
                                QualificationTestRandom random, void *context) {
    return prepare(source,length,base,size,result,random,context);
}
#endif
