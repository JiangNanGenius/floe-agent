#ifndef __COMMON_H__
#define __COMMON_H__

#include <stdlib.h>
#include "../cutils.h"
#include "slirp_config.h"

#ifdef _WIN32
# include <inttypes.h>

typedef char *caddr_t;

# include <windows.h>
# include <winsock2.h>
# include <ws2tcpip.h>
# include <sys/timeb.h>
# include <iphlpapi.h>

# define EWOULDBLOCK WSAEWOULDBLOCK
# define EINPROGRESS WSAEINPROGRESS
# define ENOTCONN WSAENOTCONN
# define EHOSTUNREACH WSAEHOSTUNREACH
# define ENETUNREACH WSAENETUNREACH
# define ECONNREFUSED WSAECONNREFUSED
#else
# define ioctlsocket ioctl
# define closesocket(s) close(s)
# if !defined(__HAIKU__)
#  define O_BINARY 0
# endif
#endif

#include <sys/types.h>
#ifdef HAVE_SYS_BITYPES_H
# include <sys/bitypes.h>
#endif

#include <sys/time.h>

#ifdef HAVE_UNISTD_H
# include <unistd.h>
#endif

#ifdef HAVE_STDLIB_H
# include <stdlib.h>
#endif

#include <stdio.h>
#include <errno.h>

#ifndef HAVE_MEMMOVE
#define memmove(x, y, z) bcopy(y, x, z)
#endif

#if TIME_WITH_SYS_TIME
# include <sys/time.h>
# include <time.h>
#else
# ifdef HAVE_SYS_TIME_H
#  include <sys/time.h>
# else
#  include <time.h>
# endif
#endif

#ifdef HAVE_STRING_H
# include <string.h>
#else
# include <strings.h>
#endif

#ifndef _WIN32
#include <sys/uio.h>
#endif

#ifndef _WIN32
#include <netinet/in.h>
#include <arpa/inet.h>
#endif

/* Systems lacking strdup() definition in <string.h>. */
#if defined(ultrix)
char *strdup(const char *);
#endif

/* Systems lacking malloc() definition in <stdlib.h>. */
#if defined(ultrix) || defined(hcx)
void *malloc(size_t arg);
void free(void *ptr);
#endif

#ifndef HAVE_INET_ATON
int inet_aton(const char *cp, struct in_addr *ia);
#endif

#include <fcntl.h>
#ifndef NO_UNIX_SOCKETS
#include <sys/un.h>
#endif
#include <signal.h>
#ifdef HAVE_SYS_SIGNAL_H
# include <sys/signal.h>
#endif
#ifndef _WIN32
#include <sys/socket.h>
#endif

#if defined(HAVE_SYS_IOCTL_H)
# include <sys/ioctl.h>
#endif

#ifdef HAVE_SYS_SELECT_H
# include <sys/select.h>
#endif

#ifdef HAVE_SYS_WAIT_H
# include <sys/wait.h>
#endif

#ifdef HAVE_SYS_FILIO_H
# include <sys/filio.h>
#endif

#ifdef USE_PPP
#include <ppp/slirppp.h>
#endif

#ifdef __STDC__
#include <stdarg.h>
#else
#include <varargs.h>
#endif

#include <sys/stat.h>

/* Avoid conflicting with the libc insque() and remque(), which
   have different prototypes. */
#define insque slirp_insque
#define remque slirp_remque

#ifdef HAVE_SYS_STROPTS_H
#include <sys/stropts.h>
#endif

#include "debug.h"

#include "libslirp.h"
#include "ip.h"
#include "tcp.h"
#include "tcp_timer.h"
#include "tcp_var.h"
#include "tcpip.h"
#include "udp.h"
#include "mbuf.h"
#include "sbuf.h"
#include "socket.h"
#include "if.h"
#include "main.h"
#include "misc.h"
#ifdef USE_PPP
#include "ppp/pppd.h"
#include "ppp/ppp.h"
#endif

#include "bootp.h"
#include "tftp.h"

struct Slirp {
    /* virtual network configuration */
    struct in_addr vnetwork_addr;
    struct in_addr vnetwork_mask;
    struct in_addr vhost_addr;
    struct in_addr vdhcp_startaddr;
    struct in_addr vnameserver_addr;

    /* ARP cache for the guest IP addresses (XXX: allow many entries) */
    uint8_t client_ethaddr[6];

    struct in_addr client_ipaddr;
    char client_hostname[33];

    int restricted;
    struct timeval tt;
    struct ex_list *exec_list;

    /* floe_slirp_mbuf states */
    struct floe_slirp_mbuf m_freelist, m_usedlist;
    int mbuf_alloced;

    /* if states */
    int if_queued;          /* number of packets queued so far */
    struct floe_slirp_mbuf if_fastq;   /* fast queue (for interactive data) */
    struct floe_slirp_mbuf if_batchq;  /* queue for non-interactive data */
    struct floe_slirp_mbuf *next_m;    /* pointer to next floe_slirp_mbuf to output */

    /* floe_slirp_ip states */
    struct floe_slirp_ipq floe_slirp_ipq;         /* floe_slirp_ip reass. queue */
    uint16_t ip_id;         /* floe_slirp_ip packet ctr, for ids */

    /* bootp/dhcp states */
    BOOTPClient bootp_clients[NB_BOOTP_CLIENTS];
    char *bootp_filename;

    /* tcp states */
    struct socket tcb;
    struct socket *tcp_last_so;
    tcp_seq tcp_iss;        /* tcp initial send seq # */
    uint32_t tcp_now;       /* for RFC 1323 timestamps */

    /* udp states */
    struct socket udb;
    struct socket *udp_last_so;

    /* tftp states */
    char *tftp_prefix;
    struct tftp_session tftp_sessions[TFTP_SESSIONS_MAX];

    void *opaque;

    /* FLOE-EMBED (patch 0006): formerly process-wide mutable globals moved
       into the instance so several networked VMs can run on separate host
       threads, each with its own timer flags, DNS cache and select()
       scratch. flds[] points at fd_sets owned by the thread currently in
       slirp_select_poll(); flds_valid guards the dereference. Nothing here
       may be replaced by TLS: slirp_select_fill/poll are always called from
       the run_slice thread and receive their instance explicitly. */
    u_int curtime;
    u_int time_fasttimo;
    u_int last_slowtimo;
    int do_slowtimo;
    struct in_addr dns_addr;
    u_int dns_addr_time;
    struct stat dns_addr_stat;
    fd_set *flds[3]; /* 0 = read, 1 = write, 2 = except */
    int flds_valid;
};

extern Slirp *slirp_instance;

#ifndef NULL
#define NULL (void *)0
#endif

#ifndef FULL_BOLT
void if_start(Slirp *);
#else
void if_start(struct ttys *);
#endif

#ifndef HAVE_STRERROR
 char *strerror(int error);
#endif

#ifndef HAVE_INDEX
 char *index(const char *, int);
#endif

#ifndef HAVE_GETHOSTID
 long gethostid(void);
#endif

void lprint(const char *, ...) __attribute__((format(printf, 1, 2)));

#ifndef _WIN32
#include <netdb.h>
#endif

#define DEFAULT_BAUD 115200

#define SO_OPTIONS DO_KEEPALIVE
#define TCP_MAXIDLE (TCPTV_KEEPCNT * TCPTV_KEEPINTVL)

/* cksum.c */
int cksum(struct floe_slirp_mbuf *m, int len);

/* if.c */
void if_init(Slirp *);
void if_output(struct socket *, struct floe_slirp_mbuf *);

/* ip_input.c */
void ip_init(Slirp *);
void ip_input(struct floe_slirp_mbuf *);
void ip_slowtimo(Slirp *);
void ip_stripoptions(register struct floe_slirp_mbuf *, struct floe_slirp_mbuf *);

/* ip_output.c */
int ip_output(struct socket *, struct floe_slirp_mbuf *);

/* tcp_input.c */
void tcp_input(register struct floe_slirp_mbuf *, int, struct socket *);
int tcp_mss(register struct floe_slirp_tcpcb *, u_int);

/* tcp_output.c */
int tcp_output(register struct floe_slirp_tcpcb *);
void tcp_setpersist(register struct floe_slirp_tcpcb *);

/* tcp_subr.c */
void tcp_init(Slirp *);
void tcp_template(struct floe_slirp_tcpcb *);
void tcp_respond(struct floe_slirp_tcpcb *, register struct floe_slirp_tcpiphdr *, register struct floe_slirp_mbuf *, tcp_seq, tcp_seq, int);
struct floe_slirp_tcpcb * tcp_newtcpcb(struct socket *);
struct floe_slirp_tcpcb * tcp_close(register struct floe_slirp_tcpcb *);
void tcp_sockclosed(struct floe_slirp_tcpcb *);
int tcp_fconnect(struct socket *);
void tcp_connect(struct socket *);
int tcp_attach(struct socket *);
uint8_t tcp_tos(struct socket *);
int tcp_emu(struct socket *, struct floe_slirp_mbuf *);
int tcp_ctl(struct socket *);
struct floe_slirp_tcpcb *tcp_drop(struct floe_slirp_tcpcb *tp, int err);

#ifdef USE_PPP
#define MIN_MRU MINMRU
#define MAX_MRU MAXMRU
#else
#define MIN_MRU 128
#define MAX_MRU 16384
#endif

#ifndef _WIN32
#define min(x,y) ((x) < (y) ? (x) : (y))
#define max(x,y) ((x) > (y) ? (x) : (y))
#endif

#ifdef _WIN32
#undef errno
#define errno (WSAGetLastError())
#endif

#endif
