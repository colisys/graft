/* Shared DAX layout: capacity, not an XDG nesting limit. Change only in sync
 * with the host. GTK also creates roleless and cursor surfaces which never
 * publish a frame: keep their guest-only metadata separate from frame slots. */
enum { DAX_SLOTS = 8, NSURF = 2 * DAX_SLOTS };
static struct shared_surface {
    struct wl_resource *s, *xd, *top, *popup, *buf, *cb, *submitted_cb;
    struct wl_listener gone;
    /* shared-popup uses top + parent_id for a popup; the legacy wire uses popup + parent. */
    unsigned id, seq, serial, parent_id;
    int popup_x, popup_y, popup_w, popup_h, dismissed;
    int scale, pending_scale, attached, configured, busy, mapped_w, mapped_h;
    int resize_w, resize_h;
    int geometry[4], pending_geometry[4];
    struct shared_surface *parent, *sub_parent;
    struct wl_resource *sub;
    int sub_role, x, y, next_x, next_y, sub_w, sub_h, visible_scale;
    unsigned char *cached, *visible;
    unsigned char *base;
    int base_w, base_h, repaint, deferred, deferred_scale, frame_scale;
    struct wl_resource *deferred_cb;
    int cached_w, cached_h, dirty;

    int64_t work_x, work_y;
    int work_w, work_h; /* parent-content points, Y down; zero width disables */
    int geom_x, geom_y, geom_w, geom_h, input_x, input_y;
    int cursor_role, xdg_role, close_pending;
    int keyboard_grab, frame_slot; /* one-based, zero until first frame */
    uint32_t grab_serial, button_serial;
    int move_press;
    /* Toplevel focus domain: recent delivered key and pointer-press serials. */
    uint32_t input_serial[16];
    unsigned input_cursor;
} windows[NSURF];
static unsigned next_id, session_base;
__attribute__((format(printf, 1, 2)))
static void shared_write(const char *format, ...) {
    if (host_lost) return;
    va_list args;
    va_start(args, format);
    int written = vprintf(format, args);
    va_end(args);
    if (written < 0 || fflush(stdout) == EOF) lose_host();
}
static void shared_event(const char *kind, unsigned id) {
    shared_write("%s %u\n", kind, id);
}
static struct wl_list devices;
static struct shared_surface *pointer_focus, *key_focus;
static int pressed, right_down, swallow_release; /* swallow_release is an evdev button */
static struct shared_surface *grab, *trigger;
static uint32_t trigger_serial;
#include <linux/input-event-codes.h>
static unsigned char held_keys[KEY_CNT];
/* BTN_MOUSE .. BTN_JOYSTICK-1; left and right also have legacy wire forms. */
static uint32_t extra_down;
static struct xkb_keymap *seat_keymap;
static struct xkb_state *seat_state;
static void init_keymap(void) {
    if (seat_state) return;
    struct xkb_context *ctx=xkb_context_new(XKB_CONTEXT_NO_FLAGS);
    /* Unspecified fields honor XKB_DEFAULT_{LAYOUT,VARIANT,OPTIONS,...}. */
    struct xkb_rule_names names={.rules="evdev"};
    seat_keymap=ctx ? xkb_keymap_new_from_names(ctx,&names,0) : NULL;
    seat_state=seat_keymap ? xkb_state_new(seat_keymap) : NULL;
    if (!seat_state) fail("GTK evdev keymap/state");
    xkb_context_unref(ctx);
}
static void send_modifiers(struct wl_resource *r,uint32_t serial) {
    wl_keyboard_send_modifiers(r,serial,xkb_state_serialize_mods(seat_state,XKB_STATE_MODS_DEPRESSED),
        xkb_state_serialize_mods(seat_state,XKB_STATE_MODS_LATCHED),
        xkb_state_serialize_mods(seat_state,XKB_STATE_MODS_LOCKED),
        xkb_state_serialize_layout(seat_state,XKB_STATE_LAYOUT_EFFECTIVE));
}
static void device_gone(struct wl_resource *r) { wl_list_remove(wl_resource_get_link(r)); }
static const struct wl_surface_interface shared_ops;
static void set_cursor(struct wl_client *c,struct wl_resource *r,uint32_t serial,struct wl_resource *s,int32_t x,int32_t y) {
    (void)c;(void)serial;(void)x;(void)y;
    if (!s) return;
    /* Record the lifetime role only. There is no host cursor image or hotspot update. */
    struct shared_surface *p=wl_resource_instance_of(s,&wl_surface_interface,&shared_ops) ? wl_resource_get_user_data(s) : NULL;
    if (!p || p->xd || p->xdg_role || p->sub_role) {
        wl_resource_post_error(r,WL_POINTER_ERROR_ROLE,"surface already has an incompatible role");
        return;
    }
    p->cursor_role=1;
}
static const char seat_map[] =
    "xkb_keymap { xkb_keycodes { minimum=8; maximum=255; <AC01>=38; <LFSH>=50; };"
    "xkb_types { type \"TWO_LEVEL\" { modifiers=Shift; map[Shift]=Level2; }; };"
    "xkb_compatibility { interpret Shift_L { action=SetMods(modifiers=Shift); }; };"
    "xkb_symbols { key <AC01> { type=\"TWO_LEVEL\", [ a, A ] }; key <LFSH> { [ Shift_L ] }; modifier_map Shift { <LFSH> }; }; };";
static void device(struct wl_client *c, uint32_t id, int version, const struct wl_interface *type) {
    struct wl_resource *r=wl_resource_create(c,type,version,id);
    if (!r) { wl_client_post_no_memory(c); return; }
    static const struct wl_pointer_interface ops={.set_cursor=set_cursor,.release=destroy_resource};
    static const struct wl_keyboard_interface keys={.release=destroy_resource};
    wl_resource_set_implementation(r,type==&wl_pointer_interface?(const void *)&ops:&keys,NULL,device_gone);
    wl_list_insert(&devices,wl_resource_get_link(r));
    if(type==&wl_keyboard_interface) {
        int fd=memfd_create("m2-xkb",MFD_CLOEXEC);
        if(fd<0) sysfail("keymap fd");
        const char *map=seat_map;
        char *text=NULL;
        if (keyboard_mode) {
            init_keymap();
            text=xkb_keymap_get_as_string(seat_keymap,XKB_KEYMAP_FORMAT_TEXT_V1);
            if (!text) fail("serialize GTK evdev keymap");
            map=text;
        } else if (!popup_mode && getenv("XKB_CONFIG_ROOT")) {
            struct xkb_context *ctx=xkb_context_new(0);
            struct xkb_rule_names names={.layout="us"};
            struct xkb_keymap *us=ctx?xkb_keymap_new_from_names(ctx,&names,0):NULL;
            if(!us || !(text=xkb_keymap_get_as_string(us,XKB_KEYMAP_FORMAT_TEXT_V1))) fail("compile US keymap");
            xkb_keymap_unref(us); xkb_context_unref(ctx);
            map=text;
        }
        size_t size=strlen(map)+1;
        if(write(fd,map,size)!=(ssize_t)size) sysfail("write keymap");
        wl_keyboard_send_keymap(r,WL_KEYBOARD_KEYMAP_FORMAT_XKB_V1,fd,size);
        if (version>=WL_KEYBOARD_REPEAT_INFO_SINCE_VERSION) wl_keyboard_send_repeat_info(r,25,600);
        free(text); close(fd);
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
/* Signed 1/120 logical point -> wl_fixed_t (24.8); saturate before narrowing. */
static wl_fixed_t scroll_fixed(int delta) {
    int64_t n=(int64_t)delta*256;
    n=(n+(delta<0 ? -60 : 60))/120;
    return n>INT32_MAX ? INT32_MAX : n<INT32_MIN ? INT32_MIN : (wl_fixed_t)n;
}
/* Resolve by lifetime id, never by a reusable slot. */
static struct shared_surface *parent_of(struct shared_surface *p) {
    if (p->parent_id) for (int i=0;i<NSURF;i++)
        if (windows[i].id==p->parent_id) return &windows[i];
    return NULL;
}
static struct shared_surface *input_domain(struct shared_surface *p) {
    while (p && p->parent_id) p=parent_of(p);
    return p && p->s && p->top ? p : NULL;
}
static void clear_input_serials(struct shared_surface *p) {
    memset(p->input_serial,0,sizeof p->input_serial);
    p->input_cursor=0;
}
static void deliver(struct shared_surface *p,char op,int x,int y) {
    if (host_lost || !p || !p->s) return;
    uint32_t serial=wl_display_next_serial(display), t=monotonic_ns()/1000000;
    int delivered_input=0;
    enum xkb_state_component changed=0;
    if (keyboard_mode && (op=='K' || op=='F')) {
        init_keymap();
        if (op=='K') changed=xkb_state_update_key(seat_state,x+8,y ? XKB_KEY_DOWN : XKB_KEY_UP);
    }
    if (op=='M' || op=='E') { x+=p->input_x; y+=p->input_y; }
    struct wl_resource *r;
    wl_resource_for_each(r,&devices) {
        if(wl_resource_get_client(r)!=wl_resource_get_client(p->s)) continue;
        if(!strcmp(wl_resource_get_class(r),"wl_pointer")) {
            if(op=='E') wl_pointer_send_enter(r,serial,p->s,wl_fixed_from_int(x),wl_fixed_from_int(y));
            if(op=='V') wl_pointer_send_leave(r,serial,p->s);
            if(op=='M') wl_pointer_send_motion(r,t,wl_fixed_from_int(x),wl_fixed_from_int(y));
            if(op=='W') wl_pointer_send_axis(r,t,x,wl_fixed_from_int(y));
            if(op=='P') {
                wl_pointer_send_button(r,serial,t,x,y);
                if (y) delivered_input=1;
                fprintf(stderr,"GTK_POINTER_BUTTON %u %d %d\n",p->id,x,y);
            }
            if(op=='S') {
                if (wl_resource_get_version(r)>=WL_POINTER_AXIS_SOURCE_SINCE_VERSION)
                    wl_pointer_send_axis_source(r,WL_POINTER_AXIS_SOURCE_CONTINUOUS);
                if(x) wl_pointer_send_axis(r,t,WL_POINTER_AXIS_HORIZONTAL_SCROLL,scroll_fixed(x));
                if(y) wl_pointer_send_axis(r,t,WL_POINTER_AXIS_VERTICAL_SCROLL,scroll_fixed(y));
                fprintf(stderr,"GTK_POINTER_SCROLL %u %d %d\n",p->id,x,y);
            }
            if(op=='B') {
                wl_pointer_send_button(r,serial,t,BTN_LEFT,x);
                if (x) { p->button_serial=serial; delivered_input=1;
                    if (!popup_mode) { trigger=p; trigger_serial=serial; }
                }
                else p->move_press=0;
            }
            if(op=='D' || op=='U' || op=='Q') {
                wl_pointer_send_button(r,serial,t,BTN_RIGHT,op!='U');
                if(op!='U') { trigger=p; trigger_serial=serial; delivered_input=1; }
            }
            if (wl_resource_get_version(r)>=WL_POINTER_FRAME_SINCE_VERSION && strchr("EVMBPDSUQ",op))
                wl_pointer_send_frame(r);
        } else {
            if(op=='F') { struct wl_array keys={0}; wl_keyboard_send_enter(r,serial,p->s,&keys);
                            if (keyboard_mode) send_modifiers(r,serial); else wl_keyboard_send_modifiers(r,serial,0,0,0,0); }
            if(op=='L') wl_keyboard_send_leave(r,serial,p->s);
            if(op=='K') {
                wl_keyboard_send_key(r,serial,t,x,y);
                delivered_input=1;
                if (keyboard_mode) fprintf(stderr,"GTK_KEY_INPUT %u %d %d\n",p->id,x,y);
                if (keyboard_mode && changed) send_modifiers(r,serial);
                if(!keyboard_mode && x==42) wl_keyboard_send_modifiers(r,serial,y,0,0,0);
            }
        }
    }
    if (keyboard_mode && delivered_input) {
        struct shared_surface *domain=input_domain(p);
        if (domain && domain==input_domain(key_focus)) {
            domain->input_serial[domain->input_cursor++ % (sizeof domain->input_serial/sizeof domain->input_serial[0])]=serial;
            if (op=='K') fprintf(stderr,"GTK_KEY_SERIAL surface=%u key=%d edge=%d serial=%u\n",p->id,x,y,serial);
        }
    }
}
static void release_keys(struct shared_surface *p) {
    for(int code=1;code<KEY_CNT;code++) if(held_keys[code]) { deliver(p,'K',code,0); held_keys[code]=0; }
}
static void release_buttons(void) {
    if (pressed) deliver(pointer_focus,'B',0,0);
    if (right_down) deliver(pointer_focus,'U',0,0);
    for (int code=BTN_MIDDLE;code<BTN_JOYSTICK;code++)
        if (extra_down & (1u<<(code-BTN_MOUSE))) deliver(pointer_focus,'P',code,0);
    pressed=right_down=0;
    extra_down=0;
}
static void focus_keyboard(struct shared_surface *next) {
    if (key_focus==next) return;
    if (keyboard_mode) fprintf(stderr,"GTK_KEY_FOCUS %u -> %u\n",key_focus?key_focus->id:0,next?next->id:0);
    if (keyboard_mode) release_buttons();
    release_keys(key_focus);
    deliver(key_focus,'L',0,0);
    struct shared_surface *domain=input_domain(key_focus);
    if (domain && domain!=input_domain(next)) clear_input_serials(domain);
    key_focus=next;
    deliver(next,'F',0,0);
}
static struct shared_surface *mapped_parent(struct shared_surface *p) {
    while ((p=parent_of(p)))
        if (p->s && p->top && p->mapped_w && !p->dismissed) return p;
    return NULL;
}
/* GTK hover may reuse the most recent key or pointer press even after the
 * surface that received it is gone. Motion and pointer enter don't qualify. */
static int branch_grab_serial(struct shared_surface *p,uint32_t serial) {
    struct shared_surface *domain=input_domain(p);
    if (domain && domain==input_domain(key_focus))
        for (unsigned i=0;i<sizeof domain->input_serial/sizeof domain->input_serial[0];i++)
            if (domain->input_serial[i]==serial) return 1;
    for (; p && p->s && p->top && p->grab_serial && !p->dismissed; p=parent_of(p))
        if (p->grab_serial==serial) return 1;
    return 0;
}
static void end_grab(struct shared_surface *p) {
    if (grab==p) {
        /* Explicit grabs, unlike keyboard focus, can precede the first buffer. */
        for (grab=parent_of(p); grab && grab->parent_id; grab=parent_of(grab))
            if (grab->s && grab->top && grab->grab_serial && !grab->dismissed) break;
        if (grab && !grab->parent_id) grab=NULL;
    }
    if (p->keyboard_grab && key_focus==p) focus_keyboard(mapped_parent(p));
    p->grab_serial=p->button_serial=0;
    p->keyboard_grab=0;
    if (!p->parent_id) clear_input_serials(p);
}
static void blur(struct shared_surface *p) {
    if (!popup_mode && grab==p) grab=NULL;
    if(trigger==p) { trigger=NULL; trigger_serial=0; }
    if(pointer_focus==p) { release_buttons(); deliver(p,'V',0,0); pointer_focus=NULL; }
    if(key_focus==p) focus_keyboard(NULL);
}
static void cancel_repaint(struct shared_surface *p);
static void dismiss_children(struct shared_surface *parent) {
    for (int i=0; i<NSURF; i++) {
        struct shared_surface *p = &windows[i];
        if (p->parent != parent) continue;
        p->parent = NULL;
        p->dismissed = 1;
        blur(p);
        if (!host_lost) {
            wl_resource_post_event(p->popup, 1);
            if (p->mapped_w) shared_event("CLOSED", p->id);
        }
        p->mapped_w = p->mapped_h = 0;
        cancel_repaint(p);
        if (p->cb) wl_resource_destroy(p->cb);
        if (p->submitted_cb) wl_resource_destroy(p->submitted_cb);
    }
}
struct positioner { int w,h,x,y,rw,rh,dx,dy; unsigned anchor,gravity; };
static int legacy_positioner_dispatch(const void *iface, void *target, uint32_t op, const struct wl_message *msg, union wl_argument *a) {
    (void)iface; (void)msg;
    struct wl_resource *r = target;
    struct positioner *q = wl_resource_get_user_data(r);
    switch (op) {
    case 0: wl_resource_destroy(r); return 0;
    case 1: if (a[0].i<1 || a[1].i<1) break; q->w=a[0].i; q->h=a[1].i; return 0;
    case 2: if (a[2].i<1 || a[3].i<1) break;
        q->x=a[0].i; q->y=a[1].i; q->rw=a[2].i; q->rh=a[3].i; return 0;
    case 3: if (a[0].u>8) break; q->anchor=a[0].u; return 0;
    case 4: if (a[0].u>8) break; q->gravity=a[0].u; return 0;
    case 5: if (a[0].u & ~63u) break; return 0;
    case 6: q->dx=a[0].i; q->dy=a[1].i; return 0;
    }
    wl_resource_post_error(r,0,"invalid positioner argument"); return 0;
}
static void positioner_free(struct wl_resource *r) { free(wl_resource_get_user_data(r)); }
static int placement(struct shared_surface *p, struct shared_surface *parent, const struct positioner *q) {
    static const int xdir[]={0,0,0,-1,1,-1,-1,1,1}, ydir[]={0,-1,1,0,0,-1,1,-1,1};
    int pw=parent->geometry[2] ?: parent->mapped_w, ph=parent->geometry[3] ?: parent->mapped_h;
    if (!q->w || !q->h || !q->rw || !q->rh || q->x<0 || q->y<0 || q->rw>pw || q->rh>ph || q->x>pw-q->rw || q->y>ph-q->rh || q->w>width || q->h>height) return 0;
    int64_t x=(int64_t)q->x + (1+xdir[q->anchor])*q->rw/2 - (1-xdir[q->gravity])*q->w/2 + q->dx;
    int64_t y=(int64_t)q->y + (1+ydir[q->anchor])*q->rh/2 - (1-ydir[q->gravity])*q->h/2 + q->dy;
    if (x>pw || y>ph || x < -q->w || y < -q->h) return 0;
    p->popup_x=x; p->popup_y=y; p->popup_w=q->w; p->popup_h=q->h;
    p->parent=parent;
    return 1;
}
static void shared_configure(struct shared_surface *p, int w, int h) {
    struct wl_array states = {0};
    p->serial = wl_display_next_serial(display);
    if (p->popup) wl_resource_post_event(p->popup, 0, p->popup_x, p->popup_y, p->popup_w, p->popup_h);
    else if (p->parent_id)
        wl_resource_post_event(p->top, 0, p->popup_x, p->popup_y, p->popup_w, p->popup_h);
    else wl_resource_post_event(p->top, 0, w, h, &states);
    wl_resource_post_event(p->xd, 0, p->serial);
}
static void shared_resize(struct shared_surface *p) {
    /* A final frame ACK may outlive the client and its XDG resources. */
    if (!p->s || !p->top || !p->xd || p->busy || p->serial || !p->resize_w) return;
    if (getenv("M2_GTK_RESIZE_TRACE"))
        fprintf(stderr, "GTK_BURST configure %u %u %d %d\n", p->id, p->seq, p->resize_w, p->resize_h);
    shared_configure(p, p->resize_w, p->resize_h);
    p->resize_w = p->resize_h = 0;
}
/* grab points to the innermost explicitly grabbed popup. */
static struct shared_surface *popup_child(unsigned id) {
    for (int i=0;i<NSURF;i++)
        if (windows[i].parent_id==id && (windows[i].top || windows[i].close_pending)) return &windows[i];
    return NULL;
}
static void dismiss_branch(struct shared_surface *p, unsigned outside) {
    for (int i=0;i<NSURF;i++)
        if (windows[i].parent_id==p->id && (windows[i].top || windows[i].close_pending))
            dismiss_branch(&windows[i],outside);
    if (!p->top || p->dismissed) return;
    p->dismissed=1;
    wl_resource_post_event(p->top,1);
    if (outside) fprintf(stderr,"GTK_GRAB popup_done %u outside %u\n",p->id,outside);
}
static void seat_input(unsigned id,char op,int x,int y) {
    /* Normalize legacy aliases before routing, including outside-grab releases.
     * Q is a right press at the existing pointer focus, unlike D which carries x/y. */
    /* B edge button in the legacy seat; B edge press_id in keyboard mode. */
    if (!keyboard_mode && op=='B') {
        if ((x!=0 && x!=1) || (y!=0 && y!=1)) return;
        if (y) op=x?'Q':'U';
    }
    if (keyboard_mode && op=='P') {
        if (x<BTN_MOUSE || x>=BTN_JOYSTICK || (y!=0 && y!=1)) return;
        if (x==BTN_LEFT) { op='B'; x=y; y=0; }
        else if (x==BTN_RIGHT) op=y?'Q':'U';
    }
    int button=op=='B' ? BTN_LEFT : strchr("DQU",op) ? BTN_RIGHT : op=='P' ? x : 0;
    int down=op=='B' ? x : op=='P' ? y : op=='D' || op=='Q';
    if (swallow_release && button && (!keyboard_mode || button==swallow_release)) {
        if (button==swallow_release && !down) {
            swallow_release=0;
            fprintf(stderr,"GTK_GRAB swallowed up %u\n",id);
        }
        return;
    }
    /* Complete an implicit button grab even if the release is tagged with
     * another host surface. An unmatched up is never delivered. */
    if (keyboard_mode && pointer_focus && button && !down &&
        ((button==BTN_LEFT && pressed) || (button==BTN_RIGHT && right_down) ||
         (button>=BTN_MIDDLE && button<BTN_JOYSTICK && (extra_down & (1u<<(button-BTN_MOUSE))))))
        id=pointer_focus->id;
    struct shared_surface *root=grab;
    int inside=0;
    for (struct shared_surface *q=grab; q && q->parent_id; q=parent_of(q)) {
        root=q;
        if (q->id==id) inside=1;
    }
    int domain=root && (inside || id==root->parent_id);
    /* A blur on the owning host window ends the entire popup focus domain.
     * Do not restore focus while the resulting popup destroys are in flight. */
    if (keyboard_mode && domain && op=='L') {
        swallow_release=0;
        dismiss_branch(root,0);
        focus_keyboard(NULL);
        if (pointer_focus) blur(pointer_focus);
        return;
    }
    if (keyboard_mode && domain && op=='K' && key_focus && key_focus->keyboard_grab) {
        inside=1; id=key_focus->id;
    }
    if (!popup_mode && grab && grab->id!=id && !strchr("RCL",op)) {
        if (button && down && grab->mapped_w) dismiss_children(grab->parent);
        return;
    }
    if (popup_mode && grab && !inside &&
        (op=='M' || op=='B' || op=='Q' || op=='D' || op=='L' || (tree_mode && op=='K') ||
         (keyboard_mode && (op=='P' || op=='Q' || op=='S')))) {
        if (button && down==1 && (op=='B' || op=='Q' || (tree_mode && op=='D') || keyboard_mode)) {
            if (!swallow_release) swallow_release=button;
            dismiss_branch(root,id);
        }
        return;
    }
    if (op=='U' && right_down && (menu_mode || (pointer_focus && pointer_focus->id==id))) {
        deliver(pointer_focus,'U',0,0); right_down=0; return;
    }
    for(int i=0;i<NSURF;i++) {
        struct shared_surface *p=&windows[i];
        if(p->id!=id || !p->s || (!p->top && !p->popup) || !p->mapped_w) continue;
        if (p->popup && (op=='C' || op=='R')) return;
        if (p->dismissed) continue;
        if(keyboard_mode && op=='F' && !grab && !p->parent_id) focus_keyboard(p);
        else if(op=='C') {
            if (p->parent_id) dismiss_branch(p,0);
            else {
                if (tree_mode && root && root->parent_id==id) dismiss_branch(root,0);
                wl_resource_post_event(p->top,1);
            }
        }
        else if(op=='R' && !p->parent_id && x>0 && y>0) {
            p->resize_w = x <= width/p->scale ? x : width/p->scale;
            p->resize_h = y <= height/p->scale ? y : height/p->scale;
            if (getenv("M2_GTK_RESIZE_TRACE"))
                fprintf(stderr, "GTK_BURST resize %u %u %d %d busy=%d\n", p->id, p->seq, x, y, p->busy);
            if (p->busy && !getenv("XKB_CONFIG_ROOT"))
                fprintf(stderr,"M2_RESIZE_PENDING %u %d %d\n",id,p->resize_w,p->resize_h);
            shared_resize(p);
        } else if((op=='M' || (menu_mode && op=='D' && !pressed && !right_down)) && x>=0 && y>=0 && x<p->mapped_w && y<p->mapped_h) {
            if(pointer_focus!=p) {
                if(pressed || right_down || extra_down) return;
                deliver(pointer_focus,'V',0,0); pointer_focus=p; deliver(p,'E',x,y);
            }
            deliver(p,'M',x,y);
            if(op=='D') { if (keyboard_mode && !grab) focus_keyboard(p); right_down=1; deliver(p,'D',x,y); }
        } else if(op=='B' && pointer_focus==p && (x==0 || x==1) && x!=pressed) {
            if(x && (!keyboard_mode || !grab)) focus_keyboard(p);
            if (x) { trigger=NULL; p->button_serial=0; }
            /* y carries the host press ID so a delayed move cannot start on a later press. */
            p->move_press=keyboard_mode && x ? y : 0;
            pressed=x; deliver(p,op,x,0);
        } else if(op=='Q' && pointer_focus==p && !right_down) {
            if (!popup_mode || !grab) focus_keyboard(p);
            right_down=1;
            deliver(p,'Q',0,0);
        } else if(keyboard_mode && op=='P' && pointer_focus==p) {
            uint32_t mask=1u<<(x-BTN_MOUSE);
            if (!!(extra_down & mask)!=y) {
                if (y && !grab) focus_keyboard(p);
                extra_down^=mask;
                deliver(p,'P',x,y);
            }
        } else if(!keyboard_mode && op=='W' && pointer_focus==p && (x==0 || x==1) && y>=-120 && y<=120) deliver(p,op,x,y);
        else if(keyboard_mode && op=='S' && pointer_focus==p && (x || y)) deliver(p,'S',x,y);
        else if(op=='K' && key_focus==p && x>0 && x<(keyboard_mode ? KEY_CNT : 128) && (y==0 || y==1) && held_keys[x]!=y) { held_keys[x]=y; deliver(p,op,x,y); }
        else if(op=='L') {
            if (keyboard_mode) swallow_release=0;
            blur(p);
        }
    }
}
static void sub_clear(struct shared_surface *p) {
    if (p->sub_parent && p->visible) p->sub_parent->repaint=1;
    free(p->cached); free(p->visible);
    p->cached = p->visible = NULL;
    p->dirty = p->sub_w = p->sub_h = 0;
    p->sub_parent = NULL;
}
static void sub_destroyed(struct wl_resource *r) {
    struct shared_surface *p = wl_resource_get_user_data(r);
    sub_clear(p);
    p->sub = NULL;
}
static void sub_position(struct wl_client *c, struct wl_resource *r, int32_t x, int32_t y) {
    (void)c;
    struct shared_surface *p = wl_resource_get_user_data(r);
    p->next_x = x; p->next_y = y;
}
static void sub_unsupported(struct wl_client *c, struct wl_resource *r) {
    (void)c;
    wl_resource_post_error(r, 0, "only synchronized subsurfaces supported");
}
static void sub_sync(struct wl_client *c, struct wl_resource *r) { (void)c; (void)r; }
static void sub_stack(struct wl_client *c, struct wl_resource *r, struct wl_resource *s) {
    (void)s;
    sub_unsupported(c,r);
}
static void get_sub(struct wl_client *c, struct wl_resource *r, uint32_t id,
                    struct wl_resource *child, struct wl_resource *parent) {
    struct shared_surface *p = wl_resource_get_user_data(child), *q = wl_resource_get_user_data(parent);
    if (p == q || p->xd || p->xdg_role || p->cursor_role || p->sub || !q->top || q->parent_id) {
        wl_resource_post_error(r, WL_SUBCOMPOSITOR_ERROR_BAD_SURFACE, "expected direct toplevel child");
        return;
    }
    static const struct wl_subsurface_interface ops = {
        .destroy=destroy_resource, .set_position=sub_position, .place_above=sub_stack,
        .place_below=sub_stack, .set_sync=sub_sync, .set_desync=sub_unsupported
    };
    p->sub = wl_resource_create(c,&wl_subsurface_interface,1,id);
    if (!p->sub) { wl_client_post_no_memory(c); return; }
    p->sub_role=1; p->sub_parent=q;
    p->next_x=p->next_y=0;
    wl_resource_set_implementation(p->sub,&ops,p,sub_destroyed);
}
static void bind_sub(struct wl_client *c, void *data, uint32_t v, uint32_t id) {
    (void)data;
    static const struct wl_subcompositor_interface ops={.destroy=destroy_resource,.get_subsurface=get_sub};
    struct wl_resource *r=wl_resource_create(c,&wl_subcompositor_interface,v,id);
    if (!r) { wl_client_post_no_memory(c); return; }
    wl_resource_set_implementation(r,&ops,NULL,NULL);
}
static void cancel_repaint(struct shared_surface *p) {
    p->repaint=p->deferred=0;
    if (p->deferred_cb) wl_resource_destroy(p->deferred_cb);
}
/* Disconnect may destroy role resources in arbitrary order. Keep the slot
 * until CLOSED has been published for all its children and its frame is ACKed. */
static void publish_closed(struct shared_surface *p) {
    if (!p->close_pending || popup_child(p->id)) return;
    p->close_pending=0;
    if (!p->busy) p->frame_slot=0;
    shared_event("CLOSED",p->id);
    for (int i=0;i<NSURF;i++)
        if (windows[i].close_pending && windows[i].id==p->parent_id) publish_closed(&windows[i]);
}
static void shared_clear(struct wl_resource *r) {
    struct shared_surface *p = wl_resource_get_user_data(r);
    if (p->s == r || p->top == r) {
        p->work_w=0;
        end_grab(p);
        blur(p);
    }
    if (p->s == r || p->top == r || p->xd == r) {
        free(p->base); p->base=NULL;
        dismiss_children(p);
        for (int i=0;i<NSURF;i++) if (windows[i].sub_parent==p) sub_clear(&windows[i]);
        cancel_repaint(p);
        if (p->cb) wl_resource_destroy(p->cb);
        if (p->submitted_cb) wl_resource_destroy(p->submitted_cb);
    }
    if (p->s == r && p->sub_role) sub_clear(p);
    if (p->popup == r) {
        blur(p);
        if (!p->busy) p->frame_slot=0;
        free(p->base); p->base=NULL;
        cancel_repaint(p);
        if (p->mapped_w && !host_lost) shared_event("CLOSED",p->id);
        p->mapped_w = p->mapped_h = 0;
        p->parent = NULL;
        p->popup = NULL;
        if (p->cb) wl_resource_destroy(p->cb);
        if (p->submitted_cb) wl_resource_destroy(p->submitted_cb);
    }
    if (p->deferred_cb == r) p->deferred_cb = NULL;
    if (p->cb == r) p->cb = NULL;
    if (p->submitted_cb == r) p->submitted_cb = NULL;
    if (p->xd == r) p->xd = NULL;
    if (p->top == r) { p->top = NULL; p->close_pending=1; publish_closed(p); }
    if (p->s == r) {
        p->s = NULL;
        if (p->buf) { wl_list_remove(&p->gone.link); p->buf = NULL; }
        if (p->cursor_role && p->cb) wl_resource_destroy(p->cb);
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
static void sub_commit(struct shared_surface *p) {
    if (!p->attached) return;
    if (!p->sub_parent) {
        p->attached=0;
        if (p->buf) {
            wl_list_remove(&p->gone.link);
            wl_buffer_send_release(p->buf); p->buf=NULL;
        }
        return;
    }
    p->attached=0;
    unsigned char *copy=NULL;
    int w=0,h=0;
    if (p->buf) {
        struct wl_shm_buffer *b=wl_shm_buffer_get(p->buf);
        if (!b || wl_shm_buffer_get_format(b)!=WL_SHM_FORMAT_XRGB8888) goto invalid;
        w=wl_shm_buffer_get_width(b); h=wl_shm_buffer_get_height(b);
        int stride=wl_shm_buffer_get_stride(b);
        if (w<1 || h<1 || w>width || h>height || stride<w*4 || w%p->pending_scale || h%p->pending_scale) goto invalid;
        copy=malloc((size_t)w*h*4);
        if (!copy) { wl_resource_post_no_memory(p->s); return; }
        wl_shm_buffer_begin_access(b);
        const unsigned char *src=wl_shm_buffer_get_data(b);
        for (int y=0;y<h;y++) memcpy(copy+y*w*4,src+(size_t)y*stride,w*4);
        wl_shm_buffer_end_access(b);
        wl_list_remove(&p->gone.link);
        wl_buffer_send_release(p->buf); p->buf=NULL;
    }
    free(p->cached); p->cached=copy;
    p->cached_w=w; p->cached_h=h; p->scale=p->pending_scale; p->dirty=1;
    return;
invalid:
    wl_resource_post_error(p->s,0,"unsupported subsurface buffer");
}
static void sub_apply(struct shared_surface *parent) {
    for (int i=0;i<NSURF;i++) {
        struct shared_surface *p=&windows[i];
        if (p->sub_parent!=parent) continue;
        p->x=p->next_x; p->y=p->next_y;
        if (p->dirty) {
            free(p->visible); p->visible=p->cached; p->cached=NULL;
            p->sub_w=p->cached_w; p->sub_h=p->cached_h; p->visible_scale=p->scale; p->dirty=0;
        }
    }
}
static void sub_draw(struct shared_surface *parent, unsigned char *dst, int w, int h, int scale) {
    for (int i=0;i<NSURF;i++) {
        struct shared_surface *p=&windows[i];
        if (p->sub_parent!=parent || !p->visible) continue;
        int64_t ox=(int64_t)p->x*scale, oy=(int64_t)p->y*scale;
        for (int y=0;y<h;y++) {
            int64_t sy=(y-oy)*p->visible_scale/scale;
            if (y<oy || sy>=p->sub_h) continue;
            for (int x=0;x<w;x++) {
                int64_t sx=(x-ox)*p->visible_scale/scale;
                if (x<ox || sx>=p->sub_w) continue;
                unsigned char *d=dst+(y*w+x)*4;
                memcpy(d,p->visible+(sy*p->sub_w+sx)*4,3); d[3]=255;
            }
        }
    }
}
static void shared_publish(struct shared_surface *p, int scale, struct wl_resource *cb) {
    int w=p->base_w, h=p->base_h;
    unsigned slot=(unsigned)(p->frame_slot-1);
    unsigned char *dst=frame+slot*RANGE;
    if (!popup_mode) {
        memcpy(dst+PREFIX,p->base,(size_t)w*h*4);
        p->repaint=0;
        sub_draw(p,dst+PREFIX,w,h,scale);
    }
    mark_slot(dst, slot); atomic_thread_fence(memory_order_release);
    p->submitted_cb = cb;
    if (p->popup && !p->mapped_w) {
        shared_write("POPUP %u %u %d %d %d %d\n",p->id,p->parent->id,p->popup_x,p->popup_y,
               p->parent->geometry[0]-p->geometry[0],p->parent->geometry[1]-p->geometry[1]);
    }
    if (!p->mapped_w && p->keyboard_grab && p==grab) focus_keyboard(p);
    p->frame_scale=scale;
    p->mapped_w=w/scale; p->mapped_h=h/scale; p->busy=1;
    shared_write("PIXELS %u %u %u %d %d %d\n", p->id, ++p->seq, slot,w,h,scale);
}
static void shared_release_buffer(struct shared_surface *p) {
    wl_buffer_send_release(p->buf);
    wl_list_remove(&p->gone.link);
    p->buf=NULL;
}
static void shared_finish_callback(struct wl_resource *cb) {
    wl_callback_send_done(cb,(uint32_t)(monotonic_ns()/1000000));
    wl_resource_destroy(cb);
}
static void shared_commit(struct wl_client *c, struct wl_resource *r) {
    (void)c;
    struct shared_surface *p = wl_resource_get_user_data(r);
    if (p->sub_role) { sub_commit(p); return; }
    if (p->cursor_role) {
        /* Discard the cursor image locally; never allocate a host frame or await an ACK. */
        p->scale=p->pending_scale;
        if (p->attached && p->buf) shared_release_buffer(p);
        p->attached=0;
        if (p->cb) shared_finish_callback(p->cb);
        return;
    }
    if (!popup_mode && ((!p->top && !p->popup) || p->dismissed)) return;
    if (popup_mode && !p->top) goto invalid;
    memcpy(p->geometry, p->pending_geometry, sizeof p->geometry);
    p->scale = p->pending_scale;
    int w=p->base_w, h=p->base_h;
    if (!p->attached) {
        int changed=p->repaint || p->cb || (p->base && p->scale!=(p->deferred ? p->deferred_scale : p->frame_scale));
        for (int i=0;i<NSURF;i++) {
            struct shared_surface *q=&windows[i];
            if (q->sub_parent==p && (q->dirty || q->x!=q->next_x || q->y!=q->next_y)) changed=1;
        }
        if (!popup_mode && p->base && changed) {
            if (w%p->scale || h%p->scale || (p->deferred_cb && p->cb)) goto invalid;
            sub_apply(p);
            if (p->busy) {
                p->deferred=1;
                p->deferred_scale=p->scale;
                if (p->cb) { p->deferred_cb=p->cb; p->cb=NULL; }
            } else {
                shared_publish(p,p->scale,p->cb);
                p->cb=NULL;
            }
            return;
        }
        sub_apply(p);
        if (!p->configured && !p->serial) shared_configure(p, 0, 0);
        return;
    }
    p->attached = 0;
    if (!p->buf) {
        free(p->base); p->base=NULL; cancel_repaint(p);
        sub_apply(p);
        if (p->mapped_w) {
            dismiss_children(p);
            end_grab(p);
            blur(p);
            if (p->popup) {
                p->dismissed = 1;
                p->parent = NULL;
                wl_resource_post_event(p->popup,1);
            }
            p->mapped_w = p->mapped_h = p->work_w = 0;
            p->resize_w = p->resize_h = 0;
            p->serial = p->configured = 0;
            if (p->cb) wl_resource_destroy(p->cb);
            if (p->submitted_cb) wl_resource_destroy(p->submitted_cb);
            shared_event(p->popup ? "CLOSED" : "UNMAP", p->id);
        } else if (!p->configured && !p->serial) shared_configure(p, 0, 0);
        return;
    }
    struct wl_shm_buffer *b = wl_shm_buffer_get(p->buf);
    struct dma_plane *dma = dma_buffer(p->buf);
    if (!p->configured || p->busy || (!b && !dma)) goto invalid;
    w = dma ? dma->w : wl_shm_buffer_get_width(b); h = dma ? dma->h : wl_shm_buffer_get_height(b);
    int64_t stride = dma ? (int64_t)dma->stride : wl_shm_buffer_get_stride(b);
    unsigned format = dma ? WL_SHM_FORMAT_XRGB8888 : wl_shm_buffer_get_format(b);
    if ((format != WL_SHM_FORMAT_XRGB8888 && format != WL_SHM_FORMAT_ARGB8888) || w%p->scale || h%p->scale || w<1 || h<1 || w>width || h>height || stride<w*4) goto invalid;
    if (p->geometry[2] && (p->geometry[0]<0 || p->geometry[1]<0 ||
        p->geometry[2]>w/p->scale || p->geometry[3]>h/p->scale ||
        p->geometry[0]>w/p->scale-p->geometry[2] || p->geometry[1]>h/p->scale-p->geometry[3])) goto invalid;
    if (p->popup && ((p->geometry[2] ?: w/p->scale)!=p->popup_w || (p->geometry[3] ?: h/p->scale)!=p->popup_h)) goto invalid;
    int crop_x=0, crop_y=0;
    if (menu_mode && p->parent_id && p->geom_w) {
        if (p->geom_w!=p->popup_w || p->geom_h!=p->popup_h ||
            p->geom_x<0 || p->geom_x>w/p->scale-p->geom_w ||
            p->geom_y<0 || p->geom_y>h/p->scale-p->geom_h) goto invalid;
        p->input_x=p->geom_x; p->input_y=p->geom_y;
        crop_x=p->geom_x*p->scale; crop_y=p->geom_y*p->scale;
        w=p->geom_w*p->scale; h=p->geom_h*p->scale;
    }
    if (p->parent_id && (w/p->scale != p->popup_w || h/p->scale != p->popup_h)) goto invalid;
    /* Legacy sessions reserve a DAX slot by surface index across reconnects. */
    if (!popup_mode) p->frame_slot=(int)(p-windows)+1;
    if (!p->frame_slot) {
        unsigned used=0;
        for (int i=0;i<NSURF;i++) {
            struct shared_surface *q=&windows[i];
            if (q->frame_slot) used |= 1u<<(q->frame_slot-1);
        }
        for (int i=0;i<DAX_SLOTS;i++) if (!(used & (1u<<i))) { p->frame_slot=i+1; break; }
        if (!p->frame_slot) { wl_resource_post_error(r,0,"shared frame slots exhausted"); return; }
    }
    unsigned slot=(unsigned)(p->frame_slot-1);
    /* Only the legacy subcompositor needs a retained, uncomposited frame. */
    unsigned char *pixels=frame+slot*RANGE+PREFIX;
    if (!popup_mode) {
        pixels=realloc(p->base,(size_t)w*h*4);
        if (!pixels) { wl_resource_post_no_memory(r); return; }
        p->base=pixels;
    }
    p->base_w=w; p->base_h=h;
    const unsigned char *src;
    if (dma) {
        if (dma_sync(dma,DMA_BUF_SYNC_START)<0) goto sync_failed;
        src = (const unsigned char *)dma->map + dma->offset;
    } else {
        wl_shm_buffer_begin_access(b);
        src = wl_shm_buffer_get_data(b);
    }
    for (int y=0; y<h; y++) {
        unsigned char *row=pixels+y*w*4;
        memcpy(row,src+(size_t)(crop_y+y)*stride+crop_x*4,w*4);
        /* XRGB's unused byte becomes alpha in the AppKit BGRA image. */
        if (dma) for (int x=0; x<w; x++) row[x*4+3]=255;
    }
    if (dma) {
        if (dma_sync(dma,DMA_BUF_SYNC_END)<0) goto sync_failed;
    } else wl_shm_buffer_end_access(b);
    shared_release_buffer(p);
    if (dma) fprintf(stderr,"M2_DMABUF DAX_RELEASE surface=%u seq=%u slot=%u %dx%d SYNC_START_END_READ\n",p->id,p->seq+1,slot,w,h);
    sub_apply(p);
    shared_publish(p,p->scale,p->cb);
    p->cb=NULL;
    return;
sync_failed:
    wl_resource_post_error(r,0,"DMA-BUF CPU read synchronization failed"); return;
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
    for (int i=0;i<(popup_mode ? NSURF : DAX_SLOTS);i++) {
        struct shared_surface *p=&windows[i];
        if (p->s || p->sub || p->xd || p->top || p->popup || p->cb || p->submitted_cb || p->busy || p->close_pending) continue;
        *p=(struct shared_surface){.scale=1, .pending_scale=1, .id=++next_id, .gone.notify=shared_buffer_gone};
        p->s=wl_resource_create(c,&wl_surface_interface,wl_resource_get_version(r),id);
        if (!p->s) { wl_client_post_no_memory(c); return; }
        wl_resource_set_implementation(p->s,&shared_ops,p,shared_clear); return;
    }
    wl_resource_post_error(r,0,"surface capacity exceeded");
}
struct positioner_state { int w,h, x,y,rw,rh, dx,dy; unsigned anchor,gravity,adjust; };
static void positioner_gone(struct wl_resource *r) { free(wl_resource_get_user_data(r)); }
static int positioner_dispatch(const void *iface, void *target, uint32_t op, const struct wl_message *msg, union wl_argument *a) {
    (void)iface;
    struct wl_resource *r=target;
    struct positioner_state *pos=wl_resource_get_user_data(r);
    if (!op) wl_resource_destroy(r);
    else if (op==1 && a[0].i>0 && a[1].i>0) { pos->w=a[0].i; pos->h=a[1].i; }
    else if (op==2 && a[2].i>0 && a[3].i>0) { pos->x=a[0].i; pos->y=a[1].i; pos->rw=a[2].i; pos->rh=a[3].i; }
    else if (op==3 && a[0].u<=8) pos->anchor=a[0].u;
    else if (op==4 && a[0].u<=8) pos->gravity=a[0].u;
    else if (op==5 && !(a[0].u & ~(menu_mode ? 63u : 0u))) pos->adjust=a[0].u;
    else if (op==6) { pos->dx=a[0].i; pos->dy=a[1].i; }
    else wl_resource_post_error(r,0,"invalid or unsupported positioner request %s",msg->name);
    return 0;
}
/* xdg_positioner anchor/gravity order: none, top, bottom, left, right,
 * top_left, bottom_left, top_right, bottom_right. */
static int edge_offset(int size, int direction) {
    return direction<0 ? 0 : direction>0 ? size : size/2;
}
static int64_t popup_axis(int origin, int span, int anchor, int size, int gravity, int offset) {
    return (int64_t)origin + edge_offset(span,anchor) - edge_offset(size,-gravity) + offset;
}
/* Per axis: keep a flip only if it fits, otherwise slide the original.
 * No resize: if larger than the work area, leave that axis unchanged. */
static int64_t constrain_axis(int64_t raw, int64_t flipped, int size, int64_t start, int span, int flip, int slide) {
    int64_t last=(int64_t)start+span-size;
    if (last<start || (raw>=start && raw<=last)) return raw;
    if (flip && flipped>=start && flipped<=last) return flipped;
    return slide ? (raw<start ? start : last) : raw;
}
static int place_popup(struct shared_surface *p, struct shared_surface *parent, const struct positioner_state *pos) {
    static const int horizontal[]={0,0,0,-1,1,-1,-1,1,1}, vertical[]={0,-1,1,0,0,-1,1,-1,1};
    if (!parent || !parent->top || parent->dismissed ||
        (parent->parent_id && (!tree_mode || parent!=grab || popup_child(parent->id)))) return 0;
    /* A grabbed popup's window geometry is fixed at placement, before its first buffer. */
    int pw=parent->parent_id ? parent->popup_w : parent->mapped_w;
    int ph=parent->parent_id ? parent->popup_h : parent->mapped_h;
    if (!pw || !pos->rw || !pos->w || pos->w>width || pos->h>height || pos->x<0 || pos->y<0 ||
        pos->rw>pw-pos->x || pos->rh>ph-pos->y) return 0;
    int ax=horizontal[pos->anchor], ay=vertical[pos->anchor], gx=horizontal[pos->gravity], gy=vertical[pos->gravity];
    int64_t raw_x=popup_axis(pos->x,pos->rw,ax,pos->w,gx,pos->dx), x=raw_x;
    int64_t raw_y=popup_axis(pos->y,pos->rh,ay,pos->h,gy,pos->dy), y=raw_y;
    if (parent->work_w) {
        /* Positioner size describes the visible geometry, not GTK's shadow buffer. */
        x=constrain_axis(x,popup_axis(pos->x,pos->rw,-ax,pos->w,-gx,pos->dx),pos->w,
                         parent->work_x,parent->work_w,pos->adjust & 4u,pos->adjust & 1u);
        y=constrain_axis(y,popup_axis(pos->y,pos->rh,-ay,pos->h,-gy,pos->dy),pos->h,
                         parent->work_y,parent->work_h,pos->adjust & 8u,pos->adjust & 2u);
        fprintf(stderr,"GTK_MENU_EDGE parent=%u popup=%u raw=%lld,%lld adjusted=%lld,%lld size=%d,%d work=%lld,%lld,%d,%d flags=%u\n",
                parent->id,p->id,(long long)raw_x,(long long)raw_y,(long long)x,(long long)y,pos->w,pos->h,
                (long long)parent->work_x,(long long)parent->work_y,parent->work_w,parent->work_h,pos->adjust);
    }
    if (x<INT32_MIN || x>INT32_MAX || y<INT32_MIN || y>INT32_MAX) return 0;
    /* Each positioner uses its immediate parent's window geometry origin. */
    p->work_x=parent->work_x-x; p->work_y=parent->work_y-y;
    p->work_w=parent->work_w; p->work_h=parent->work_h;
    p->parent_id=parent->id; p->popup_x=x; p->popup_y=y; p->popup_w=pos->w; p->popup_h=pos->h;
    return 1;
}
static int shared_dispatch(const void *iface, void *target, uint32_t op, const struct wl_message *msg, union wl_argument *a) {
    struct wl_resource *r=target;
    struct shared_surface *p=wl_resource_get_user_data(r);
    struct wl_client *c=wl_resource_get_client(r);
    if (!op) { wl_resource_destroy(r); return 0; }
    struct wl_resource **out;
    const struct wl_interface *type;
    if (!popup_mode && iface==&shell_base && op==1) {
        struct positioner *q=calloc(1,sizeof *q);
        struct wl_resource *pos=q?wl_resource_create(c,&shell_positioner,1,a[0].n):NULL;
        if (!pos) { free(q); wl_client_post_no_memory(c); return 0; }
        wl_resource_set_dispatcher(pos,legacy_positioner_dispatch,&shell_positioner,q,positioner_free);
        return 0;
    }
    if (popup_mode && iface==&shell_base && op==1) {
        struct positioner_state *pos=calloc(1,sizeof *pos);
        if (!pos) { wl_client_post_no_memory(c); return 0; }
        struct wl_resource *pr=wl_resource_create(c,&shell_positioner,1,a[0].n);
        if (!pr) { free(pos); wl_client_post_no_memory(c); return 0; }
        wl_resource_set_dispatcher(pr,positioner_dispatch,&shell_positioner,pos,positioner_gone);
        return 0;
    }
    if (iface==&shell_base && op==2) {
        struct wl_resource *s=(void*)a[1].o;
        p=wl_resource_get_user_data(s);
        if (!p || p->xd || p->cursor_role || p->sub_role) goto invalid;
        out=&p->xd; type=&shell_surface;
    } else if (iface==&shell_surface && op==1 && !p->top && !p->popup && !p->dismissed) {
        out=&p->top; type=&shell_top;
    } else if (!popup_mode && iface==&shell_surface && op==2 && !p->top && !p->popup && !p->dismissed && a[1].o) {
        struct shared_surface *parent=wl_resource_get_user_data((void *)a[1].o);
        if (parent==p || !parent->s || !parent->top || !parent->mapped_w || p->seq ||
            !placement(p,parent,wl_resource_get_user_data((void *)a[2].o))) goto invalid;
        out=&p->popup; type=&shell_popup;
    } else if (!popup_mode && iface==&shell_popup && op==1) {
        if (!p->parent || p->mapped_w || p->configured || p->serial || grab) goto invalid;
        if (trigger!=p->parent || a[1].u!=trigger_serial) {
            p->dismissed=1; p->parent=NULL; wl_resource_post_event(r,1); return 0;
        }
        trigger=NULL; grab=p; blur(p->parent);
        fprintf(stderr,"M2_MENU_GRAB %u\n",p->id);
        return 0;
    } else if (popup_mode && iface==&shell_surface && op==2 && !p->top && a[1].o &&
               place_popup(p,wl_resource_get_user_data((void *)a[1].o),wl_resource_get_user_data((void *)a[2].o))) {
        out=&p->top; type=&shell_popup;
    } else if (menu_mode && iface==&shell_popup && op==1 && !p->configured && !p->serial && !p->dismissed && a[1].u &&
               ((!grab && trigger && trigger->id==p->parent_id && trigger_serial==a[1].u) ||
                (tree_mode && grab && !grab->dismissed && grab->id==p->parent_id &&
                 (grab->button_serial==a[1].u || (trigger==grab && trigger_serial==a[1].u) || branch_grab_serial(grab,a[1].u))))) {
        /* One advertised seat; Wayland checks the argument's client and type. */
        if (tree_mode) fprintf(stderr,"GTK_GRAB %s begin %u parent %u serial %u\n",
                               grab ? "SUBMENU" : "ROOT",p->id,p->parent_id,a[1].u);
        p->keyboard_grab=keyboard_mode;
        p->grab_serial=a[1].u;
        grab=p;
        trigger=NULL;
        trigger_serial=0;
        if (!tree_mode) fprintf(stderr,"GTK_GRAB begin %u %u\n",p->id,a[1].u);
        return 0;
    } else if (iface==&shell_surface && op==4 && p->serial && p->serial==a[0].u) {
        p->serial=0; p->configured=1; shared_resize(p); return 0;
    } else if (iface==&shell_surface && op==3) {
            if (!popup_mode) {
                if (a[2].i<=0 || a[3].i<=0) goto invalid;
                for (int i=0;i<4;i++) p->pending_geometry[i]=a[i].i;
            } else if (menu_mode && p->parent_id) {
                if (a[2].i<=0 || a[3].i<=0) goto invalid;
                p->geom_x=a[0].i; p->geom_y=a[1].i; p->geom_w=a[2].i; p->geom_h=a[3].i;
            }
            return 0;
        }
    else if (iface==&shell_top && op==5) {
        if (keyboard_mode && !grab && pointer_focus==p && pressed && p->move_press>0 &&
            a[1].u && a[1].u==p->button_serial) {
            shared_write("MOVE %u %d\n",p->id,p->move_press);
            p->move_press=0;
        }
        return 0;
    } else if (iface==&shell_top && (op==2 || op==3 || op==7 || op==8 || (op==1 && !a[0].o))) return 0;
    else goto invalid;
    *out=wl_resource_create(c,type,1,a[0].n);
    if (!*out) { p->parent=NULL; wl_client_post_no_memory(c); return 0; }
    wl_resource_set_dispatcher(*out,shared_dispatch,type,p,shared_clear);
    if (type==&shell_top || type==&shell_popup) p->xdg_role=1;
    if (type==&shell_top) shared_event("OPEN",p->id);
    else if (popup_mode && type==&shell_popup)
        shared_write("POPUP %u %u %d %d %d %d\n",p->id,p->parent_id,p->popup_x,p->popup_y,p->popup_w,p->popup_h);
    return 0;
invalid:
    if (iface==&shell_popup && op==1)
        fprintf(stderr,"GTK_GRAB_REJECT popup=%u parent=%u grab=%u focus=%u serial=%u configured=%d pending=%u dismissed=%d\n",
                p->id,p->parent_id,grab?grab->id:0,key_focus?key_focus->id:0,a[1].u,p->configured,p->serial,p->dismissed);

    wl_resource_post_error(r,0,"invalid shared request %s",msg->name); return 0;
}
static void shared_reset(void) {
    int abandoned = 0;
    for (int i = 0; i < NSURF; ++i) {
        struct shared_surface *p = &windows[i];
        if (p->s || p->xd || p->top || p->popup || p->cb || p->submitted_cb || p->deferred_cb || p->sub || p->sub_parent || p->base || p->visible || p->cached || p->buf) fail("live Wayland resource after teardown");
        abandoned += p->busy;
        *p = (struct shared_surface){0};
    }
    if (!wl_list_empty(&devices) || grab || trigger || pointer_focus || key_focus || pressed || right_down || extra_down)
        fail("live seat state after teardown");
    for (size_t i = 0; i < sizeof held_keys; ++i)
        if (held_keys[i]) fail("held key after teardown");
    if (seat_state) { xkb_state_unref(seat_state); seat_state=NULL; }
    if (seat_keymap) { xkb_keymap_unref(seat_keymap); seat_keymap=NULL; }
    swallow_release=0;
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
    char op; int x=0,y=0;
    /* W <parent_sid> <x> <y> <w> <h>\n: mapped GTK parent, before menu input. */
    if (menu_mode && ack_line[0]=='W') {
        const char *s=ack_line+1;
        long long v[5];
        for (int i=0;i<5;i++) {
            if (*s++!=' ' || !((*s>='0' && *s<='9') || (i && *s=='-'))) fail("bad work area");
            char *next;
            errno=0; v[i]=strtoll(s,&next,10);
            if (next==s || errno || (i ? v[i]<INT32_MIN || v[i]>INT32_MAX : v[i]<=0 || v[i]>UINT32_MAX)) fail("bad work area number");
            s=next;
        }
        if (s!=ack_line+ack_len-1 || *s!='\n' || v[3]<=0 || v[4]<=0) fail("bad work area");
        id=(unsigned)v[0];
        if (stale_surface(id,"WORKAREA")) return;
        for (int i=0;i<NSURF;i++) {
            struct shared_surface *p=&windows[i];
            if (p->id!=id || !p->s || !p->top || p->parent_id || !p->mapped_w) continue;
            p->work_x=v[1]; p->work_y=v[2]; p->work_w=v[3]; p->work_h=v[4];
            return;
        }
        fail("work area requires mapped parent");
    }
    /* SeatView sends K <evdev> <0|1> and L 0; shared host prefixes I <sid>.
     * Bare F is an explicit keyboard-probe focus request, not an AppKit event.
     * P <evdev BTN_MOUSE code> <0|1> and S <dx120> <dy120> use pointer focus;
     * S is signed logical points times 120, positive right/down, not wheel clicks. */
    int fields=sscanf(ack_line,"I %u %c %d %d",&id,&op,&x,&y);
    if ((fields>=3 || (fields==2 && keyboard_mode && op=='F')) && ((op!='K' && op!='P' && op!='S') || fields==4)) {
        if (op!='Q' && op!='V' && !stale_surface(id, "INPUT")) seat_input(id,op,x,y);
        return;
    }
    if (!strcmp(ack_line,"STOP\n")) {
        for(int i=0;i<NSURF;i++) if(windows[i].s || windows[i].sub || windows[i].busy || windows[i].deferred) fail("STOP with live surface");
        wl_display_terminate(display); return;
    }
    if(sscanf(ack_line,"ACK %u %u%n",&id,&seq,&end)!=2 || strcmp(ack_line+end,"\n")) fail("bad shared ACK");
    if (stale_surface(id, "ACK")) return;
    for(int i=0;i<NSURF;i++) {
        struct shared_surface *p=&windows[i];
        if(p->id!=id || !p->busy || p->seq!=seq) continue;
        p->busy=0;
        if (!p->popup && !p->top && !p->close_pending) p->frame_slot=0;
        if (p->resize_w && getenv("M2_GTK_RESIZE_TRACE"))
            fprintf(stderr, "GTK_BURST release %u %u callback=%d\n", p->id, p->seq, p->submitted_cb != NULL);
        if (p->submitted_cb) shared_finish_callback(p->submitted_cb);
        if (p->deferred) {
            p->deferred=0;
            struct wl_resource *cb=p->deferred_cb;
            p->deferred_cb=NULL;
            shared_publish(p,p->deferred_scale,cb);
        }
        shared_resize(p);
        return;
    }
    fail("unknown shared ACK");
}
