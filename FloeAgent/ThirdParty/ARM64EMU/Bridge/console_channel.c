/* SPDX-License-Identifier: MPL-2.0 */
#include "embedded_internal.h"
#include "parallel_runtime.h"
#include <stdarg.h>
#include <string.h>
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
void ae_signal_locked(AESession *s) { s->sequence++;pthread_cond_broadcast(&s->condition);ae_parallel_notify(s); }
ConsoleEP *console_stdio(void) { return NULL; }
ConsoleEP *console_open_fd(int a,int b) { (void)a;(void)b;return NULL; }
void console_close(ConsoleEP *e) { (void)e; }
bool console_is_stdio(const ConsoleEP *e) { (void)e;return false; }
int console_getchar(ConsoleEP *e) {
    if(!e)return -1;AESession *s=e->owner;unsigned char ch;
    pthread_mutex_lock(&s->mutex);size_t n=ae_ring_read(&s->input,&ch,1);pthread_mutex_unlock(&s->mutex);
    return n?ch:-1;
}
void console_write(ConsoleEP *e,const void *data,size_t n) {
    if(!e)return;AESession *s=e->owner;pthread_mutex_lock(&s->mutex);
    size_t accepted=ae_ring_write(&s->output,data,n);
    /* A valid PL011 slice reserves >2x its maximum output before each batch.
     * An unexpected backend overflow poisons instead of silently losing bytes. */
    if(accepted!=n)s->machine.host_error=FLOE_AE_FAULT;
    pthread_mutex_unlock(&s->mutex);
}
void console_putchar(ConsoleEP *e,int c) { unsigned char b=(unsigned char)c;console_write(e,&b,1); }
void console_flush(ConsoleEP *e) { (void)e; }
int console_poll_fd(const ConsoleEP *e) { (void)e;return -1; }
void console_get_winsize(ConsoleEP *e,u16 *cols,u16 *rows) { (void)e;*cols=0;*rows=0; }
void console_set_winsize(ConsoleEP *e,u16 cols,u16 rows) { (void)e;(void)cols;(void)rows; }
bool console_take_winch(ConsoleEP *e) { (void)e;return false; }
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
