/* Bounded shared XDG smoke compositor. Slots are not recycled until host ACK. */
enum { NSURF = 8 };
static struct shared_surface {
    struct wl_resource *s, *xd, *top, *buf, *cb, *submitted_cb;
    struct wl_listener gone;
    unsigned id, seq, serial;
    int scale, pending_scale, attached, configured, busy, mapped_w, mapped_h;
    int resize_w, resize_h;
} windows[NSURF];
static unsigned next_id, session_base;
static void shared_event(const char *kind, unsigned id) {
    printf("%s %u\n", kind, id); fflush(stdout);
}
static struct wl_list devices;
static struct shared_surface *pointer_focus, *key_focus;
static int pressed;
static unsigned char held_keys[128];
static void device_gone(struct wl_resource *r) { wl_list_remove(wl_resource_get_link(r)); }
static void ignore_cursor(struct wl_client *c,struct wl_resource *r,uint32_t serial,struct wl_resource *s,int32_t x,int32_t y) {
    (void)c;(void)r;(void)serial;(void)s;(void)x;(void)y;
}
static const char seat_map[] =
    "xkb_keymap { xkb_keycodes { minimum=8; maximum=255; <AC01>=38; <LFSH>=50; };"
    "xkb_types { type \"TWO_LEVEL\" { modifiers=Shift; map[Shift]=Level2; }; };"
    "xkb_compatibility { interpret Shift_L { action=SetMods(modifiers=Shift); }; };"
    "xkb_symbols { key <AC01> { type=\"TWO_LEVEL\", [ a, A ] }; key <LFSH> { [ Shift_L ] }; modifier_map Shift { <LFSH> }; }; };";
static void device(struct wl_client *c, uint32_t id, int version, const struct wl_interface *type) {
    struct wl_resource *r=wl_resource_create(c,type,version,id);
    if (!r) { wl_client_post_no_memory(c); return; }
    static const struct wl_pointer_interface ops={.set_cursor=ignore_cursor,.release=destroy_resource};
    static const struct wl_keyboard_interface keys={.release=destroy_resource};
    wl_resource_set_implementation(r,type==&wl_pointer_interface?(const void *)&ops:&keys,NULL,device_gone);
    wl_list_insert(&devices,wl_resource_get_link(r));
    if(type==&wl_keyboard_interface) {
        int fd=memfd_create("m2-xkb",MFD_CLOEXEC);
        if(fd<0) sysfail("keymap fd");
        if(write(fd,seat_map,sizeof seat_map)!=sizeof seat_map) sysfail("write keymap");
        wl_keyboard_send_keymap(r,WL_KEYBOARD_KEYMAP_FORMAT_XKB_V1,fd,sizeof seat_map); close(fd);
    }
}
static void pointer(struct wl_client *c,struct wl_resource *r,uint32_t id) { device(c,id,wl_resource_get_version(r),&wl_pointer_interface); }
static void keyboard(struct wl_client *c,struct wl_resource *r,uint32_t id) { device(c,id,wl_resource_get_version(r),&wl_keyboard_interface); }
static void bind_seat(struct wl_client *c,void *data,uint32_t v,uint32_t id) {
    (void)data;
    static const struct wl_seat_interface ops={.get_pointer=pointer,.get_keyboard=keyboard,.release=destroy_resource};
    struct wl_resource *r=wl_resource_create(c,&wl_seat_interface,v,id);
    if(!r) { wl_client_post_no_memory(c); return; }
    wl_resource_set_implementation(r,&ops,NULL,NULL);
    if (v >= 2) wl_seat_send_name(r, "m2");
    wl_seat_send_capabilities(r,WL_SEAT_CAPABILITY_POINTER|WL_SEAT_CAPABILITY_KEYBOARD);
}
static void data_device(struct wl_client *c, struct wl_resource *r, uint32_t id, struct wl_resource *seat) {
    (void)r; (void)seat;
    struct wl_resource *device = wl_resource_create(c, &wl_data_device_interface, 1, id);
    if (!device) { wl_client_post_no_memory(c); return; }
    wl_resource_set_implementation(device, NULL, NULL, NULL);
}
static void bind_data_manager(struct wl_client *c, void *data, uint32_t v, uint32_t id) {
    (void)data;
    static const struct wl_data_device_manager_interface ops = {.get_data_device=data_device};
    struct wl_resource *r = wl_resource_create(c, &wl_data_device_manager_interface, v, id);
    if (!r) { wl_client_post_no_memory(c); return; }
    wl_resource_set_implementation(r, &ops, NULL, NULL);
}
static void deliver(struct shared_surface *p,char op,int x,int y) {
    if(!p || !p->s) return;
    uint32_t serial=wl_display_next_serial(display), t=monotonic_ns()/1000000;
    struct wl_resource *r;
    wl_resource_for_each(r,&devices) {
        if(wl_resource_get_client(r)!=wl_resource_get_client(p->s)) continue;
        if(!strcmp(wl_resource_get_class(r),"wl_pointer")) {
            if(op=='E') wl_pointer_send_enter(r,serial,p->s,wl_fixed_from_int(x),wl_fixed_from_int(y));
            if(op=='P') wl_pointer_send_leave(r,serial,p->s);
            if(op=='M') wl_pointer_send_motion(r,t,wl_fixed_from_int(x),wl_fixed_from_int(y));
            if(op=='B') wl_pointer_send_button(r,serial,t,272,x);
        } else {
            if(op=='F') { struct wl_array keys={0}; wl_keyboard_send_enter(r,serial,p->s,&keys); wl_keyboard_send_modifiers(r,serial,0,0,0,0); }
            if(op=='L') wl_keyboard_send_leave(r,serial,p->s);
            if(op=='K') { wl_keyboard_send_key(r,serial,t,x,y); if(x==42) wl_keyboard_send_modifiers(r,serial,y,0,0,0); }
        }
    }
}
static void release_keys(struct shared_surface *p) {
    for(int code=1;code<128;code++) if(held_keys[code]) { deliver(p,'K',code,0); held_keys[code]=0; }
}
static void blur(struct shared_surface *p) {
    if(pointer_focus==p) { if(pressed) deliver(p,'B',0,0); pressed=0; deliver(p,'P',0,0); pointer_focus=NULL; }
    if(key_focus==p) { release_keys(p); deliver(p,'L',0,0); key_focus=NULL; }
}
static void shared_configure(struct shared_surface *p, int w, int h) {
    struct wl_array states = {0};
    p->serial = wl_display_next_serial(display);
    wl_resource_post_event(p->top, 0, w, h, &states);
    wl_resource_post_event(p->xd, 0, p->serial);
}
static void shared_resize(struct shared_surface *p) {
    if (p->busy || p->serial || !p->resize_w) return;
    shared_configure(p, p->resize_w, p->resize_h);
    p->resize_w = p->resize_h = 0;
}
static void seat_input(unsigned id,char op,int x,int y) {
    for(int i=0;i<NSURF;i++) {
        struct shared_surface *p=&windows[i];
        if(p->id!=id || !p->s || !p->top || !p->mapped_w) continue;
        if(op=='C') wl_resource_post_event(p->top,1);
        else if(op=='R' && x>0 && y>0) {
            p->resize_w = x <= width/p->scale ? x : width/p->scale;
            p->resize_h = y <= height/p->scale ? y : height/p->scale;
            shared_resize(p);
        } else if(op=='M' && x>=0 && y>=0 && x<p->mapped_w && y<p->mapped_h) {
            if(pointer_focus!=p) {
                if(pressed) return;
                deliver(pointer_focus,'P',0,0); pointer_focus=p; deliver(p,'E',x,y);
            }
            deliver(p,op,x,y);
        } else if(op=='B' && pointer_focus==p && (x==0 || x==1) && x!=pressed) {
            if(x && key_focus!=p) {
                release_keys(key_focus); deliver(key_focus,'L',0,0); key_focus=p; deliver(p,'F',0,0);
            }
            pressed=x; deliver(p,op,x,0);
        } else if(op=='K' && key_focus==p && x>0 && x<128 && (y==0 || y==1) && held_keys[x]!=y) { held_keys[x]=y; deliver(p,op,x,y); }
        else if(op=='L') blur(p);
    }
}
static void shared_clear(struct wl_resource *r) {
    struct shared_surface *p = wl_resource_get_user_data(r);
    if (p->s == r || p->top == r) blur(p);
    if (p->cb == r) p->cb = NULL;
    if (p->submitted_cb == r) p->submitted_cb = NULL;
    if (p->xd == r) p->xd = NULL;
    if (p->top == r) { p->top = NULL; if (!host_lost) shared_event("CLOSED", p->id); }
    if (p->s == r) {
        p->s = NULL;
        if (p->buf) { wl_list_remove(&p->gone.link); p->buf = NULL; }
    }
}
static void shared_buffer_gone(struct wl_listener *l, void *unused) {
    (void)unused;
    struct shared_surface *p = wl_container_of(l, p, gone);
    p->buf = NULL;
}
static void shared_attach(struct wl_client *c, struct wl_resource *r, struct wl_resource *b, int x, int y) {
    (void)c;
    struct shared_surface *p = wl_resource_get_user_data(r);
    if (x || y) { wl_resource_post_error(r, 0, "offset unsupported"); return; }
    if (p->buf) wl_list_remove(&p->gone.link);
    p->attached = 1;
    p->buf = b;
    if (b) wl_resource_add_destroy_listener(b, &p->gone);
}
static void shared_callback(struct wl_client *c, struct wl_resource *r, uint32_t id) {
    struct shared_surface *p = wl_resource_get_user_data(r);
    if (p->cb) { wl_resource_post_error(r, 0, "one callback per frame"); return; }
    p->cb = wl_resource_create(c, &wl_callback_interface, 1, id);
    if (!p->cb) { wl_client_post_no_memory(c); return; }
    wl_resource_set_implementation(p->cb, NULL, p, shared_clear);
}
static void shared_commit(struct wl_client *c, struct wl_resource *r) {
    (void)c;
    struct shared_surface *p = wl_resource_get_user_data(r);
    if (!p->top) goto invalid;
    p->scale = p->pending_scale;
    if (!p->attached) {
        if (!p->configured && !p->serial) shared_configure(p, 0, 0);
        return;
    }
    p->attached = 0;
    if (!p->buf) {
        if (p->mapped_w) {
            blur(p);
            p->mapped_w = p->mapped_h = 0;
            p->resize_w = p->resize_h = 0;
            p->serial = p->configured = 0;
            if (p->cb) wl_resource_destroy(p->cb);
            if (p->submitted_cb) wl_resource_destroy(p->submitted_cb);
            shared_event("UNMAP", p->id);
        } else if (!p->configured && !p->serial) shared_configure(p, 0, 0);
        return;
    }
    struct wl_shm_buffer *b = wl_shm_buffer_get(p->buf);
    if (!p->configured || p->busy || !b) goto invalid;
    int w = wl_shm_buffer_get_width(b), h = wl_shm_buffer_get_height(b), stride = wl_shm_buffer_get_stride(b);
    unsigned format = wl_shm_buffer_get_format(b);
    if ((format != WL_SHM_FORMAT_XRGB8888 && format != WL_SHM_FORMAT_ARGB8888) || w%p->scale || h%p->scale || w<1 || h<1 || w>width || h>height || stride<w*4) goto invalid;
    unsigned slot = (unsigned)(p-windows);
    unsigned char *dst = frame + slot*RANGE;
    wl_shm_buffer_begin_access(b);
    const unsigned char *src = wl_shm_buffer_get_data(b);
    for (int y=0; y<h; y++) memcpy(dst+PREFIX+y*w*4, src+(size_t)y*stride, w*4);
    wl_shm_buffer_end_access(b);
    wl_buffer_send_release(p->buf); wl_list_remove(&p->gone.link); p->buf=NULL;
    mark_slot(dst, slot); atomic_thread_fence(memory_order_release);
    p->submitted_cb = p->cb;
    p->cb = NULL;
    p->mapped_w=w/p->scale; p->mapped_h=h/p->scale; p->busy=1;
    printf("PIXELS %u %u %u %d %d %d\n", p->id, ++p->seq, slot,w,h,p->scale); fflush(stdout);
    return;
invalid: wl_resource_post_error(r, 0, "invalid or unpaced shared commit");
}
static void shared_scale(struct wl_client *c,struct wl_resource *r,int scale) {
    (void)c;
    struct shared_surface *p=wl_resource_get_user_data(r);
    if(scale<1) wl_resource_post_error(r,WL_SURFACE_ERROR_INVALID_SCALE,"invalid scale");
    else p->pending_scale=scale;
}
static void bind_output(struct wl_client *c,void *data,uint32_t v,uint32_t id) {
    (void)data;
    struct wl_resource *r=wl_resource_create(c,&wl_output_interface,v,id);
    if(!r) { wl_client_post_no_memory(c); return; }
    wl_output_send_geometry(r,0,0,300,200,0,"M2","virtual",0);
    wl_output_send_mode(r,WL_OUTPUT_MODE_CURRENT,1280,960,60000);
    if(v>=2) { wl_output_send_scale(r,shared_output_scale); wl_output_send_done(r); }
}
static const struct wl_surface_interface shared_ops = {
    .destroy=destroy_resource, .set_buffer_scale=shared_scale, .attach=shared_attach, .commit=shared_commit, .frame=shared_callback,
    .damage=damage, .set_input_region=ignore_region, .set_opaque_region=ignore_region
};
static void shared_create(struct wl_client *c, struct wl_resource *r, uint32_t id) {
    if ((next_id & 0xffff) == 0xffff) {
        wl_resource_post_error(r, 0, "session surface IDs exhausted");
        return;
    }
    for (int i=0;i<NSURF;i++) {
        struct shared_surface *p=&windows[i];
        if (p->s || p->xd || p->top || p->cb || p->submitted_cb || p->busy) continue;
        *p=(struct shared_surface){.scale=1, .pending_scale=1, .id=++next_id, .gone.notify=shared_buffer_gone};
        p->s=wl_resource_create(c,&wl_surface_interface,wl_resource_get_version(r),id);
        if (!p->s) { wl_client_post_no_memory(c); return; }
        wl_resource_set_implementation(p->s,&shared_ops,p,shared_clear); return;
    }
    wl_resource_post_error(r,0,"surface capacity exceeded");
}
static int shared_dispatch(const void *iface, void *target, uint32_t op, const struct wl_message *msg, union wl_argument *a) {
    struct wl_resource *r=target;
    struct shared_surface *p=wl_resource_get_user_data(r);
    struct wl_client *c=wl_resource_get_client(r);
    if (!op) { wl_resource_destroy(r); return 0; }
    struct wl_resource **out;
    const struct wl_interface *type;
    if (iface==&shell_base && op==2) {
        struct wl_resource *s=(void*)a[1].o;
        p=wl_resource_get_user_data(s);
        if (!p || p->xd) goto invalid;
        out=&p->xd; type=&shell_surface;
    } else if (iface==&shell_surface && op==1 && !p->top) {
        out=&p->top; type=&shell_top;
    } else if (iface==&shell_surface && op==4 && p->serial && p->serial==a[0].u) {
        p->serial=0; p->configured=1; shared_resize(p); return 0;
    } else if (iface==&shell_surface && op==3) return 0;
    else if (iface==&shell_top && (op==2 || op==3 || op==7 || op==8 || (op==1 && !a[0].o))) return 0;
    else goto invalid;
    *out=wl_resource_create(c,type,1,a[0].n);
    if (!*out) { wl_client_post_no_memory(c); return 0; }
    wl_resource_set_dispatcher(*out,shared_dispatch,type,p,shared_clear);
    if (type==&shell_top) shared_event("OPEN",p->id);
    return 0;
invalid: wl_resource_post_error(r,0,"invalid shared request %s",msg->name); return 0;
}
static void shared_reset(void) {
    int abandoned = 0;
    for (int i = 0; i < NSURF; ++i) {
        struct shared_surface *p = &windows[i];
        if (p->s || p->xd || p->top || p->cb || p->submitted_cb || p->buf) fail("live Wayland resource after teardown");
        abandoned += p->busy;
        *p = (struct shared_surface){0};
    }
    if (!wl_list_empty(&devices) || pointer_focus || key_focus || pressed)
        fail("live seat state after teardown");
    for (size_t i = 0; i < sizeof held_keys; ++i)
        if (held_keys[i]) fail("held key after teardown");
    memset(frame, 0, slots * RANGE);
    if (msync(frame, slots * RANGE, MS_SYNC)) sysfail("clear shared DAX slots");
    if (host_lost) fprintf(stderr, "SHARED_HOST_LOST abandoned=%d\n", abandoned);
}
static int stale_surface(unsigned id, const char *kind) {
    if (id >> 16 >= session_base >> 16) return 0;
    fprintf(stderr, "SHARED_STALE_%s %u\n", kind, id);
    return 1;
}
static void shared_command(void) {
    unsigned id,seq; int end=0;
    char op; int x,y=0;
    if(sscanf(ack_line,"I %u %c %d %d",&id,&op,&x,&y)>=3) {
        if (!stale_surface(id, "INPUT")) seat_input(id,op,x,y);
        return;
    }
    if (!strcmp(ack_line,"STOP\n")) {
        for(int i=0;i<NSURF;i++) if(windows[i].s || windows[i].busy) fail("STOP with live surface");
        wl_display_terminate(display); return;
    }
    if(sscanf(ack_line,"ACK %u %u%n",&id,&seq,&end)!=2 || strcmp(ack_line+end,"\n")) fail("bad shared ACK");
    if (stale_surface(id, "ACK")) return;
    for(int i=0;i<NSURF;i++) {
        struct shared_surface *p=&windows[i];
        if(p->id!=id || !p->busy || p->seq!=seq) continue;
        p->busy=0;
        if (p->submitted_cb) {
            wl_callback_send_done(p->submitted_cb, (uint32_t)(monotonic_ns()/1000000));
            wl_resource_destroy(p->submitted_cb);
        }
        shared_resize(p);
        return;
    }
    fail("unknown shared ACK");
}
