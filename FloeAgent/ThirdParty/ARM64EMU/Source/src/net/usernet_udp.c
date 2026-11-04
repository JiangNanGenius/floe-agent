/* SPDX-License-Identifier: Apache-2.0 */
/* Copyright 2026 Sylirre */
/* usernet UDP: the built-in DHCP server, the NAT flow table, and the DNS
 * redirect (guest 10.0.2.3:53 -> the configured or probed host resolver).
 *
 * When no resolver exists the DNS redirect refuses honestly with an ICMP
 * port-unreachable instead of substituting a hardcoded server. */
#include "usernet_priv.h"
#include <netinet/in.h>
#include <stdlib.h>
#include <sys/socket.h>
#include <unistd.h>

/* Build and emit a UDP datagram to the guest. eth_dst may be NULL for the
 * learned guest MAC, or the broadcast MAC for DHCP replies that ask for it. */
bool un_emit_udp(UserNet *un, const uint8_t *eth_dst,
                 uint32_t src_ip, uint16_t src_port,
                 uint32_t dst_ip, uint16_t dst_port,
                 const uint8_t *payload, size_t plen) {
    if (plen > UN_MTU - 28) return false;
    if (!eth_dst) eth_dst = un->guest_mac;
    uint8_t buf[UN_MAX_FRAME];

    memcpy(buf + 0, eth_dst, 6);
    memcpy(buf + 6, un_host_mac, 6);
    un_wr16(buf + 12, UN_ETH_IP);

    uint8_t *ip = buf + 14;
    ip[0] = 0x45; ip[1] = 0;
    un_wr16(ip + 2, (uint16_t)(28 + plen));
    un_wr16(ip + 4, un->ip_id++);
    un_wr16(ip + 6, 0);
    ip[8] = 64; ip[9] = UN_IPP_UDP;
    un_wr16(ip + 10, 0);
    un_wr32(ip + 12, src_ip);
    un_wr32(ip + 16, dst_ip);
    un_wr16(ip + 10, un_cksum_fin(un_cksum_add(0, ip, 20)));

    uint8_t *udp = ip + 20;
    un_wr16(udp + 0, src_port);
    un_wr16(udp + 2, dst_port);
    un_wr16(udp + 4, (uint16_t)(8 + plen));
    un_wr16(udp + 6, 0);
    memcpy(udp + 8, payload, plen);
    uint16_t ck = un_l4_cksum(src_ip, dst_ip, UN_IPP_UDP, udp, 8 + plen);
    un_wr16(udp + 6, ck ? ck : 0xffff);

    return un_output(un, buf, 14 + 28 + plen);
}

/* ---- DHCP server: one static lease, 10.0.2.15 ---- */

#define DHCP_MAGIC     0x63825363u
#define DHCPDISCOVER   1
#define DHCPOFFER      2
#define DHCPREQUEST    3
#define DHCPACK        5
#define DHCPNAK        6

/* Find a DHCP option in the options region; returns NULL if absent. */
static const uint8_t *dhcp_opt(const uint8_t *opts, const uint8_t *end, uint8_t code) {
    while (opts < end && *opts != 255) {
        if (*opts == 0) { opts++; continue; }        /* pad */
        if (opts + 2 > end || opts + 2 + opts[1] > end) return NULL;
        if (*opts == code) return opts;
        opts += 2 + opts[1];
    }
    return NULL;
}

static void dhcp_input(UserNet *un, const uint8_t *p, size_t len) {
    if (len < 240 || p[0] != 1 || p[1] != 1 || p[2] != 6) return;
    if (un_rd32(p + 236) != DHCP_MAGIC) return;
    const uint8_t *opts = p + 240, *end = p + len;
    const uint8_t *mt = dhcp_opt(opts, end, 53);
    if (!mt || mt[1] < 1) return;
    uint8_t reqtype = mt[2];

    uint8_t reply_type;
    uint32_t yiaddr = UN_IP_GUEST;
    if (reqtype == DHCPDISCOVER) {
        reply_type = DHCPOFFER;
    } else if (reqtype == DHCPREQUEST) {
        /* NAK a request for any address other than the one static lease */
        const uint8_t *rip = dhcp_opt(opts, end, 50);
        uint32_t requested = rip && rip[1] == 4 ? un_rd32(rip + 2) : un_rd32(p + 12);
        if (requested && requested != UN_IP_GUEST) {
            reply_type = DHCPNAK; yiaddr = 0;
        } else {
            reply_type = DHCPACK;
        }
    } else {
        return;                                       /* DECLINE/RELEASE/INFORM: ignore */
    }

    uint8_t r[300];
    memset(r, 0, sizeof(r));
    r[0] = 2; r[1] = 1; r[2] = 6;                     /* BOOTREPLY, eth */
    memcpy(r + 4, p + 4, 4);                          /* xid */
    memcpy(r + 10, p + 10, 2);                        /* flags */
    un_wr32(r + 16, yiaddr);
    un_wr32(r + 20, UN_IP_HOST);                      /* siaddr */
    memcpy(r + 24, p + 24, 4);                        /* giaddr */
    memcpy(r + 28, p + 28, 16);                       /* chaddr */
    un_wr32(r + 236, DHCP_MAGIC);
    uint8_t *o = r + 240;
    *o++ = 53; *o++ = 1; *o++ = reply_type;
    *o++ = 54; *o++ = 4; un_wr32(o, UN_IP_HOST); o += 4;   /* server id */
    if (reply_type != DHCPNAK) {
        *o++ = 51; *o++ = 4; un_wr32(o, 86400); o += 4;    /* lease 24 h */
        *o++ = 1;  *o++ = 4; un_wr32(o, UN_NETMASK); o += 4;
        *o++ = 3;  *o++ = 4; un_wr32(o, UN_IP_HOST); o += 4;
        *o++ = 6;  *o++ = 4; un_wr32(o, UN_IP_DNS);  o += 4;
    }
    *o++ = 255;
    /* whole 300-byte buffer goes out: classic BOOTP minimum, zero padding */

    /* RFC 2131 reply addressing, simplified for the single-guest network:
     * unicast IP to ciaddr on renew, otherwise broadcast if the client asked
     * for it (or on NAK), else unicast to the offered address. The Ethernet
     * destination is the client MAC unless IP-broadcasting. */
    uint32_t ciaddr = un_rd32(p + 12);
    bool bcast = (un_rd16(p + 10) & 0x8000) || reply_type == DHCPNAK;
    uint32_t dst_ip = ciaddr && reply_type == DHCPACK ? ciaddr :
                      bcast ? 0xffffffffu : yiaddr;
    static const uint8_t bmac[6] = {0xff,0xff,0xff,0xff,0xff,0xff};
    const uint8_t *eth_dst = dst_ip == 0xffffffffu ? bmac : p + 28;

    un_emit_udp(un, eth_dst, UN_IP_HOST, 67, dst_ip, 68, r, sizeof(r));
}

/* ---- NAT flow table ---- */

static void flow_close(UdpFlow *f) {
    if (f->fd >= 0) close(f->fd);
    f->fd = -1;
    f->in_use = false;
}

static UdpFlow *flow_lookup(UserNet *un, uint16_t g_port,
                            uint32_t r_ip, uint16_t r_port) {
    for (int i = 0; i < UN_UDP_MAX; i++) {
        UdpFlow *f = &un->udp[i];
        if (f->in_use && f->g_port == g_port &&
            f->r_ip == r_ip && f->r_port == r_port)
            return f;
    }
    return NULL;
}

static UdpFlow *flow_create(UserNet *un, uint16_t g_port,
                            uint32_t r_ip, uint16_t r_port) {
    UdpFlow *f = NULL;
    for (int i = 0; i < UN_UDP_MAX; i++)
        if (!un->udp[i].in_use) { f = &un->udp[i]; break; }
    if (!f) {                                /* table full: evict the oldest */
        f = &un->udp[0];
        for (int i = 1; i < UN_UDP_MAX; i++)
            if (un->udp[i].last_ms < f->last_ms) f = &un->udp[i];
        flow_close(f);
    }

    /* Pick the real target: the virtual DNS goes to the configured/probed
     * resolver, the virtual gateway to host loopback, anything else straight
     * out. An undiscoverable resolver is an honest refusal, not a guess. */
    bool is_dns = r_ip == UN_IP_DNS && r_port == 53;
    uint32_t t_ip = is_dns              ? usernet_dns_server(un) :
                    r_ip == UN_IP_HOST  ? UN_IP(127,0,0,1) : r_ip;
    if (!t_ip) return NULL;

    int fd = un_socket(SOCK_DGRAM, 0);
    if (fd < 0) return NULL;
    struct sockaddr_in sa = {0};
    sa.sin_family = AF_INET;
    sa.sin_addr.s_addr = htonl(t_ip);
    sa.sin_port = htons(r_port);
    if (connect(fd, (struct sockaddr *)&sa, sizeof(sa)) < 0) {
        close(fd);
        return NULL;
    }

    f->in_use = true; f->is_dns = is_dns;
    f->g_port = g_port; f->r_ip = r_ip; f->r_port = r_port;
    f->fd = fd; f->last_ms = un->now_ms;
    return f;
}

void un_udp_fill(UserNet *un) {
    for (int i = 0; i < UN_UDP_MAX; i++)
        if (un->udp[i].in_use)
            un_poll_add(un, un->udp[i].fd, POLLIN, UN_PK_UDP, &un->udp[i]);
}

void un_udp_readable(UserNet *un, UdpFlow *f) {
    uint8_t buf[UN_MTU - 28];
    for (int burst = 0; burst < 32; burst++) {
        ssize_t n = recv(f->fd, buf, sizeof(buf), 0);
        if (n < 0) return;                   /* EAGAIN or ICMP error: done */
        f->last_ms = un->now_ms;
        if (!un_emit_udp(un, NULL, f->r_ip, f->r_port,
                         UN_IP_GUEST, f->g_port, buf, (size_t)n))
            return;                          /* RX ring full: drop the rest */
    }
}

void un_udp_tick(UserNet *un) {
    if (un->now_ms - un->udp_sweep_ms < 1000) return;
    un->udp_sweep_ms = un->now_ms;
    for (int i = 0; i < UN_UDP_MAX; i++) {
        UdpFlow *f = &un->udp[i];
        if (f->in_use &&
            un->now_ms - f->last_ms > (f->is_dns ? UN_DNS_TTL_MS : UN_UDP_TTL_MS))
            flow_close(f);
    }
}

void un_udp_reset(UserNet *un) {
    for (int i = 0; i < UN_UDP_MAX; i++)
        if (un->udp[i].in_use) flow_close(&un->udp[i]);
}

void un_udp_destroy(UserNet *un) { un_udp_reset(un); }

/* ---- UDP hostfwd ---- */

/* Host datagram on a -netfwd socket -> guest, spoofed from the real peer. */
void un_udp_fwd_readable(UserNet *un, HostFwd *fw) {
    uint8_t buf[UN_MTU - 28];
    for (int burst = 0; burst < 32; burst++) {
        struct sockaddr_in peer;
        socklen_t plen = sizeof(peer);
        ssize_t n = recvfrom(fw->fd, buf, sizeof(buf), 0,
                             (struct sockaddr *)&peer, &plen);
        if (n < 0) return;
        uint32_t p_ip = ntohl(peer.sin_addr.s_addr);
        /* loopback peers are unroutable from the guest: show the gateway */
        if ((p_ip >> 24) == 127 || p_ip == 0) p_ip = UN_IP_HOST;
        if (!un_emit_udp(un, NULL, p_ip, ntohs(peer.sin_port),
                         UN_IP_GUEST, fw->guest_port, buf, (size_t)n))
            return;
    }
}

/* Guest datagrams sourced from a forwarded port reply through the rule's
 * bound socket, so the peer sees them coming from the forwarded host port. */
bool un_udp_fwd_input(UserNet *un, uint32_t dst, uint16_t sport,
                      uint16_t dport, const uint8_t *payload, size_t plen) {
    for (int i = 0; i < un->n_fwd; i++) {
        HostFwd *fw = &un->fwd[i];
        if (!fw->is_udp || fw->guest_port != sport) continue;
        struct sockaddr_in sa = {0};
        sa.sin_family = AF_INET;
        /* the gateway address stands in for loopback peers; map it back */
        sa.sin_addr.s_addr = htonl(dst == UN_IP_HOST ? UN_IP(127,0,0,1) : dst);
        sa.sin_port = htons(dport);
        sendto(fw->fd, payload, plen, UN_SEND_FLAGS,
               (struct sockaddr *)&sa, sizeof(sa));
        return true;
    }
    return false;
}

/* Guest UDP entry point: DHCP is served locally, the rest is NATed. */
void un_udp_input(UserNet *un, uint32_t src, uint32_t dst,
                  const uint8_t *udp, size_t len) {
    (void)src;
    if (len < 8) return;
    uint16_t sport = un_rd16(udp + 0);
    uint16_t dport = un_rd16(udp + 2);
    size_t ulen = un_rd16(udp + 4);
    if (ulen < 8 || ulen > len) return;

    if (dport == 67) {
        dhcp_input(un, udp + 8, ulen - 8);
        return;
    }
    if (un_udp_fwd_input(un, dst, sport, dport, udp + 8, ulen - 8))
        return;
    /* No NAT for broadcast/multicast chatter (SSDP, mDNS, ...). */
    if (dst == 0xffffffffu || dst == (UN_NET | ~UN_NETMASK) ||
        (dst >> 28) == 0xe)
        return;

    if (dst == UN_IP_DNS && dport == 53 && !usernet_dns_server(un)) {
        /* Honest refusal: no resolver relay target exists (and none was
         * configured), so the guest learns the service is unreachable
         * instead of black-holing behind a fabricated server. */
        un_icmp_unreach(un, UN_IP_GUEST, UN_IP_DNS, udp, ulen);
        return;
    }

    UdpFlow *f = flow_lookup(un, sport, dst, dport);
    if (!f) f = flow_create(un, sport, dst, dport);
    if (!f) return;
    f->last_ms = un->now_ms;
    send(f->fd, udp + 8, ulen - 8, UN_SEND_FLAGS);
}
