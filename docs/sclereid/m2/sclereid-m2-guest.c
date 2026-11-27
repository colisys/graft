/* Single-surface Linux SHM fixture (private client or simple-shm toplevel). */
#define _GNU_SOURCE
#include <endian.h>
#include <errno.h>
#include <time.h>
#include <fcntl.h>
#include <poll.h>

#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <unistd.h>
#include <wayland-client.h>
#include <wayland-server.h>
#include "sclereid-m2-xdg.h"

#ifndef STATX_ATTR_DAX
#define STATX_ATTR_DAX 0x00200000
#endif

enum { PREFIX = 32, FPS = 60, MAX_SLOTS = 4 };
static int slots = 1, ticks = 3 * FPS, lane;
static int animate, width = 64, height = 48;
#define STRIDE (width * 4)
#define PIXELS (STRIDE * height)
#define RANGE ((PREFIX + PIXELS + 4095) & ~4095)

static void fail(const char *why) { fprintf(stderr, "%s\n", why); exit(1); }
static void sysfail(const char *what) { perror(what); exit(1); }

static struct wl_display *display;
static unsigned char *frame;
static struct wl_resource *pending;
static int surface_created, published;

static struct {
    struct wl_resource *buffer;
    struct wl_listener destroy;
    unsigned tick;
} held[MAX_SLOTS];
static int last_tick = -1;
static char ack_line[32];
static size_t ack_len;

enum { XDG_WIDTH = 640, XDG_HEIGHT = 480 };
static int xdg, configured, slot_busy, closing, disconnected;
static uint32_t configure_serial;
static struct wl_resource *surface, *role, *toplevel, *callback;
static int64_t monotonic_ns(void);

static void xdg_command(void) {
    if (ack_len == sizeof("XDG_CLOSE\n") - 1 && !memcmp(ack_line, "XDG_CLOSE\n", ack_len)) {
        if (!toplevel || closing) fail("no active XDG toplevel to close");
        closing = 1;
        wl_resource_post_event(toplevel, 1); /* xdg_toplevel.close */
        return;
    }
    char expected[sizeof ack_line];
    int n = snprintf(expected, sizeof expected, "XDG_ACK %d\n", published - 1);
    if (!slot_busy || (size_t)n != ack_len || memcmp(expected, ack_line, ack_len))
        fail("unexpected XDG ACK");
    slot_busy = 0;
    if (callback && !closing) {
        wl_callback_send_done(callback, (uint32_t)(monotonic_ns() / 1000000));
        wl_resource_destroy(callback);
    }
    if (disconnected) wl_display_terminate(display);
}

static void held_gone(struct wl_listener *listener, void *data) {
    (void)listener; (void)data;
    fail("occupied buffer destroyed before ACK");
}

static void acknowledge(void) {
    for (int i = 0; i < slots; ++i) {
        if (!held[i].buffer) continue;
        char expected[sizeof ack_line];
        int n = snprintf(expected, sizeof expected, "ACK %u %d\n", held[i].tick, i);
        if ((size_t)n != ack_len || memcmp(expected, ack_line, ack_len)) continue;
        wl_list_remove(&held[i].destroy.link);
        wl_buffer_send_release(held[i].buffer);
        wl_client_flush(wl_resource_get_client(held[i].buffer));
        held[i].buffer = NULL;
        return;
    }
    fail("unexpected ACK line");
}

static int host_ready(int fd, uint32_t mask, void *data) {
    (void)data;
    if (mask & (WL_EVENT_ERROR | WL_EVENT_HANGUP)) fail("host disconnected");
    char buf[256];
    ssize_t n = read(fd, buf, sizeof buf);
    if (n < 0 && (errno == EINTR || errno == EAGAIN)) return 0;
    if (n <= 0) fail("cannot read host ACK");
    for (ssize_t i = 0; i < n; ++i) {
        if (ack_len == sizeof ack_line) fail("overlong ACK line");
        ack_line[ack_len++] = buf[i];
        if (buf[i] == '\n') {
                    if (xdg) xdg_command(); else acknowledge();
                    ack_len = 0;
                }
    }
    return 0;
}

static void buffer_gone(struct wl_listener *listener, void *data) {
    (void)listener; (void)data;
    pending = NULL;
}
static struct wl_listener watch_buffer = { .notify = buffer_gone };

static void attach(struct wl_client *c, struct wl_resource *s,
                   struct wl_resource *buffer, int32_t x, int32_t y) {
    (void)c; (void)s;
    if (x || y) fail("unexpected attach offset");
    if (pending) wl_list_remove(&watch_buffer.link);
    pending = buffer;
    if (pending) wl_resource_add_destroy_listener(buffer, &watch_buffer);
}

static void mark_slot(unsigned char *dst, unsigned slot) {

    /* Never stage the plain marker in the ELF, initramfs source or SHM pool.
     * Volatile reads prevent constant folding into an embedded literal. */
    static const volatile unsigned char inverted[] = {
        0xac,0xbc,0xb3,0xba,0xad,0xba,0xb6,0xbb,0xd2,0xb2,0xcd,0xd2,
        0xbb,0xbe,0xa7,0xd2,0xb9,0xad,0xbe,0xb2,0xba,0xd2,0xad,0xba,
        0xb8,0xb6,0xb0,0xb1,0xd2,0xa9,0xce,0xde
    };
    _Static_assert(sizeof inverted == PREFIX, "marker length");
    for (size_t i = 0; i < PREFIX - 1; ++i) dst[i] = (unsigned char)~inverted[i];
    dst[PREFIX - 1] = 0x21 + lane * MAX_SLOTS + slot;
}

static void xdg_commit(void) {
    if (!toplevel) fail("expected XDG toplevel before commit");
    if (!pending) {
        if (!configured && !configure_serial) {
            struct wl_array states = {0};
            configure_serial = wl_display_next_serial(display);
            wl_resource_post_event(toplevel, 0, 0, 0, &states); /* client chooses size */
            wl_resource_post_event(role, 0, configure_serial);
        }
        return;
    }
    if (!configured) fail("buffer before ack_configure");
    if (!closing) {
        if (slot_busy) fail("XDG frame before host ACK");
        struct wl_shm_buffer *b = wl_shm_buffer_get(pending);
        if (!b || wl_shm_buffer_get_format(b) != WL_SHM_FORMAT_XRGB8888)
            fail("expected XRGB8888 SHM buffer");
        int w = wl_shm_buffer_get_width(b), h = wl_shm_buffer_get_height(b);
        int stride = wl_shm_buffer_get_stride(b);
        if (w <= 0 || w > XDG_WIDTH || h <= 0 || h > XDG_HEIGHT || stride < 4*w)
            fail("invalid XDG dimensions/stride");
        wl_shm_buffer_begin_access(b);
        const unsigned char *src = wl_shm_buffer_get_data(b);
        for (int y = 0; y < h; ++y) {
            unsigned char *row = frame + PREFIX + y*w*4;
            memcpy(row, src + (size_t)y*stride, w*4);
            for (int x = 0; x < w; ++x) row[x*4+3] = 255;
        }
        wl_shm_buffer_end_access(b);
        mark_slot(frame, 0);
        atomic_thread_fence(memory_order_release);
        slot_busy = 1;
        if (printf("XDG_FRAME %d %d %d\n", w, h, published++) < 0 || fflush(stdout)) sysfail("stdout");
    }
    /* SHM may be reused after copying; only the DAX slot is held until ACK. */
    wl_buffer_send_release(pending);
    wl_list_remove(&watch_buffer.link);
    pending = NULL;
}

static void commit(struct wl_client *c, struct wl_resource *s) {
    (void)s;
    if (xdg) { xdg_commit(); return; }
    struct wl_shm_buffer *b = pending ? wl_shm_buffer_get(pending) : NULL;
    if ((!animate && published) || !b || wl_shm_buffer_get_format(b) != WL_SHM_FORMAT_XRGB8888 ||
        wl_shm_buffer_get_width(b) != width || wl_shm_buffer_get_height(b) != height ||
        wl_shm_buffer_get_stride(b) != STRIDE) fail("unexpected committed buffer");
    wl_shm_buffer_begin_access(b);
    uint32_t *src = wl_shm_buffer_get_data(b);
    unsigned tick = 0, slot = 0;
    if (animate) {
        tick = le32toh(src[0]) - 0xff000000u;
        slot = le32toh(src[1]) - 0xff000000u;
        if (tick >= (unsigned)ticks || (int)tick <= last_tick || slot >= (unsigned)slots)
            fail("bad tick/slot pixel");
        if (held[slot].buffer) fail("occupied DAX slot reused");
        for (int i = 0; i < slots; ++i)
            if (pending == held[i].buffer) fail("occupied SHM buffer reused");
        last_tick = (int)tick;
    }
    unsigned char *dst = frame + slot * RANGE;
    memcpy(dst + PREFIX, src, PIXELS);
    wl_shm_buffer_end_access(b);
    memset(dst + PREFIX + PIXELS, 0, RANGE - PREFIX - PIXELS);
    mark_slot(dst, slot);
    if (animate) {
        held[slot].buffer = pending;
        held[slot].tick = tick;
        held[slot].destroy.notify = held_gone;
        wl_resource_add_destroy_listener(pending, &held[slot].destroy);
        atomic_thread_fence(memory_order_release);
        if (printf("FRAME %d %d %u %u\n", width, height, tick, slot) < 0 || fflush(stdout))
            sysfail("stdout");
        wl_list_remove(&watch_buffer.link);
        pending = NULL;
        ++published;
        return;
    }
    atomic_thread_fence(memory_order_seq_cst);
    if (msync(frame, RANGE, MS_SYNC)) sysfail("sync /mnt/frame");
    wl_buffer_send_release(pending);
    wl_client_flush(c);
    published = 1;
    if (fputs("FRAME 64 48\n", stdout) == EOF || fflush(stdout)) sysfail("stdout");
    char line[16];
    if (!fgets(line, sizeof line, stdin) || strcmp(line, "ACK\n")) fail("expected ACK line");
    wl_display_terminate(display);
}

static void destroy_resource(struct wl_client *c, struct wl_resource *r) {
    (void)c; wl_resource_destroy(r);
}
static void clear_resource(struct wl_resource *r) {
    struct wl_resource **ref = wl_resource_get_user_data(r);
    *ref = NULL;
}

static void xdg_frame_callback(struct wl_client *c, struct wl_resource *s, uint32_t id) {
    (void)s;
    if (callback) fail("fixture accepts one frame callback per commit");
    callback = wl_resource_create(c, &wl_callback_interface, 1, id);
    if (!callback) fail("creating frame callback");
    wl_resource_set_implementation(callback, NULL, &callback, clear_resource);
}

static void damage(struct wl_client *c, struct wl_resource *s, int32_t x, int32_t y,
                   int32_t w, int32_t h) {
    (void)c; (void)s; (void)x; (void)y; (void)w; (void)h; /* publish the whole buffer */
}
static void ignore_region(struct wl_client *c, struct wl_resource *s, struct wl_resource *region) {
    (void)c; (void)s; (void)region;
}
static const struct wl_surface_interface xdg_surface_ops = {
    .destroy = destroy_resource, .attach = attach, .commit = commit, .damage = damage,
    .frame = xdg_frame_callback, .set_opaque_region = ignore_region, .set_input_region = ignore_region
};
static void surface_gone(struct wl_resource *s) {
    (void)s;
    if (pending) { wl_list_remove(&watch_buffer.link); pending = NULL; }
    if (callback) wl_resource_destroy(callback);
    surface = NULL;
}
static const struct wl_surface_interface surface_ops = {
    .destroy = destroy_resource, .attach = attach, .commit = commit
};
static void create_surface(struct wl_client *c, struct wl_resource *r, uint32_t id) {
    (void)r;
    if (surface_created++) fail("fixture accepts only one surface");
    struct wl_resource *s = wl_resource_create(c, &wl_surface_interface, 1, id);
    if (!s) fail("creating surface");
    if (xdg) {
            surface = s;
            wl_resource_set_implementation(s, &xdg_surface_ops, NULL, surface_gone);
        } else wl_resource_set_implementation(s, &surface_ops, NULL, NULL);
}
static const struct wl_compositor_interface compositor_ops = { .create_surface = create_surface };
static void bind_compositor(struct wl_client *c, void *data, uint32_t version, uint32_t id) {
    (void)data;
    struct wl_resource *r = wl_resource_create(c, &wl_compositor_interface, version, id);
    if (!r) fail("binding compositor");
    wl_resource_set_implementation(r, &compositor_ops, NULL, NULL);
}

/* One client, one role. The dispatcher's implementation pointer identifies
 * the request table; resource user data tracks the lifetime of each role. */
static int shell_dispatch(const void *iface, void *target, uint32_t op,
                          const struct wl_message *msg, union wl_argument *a) {
    struct wl_resource *r = target;
    struct wl_client *c = wl_resource_get_client(r);
    if (op == 0) {
        if ((iface == &shell_base && role) || (iface == &shell_surface && toplevel))
            fail("XDG roles destroyed out of order");
        wl_resource_destroy(r);
        return 0;
    }
    struct wl_resource **ref = NULL;
    const struct wl_interface *child = NULL;
    if (iface == &shell_base && op == 2 && !role && surface && (void *)a[1].o == surface) {
        ref = &role; child = &shell_surface;
    } else if (iface == &shell_surface && op == 1 && !toplevel) {
        ref = &toplevel; child = &shell_top;
    } else if (iface == &shell_surface && op == 4 && configure_serial &&
               a[0].u == configure_serial && !configured) {
        configured = 1;
        return 0;
    } else if ((iface == &shell_top && (op == 2 || op == 3)) || /* title/app_id: no decoration */
               (iface == &shell_surface && op == 3) || (iface == &shell_base && op == 3)) {
        return 0;
    } else {
        fprintf(stderr, "unexpected XDG request: %s\n", msg->name);
        exit(1);
    }
    *ref = wl_resource_create(c, child, 1, a[0].n);
    if (!*ref) fail("creating XDG role");
    wl_resource_set_dispatcher(*ref, shell_dispatch, child, ref, clear_resource);
    return 0;
}
static void bind_shell(struct wl_client *c, void *data, uint32_t version, uint32_t id) {
    (void)data;
    struct wl_resource *r = wl_resource_create(c, &shell_base, version, id);
    if (!r) fail("binding xdg_wm_base");
    wl_resource_set_dispatcher(r, shell_dispatch, &shell_base, NULL, NULL);
}

static void client_gone(struct wl_listener *listener, void *data) {
    (void)data;
    if (xdg) {
        /* A socket hangup can arrive together with queued destructor requests.
         * Wayland cleans up any remaining resources after this notification. */
        if (!closing || !published) fail("disconnect before XDG close/frame");
        disconnected = 1;
        wl_list_remove(&listener->link);
        if (!slot_busy) wl_display_terminate(display);
        return;
    }
    if (ack_len || pending) fail("disconnect with unfinished frame/ACK");
    for (int i = 0; i < slots; ++i)
        if (held[i].buffer) fail("disconnect with occupied slot");
    wl_list_remove(&listener->link);
    wl_display_terminate(display);
}
static void client_created(struct wl_listener *listener, void *data) {
    static struct wl_listener gone = { .notify = client_gone };
    wl_list_remove(&listener->link);
    wl_client_add_destroy_listener(data, &gone);
}

static int server(const char *socket_name) {
    char path[48];
        snprintf(path, sizeof path, "/mnt/frame%d", lane);
        int fd = open(path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0600);
    if (fd < 0) sysfail("open /mnt/frame");
    struct statx st = {0};
    if (syscall(SYS_statx, fd, "", AT_EMPTY_PATH, STATX_BASIC_STATS, &st)) sysfail("statx /mnt/frame");
    if (!(st.stx_mask & STATX_TYPE) || !S_ISREG(st.stx_mode) ||
        !(st.stx_attributes_mask & st.stx_attributes & STATX_ATTR_DAX))
        fail("/mnt/frame is not a confirmed DAX regular file");
    if (ftruncate(fd, slots * RANGE)) sysfail("size /mnt/frame");
    frame = mmap(NULL, slots * RANGE, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (frame == MAP_FAILED) sysfail("mmap /mnt/frame");
    close(fd);
    display = wl_display_create();
    if (!display || wl_display_init_shm(display) < 0 ||
        !wl_global_create(display, &wl_compositor_interface, 1, NULL, bind_compositor))
        fail("initializing Wayland server");
    struct wl_listener created = { .notify = client_created };
    struct wl_event_source *acks = NULL;
    if (xdg && !wl_global_create(display, &shell_base, 1, NULL, bind_shell)) fail("creating xdg_wm_base");
    if (animate || xdg) {
        wl_display_add_client_created_listener(display, &created);
        int flags = fcntl(STDIN_FILENO, F_GETFL);
        if (flags < 0 || fcntl(STDIN_FILENO, F_SETFL, flags | O_NONBLOCK)) sysfail("host fd flags");
        acks = wl_event_loop_add_fd(wl_display_get_event_loop(display), STDIN_FILENO,
                                    WL_EVENT_READABLE, host_ready, NULL);
        if (!acks) sysfail("watch host ACKs");
    }
    if (wl_display_add_socket(display, socket_name)) sysfail("Wayland socket");
    wl_display_run(display);
    if (acks) wl_event_source_remove(acks);
    wl_display_destroy_clients(display);
    wl_display_destroy(display);
    munmap(frame, slots * RANGE);
    return published ? 0 : 1;
}

static struct wl_shm *shm;
static struct wl_compositor *compositor;
static void global(void *data, struct wl_registry *r, uint32_t name, const char *iface, uint32_t version) {
    (void)data; (void)version;
    if (!strcmp(iface, wl_shm_interface.name)) shm = wl_registry_bind(r, name, &wl_shm_interface, 1);
    if (!strcmp(iface, wl_compositor_interface.name))
        compositor = wl_registry_bind(r, name, &wl_compositor_interface, 1);
}
static void removed(void *data, struct wl_registry *r, uint32_t name) {
    (void)data; (void)r; (void)name;
}
static const struct wl_registry_listener registry_ops = { .global = global, .global_remove = removed };
static void release(void *data, struct wl_buffer *buffer) { (void)buffer; *(int *)data = 1; }
static const struct wl_buffer_listener buffer_ops = { .release = release };

static int64_t monotonic_ns(void) {
    struct timespec now;
    if (clock_gettime(CLOCK_MONOTONIC, &now)) sysfail("clock_gettime");
    return (int64_t)now.tv_sec * 1000000000 + now.tv_nsec;
}

static void submit(struct wl_surface *s, struct wl_buffer *b, int *released) {
    *released = 0;
    wl_surface_attach(s, b, 0, 0);
    wl_surface_commit(s);
    while (!*released) if (wl_display_dispatch(display) < 0) sysfail("dispatch Wayland release");
}

static struct client_slot {
    struct wl_buffer *buffer;
    int64_t deadline; /* zero when free */
} buffers[MAX_SLOTS];
static int occupied, late;

static void anim_release(void *data, struct wl_buffer *buffer) {
    struct client_slot *slot = data;
    if (!slot->deadline || slot->buffer != buffer) fail("unexpected buffer release");
    late += monotonic_ns() > slot->deadline;
    slot->deadline = 0;
    --occupied;
}
static const struct wl_buffer_listener anim_ops = { .release = anim_release };

/* Single-threaded default queue. Flush requests even while waiting for a release;
 * after the deadline, keep polling with zero timeout to drain ready events. */
static void pump_until(int64_t deadline, int draining) {
    const int64_t second = 1000000000;
    for (;;) {
        if (wl_display_dispatch_pending(display) < 0) sysfail("dispatch pending");
        if (draining && !occupied) return;
        struct pollfd fd = { .fd = wl_display_get_fd(display), .events = POLLIN };
        if (wl_display_flush(display) < 0) {
            if (errno == EINTR) continue;
            if (errno != EAGAIN) sysfail("flush Wayland");
            fd.events |= POLLOUT;
        }
        if (wl_display_prepare_read(display) < 0) continue;
        int64_t left = deadline - monotonic_ns();
        if (left < 0) left = 0;
        struct timespec wait = { .tv_sec = left / second, .tv_nsec = left % second };
        int rc = ppoll(&fd, 1, &wait, NULL);
        if (rc > 0 && (fd.revents & POLLIN)) {
            if (wl_display_read_events(display) < 0) sysfail("read Wayland events");
        } else {
            int err = errno;
            wl_display_cancel_read(display);
            if (rc < 0 && err == EINTR) continue;
            if (rc < 0) { errno = err; sysfail("poll Wayland"); }
        }
        if (fd.revents & (POLLERR | POLLNVAL | POLLHUP)) fail("Wayland disconnected");
        if (!rc && !left) return;
    }
}

static void play(struct wl_surface *s, uint32_t *pool_pixels) {
    const int64_t second = 1000000000, start = monotonic_ns();
    int sent = 0, expired = 0, no_slot = 0, peak = 0;
    for (int tick = 0; tick < ticks; ++tick) {
        pump_until(start + tick * second / FPS, 0);
        int64_t next = start + (tick + 1) * second / FPS;
        if (monotonic_ns() >= next) { ++expired; continue; }
        int slot = 0;
        while (slot < slots && buffers[slot].deadline) ++slot;
        if (slot == slots) { ++no_slot; continue; }
        uint32_t *pixels = pool_pixels + slot * width * height;
        int split = (tick * 7 + lane * 31) % width;
        for (int x = 0; x < width; ++x)
            pixels[x] = htole32(x < split ? 0xffff0000u : 0xff0000ffu);
        for (int y = 1; y < height; ++y) memcpy(pixels + y * width, pixels, STRIDE);
        pixels[0] = htole32(0xff000000u | (unsigned)tick);
        pixels[1] = htole32(0xff000000u | (unsigned)slot);
        if (monotonic_ns() >= next) { ++expired; continue; }
        buffers[slot].deadline = next;
        if (++occupied > peak) peak = occupied;
        wl_surface_attach(s, buffers[slot].buffer, 0, 0);
        wl_surface_commit(s);
        ++sent;
    }
    pump_until(monotonic_ns() + 10 * second, 1);
    if (occupied) fail("timed out draining buffer releases");
    if (printf("ANIM_STATS %d %d %d %d %d\n", sent, expired, no_slot, late, peak) < 0 || fflush(stdout))
        sysfail("stdout");
}

static int client(const char *socket_name) {
    display = wl_display_connect(socket_name);
    if (!display) sysfail("connect Wayland socket");
    struct wl_registry *r = wl_display_get_registry(display);
    if (!r || wl_registry_add_listener(r, &registry_ops, NULL) || wl_display_roundtrip(display) < 0 ||
        !shm || !compositor) fail("missing Wayland globals");
    int fd = memfd_create("sclereid-shm", MFD_CLOEXEC);
    if (fd < 0 || ftruncate(fd, slots * PIXELS)) sysfail("create SHM pool");
    uint32_t *pixels = mmap(NULL, slots * PIXELS, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (pixels == MAP_FAILED) sysfail("mmap SHM pool");
    static const uint32_t colors[] = { 0xffff0000, 0xff00ff00, 0xff0000ff, 0xffffffff };
    if (!animate) {
        for (int y = 0; y < height; ++y)
            for (int x = 0; x < width; ++x)
                pixels[y * width + x] = htole32(colors[2 * (y >= height/2) + (x >= width/2)]);
        munmap(pixels, PIXELS);
    }
    struct wl_shm_pool *pool = wl_shm_create_pool(shm, fd, slots * PIXELS);
    close(fd);
    if (!pool) fail("creating wl_shm_pool");
    int released = 0;
    for (int i = 0; i < slots; ++i) {
        buffers[i].buffer = wl_shm_pool_create_buffer(pool, i * PIXELS, width, height, STRIDE,
                                                       WL_SHM_FORMAT_XRGB8888);
        if (!buffers[i].buffer || wl_buffer_add_listener(buffers[i].buffer, animate ? &anim_ops : &buffer_ops,
                                    animate ? (void *)&buffers[i] : (void *)&released)) fail("creating buffer");
    }
    wl_shm_pool_destroy(pool);
    struct wl_surface *s = wl_compositor_create_surface(compositor);
    if (!s) fail("creating surface");
    if (animate) {
        play(s, pixels);
        munmap(pixels, slots * PIXELS);
    } else submit(s, buffers[0].buffer, &released);
    wl_display_disconnect(display);
    return 0;
}

static int setting(const char *name, int fallback, int max) {
    const char *value = getenv(name);
    if (!value) return fallback;
    int n = 0;
    for (; *value; ++value) {
        if (*value < '0' || *value > '9') fail(name);
        n = n * 10 + (*value - '0');
        if (n > max) fail(name);
    }
    if (!n) fail(name);
    return n;
}

int main(int argc, char **argv) {
    const char *socket_name = getenv("WAYLAND_DISPLAY");
    if (!getenv("XDG_RUNTIME_DIR") || !socket_name || !*socket_name || strchr(socket_name, '/'))
        fail("set XDG_RUNTIME_DIR and a private WAYLAND_DISPLAY socket name");
    const char *mode = getenv("M2_ANIMATE");
    animate = mode && !strcmp(mode, "1");
    if (animate) {
        width = 640; height = 360;
        lane = setting("M2_INSTANCE", 1, 8) - 1;
        slots = setting("M2_SLOTS", 1, MAX_SLOTS);
        ticks = FPS * setting("M2_SECONDS", 3, 30);
    }
    if (argc == 2 && !strcmp(argv[1], "server")) {
        mode = getenv("M2_XDG");
        xdg = mode && !strcmp(mode, "1");
        if (xdg) {
            if (animate) fail("choose M2_XDG or M2_ANIMATE");
            width = XDG_WIDTH; height = XDG_HEIGHT; /* capacity, not configured size */
        }
        int rc = server(socket_name);
        if ((animate || xdg) && !rc && (fputs("DONE\n", stdout) == EOF || fflush(stdout))) sysfail("stdout");
        return rc;
    }
    if (argc == 2 && !strcmp(argv[1], "client")) return client(socket_name);
    fail("usage: sclereid-m2-guest server|client");
}
