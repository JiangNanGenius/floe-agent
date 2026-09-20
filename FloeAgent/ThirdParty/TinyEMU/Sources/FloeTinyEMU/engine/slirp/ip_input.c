/*
 * Copyright (c) 1982, 1986, 1988, 1993
 *	The Regents of the University of California.  All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 * 1. Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 * 3. Neither the name of the University nor the names of its contributors
 *    may be used to endorse or promote products derived from this software
 *    without specific prior written permission.
 *
 * THIS SOFTWARE IS PROVIDED BY THE REGENTS AND CONTRIBUTORS ``AS IS'' AND
 * ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
 * ARE DISCLAIMED.  IN NO EVENT SHALL THE REGENTS OR CONTRIBUTORS BE LIABLE
 * FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
 * DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
 * OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
 * HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
 * LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY
 * OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF
 * SUCH DAMAGE.
 *
 *	@(#)ip_input.c	8.2 (Berkeley) 1/4/94
 * ip_input.c,v 1.11 1994/11/16 10:17:08 jkh Exp
 */

/*
 * Changes and additions relating to SLiRP are
 * Copyright (c) 1995 Danny Gasparovski.
 *
 * Please read the file COPYRIGHT for the
 * terms and conditions of the copyright.
 */

#include "slirp.h"
#include "ip_icmp.h"

#define container_of(ptr, type, member) ({                      \
        const typeof( ((type *)0)->member ) *__mptr = (ptr);    \
        (type *)( (char *)__mptr - offsetof(type,member) );})

static struct floe_slirp_ip *ip_reass(Slirp *slirp, struct floe_slirp_ip *floe_slirp_ip, struct floe_slirp_ipq *fp);
static void ip_freef(Slirp *slirp, struct floe_slirp_ipq *fp);
static void ip_enq(register struct floe_slirp_ipasfrag *p,
                   register struct floe_slirp_ipasfrag *prev);
static void ip_deq(register struct floe_slirp_ipasfrag *p);

/*
 * IP initialization: fill in IP protocol switch table.
 * All protocols not implemented in kernel go to raw IP protocol handler.
 */
void
ip_init(Slirp *slirp)
{
    slirp->floe_slirp_ipq.ip_link.next = slirp->floe_slirp_ipq.ip_link.prev = &slirp->floe_slirp_ipq.ip_link;
    udp_init(slirp);
    tcp_init(slirp);
}

/*
 * Ip input routine.  Checksum and byte swap header.  If fragmented
 * try to reassemble.  Process options.  Pass to next level.
 */
void
ip_input(struct floe_slirp_mbuf *m)
{
	Slirp *slirp = m->slirp;
	register struct floe_slirp_ip *floe_slirp_ip;
	int hlen;

	DEBUG_CALL("ip_input");
	DEBUG_ARG("m = %lx", (long)m);
	DEBUG_ARG("m_len = %d", m->m_len);

	if (m->m_len < sizeof (struct floe_slirp_ip)) {
		return;
	}

	floe_slirp_ip = mtod(m, struct floe_slirp_ip *);

	if (floe_slirp_ip->ip_v != IPVERSION) {
		goto bad;
	}

	hlen = floe_slirp_ip->ip_hl << 2;
	if (hlen<sizeof(struct floe_slirp_ip ) || hlen>m->m_len) {/* min header length */
	  goto bad;                                  /* or packet too short */
	}

        /* keep floe_slirp_ip header intact for ICMP reply
	 * floe_slirp_ip->ip_sum = cksum(m, hlen);
	 * if (floe_slirp_ip->ip_sum) {
	 */
	if(cksum(m,hlen)) {
	  goto bad;
	}

	/*
	 * Convert fields to host representation.
	 */
	NTOHS(floe_slirp_ip->ip_len);
	if (floe_slirp_ip->ip_len < hlen) {
		goto bad;
	}
	NTOHS(floe_slirp_ip->ip_id);
	NTOHS(floe_slirp_ip->ip_off);

	/*
	 * Check that the amount of data in the buffers
	 * is as at least much as the IP header would have us expect.
	 * Trim mbufs if longer than we expect.
	 * Drop packet if shorter than we expect.
	 */
	if (m->m_len < floe_slirp_ip->ip_len) {
		goto bad;
	}

    if (slirp->restricted) {
        if ((floe_slirp_ip->ip_dst.s_addr & slirp->vnetwork_mask.s_addr) ==
            slirp->vnetwork_addr.s_addr) {
            if (floe_slirp_ip->ip_dst.s_addr == 0xffffffff && floe_slirp_ip->ip_p != IPPROTO_UDP)
                goto bad;
        } else {
            uint32_t inv_mask = ~slirp->vnetwork_mask.s_addr;
            struct ex_list *ex_ptr;

            if ((floe_slirp_ip->ip_dst.s_addr & inv_mask) == inv_mask) {
                goto bad;
            }
            for (ex_ptr = slirp->exec_list; ex_ptr; ex_ptr = ex_ptr->ex_next)
                if (ex_ptr->ex_addr.s_addr == floe_slirp_ip->ip_dst.s_addr)
                    break;

            if (!ex_ptr)
                goto bad;
        }
    }

	/* Should drop packet if floe_slirp_mbuf too long? hmmm... */
	if (m->m_len > floe_slirp_ip->ip_len)
	   m_adj(m, floe_slirp_ip->ip_len - m->m_len);

	/* check ip_ttl for a correct ICMP reply */
	if(floe_slirp_ip->ip_ttl==0) {
	  icmp_error(m, ICMP_TIMXCEED,ICMP_TIMXCEED_INTRANS, 0,"ttl");
	  goto bad;
	}

	/*
	 * If offset or IP_MF are set, must reassemble.
	 * Otherwise, nothing need be done.
	 * (We could look in the reassembly queue to see
	 * if the packet was previously fragmented,
	 * but it's not worth the time; just let them time out.)
	 *
	 * XXX This should fail, don't fragment yet
	 */
	if (floe_slirp_ip->ip_off &~ IP_DF) {
	  register struct floe_slirp_ipq *fp;
      struct qlink *l;
		/*
		 * Look for queue of fragments
		 * of this datagram.
		 */
		for (l = slirp->floe_slirp_ipq.ip_link.next; l != &slirp->floe_slirp_ipq.ip_link;
		     l = l->next) {
            fp = container_of(l, struct floe_slirp_ipq, ip_link);
            if (floe_slirp_ip->ip_id == fp->ipq_id &&
                    floe_slirp_ip->ip_src.s_addr == fp->ipq_src.s_addr &&
                    floe_slirp_ip->ip_dst.s_addr == fp->ipq_dst.s_addr &&
                    floe_slirp_ip->ip_p == fp->ipq_p)
		    goto found;
        }
        fp = NULL;
	found:

		/*
		 * Adjust ip_len to not reflect header,
		 * set ip_mff if more fragments are expected,
		 * convert offset of this to bytes.
		 */
		floe_slirp_ip->ip_len -= hlen;
		if (floe_slirp_ip->ip_off & IP_MF)
		  floe_slirp_ip->ip_tos |= 1;
		else
		  floe_slirp_ip->ip_tos &= ~1;

		floe_slirp_ip->ip_off <<= 3;

		/*
		 * If datagram marked as having more fragments
		 * or if this is not the first fragment,
		 * attempt reassembly; if it succeeds, proceed.
		 */
		if (floe_slirp_ip->ip_tos & 1 || floe_slirp_ip->ip_off) {
			floe_slirp_ip = ip_reass(slirp, floe_slirp_ip, fp);
                        if (floe_slirp_ip == NULL)
				return;
			m = dtom(slirp, floe_slirp_ip);
		} else
			if (fp)
		   	   ip_freef(slirp, fp);

	} else
		floe_slirp_ip->ip_len -= hlen;

	/*
	 * Switch out to protocol's input routine.
	 */
	switch (floe_slirp_ip->ip_p) {
	 case IPPROTO_TCP:
		tcp_input(m, hlen, (struct socket *)NULL);
		break;
	 case IPPROTO_UDP:
		udp_input(m, hlen);
		break;
	 case IPPROTO_ICMP:
		icmp_input(m, hlen);
		break;
	 default:
		m_free(m);
	}
	return;
bad:
	m_freem(m);
	return;
}

#define iptofrag(P) ((struct floe_slirp_ipasfrag *)(((char*)(P)) - sizeof(struct qlink)))
#define fragtoip(P) ((struct floe_slirp_ip*)(((char*)(P)) + sizeof(struct qlink)))
/*
 * Take incoming datagram fragment and try to
 * reassemble it into whole datagram.  If a chain for
 * reassembly of this datagram already exists, then it
 * is given as fp; otherwise have to make a chain.
 */
static struct floe_slirp_ip *
ip_reass(Slirp *slirp, struct floe_slirp_ip *floe_slirp_ip, struct floe_slirp_ipq *fp)
{
	register struct floe_slirp_mbuf *m = dtom(slirp, floe_slirp_ip);
	register struct floe_slirp_ipasfrag *q;
	int hlen = floe_slirp_ip->ip_hl << 2;
	int i, next;

	DEBUG_CALL("ip_reass");
	DEBUG_ARG("floe_slirp_ip = %lx", (long)floe_slirp_ip);
	DEBUG_ARG("fp = %lx", (long)fp);
	DEBUG_ARG("m = %lx", (long)m);

	/*
	 * Presence of header sizes in mbufs
	 * would confuse code below.
         * Fragment m_data is concatenated.
	 */
	m->m_data += hlen;
	m->m_len -= hlen;

	/*
	 * If first fragment to arrive, create a reassembly queue.
	 */
        if (fp == NULL) {
	  struct floe_slirp_mbuf *t = m_get(slirp);

	  if (t == NULL) {
	      goto dropfrag;
	  }
	  fp = mtod(t, struct floe_slirp_ipq *);
	  insque(&fp->ip_link, &slirp->floe_slirp_ipq.ip_link);
	  fp->ipq_ttl = IPFRAGTTL;
	  fp->ipq_p = floe_slirp_ip->ip_p;
	  fp->ipq_id = floe_slirp_ip->ip_id;
	  fp->frag_link.next = fp->frag_link.prev = &fp->frag_link;
	  fp->ipq_src = floe_slirp_ip->ip_src;
	  fp->ipq_dst = floe_slirp_ip->ip_dst;
	  q = (struct floe_slirp_ipasfrag *)fp;
	  goto insert;
	}

	/*
	 * Find a segment which begins after this one does.
	 */
	for (q = fp->frag_link.next; q != (struct floe_slirp_ipasfrag *)&fp->frag_link;
            q = q->ipf_next)
		if (q->ipf_off > floe_slirp_ip->ip_off)
			break;

	/*
	 * If there is a preceding segment, it may provide some of
	 * our data already.  If so, drop the data from the incoming
	 * segment.  If it provides all of our data, drop us.
	 */
	if (q->ipf_prev != &fp->frag_link) {
        struct floe_slirp_ipasfrag *pq = q->ipf_prev;
		i = pq->ipf_off + pq->ipf_len - floe_slirp_ip->ip_off;
		if (i > 0) {
			if (i >= floe_slirp_ip->ip_len)
				goto dropfrag;
			m_adj(dtom(slirp, floe_slirp_ip), i);
			floe_slirp_ip->ip_off += i;
			floe_slirp_ip->ip_len -= i;
		}
	}

	/*
	 * While we overlap succeeding segments trim them or,
	 * if they are completely covered, dequeue them.
	 */
	while (q != (struct floe_slirp_ipasfrag*)&fp->frag_link &&
            floe_slirp_ip->ip_off + floe_slirp_ip->ip_len > q->ipf_off) {
		i = (floe_slirp_ip->ip_off + floe_slirp_ip->ip_len) - q->ipf_off;
		if (i < q->ipf_len) {
			q->ipf_len -= i;
			q->ipf_off += i;
			m_adj(dtom(slirp, q), i);
			break;
		}
		q = q->ipf_next;
		m_freem(dtom(slirp, q->ipf_prev));
		ip_deq(q->ipf_prev);
	}

insert:
	/*
	 * Stick new segment in its place;
	 * check for complete reassembly.
	 */
	ip_enq(iptofrag(floe_slirp_ip), q->ipf_prev);
	next = 0;
	for (q = fp->frag_link.next; q != (struct floe_slirp_ipasfrag*)&fp->frag_link;
            q = q->ipf_next) {
		if (q->ipf_off != next)
                        return NULL;
		next += q->ipf_len;
	}
	if (((struct floe_slirp_ipasfrag *)(q->ipf_prev))->ipf_tos & 1)
                return NULL;

	/*
	 * Reassembly is complete; concatenate fragments.
	 */
    q = fp->frag_link.next;
	m = dtom(slirp, q);

	q = (struct floe_slirp_ipasfrag *) q->ipf_next;
	while (q != (struct floe_slirp_ipasfrag*)&fp->frag_link) {
	  struct floe_slirp_mbuf *t = dtom(slirp, q);
	  q = (struct floe_slirp_ipasfrag *) q->ipf_next;
	  m_cat(m, t);
	}

	/*
	 * Create header for new floe_slirp_ip packet by
	 * modifying header of first packet;
	 * dequeue and discard fragment reassembly header.
	 * Make header visible.
	 */
	q = fp->frag_link.next;

	/*
	 * If the fragments concatenated to an floe_slirp_mbuf that's
	 * bigger than the total size of the fragment, then and
	 * m_ext buffer was alloced. But fp->ipq_next points to
	 * the old buffer (in the floe_slirp_mbuf), so we must point floe_slirp_ip
	 * into the new buffer.
	 */
	if (m->m_flags & M_EXT) {
	  int delta = (char *)q - m->m_dat;
	  q = (struct floe_slirp_ipasfrag *)(m->m_ext + delta);
	}

    floe_slirp_ip = fragtoip(q);
	floe_slirp_ip->ip_len = next;
	floe_slirp_ip->ip_tos &= ~1;
	floe_slirp_ip->ip_src = fp->ipq_src;
	floe_slirp_ip->ip_dst = fp->ipq_dst;
	remque(&fp->ip_link);
	(void) m_free(dtom(slirp, fp));
	m->m_len += (floe_slirp_ip->ip_hl << 2);
	m->m_data -= (floe_slirp_ip->ip_hl << 2);

	return floe_slirp_ip;

dropfrag:
	m_freem(m);
        return NULL;
}

/*
 * Free a fragment reassembly header and all
 * associated datagrams.
 */
static void
ip_freef(Slirp *slirp, struct floe_slirp_ipq *fp)
{
	register struct floe_slirp_ipasfrag *q, *p;

	for (q = fp->frag_link.next; q != (struct floe_slirp_ipasfrag*)&fp->frag_link; q = p) {
		p = q->ipf_next;
		ip_deq(q);
		m_freem(dtom(slirp, q));
	}
	remque(&fp->ip_link);
	(void) m_free(dtom(slirp, fp));
}

/*
 * Put an floe_slirp_ip fragment on a reassembly chain.
 * Like insque, but pointers in middle of structure.
 */
static void
ip_enq(register struct floe_slirp_ipasfrag *p, register struct floe_slirp_ipasfrag *prev)
{
	DEBUG_CALL("ip_enq");
	DEBUG_ARG("prev = %lx", (long)prev);
	p->ipf_prev =  prev;
	p->ipf_next = prev->ipf_next;
	((struct floe_slirp_ipasfrag *)(prev->ipf_next))->ipf_prev = p;
	prev->ipf_next = p;
}

/*
 * To ip_enq as remque is to insque.
 */
static void
ip_deq(register struct floe_slirp_ipasfrag *p)
{
	((struct floe_slirp_ipasfrag *)(p->ipf_prev))->ipf_next = p->ipf_next;
	((struct floe_slirp_ipasfrag *)(p->ipf_next))->ipf_prev = p->ipf_prev;
}

/*
 * IP timer processing;
 * if a timer expires on a reassembly
 * queue, discard it.
 */
void
ip_slowtimo(Slirp *slirp)
{
    struct qlink *l;

	DEBUG_CALL("ip_slowtimo");

    l = slirp->floe_slirp_ipq.ip_link.next;

        if (l == NULL)
	   return;

    while (l != &slirp->floe_slirp_ipq.ip_link) {
        struct floe_slirp_ipq *fp = container_of(l, struct floe_slirp_ipq, ip_link);
        l = l->next;
		if (--fp->ipq_ttl == 0) {
			ip_freef(slirp, fp);
		}
    }
}

/*
 * Do option processing on a datagram,
 * possibly discarding it if bad options are encountered,
 * or forwarding it if source-routed.
 * Returns 1 if packet has been forwarded/freed,
 * 0 if the packet should be processed further.
 */

#ifdef notdef

int
ip_dooptions(m)
	struct floe_slirp_mbuf *m;
{
	register struct floe_slirp_ip *floe_slirp_ip = mtod(m, struct floe_slirp_ip *);
	register u_char *cp;
	register struct ip_timestamp *ipt;
	register struct in_ifaddr *ia;
	int opt, optlen, cnt, off, code, type, forward = 0;
	struct in_addr *sin, dst;
typedef uint32_t n_time;
	n_time ntime;

	dst = floe_slirp_ip->ip_dst;
	cp = (u_char *)(floe_slirp_ip + 1);
	cnt = (floe_slirp_ip->ip_hl << 2) - sizeof (struct floe_slirp_ip);
	for (; cnt > 0; cnt -= optlen, cp += optlen) {
		opt = cp[IPOPT_OPTVAL];
		if (opt == IPOPT_EOL)
			break;
		if (opt == IPOPT_NOP)
			optlen = 1;
		else {
			optlen = cp[IPOPT_OLEN];
			if (optlen <= 0 || optlen > cnt) {
				code = &cp[IPOPT_OLEN] - (u_char *)floe_slirp_ip;
				goto bad;
			}
		}
		switch (opt) {

		default:
			break;

		/*
		 * Source routing with record.
		 * Find interface with current destination address.
		 * If none on this machine then drop if strictly routed,
		 * or do nothing if loosely routed.
		 * Record interface address and bring up next address
		 * component.  If strictly routed make sure next
		 * address is on directly accessible net.
		 */
		case IPOPT_LSRR:
		case IPOPT_SSRR:
			if ((off = cp[IPOPT_OFFSET]) < IPOPT_MINOFF) {
				code = &cp[IPOPT_OFFSET] - (u_char *)floe_slirp_ip;
				goto bad;
			}
			ipaddr.sin_addr = floe_slirp_ip->ip_dst;
			ia = (struct in_ifaddr *)
				ifa_ifwithaddr((struct sockaddr *)&ipaddr);
			if (ia == 0) {
				if (opt == IPOPT_SSRR) {
					type = ICMP_UNREACH;
					code = ICMP_UNREACH_SRCFAIL;
					goto bad;
				}
				/*
				 * Loose routing, and not at next destination
				 * yet; nothing to do except forward.
				 */
				break;
			}
			off--;			/ * 0 origin *  /
			if (off > optlen - sizeof(struct in_addr)) {
				/*
				 * End of source route.  Should be for us.
				 */
				save_rte(cp, floe_slirp_ip->ip_src);
				break;
			}
			/*
			 * locate outgoing interface
			 */
			bcopy((caddr_t)(cp + off), (caddr_t)&ipaddr.sin_addr,
			    sizeof(ipaddr.sin_addr));
			if (opt == IPOPT_SSRR) {
#define	INA	struct in_ifaddr *
#define	SA	struct sockaddr *
 			    if ((ia = (INA)ifa_ifwithdstaddr((SA)&ipaddr)) == 0)
				ia = (INA)ifa_ifwithnet((SA)&ipaddr);
			} else
				ia = ip_rtaddr(ipaddr.sin_addr);
			if (ia == 0) {
				type = ICMP_UNREACH;
				code = ICMP_UNREACH_SRCFAIL;
				goto bad;
			}
			floe_slirp_ip->ip_dst = ipaddr.sin_addr;
			bcopy((caddr_t)&(IA_SIN(ia)->sin_addr),
			    (caddr_t)(cp + off), sizeof(struct in_addr));
			cp[IPOPT_OFFSET] += sizeof(struct in_addr);
			/*
			 * Let ip_intr's mcast routing check handle mcast pkts
			 */
			forward = !IN_MULTICAST(ntohl(floe_slirp_ip->ip_dst.s_addr));
			break;

		case IPOPT_RR:
			if ((off = cp[IPOPT_OFFSET]) < IPOPT_MINOFF) {
				code = &cp[IPOPT_OFFSET] - (u_char *)floe_slirp_ip;
				goto bad;
			}
			/*
			 * If no space remains, ignore.
			 */
			off--;			 * 0 origin *
			if (off > optlen - sizeof(struct in_addr))
				break;
			bcopy((caddr_t)(&floe_slirp_ip->ip_dst), (caddr_t)&ipaddr.sin_addr,
			    sizeof(ipaddr.sin_addr));
			/*
			 * locate outgoing interface; if we're the destination,
			 * use the incoming interface (should be same).
			 */
			if ((ia = (INA)ifa_ifwithaddr((SA)&ipaddr)) == 0 &&
			    (ia = ip_rtaddr(ipaddr.sin_addr)) == 0) {
				type = ICMP_UNREACH;
				code = ICMP_UNREACH_HOST;
				goto bad;
			}
			bcopy((caddr_t)&(IA_SIN(ia)->sin_addr),
			    (caddr_t)(cp + off), sizeof(struct in_addr));
			cp[IPOPT_OFFSET] += sizeof(struct in_addr);
			break;

		case IPOPT_TS:
			code = cp - (u_char *)floe_slirp_ip;
			ipt = (struct ip_timestamp *)cp;
			if (ipt->ipt_len < 5)
				goto bad;
			if (ipt->ipt_ptr > ipt->ipt_len - sizeof (int32_t)) {
				if (++ipt->ipt_oflw == 0)
					goto bad;
				break;
			}
			sin = (struct in_addr *)(cp + ipt->ipt_ptr - 1);
			switch (ipt->ipt_flg) {

			case IPOPT_TS_TSONLY:
				break;

			case IPOPT_TS_TSANDADDR:
				if (ipt->ipt_ptr + sizeof(n_time) +
				    sizeof(struct in_addr) > ipt->ipt_len)
					goto bad;
				ipaddr.sin_addr = dst;
				ia = (INA)ifaof_ i f p foraddr((SA)&ipaddr,
							    m->m_pkthdr.rcvif);
				if (ia == 0)
					continue;
				bcopy((caddr_t)&IA_SIN(ia)->sin_addr,
				    (caddr_t)sin, sizeof(struct in_addr));
				ipt->ipt_ptr += sizeof(struct in_addr);
				break;

			case IPOPT_TS_PRESPEC:
				if (ipt->ipt_ptr + sizeof(n_time) +
				    sizeof(struct in_addr) > ipt->ipt_len)
					goto bad;
				bcopy((caddr_t)sin, (caddr_t)&ipaddr.sin_addr,
				    sizeof(struct in_addr));
				if (ifa_ifwithaddr((SA)&ipaddr) == 0)
					continue;
				ipt->ipt_ptr += sizeof(struct in_addr);
				break;

			default:
				goto bad;
			}
			ntime = iptime();
			bcopy((caddr_t)&ntime, (caddr_t)cp + ipt->ipt_ptr - 1,
			    sizeof(n_time));
			ipt->ipt_ptr += sizeof(n_time);
		}
	}
	if (forward) {
		ip_forward(m, 1);
		return (1);
	}
	return (0);
bad:
 	icmp_error(m, type, code, 0, 0);

	return (1);
}

#endif /* notdef */

/*
 * Strip out IP options, at higher
 * level protocol in the kernel.
 * Second argument is buffer to which options
 * will be moved, and return value is their length.
 * (XXX) should be deleted; last arg currently ignored.
 */
void
ip_stripoptions(register struct floe_slirp_mbuf *m, struct floe_slirp_mbuf *mopt)
{
	register int i;
	struct floe_slirp_ip *floe_slirp_ip = mtod(m, struct floe_slirp_ip *);
	register caddr_t opts;
	int olen;

	olen = (floe_slirp_ip->ip_hl<<2) - sizeof (struct floe_slirp_ip);
	opts = (caddr_t)(floe_slirp_ip + 1);
	i = m->m_len - (sizeof (struct floe_slirp_ip) + olen);
	memcpy(opts, opts  + olen, (unsigned)i);
	m->m_len -= olen;

	floe_slirp_ip->ip_hl = sizeof(struct floe_slirp_ip) >> 2;
}
