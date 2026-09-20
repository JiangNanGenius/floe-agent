/*
 * Copyright (c) 1995 Danny Gasparovski.
 *
 * Please read the file COPYRIGHT for the
 * terms and conditions of the copyright.
 */

#ifndef _SBUF_H_
#define _SBUF_H_

#define sbflush(sb) sbdrop((sb),(sb)->sb_cc)
#define sbspace(sb) ((sb)->sb_datalen - (sb)->sb_cc)

struct floe_slirp_sbuf {
	u_int	sb_cc;		/* actual chars in buffer */
	u_int	sb_datalen;	/* Length of data  */
	char	*sb_wptr;	/* write pointer. points to where the next
				 * bytes should be written in the floe_slirp_sbuf */
	char	*sb_rptr;	/* read pointer. points to where the next
				 * byte should be read from the floe_slirp_sbuf */
	char	*sb_data;	/* Actual data */
};

void sbfree(struct floe_slirp_sbuf *);
void sbdrop(struct floe_slirp_sbuf *, int);
void sbreserve(struct floe_slirp_sbuf *, int);
void sbappend(struct socket *, struct floe_slirp_mbuf *);
void sbcopy(struct floe_slirp_sbuf *, int, int, char *);

#endif
