/* SPDX-License-Identifier: Apache-2.0 */
/* Packet-level tests of the actual device parser and native filesystem I/O.
 * No Machine, DMA, interrupt or guest-boot acceptance is claimed here. */
#include "../../ThirdParty/ARM64EMU/Source/src/devices/virtio_9p.c"
#include <assert.h>

static unsigned passed;
static const char *current;
#define CHECK(x) do { if (!(x)) { fprintf(stderr, "FAIL %s:%d %s: %s\n", __FILE__, __LINE__, current, #x); exit(1); } } while (0)
static void check_case(const char *name) { current = name; }
static void done(void) { printf("PASS %s\n", current); passed++; }

static Cur request(VirtIO9P *v, u8 type) {
    Cur c = {v->req, P9_MSIZE_MAX, 0, false};
    p_u32(&c, 0); p_u8(&c, type); p_u16(&c, 42);
    return c;
}
static Cur response(VirtIO9P *v, Cur *c, u8 expected) {
    CHECK(!c->err); patch_size(v->req, c->pos);
    u32 n = p9_dispatch(v, c->pos, P9_MSIZE_MAX);
    Cur r = {v->resp, n, 0, false};
    CHECK(c_u32(&r) == n);
    u8 type = c_u8(&r); CHECK(c_u16(&r) == 42);
    if (type != expected) {
        fprintf(stderr, "reply type=%u expected=%u errno=%u\n", type, expected,
                type == P9_RLERROR ? c_u32(&r) : 0);
        CHECK(type == expected);
    }
    return r;
}
static void error_reply(VirtIO9P *v, Cur *c, int first, int second) {
    Cur r = response(v, c, P9_RLERROR);
    int actual = (int)c_u32(&r);
    if (actual != first && actual != second)
        fprintf(stderr, "wire errno=%d expected=%d or %d\n", actual, first, second);
    CHECK(actual == first || actual == second);
}
static void attach(VirtIO9P *v, u32 fid) {
    Cur c = request(v, P9_TATTACH);
    p_u32(&c, fid); p_u32(&c, UINT32_MAX); p_str(&c, "root"); p_str(&c, ""); p_u32(&c, 0);
    (void)response(v, &c, P9_RATTACH);
}
static Cur walk_request(VirtIO9P *v, u32 from, u32 to, const char **parts, u16 count) {
    Cur c = request(v, P9_TWALK);
    p_u32(&c, from); p_u32(&c, to); p_u16(&c, count);
    for (u16 i=0; i<count; i++) p_str(&c, parts[i]);
    return c;
}
static void walk(VirtIO9P *v, u32 from, u32 to, const char *name, u8 qid) {
    const char *parts[] = {name}; Cur c = walk_request(v, from, to, parts, 1);
    Cur r = response(v, &c, P9_RWALK);
    CHECK(c_u16(&r) == 1); CHECK(c_u8(&r) == qid);
}
static void symlink_request(VirtIO9P *v, u32 parent, const char *name, const char *target) {
    Cur c = request(v, P9_TSYMLINK);
    p_u32(&c, parent); p_str(&c, name); p_str(&c, target); p_u32(&c, 0);
    Cur r = response(v, &c, P9_RSYMLINK); CHECK(c_u8(&r) == P9_QTSYMLINK);
}
static void link_metadata(VirtIO9P *v, u32 fid, const char *target) {
    Cur c = request(v, P9_TGETATTR); p_u32(&c, fid); p_u64(&c, P9_STATS_BASIC);
    Cur r = response(v, &c, P9_RGETATTR);
    (void)c_u64(&r); CHECK(c_u8(&r) == P9_QTSYMLINK);
    (void)c_u32(&r); (void)c_u64(&r); CHECK(S_ISLNK(c_u32(&r)));
    c = request(v, P9_TREADLINK); p_u32(&c, fid);
    r = response(v, &c, P9_RREADLINK);
    char got[PATH_MAX]; CHECK(c_str(&r, got, sizeof(got))); CHECK(!strcmp(got, target));
}
static Cur open_request(VirtIO9P *v, u32 fid, u32 flags) {
    Cur c = request(v, P9_TLOPEN); p_u32(&c, fid); p_u32(&c, flags); return c;
}
static void read_inside(VirtIO9P *v, u32 fid) {
    Cur c = open_request(v, fid, 0); (void)response(v, &c, P9_RLOPEN);
    c = request(v, P9_TREAD); p_u32(&c, fid); p_u64(&c, 0); p_u32(&c, 64);
    Cur r = response(v, &c, P9_RREAD); u32 n = c_u32(&r);
    CHECK(n == 6 && !memcmp(r.b+r.pos, "inside", 6));
}
static Cur unlink_request(VirtIO9P *v, u32 parent, const char *name) {
    Cur c = request(v, P9_TUNLINKAT); p_u32(&c,parent); p_str(&c,name); p_u32(&c,0); return c;
}
static void host_write(const char *path, const char *body) {
    int fd = open(path, O_WRONLY|O_CREAT|O_EXCL, 0600); CHECK(fd>=0);
    CHECK(write(fd,body,strlen(body)) == (ssize_t)strlen(body)); CHECK(close(fd)==0);
}
static void host_body(const char *path, const char *expected) {
    char b[128]; int fd=open(path,O_RDONLY|O_NOFOLLOW); CHECK(fd>=0);
    ssize_t n=read(fd,b,sizeof(b)); CHECK(n==(ssize_t)strlen(expected));
    CHECK(!memcmp(b,expected,(size_t)n)); CHECK(close(fd)==0);
}

int main(int argc, char **argv) {
    check_case("fixture"); CHECK(argc==2);
    char temp[PATH_MAX]; CHECK(snprintf(temp,sizeof(temp),"%s/fixture-XXXXXX",argv[1])<(int)sizeof(temp));
    CHECK(mkdtemp(temp)); char root[PATH_MAX], outside[PATH_MAX], nested[PATH_MAX], inside[PATH_MAX], victim[PATH_MAX];
    snprintf(root,sizeof(root),"%s/root",temp); CHECK(mkdir(root,0700)==0);
    snprintf(outside,sizeof(outside),"%s/outside",temp); CHECK(mkdir(outside,0700)==0);
    snprintf(nested,sizeof(nested),"%s/nested",root); CHECK(mkdir(nested,0700)==0);
    snprintf(inside,sizeof(inside),"%s/table.csv",nested); host_write(inside,"inside");
    snprintf(victim,sizeof(victim),"%s/victim",outside); host_write(victim,"outside-sentinel");
    VirtIO9P *v=calloc(1,sizeof(*v)); CHECK(v); v->rootfd=-1; v->msize=P9_MSIZE_MAX;
    v->req=malloc(P9_MSIZE_MAX); v->resp=malloc(P9_MSIZE_MAX); CHECK(v->req && v->resp);
    p9s_init(&v->share); CHECK(virtio_9p_attach_root(v,root,0,0,false)==0); attach(v,1);
    walk(v,1,2,"nested",P9_QTDIR);

    check_case("final relative link retains symlink qid lstat and readlink");
    symlink_request(v,2,"relative.csv","table.csv");
    walk(v,2,3,"relative.csv",P9_QTSYMLINK); link_metadata(v,3,"table.csv"); done();

    check_case("contained final link content open still works"); read_inside(v,3); done();
    check_case("nofollow content open refuses link");
    Cur c=open_request(v,3,P9_O_NOFOLLOW); error_reply(v,&c,40,40); done();

    check_case("guest absolute link can be inspected without following it");
    const char *guest_absolute="/floe/env/tmp/outside.csv";
    symlink_request(v,2,"absolute.csv",guest_absolute); walk(v,2,4,"absolute.csv",P9_QTSYMLINK);
    link_metadata(v,4,guest_absolute); c=open_request(v,4,0); error_reply(v,&c,13,13); done();

    check_case("unlink removes guest absolute link node only");
    c=unlink_request(v,2,"absolute.csv"); (void)response(v,&c,P9_RUNLINKAT); host_body(inside,"inside"); done();
    check_case("remove removes link node without touching its target");
    c=request(v,P9_TREMOVE);p_u32(&c,3);(void)response(v,&c,P9_RREMOVE);host_body(inside,"inside");done();

    check_case("escaping host link metadata is visible but content is refused");
    symlink_request(v,1,"escape",outside);walk(v,1,5,"escape",P9_QTSYMLINK);link_metadata(v,5,outside);
    c=open_request(v,5,0);error_reply(v,&c,13,13);done();

    check_case("intermediate escaping walk refuses traversal and creates no fid");
    const char *parts[]={"escape","victim"};c=walk_request(v,1,6,parts,2);
    Cur r=response(v,&c,P9_RWALK);CHECK(c_u16(&r)==1);
    c=request(v,P9_TGETATTR);p_u32(&c,6);p_u64(&c,P9_STATS_BASIC);error_reply(v,&c,9,9);
    const char *leaf[]={"victim"};c=walk_request(v,5,7,leaf,1);error_reply(v,&c,13,13);done();

    check_case("contained intermediate directory link still traverses");
    symlink_request(v,1,"alias","nested");const char *safe[]={"alias","table.csv"};
    c=walk_request(v,1,8,safe,2);r=response(v,&c,P9_RWALK);CHECK(c_u16(&r)==2);read_inside(v,8);done();

    check_case("unlink cannot use a symlink fid as its parent");
    c=unlink_request(v,5,"victim");error_reply(v,&c,20,40);host_body(victim,"outside-sentinel");done();
    check_case("rename cannot use escaping destination directory fid");
    walk(v,2,9,"table.csv",P9_QTFILE);
    c=request(v,P9_TRENAME);p_u32(&c,9);p_u32(&c,5);p_str(&c,"stolen");error_reply(v,&c,20,40);
    host_body(inside,"inside");host_body(victim,"outside-sentinel");done();
    check_case("renameat cannot use escaping source or destination directory fid");
    c=request(v,P9_TRENAMEAT);p_u32(&c,5);p_str(&c,"victim");p_u32(&c,2);p_str(&c,"stolen");error_reply(v,&c,20,40);
    c=request(v,P9_TRENAMEAT);p_u32(&c,2);p_str(&c,"table.csv");p_u32(&c,5);p_str(&c,"stolen");error_reply(v,&c,20,40);
    host_body(inside,"inside");host_body(victim,"outside-sentinel");done();

    check_case("link cycle stays metadata but content has bounded ELOOP");
    symlink_request(v,1,"cycle-a","cycle-b");symlink_request(v,1,"cycle-b","cycle-a");
    walk(v,1,10,"cycle-a",P9_QTSYMLINK);link_metadata(v,10,"cycle-b");
    c=open_request(v,10,0);error_reply(v,&c,40,40);done();

    check_case("normal rename renameat and unlink still work");
    c=request(v,P9_TRENAMEAT);p_u32(&c,2);p_str(&c,"table.csv");p_u32(&c,2);p_str(&c,"moved.csv");(void)response(v,&c,P9_RRENAMEAT);
    c=request(v,P9_TRENAMEAT);p_u32(&c,2);p_str(&c,"moved.csv");p_u32(&c,2);p_str(&c,"table.csv");(void)response(v,&c,P9_RRENAMEAT);
    c=request(v,P9_TRENAME);p_u32(&c,9);p_u32(&c,2);p_str(&c,"renamed.csv");(void)response(v,&c,P9_RRENAME);
    c=unlink_request(v,2,"renamed.csv");(void)response(v,&c,P9_RUNLINKAT);done();

    check_case("generation fence refuses old fid");
    CHECK(p9s_detach(&v->share,true)==0);CHECK(p9s_attach(&v->share,0,0,false)==0);
    c=request(v,P9_TGETATTR);p_u32(&c,1);p_u64(&c,P9_STATS_BASIC);error_reply(v,&c,116,116);done();

    check_case("read-only mount retains metadata but refuses mutations");
    CHECK(virtio_9p_detach_root(v,true)==0);CHECK(virtio_9p_attach_root(v,root,0,0,true)==0);attach(v,20);
    walk(v,20,21,"escape",P9_QTSYMLINK);link_metadata(v,21,outside);
    c=unlink_request(v,20,"escape");error_reply(v,&c,30,30);
    c=request(v,P9_TRENAME);p_u32(&c,21);p_u32(&c,20);p_str(&c,"changed");error_reply(v,&c,30,30);
    c=request(v,P9_TRENAMEAT);p_u32(&c,20);p_str(&c,"escape");p_u32(&c,20);p_str(&c,"changed");error_reply(v,&c,30,30);
    c=open_request(v,21,1);error_reply(v,&c,30,30);host_body(victim,"outside-sentinel");done();
    virtio_9p_destroy(v);
    printf("NINEP_PROTOCOL_OK checks=%u\n",passed); return 0;
}
