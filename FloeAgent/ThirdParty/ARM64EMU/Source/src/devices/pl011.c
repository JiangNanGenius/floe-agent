/* SPDX-License-Identifier: Apache-2.0 */
/* Copyright 2026 Sylirre */
/* PL011 UART: TX and RX on a host console endpoint (the process terminal unless
 * bound elsewhere — see console.h), with RX/TX interrupts. */
#include "../devices.h"
#include "../console.h"
#include <stdlib.h>
#include <string.h>

/* PrimeCell identification (amba bus matches on these). */
static const u8 pl011_id[8] = { 0x11, 0x10, 0x14, 0x00, 0x0d, 0xf0, 0x05, 0xb1 };

#define RXRIS (1u << 4)
#define TXRIS (1u << 5)

static bool rx_empty(PL011 *p) { return p->rx_head == p->rx_tail; }
static bool rx_full(PL011 *p)  { return ((p->rx_tail + 1) % (int)sizeof(p->rx_fifo)) == p->rx_head; }

static void rx_push(PL011 *p, u8 ch) {
    if (rx_full(p)) return;
    p->rx_fifo[p->rx_tail] = ch;
    p->rx_tail = (p->rx_tail + 1) % (int)sizeof(p->rx_fifo);
}
static int rx_pop(PL011 *p) {
    if (rx_empty(p)) return -1;
    u8 ch = p->rx_fifo[p->rx_head];
    p->rx_head = (p->rx_head + 1) % (int)sizeof(p->rx_fifo);
    return ch;
}

static void update_irq(PL011 *p) {
    p->ris = TXRIS | (rx_empty(p) ? 0 : RXRIS);
    gic_set_irq(p->gic, INTID_UART, (p->ris & p->imsc) != 0);
}

void pl011_rx_poll(Machine *m) {
    PL011 *p = m->uart;
    if (!p) return;
    console_flush(p->ep);            /* retry output a stalled peer refused earlier */
    int ch;
    while (!rx_full(p) && (ch = console_getchar(p->ep)) >= 0) rx_push(p, (u8)ch);
    update_irq(p);
}

/* True while this UART is on the shared process terminal (see machine_tick). */
bool pl011_is_stdio(PL011 *p) { return p && console_is_stdio(p->ep); }

static u64 uart_read(void *opaque, u64 off, unsigned size) {
    PL011 *p = opaque;
    if (off >= 0xfe0 && off <= 0xffc) return pl011_id[(off - 0xfe0) / 4];
    switch (off) {
        case 0x00: {                                   /* DR */
            int ch = rx_pop(p);
            update_irq(p);
            return ch < 0 ? 0 : (u32)ch;
        }
        case 0x18: {                                   /* FR */
            u32 fr = (1u << 7);                          /* TXFE */
            if (rx_empty(p)) fr |= (1u << 4);           /* RXFE */
            /* TXFF (bit5) clear: always room */
            return fr;
        }
        case 0x24: return p->ibrd;
        case 0x28: return p->fbrd;
        case 0x2c: return p->lcr_h;
        case 0x30: return p->cr;
        case 0x34: return p->ifls;
        case 0x38: return p->imsc;
        case 0x3c: return p->ris;
        case 0x40: return p->ris & p->imsc;             /* MIS */
        default: return 0;
    }
}

static void uart_write(void *opaque, u64 off, unsigned size, u64 val) {
    PL011 *p = opaque;
    switch (off) {
        case 0x00:                                                        /* DR */
            console_putchar(p->ep, (int)(val & 0xff));
            /* Output on the serial console -> host input follows it back to
             * ttyAMA0 (until the guest next writes to hvc0). See machine_tick. */
            if (p->m->console_virtio) p->m->console_active_virtio = false;
            update_irq(p);
            break;
        case 0x24: p->ibrd = (u32)val; break;
        case 0x28: p->fbrd = (u32)val; break;
        case 0x2c: p->lcr_h = (u32)val; break;
        case 0x30: p->cr = (u32)val; break;
        case 0x34: p->ifls = (u32)val; break;
        case 0x38: p->imsc = (u32)val; update_irq(p); break;              /* IMSC */
        case 0x44: update_irq(p); break;                                  /* ICR */
        default: break;
    }
}

PL011 *pl011_create(Machine *m, GIC *gic) {
    PL011 *p = calloc(1, sizeof(*p));
    if (!p) return NULL;
    p->m = m;
    p->gic = gic;
    p->ep = m->uart_ep ? m->uart_ep : console_stdio();
    if (!p->ep) { free(p);return NULL; }
    p->cr = 0x300;     /* TXE|RXE */
    machine_add_device(m, UART_BASE, 0x1000, uart_read, uart_write, p, "pl011");
    m->uart = p;
    return p;
}

/* Return the UART to power-on state (system reset): drop masks, the RX FIFO
 * (any type-ahead), and the pending interrupt; keeps the GIC backpointer. */
void pl011_reset(PL011 *p) {
    Machine *m = p->m;
    GIC *gic = p->gic;
    ConsoleEP *ep = p->ep;         /* the host endpoint outlives a guest reset */
    memset(p, 0, sizeof(*p));
    p->m = m;
    p->gic = gic;
    p->ep = ep;
    p->cr = 0x300;     /* TXE|RXE */
    gic_set_irq(gic, INTID_UART, 0);
}

/* Embedded typed ownership; borrowed backpointers are not freed here. */
void pl011_destroy(PL011 *p) { free(p); }
