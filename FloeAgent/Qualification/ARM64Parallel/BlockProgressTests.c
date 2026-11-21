/* SPDX-License-Identifier: MPL-2.0 */
#include "../../ThirdParty/ARM64EMU/Bridge/runtime.c"
#include <assert.h>

static unsigned block_passes;

static void keep_block_work_pending(struct VirtIOBlk *disk) {
    assert(virtio_blk_has_work(disk));
    /* Model a continuously backlogged disk without host cache or guest
     * producer timing affecting whether the queue becomes empty. */
    ++block_passes;
}

int main(int argc, char **argv) {
    assert(argc == 3);
    int fw = open(argv[1], O_CREAT | O_EXCL | O_WRONLY, 0600);
    assert(fw >= 0);
    const u32 branch = 0x14000000; /* AArch64 "b ." */
    assert(write(fw, &branch, sizeof(branch)) == sizeof(branch) && close(fw) == 0);
    int disk = open(argv[2], O_CREAT | O_EXCL | O_WRONLY, 0600);
    assert(disk >= 0 && ftruncate(disk, 65536) == 0 && close(disk) == 0);

    floe_ae_config config = {.abi_version = 1, .struct_size = sizeof(config),
        .ram_mib = 16, .requested_vcpus = 1, .firmware_path = argv[1],
        .private_writable_disk_path = argv[2]};
    floe_ae_handle handle = 0;
    assert(floe_ae_create(&config, &handle) == 0 && live);
    Machine *machine = &live->machine;
    assert(machine->n_blk == 1 && machine->blk[0]);
    u64 base = 0;
    for (int i = 0; i < machine->ndev; ++i)
        if (machine->dev[i].opaque == machine->blk[0]) base = machine->dev[i].base;
    assert(base);
    phys_write(machine, base + 0x50, 4, 0); /* QueueNotify */
    assert(virtio_blk_has_work(machine->blk[0]));

    const AEParallelCallbacks callbacks = {.step = pd_step, .tick = machine_tick,
        .fw_service = fwcfg_service, .blk_service = keep_block_work_pending,
        .fp_sync = fpsr_sync};
    AEParallelResult result = ae_parallel_run(live, 100000000, 8192, &callbacks);
    assert(result.error == 0 && result.reason == FLOE_AE_BUDGET);
    assert(block_passes > 1 && result.instructions == 8192);
    assert(virtio_blk_has_work(machine->blk[0]));
    assert(floe_ae_destroy(handle) == 0);
    printf("ARM64_BLOCK_PROGRESS_OK with %u disk service passes\n", block_passes);
    return 0;
}
