/* SPDX-License-Identifier: MPL-2.0 */
/* Multi-channel console endpoints for the embedded profile.
 *
 * Every guest console device speaks through a ConsoleEP naming one of the
 * session's AEChannels. Channel 0 backs the PL011; each virtio-console gets
 * its own channel (its own bounded input/output rings, its own geometry).
 * The legacy floe_ae_console_read/write ABI targets channel 0; the version-2
 * channel operations address any present channel by index.
 *
 * Geometry lives here: the ABI pushes cols/rows into a channel and sets its
 * winch flag; virtio_console_poll() (already upstream logic) notices the
 * change through console_take_winch()/console_get_winsize(), updates config
 * space and raises the virtio config-change interrupt. No SIGWINCH, no host
 * terminal, no inherited descriptors anywhere in this profile.
 *
 * Ring access is serialized on the session mutex: devices touch the rings
 * from the machine coordinator, embedders from arbitrary host threads. */
#include "embedded_internal.h"
#include "parallel_runtime.h"
#include <stdarg.h>
#include <string.h>
#include <stdlib.h>
#include <unistd.h>
_Thread_local AESession *ae_current;
size_t ae_ring_write(AERing *r,const void *data,size_t n) {
    if(n>r->cap-r->count)n=r->cap-r->count;
    if(!n)return 0;
    size_t tail=(r->head+r->count)%r->cap,first=r->cap-tail;if(first>n)first=n;
    memcpy(r->bytes+tail,data,first);memcpy(r->bytes,(const unsigned char *)data+first,n-first);r->count+=n;return n;
}
size_t ae_ring_read(AERing *r,void *data,size_t n) {
    if(n>r->count)n=r->count;if(!n)return 0;size_t first=r->cap-r->head;if(first>n)first=n;
    memcpy(data,r->bytes+r->head,first);memcpy((unsigned char *)data+first,r->bytes,n-first);
    r->head=(r->head+n)%r->cap;r->count-=n;return n;
}
size_t ae_ring_space(const AERing *r) { return r->cap-r->count; }
/* Drop every pending wake byte. Called by readiness waiters after poll(2)
 * reports the pipe readable, so stale bytes cannot shorten a later wait. */
void ae_wake_drain(AESession *s) {
    if(!s->wake_pipe_ready)return;unsigned char scratch[64];
    for(;;){ssize_t n=read(s->wake_pipe[0],scratch,sizeof(scratch));if(n<(ssize_t)sizeof(scratch))break;}
}
void ae_signal_locked(AESession *s) {
    s->sequence++;
    if(s->wake_pipe_ready){unsigned char b=0;(void)write(s->wake_pipe[1],&b,1);} /* EAGAIN when full: a byte is already pending */
    pthread_cond_broadcast(&s->condition);ae_parallel_notify(s);
}
static AEChannel *ae_channel(AESession *s,uint32_t index) {
    if(index>=AE_MAX_CHANNELS||!s->channels[index].present)return NULL;
    return &s->channels[index];
}
/* There is no process terminal in the embedded profile: every console is on
 * a native-owned channel endpoint, so the "shared stdio" endpoint and the
 * inherited-fd endpoint are explicitly absent (NULL), never success stubs. */
ConsoleEP *console_stdio(void) { return NULL; }
ConsoleEP *console_open_fd(int a,int b) { (void)a;(void)b;return NULL; }
void console_close(ConsoleEP *e) { (void)e; }
bool console_is_stdio(const ConsoleEP *e) { (void)e;return false; }
int console_getchar(ConsoleEP *e) {
    if(!e)return -1;AESession *s=e->owner;AEChannel *ch=ae_channel(s,e->channel);
    if(!ch)return -1;unsigned char chb;
    pthread_mutex_lock(&s->mutex);size_t n=ae_ring_read(&ch->input,&chb,1);pthread_mutex_unlock(&s->mutex);
    return n?chb:-1;
}
size_t console_output_space(const ConsoleEP *e) {
    if(!e)return 0;AESession *s=e->owner;AEChannel *ch=ae_channel(s,e->channel);
    if(!ch)return 0;pthread_mutex_lock(&s->mutex);
    size_t space=ae_ring_space(&ch->output);pthread_mutex_unlock(&s->mutex);return space;
}
size_t console_write(ConsoleEP *e,const void *data,size_t n) {
    if(!e||!n)return 0;AESession *s=e->owner;AEChannel *ch=ae_channel(s,e->channel);
    if(!ch)return 0;pthread_mutex_lock(&s->mutex);
    size_t accepted=ae_ring_write(&ch->output,data,n);
    /* virtio-console callers must pre-check ae_ring_space and apply transport
     * backpressure, so a partial write here is impossible for channels > 0 and
     * never faults the machine. Channel 0 (the PL011 UART) keeps the legacy
     * bounded contract: the run loop parks with FLOE_AE_OUTPUT_FULL before its
     * ring can overflow; reaching the poison below means that invariant was
     * violated, so it stays a hard fault for the UART only. */
    if(accepted!=n&&e->channel==0)s->machine.host_error=FLOE_AE_FAULT;
    pthread_mutex_unlock(&s->mutex);return accepted;
}
void console_putchar(ConsoleEP *e,int c) { unsigned char b=(unsigned char)c;console_write(e,&b,1); }
void console_flush(ConsoleEP *e) { (void)e; }  /* rings drain through the ABI */
int console_poll_fd(const ConsoleEP *e) { (void)e;return -1; }
void console_get_winsize(ConsoleEP *e,u16 *cols,u16 *rows) {
    if(!e){*cols=0;*rows=0;return;}AESession *s=e->owner;AEChannel *ch=ae_channel(s,e->channel);
    if(!ch){*cols=0;*rows=0;return;}
    pthread_mutex_lock(&s->mutex);*cols=ch->cols;*rows=ch->rows;pthread_mutex_unlock(&s->mutex);
}
void console_set_winsize(ConsoleEP *e,u16 cols,u16 rows) {
    if(!e)return;AESession *s=e->owner;AEChannel *ch=ae_channel(s,e->channel);
    if(!ch)return;
    pthread_mutex_lock(&s->mutex);
    if(ch->cols!=cols||ch->rows!=rows){ch->cols=cols;ch->rows=rows;ch->winch=true;}
    pthread_mutex_unlock(&s->mutex);
}
bool console_take_winch(ConsoleEP *e) {
    if(!e)return false;AESession *s=e->owner;AEChannel *ch=ae_channel(s,e->channel);
    if(!ch)return false;
    pthread_mutex_lock(&s->mutex);bool w=ch->winch;ch->winch=false;pthread_mutex_unlock(&s->mutex);
    return w;
}
/* The inherited-fd control channel is not part of the embedded profile:
 * terminal geometry is pushed through floe_ae_channel_set_winsize instead.
 * These stay explicit absence stubs so the platform code paths never bind. */
ConsoleCtrl *console_ctrl_open(int fd) { (void)fd;return NULL; }
void console_ctrl_poll(ConsoleCtrl *c,ConsoleEP *u,ConsoleEP **v,int n) { (void)c;(void)u;(void)v;(void)n; }
int console_ctrl_fd(const ConsoleCtrl *c) { (void)c;return -1; }
static int diag(const char *format,va_list args) {
    AESession *s=ae_current;if(!s)return 0;char text[768];int n=vsnprintf(text,sizeof(text),format,args);
    if(n<=0)return n;size_t length=(size_t)n<sizeof(text)?(size_t)n:sizeof(text)-1;
    pthread_mutex_lock(&s->mutex);size_t saved=ae_ring_write(&s->diagnostic,text,length);
    s->diagnostic_dropped+=(size_t)n-saved;pthread_mutex_unlock(&s->mutex);return n;
}
int ae_vendor_fprintf(FILE *ignored,const char *format,...) { (void)ignored;va_list a;va_start(a,format);int n=diag(format,a);va_end(a);return n; }
int ae_vendor_printf(const char *format,...) { va_list a;va_start(a,format);int n=diag(format,a);va_end(a);return n; }
int ae_vendor_fputc(int c,FILE *ignored) { (void)ignored;return ae_vendor_printf("%c",c); }
