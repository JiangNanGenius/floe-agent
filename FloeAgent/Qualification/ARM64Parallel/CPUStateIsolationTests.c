/* SPDX-License-Identifier: MPL-2.0 */
/* Actual session allocation, not an over-aligned test-only CPU array. */
#include "../../ThirdParty/ARM64EMU/Bridge/runtime.c"
#include <assert.h>

#ifdef NDEBUG
#error "CPU state isolation qualification requires assertions"
#endif

int main(int argc,char **argv) {
    assert(argc==2);
    /* Padding protects ordinary calloc and stack-embedded Machine instances;
     * requiring a new allocator alignment would make those callers invalid. */
    assert(_Alignof(CPU)==_Alignof(u64));
    assert(sizeof(CPU)-offsetof(CPU,m)-sizeof(((CPU *)0)->m)>=128);
    char path[PATH_MAX];
    assert(snprintf(path,sizeof(path),"%s/cpu-isolation-fw.bin",argv[1])<(int)sizeof(path));
    int fd=open(path,O_CREAT|O_EXCL|O_WRONLY,0600);assert(fd>=0);
    u32 branch=0x14000000;assert(write(fd,&branch,4)==4&&!close(fd));
    floe_ae_config_v2 cfg={.machine={.abi_version=FLOE_AE_ABI_VERSION,.struct_size=sizeof(cfg),
        .ram_mib=16,.requested_vcpus=A64_MAX_CPUS,.firmware_path=path,
        .input_capacity=256,.output_capacity=4096},
        .devices={.struct_size=sizeof(floe_ae_devices_config)}};
    floe_ae_handle handle=0;
    assert(!floe_ae_create(&cfg.machine,&handle)&&live);
    for(unsigned h=0;h+1<A64_MAX_CPUS;h++) {
        CPU *a=machine_cpu(&live->machine,h),*b=machine_cpu(&live->machine,h+1);
        uintptr_t control=(uintptr_t)&a->stop,retire=(uintptr_t)&a->icount;
        uintptr_t current=(uintptr_t)&a->cur_insn_pc,neighbor=(uintptr_t)&b->exec;
        assert(neighbor>(uintptr_t)&a->m+sizeof(a->m)+127);
        assert(control/128!=neighbor/128&&retire/128!=neighbor/128&&current/128!=neighbor/128);
        dprintf(1,"CPU_STATE_ISOLATION hart=%u control=%llu retire=%llu nextExec=%llu\n",
                h,(unsigned long long)(control%128),(unsigned long long)(retire%128),
                (unsigned long long)(neighbor%128));
    }
    assert(!floe_ae_destroy(handle));
    floe_ae_stats stats={.struct_size=sizeof(stats)};
    assert(floe_ae_get_stats(handle,&stats)==FLOE_AE_STALE);
    assert(!unlink(path));
    dprintf(1,"ARM64_CPU_STATE_ISOLATION_OK size=%zu alignment=%zu\n",sizeof(CPU),(size_t)_Alignof(CPU));
    return 0;
}
