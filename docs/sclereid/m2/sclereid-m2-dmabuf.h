/* Private server-side wire definitions; no wayland-scanner/libdrm dependency. */
#include <linux/dma-buf.h>
#include <drm/drm_fourcc.h>
#include <sys/ioctl.h>

static const struct wl_interface dma_params, dma_feedback;
static const struct wl_message dma_requests[] = {
    {"destroy", "", NULL}, {"create_params", "n", (const struct wl_interface *[]){&dma_params}},
    {"get_default_feedback", "4n", (const struct wl_interface *[]){&dma_feedback}},
    {"get_surface_feedback", "4no", (const struct wl_interface *[]){&dma_feedback,&wl_surface_interface}}
};
static const struct wl_message dma_events[] = {{"format","u",NULL},{"modifier","3uuu",NULL}};
static const struct wl_interface dma_factory = {"zwp_linux_dmabuf_v1",4,4,dma_requests,2,dma_events};
static const struct wl_message params_requests[] = {
    {"destroy","",NULL},{"add","huuuuu",NULL},{"create","iiuu",NULL},
    {"create_immed","2niiuu",(const struct wl_interface *[]){&wl_buffer_interface,NULL,NULL,NULL,NULL}}
};
static const struct wl_message params_events[] = {
    {"created","n",(const struct wl_interface *[]){&wl_buffer_interface}},{"failed","",NULL}
};
static const struct wl_interface dma_params = {"zwp_linux_buffer_params_v1",4,4,params_requests,2,params_events};
static const struct wl_message feedback_events[] = {
    {"done","",NULL},{"format_table","hu",NULL},{"main_device","a",NULL},{"tranche_done","",NULL},
    {"tranche_target_device","a",NULL},{"tranche_formats","a",NULL},{"tranche_flags","u",NULL}
};
static const struct wl_interface dma_feedback = {"zwp_linux_dmabuf_feedback_v1",4,1,dma_requests,7,feedback_events};
static dev_t dma_dev;
static int dma_table = -1;
struct dma_plane {
    int fd, w, h, used;
    uint32_t offset, stride;
    uint64_t modifier;
    size_t length;
    void *map;
};
static const struct wl_buffer_interface dma_buffer_ops = {.destroy=destroy_resource};
static void dma_free(struct wl_resource *r) {
    struct dma_plane *p = wl_resource_get_user_data(r);
    if (!p) return; /* transferred to wl_buffer */
    if (p->map != MAP_FAILED) munmap(p->map,p->length);
    if (p->fd >= 0) close(p->fd);
    free(p);
}
static struct dma_plane *dma_buffer(struct wl_resource *r) {
    return wl_resource_instance_of(r,&wl_buffer_interface,&dma_buffer_ops) ? wl_resource_get_user_data(r) : NULL;
}
static int dma_sync(struct dma_plane *p, uint64_t phase) {
    struct dma_buf_sync s = {.flags=DMA_BUF_SYNC_READ | phase};
    int rc;
    do rc=ioctl(p->fd,DMA_BUF_IOCTL_SYNC,&s); while (rc<0 && (errno==EINTR || errno==EAGAIN));
    if (rc<0) fprintf(stderr,"M2_DMABUF SYNC %s READ failed: %s\n", phase==DMA_BUF_SYNC_START?"START":"END",strerror(errno));
    return rc;
}
static void dma_error(struct wl_resource *r, unsigned code, const char *reason) {
    fprintf(stderr,"M2_DMABUF reject: %s\n",reason);
    wl_resource_post_error(r,code,"%s",reason);
}
static int params_dispatch(const void *impl, void *object, uint32_t op,
                           const struct wl_message *msg, union wl_argument *a) {
    (void)impl; (void)msg;
    struct wl_resource *r=object;
    struct dma_plane *p=wl_resource_get_user_data(r);
    if (!op) { wl_resource_destroy(r); return 0; }
    if (!p || p->used) {
        if (op==1) close(a[0].h);
        dma_error(r,0,"params already used"); return 0;
    }
    if (op==1) {
        /* libwayland transfers the received fd, including on rejected adds. */
        if (a[1].u || p->fd>=0) {
            close(a[0].h); dma_error(r,a[1].u?1:2,"expected plane 0 exactly once"); return 0;
        }
        p->fd=a[0].h; p->offset=a[2].u; p->stride=a[3].u;
        p->modifier=((uint64_t)a[4].u<<32)|a[5].u;
        return 0;
    }
    p->used=1;
    int immediate=op==3;
    uint32_t id=immediate?a++->n:0;
    p->w=a[0].i; p->h=a[1].i;
    if (p->fd<0) { dma_error(r,3,"missing plane"); return 0; }
    if (p->w<1 || p->h<1 || p->w>width || p->h>height) { dma_error(r,5,"invalid or oversized dimensions"); return 0; }
    if (a[2].u!=DRM_FORMAT_XRGB8888 || a[3].u || p->modifier!=DRM_FORMAT_MOD_LINEAR) {
        fprintf(stderr,"M2_DMABUF format=%08x flags=%x modifier=%016llx\n",a[2].u,a[3].u,(unsigned long long)p->modifier);
        dma_error(r,4,"requires XRGB8888, explicit LINEAR and no flags"); return 0;
    }
    /* Positive int32 dimensions and uint32 pitch/offset fit in uint64_t. */
    uint64_t row=(uint64_t)p->w*4, end=p->offset+(uint64_t)(p->h-1)*p->stride+row;
    off_t size=lseek(p->fd,0,SEEK_END);
    if (size<0) { perror("M2_DMABUF SEEK_END"); goto failed; }
    if (p->stride<row || end>SIZE_MAX || end>(uint64_t)size) { dma_error(r,6,"plane pitch or extent out of bounds"); return 0; }
    p->length=(size_t)end;
    /* Check the DMA-BUF UAPI before accepting a buffer (a plain memfd can mmap). */
    if (dma_sync(p,DMA_BUF_SYNC_START)<0 || dma_sync(p,DMA_BUF_SYNC_END)<0) goto failed;
    p->map=mmap(NULL,p->length,PROT_READ,MAP_SHARED,p->fd,0);
    if (p->map==MAP_FAILED) { perror("M2_DMABUF mmap"); goto failed; }
    struct wl_client *c=wl_resource_get_client(r);
    struct wl_resource *b=wl_resource_create(c,&wl_buffer_interface,1,id);
    if (!b) { wl_client_post_no_memory(c); return 0; }
    wl_resource_set_user_data(r,NULL);
    wl_resource_set_implementation(b,&dma_buffer_ops,p,dma_free);
    if (!immediate) wl_resource_post_event(r,0,b);
    fprintf(stderr,"M2_DMABUF IMPORT buffer=%u XRGB8888 LINEAR %dx%d offset=%u stride=%u\n",wl_resource_get_id(b),p->w,p->h,p->offset,p->stride);
    return 0;
failed:
    if (immediate) dma_error(r,7,"DMA-BUF import failed"); else wl_resource_post_event(r,1);
    return 0;
}
static int dma_dispatch(const void *impl, void *object, uint32_t op,
                        const struct wl_message *msg, union wl_argument *a) {
    (void)impl; (void)msg;
    struct wl_resource *r=object;
    if (!op) { wl_resource_destroy(r); return 0; }
    struct wl_client *c=wl_resource_get_client(r);
    struct wl_resource *child=wl_resource_create(c,op==1?&dma_params:&dma_feedback,wl_resource_get_version(r),a[0].n);
    if (!child) { wl_client_post_no_memory(c); return 0; }
    if (op==1) {
        struct dma_plane *p=calloc(1,sizeof *p);
        if (!p) { wl_client_post_no_memory(c); return 0; }
        p->fd=-1; p->map=MAP_FAILED;
        wl_resource_set_dispatcher(child,params_dispatch,NULL,p,dma_free);
    } else {
        static const struct { void (*destroy)(struct wl_client *,struct wl_resource *); } ops={destroy_resource};
        wl_resource_set_implementation(child,&ops,NULL,NULL);
        uint16_t index=0;
        struct wl_array device={sizeof dma_dev,0,&dma_dev}, indices={sizeof index,0,&index};
        wl_resource_post_event(child,1,dma_table,16u);
        wl_resource_post_event(child,2,&device);
        wl_resource_post_event(child,4,&device);
        wl_resource_post_event(child,6,0u);
        wl_resource_post_event(child,5,&indices);
        wl_resource_post_event(child,3);
        wl_resource_post_event(child,0);
        fprintf(stderr,"M2_DMABUF FEEDBACK %s XRGB8888 LINEAR\n",op==2?"default":"surface");
    }
    return 0;
}
static void dma_bind(struct wl_client *c, void *data, uint32_t version,uint32_t id) {
    (void)data;
    struct wl_resource *r=wl_resource_create(c,&dma_factory,version,id);
    if (!r) { wl_client_post_no_memory(c); return; }
    wl_resource_set_dispatcher(r,dma_dispatch,NULL,NULL,NULL);
    if (version<3) wl_resource_post_event(r,0,DRM_FORMAT_XRGB8888);
    if (version==3) wl_resource_post_event(r,1,DRM_FORMAT_XRGB8888,0u,0u);
}
static void dma_init(void) {
    struct stat st;
    if (stat("/dev/dri/card0",&st)<0) sysfail("M2_DMABUF stat card0");
    if (!S_ISCHR(st.st_mode)) fail("M2_DMABUF card0 not a DRM device");
    dma_dev=st.st_rdev;
    const struct {uint32_t format,pad; uint64_t modifier;} entry={DRM_FORMAT_XRGB8888,0,DRM_FORMAT_MOD_LINEAR};
    _Static_assert(sizeof entry==16,"feedback format table ABI");
    dma_table=memfd_create("m2-format-table",MFD_CLOEXEC|MFD_ALLOW_SEALING);
    if (dma_table<0 || write(dma_table,&entry,sizeof entry)!=sizeof entry ||
        fcntl(dma_table,F_ADD_SEALS,F_SEAL_WRITE|F_SEAL_GROW|F_SEAL_SHRINK|F_SEAL_SEAL)<0) sysfail("M2_DMABUF format table");
    if (!wl_global_create(display,&dma_factory,4,NULL,dma_bind)) fail("M2_DMABUF global");
    fprintf(stderr,"M2_DMABUF READY v4 main_device=/dev/dri/card0\n");
}
