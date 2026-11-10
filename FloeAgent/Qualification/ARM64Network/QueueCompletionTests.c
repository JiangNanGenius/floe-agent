/* SPDX-License-Identifier: MPL-2.0 */
/* Root acceptance: real DMA, used ring, held-tail progress and reset. */
#include "DeviceFixture.h"

#define FEAT_BASE (VIRTIO_F_VERSION_1 | VIRTIO_NET_F_MAC | VIRTIO_NET_F_STATUS)

static void recycle_rx(void) {
    for(unsigned pass=0;pass<8 && vq_used_pending(&rq);pass++) {
        while(vq_used_pending(&rq)) {
            uint16_t id;uint32_t len;
            vq_used_next(&rq,&id,&len);
            vq_push(&rq,id);
        }
        mmio_w(MMIO_QNOTIFY,Q_RX);
    }
    assert(!vq_used_pending(&rq));
}
static void post_one(uint16_t id, bool bulk) {
    TestFrame frame;uint8_t header[NET_HDR_LEN],body[1024];
    memset(body,0x37,sizeof(body));
    hdr_of(header,VN_GSO_NONE,0,false,0,0);
    mk_tcp4(&frame,IP_GUEST,IP_HOST,41000+id,81,1,0,
            bulk?VN_TCP_ACK:VN_TCP_RST,65535,1,0,64,
            bulk?body:NULL,bulk?sizeof(body):0);
    eth_guest_to_host(frame.buf);
    uint64_t at=pa(G_TX_POOL+(uint64_t)id*2048);
    gw(at,header,sizeof(header));gw(at+sizeof(header),frame.buf,frame.len);
    vq_set_desc(&tq,id,at,sizeof(header)+frame.len,0,0);
    vq_push(&tq,id);mmio_w(MMIO_QNOTIFY,Q_TX);
}
static void queue_case(uint16_t size) {
    device_negotiate(FEAT_BASE);
    mmio_w(MMIO_QSEL,Q_TX);mmio_w(MMIO_QREADY,0);
    vq_setup(&tq,Q_TX,G_TX_DESC,G_TX_AVAIL,G_TX_USED,size);
    post_rx(64,false);
    const unsigned hold=(size/4)*3;
    assert(hold<=192 && hold<size);
    for(unsigned id=0;id<hold;id++) {
        post_one((uint16_t)id,true);
        assert(!vq_used_pending(&tq)); /* notify schedules; it does not drain */
        dev_poll();recycle_rx();
        assert(!vq_used_pending(&tq));
    }
    assert(v->tx_deferred_n==hold);
    unsigned complete_bulk=0,complete_controls=0;
    bool seen[256]={0};
    for(unsigned turn=0;turn<2u*size;turn++) {
        post_one((uint16_t)hold,false);dev_poll();recycle_rx();
        while(vq_used_pending(&tq)) {
            uint16_t id;uint32_t len;vq_used_next(&tq,&id,&len);
            assert(!len);
            if(id<hold) {assert(!seen[id]);seen[id]=true;complete_bulk++;}
            else {assert(id==hold);complete_controls++;}
        }
    }
    assert(complete_bulk==hold && complete_controls==2u*size);
    assert(!v->tx_deferred_n);
    dev_poll();assert(!vq_used_pending(&tq));
    /* Reset invalidates old IDs. No completion may appear in the new ring. */
    post_one(0,true);dev_poll();recycle_rx();assert(v->tx_deferred_n==1);
    mmio_w(MMIO_STATUS,0);assert(!v->tx_deferred_n);
    device_negotiate(FEAT_BASE);dev_poll();assert(!vq_used_pending(&tq));
    printf("QUEUE_TAIL_OK size=%u bulk=%u controls=%u reset=passed\n",size,complete_bulk,complete_controls);
}
int main(int argc,char **argv) {
    assert(argc==2);
    /* Unchanged independent packet oracle checks the actual production helpers. */
    test_checksum_core();test_frame_parse();test_header_codec();test_tx_partial_csum();
    test_tx_segment_v4();test_tx_segment_v6();test_rx_verify();test_coalesce_rules();
    test_fairness();test_flow_key_and_stats();
    char fw[PATH_MAX];snprintf(fw,sizeof(fw),"%s/tail-suite-fw.bin",argv[1]);
    int fd=open(fw,O_CREAT|O_EXCL|O_WRONLY,0600);assert(fd>=0);
    uint32_t branch=0x14000000u;assert(write(fd,&branch,4)==4 && !close(fd));
    floe_ae_config_v2 cfg={0};cfg.machine.abi_version=FLOE_AE_ABI_VERSION;
    cfg.machine.struct_size=sizeof(cfg);cfg.machine.ram_mib=16;
    cfg.machine.requested_vcpus=1;cfg.machine.firmware_path=fw;
    cfg.machine.input_capacity=256;cfg.machine.output_capacity=65536;
    cfg.devices.struct_size=sizeof(cfg.devices);cfg.devices.network_enabled=1;
    assert(!floe_ae_create(&cfg.machine,&handle));m=&live->machine;v=m->net;
    queue_case(8);queue_case(32);queue_case(64);queue_case(256);
    assert(!floe_ae_destroy(handle) && !unlink(fw));
    printf("HELD_TAIL_SUITE_OK independentChecks=%u destroy=0\n",checks);
    return 0;
}
