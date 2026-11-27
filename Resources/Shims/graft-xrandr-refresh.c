/*
 * Graft XRandR refresh shim.
 *
 * XQuartz's rootless mode hard-codes its fake XRandR mode to 1 Hz
 * (hw/xquartz/quartzRandR.c: FAKE_REFRESH_ROOTLESS 1).  Chromium trusts that
 * value and caps its compositor at ~1 fps.  Graft keeps XQuartz untouched and
 * instead presents the macOS display refresh rate to X11 clients by rewriting
 * the refresh field in XRandR replies inside the container.
 *
 * The target rate is read from GRAFT_MAX_REFRESH (Hz).  If unset/zero the
 * shim is a no-op.  Both the Xlib and XCB APIs are intercepted because
 * Chromium uses XCB while GTK/Qt/OpenGL applications generally use Xlib.
 *
 * This file is Graft's own code, licensed GPL-3.0-or-later.
 */
#define _GNU_SOURCE
#include <X11/Xlib.h>
#include <X11/extensions/Xrandr.h>
#include <xcb/xcb.h>
#include <xcb/randr.h>
#include <dlfcn.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/uio.h>
#include <xcb/xcbext.h>

#define GRAFT_MAX_PENDING 256

static int graft_target_hz(void)
{
    const char *value = getenv("GRAFT_MAX_REFRESH");
    if (!value || !*value)
        return 0;
    char *end = NULL;
    long hz = strtol(value, &end, 10);
    if (end == value || hz < 1 || hz > 1000)
        return 0;
    return (int)hz;
}

/* ---------------------------------------------------------------- Xlib */

static void graft_fix_xlib_modes(XRRScreenResources *resources)
{
    int hz = graft_target_hz();
    if (!resources || hz <= 0)
        return;
    for (int i = 0; i < resources->nmode; i++) {
        XRRModeInfo *mode = &resources->modes[i];
        if (!mode->hTotal || !mode->vTotal)
            continue;
        uint64_t clock = (uint64_t)hz * mode->hTotal * mode->vTotal;
        if (clock > 0xffffffffULL)
            clock = 0xffffffffULL;
        mode->dotClock = (unsigned long)clock;
    }
}

XRRScreenResources *XRRGetScreenResources(Display *display, Window window)
{
    static XRRScreenResources *(*real)(Display *, Window) = NULL;
    if (!real)
        real = (XRRScreenResources *(*)(Display *, Window))dlsym(RTLD_NEXT, "XRRGetScreenResources");
    if (!real)
        return NULL;
    XRRScreenResources *resources = real(display, window);
    graft_fix_xlib_modes(resources);
    return resources;
}

XRRScreenResources *XRRGetScreenResourcesCurrent(Display *display, Window window)
{
    static XRRScreenResources *(*real)(Display *, Window) = NULL;
    if (!real)
        real = (XRRScreenResources *(*)(Display *, Window))dlsym(RTLD_NEXT, "XRRGetScreenResourcesCurrent");
    if (!real)
        return NULL;
    XRRScreenResources *resources = real(display, window);
    graft_fix_xlib_modes(resources);
    return resources;
}

/* ---------------------------------------------------------------- XCB */

static uint16_t graft_pending[GRAFT_MAX_PENDING];

static void graft_remember_pending(unsigned int sequence)
{
    graft_pending[sequence % GRAFT_MAX_PENDING] = (uint16_t)sequence;
}

static int graft_is_pending(uint16_t sequence)
{
    return graft_pending[sequence % GRAFT_MAX_PENDING] == sequence;
}

static void graft_fix_xcb_reply(void *reply)
{
    int hz = graft_target_hz();
    if (!reply || hz <= 0)
        return;

    xcb_generic_reply_t *generic = (xcb_generic_reply_t *)reply;
    if (!graft_is_pending(generic->sequence))
        return;

    xcb_randr_get_screen_resources_current_reply_t *resources =
        (xcb_randr_get_screen_resources_current_reply_t *)reply;
    if (resources->num_modes == 0)
        return;

    uint8_t *mode_start = (uint8_t *)resources + sizeof(*resources);
    mode_start += (size_t)resources->num_crtcs * sizeof(xcb_randr_crtc_t);
    mode_start += (size_t)resources->num_outputs * sizeof(xcb_randr_output_t);
    xcb_randr_mode_info_t *modes = (xcb_randr_mode_info_t *)mode_start;
    for (uint32_t i = 0; i < resources->num_modes; i++) {
        if (!modes[i].htotal || !modes[i].vtotal)
            continue;
        uint64_t clock = (uint64_t)hz * modes[i].htotal * modes[i].vtotal;
        if (clock > 0xffffffffULL)
            clock = 0xffffffffULL;
        modes[i].dot_clock = (uint32_t)clock;
    }
}

static int graft_is_resources_request(const xcb_protocol_request_t *request)
{
    if (!request || !request->ext || !request->ext->name)
        return 0;
    if (strcasecmp(request->ext->name, "RANDR") != 0)
        return 0;
    return request->opcode == XCB_RANDR_GET_SCREEN_RESOURCES
        || request->opcode == XCB_RANDR_GET_SCREEN_RESOURCES_CURRENT;
}

/* Chromium's generated XCB binding sends RandR requests through
 * xcb_send_request() rather than libxcb-randr's convenience functions, so
 * remember those sequences too. */
unsigned int xcb_send_request(xcb_connection_t *connection, int flags,
                              struct iovec *vector,
                              const xcb_protocol_request_t *request)
{
    static unsigned int (*real)(xcb_connection_t *, int, struct iovec *,
                                const xcb_protocol_request_t *) = NULL;
    if (!real)
        real = (unsigned int (*)(xcb_connection_t *, int, struct iovec *,
                                 const xcb_protocol_request_t *))
            dlsym(RTLD_NEXT, "xcb_send_request");
    if (!real)
        return 0;
    unsigned int sequence = real(connection, flags, vector, request);
    if (graft_is_resources_request(request))
        graft_remember_pending(sequence);
    return sequence;
}

uint64_t xcb_send_request64(xcb_connection_t *connection, int flags,
                            struct iovec *vector,
                            const xcb_protocol_request_t *request)
{
    static uint64_t (*real)(xcb_connection_t *, int, struct iovec *,
                            const xcb_protocol_request_t *) = NULL;
    if (!real)
        real = (uint64_t (*)(xcb_connection_t *, int, struct iovec *,
                             const xcb_protocol_request_t *))
            dlsym(RTLD_NEXT, "xcb_send_request64");
    if (!real)
        return 0;
    uint64_t sequence = real(connection, flags, vector, request);
    if (graft_is_resources_request(request))
        graft_remember_pending((unsigned int)sequence);
    return sequence;
}

xcb_randr_get_screen_resources_current_cookie_t
xcb_randr_get_screen_resources_current(xcb_connection_t *connection,
                                       xcb_window_t window)
{
    static xcb_randr_get_screen_resources_current_cookie_t (*real)(
        xcb_connection_t *, xcb_window_t) = NULL;
    if (!real)
        real = (xcb_randr_get_screen_resources_current_cookie_t (*)(
            xcb_connection_t *, xcb_window_t))
            dlsym(RTLD_NEXT, "xcb_randr_get_screen_resources_current");
    if (!real) {
        xcb_randr_get_screen_resources_current_cookie_t empty = { 0 };
        return empty;
    }
    xcb_randr_get_screen_resources_current_cookie_t cookie = real(connection, window);
    graft_remember_pending(cookie.sequence);
    return cookie;
}

xcb_randr_get_screen_resources_current_cookie_t
xcb_randr_get_screen_resources_current_unchecked(xcb_connection_t *connection,
                                                 xcb_window_t window)
{
    static xcb_randr_get_screen_resources_current_cookie_t (*real)(
        xcb_connection_t *, xcb_window_t) = NULL;
    if (!real)
        real = (xcb_randr_get_screen_resources_current_cookie_t (*)(
            xcb_connection_t *, xcb_window_t))
            dlsym(RTLD_NEXT, "xcb_randr_get_screen_resources_current_unchecked");
    if (!real) {
        xcb_randr_get_screen_resources_current_cookie_t empty = { 0 };
        return empty;
    }
    xcb_randr_get_screen_resources_current_cookie_t cookie = real(connection, window);
    graft_remember_pending(cookie.sequence);
    return cookie;
}

xcb_randr_get_screen_resources_cookie_t
xcb_randr_get_screen_resources(xcb_connection_t *connection,
                               xcb_window_t window)
{
    static xcb_randr_get_screen_resources_cookie_t (*real)(
        xcb_connection_t *, xcb_window_t) = NULL;
    if (!real)
        real = (xcb_randr_get_screen_resources_cookie_t (*)(
            xcb_connection_t *, xcb_window_t))
            dlsym(RTLD_NEXT, "xcb_randr_get_screen_resources");
    if (!real) {
        xcb_randr_get_screen_resources_cookie_t empty = { 0 };
        return empty;
    }
    xcb_randr_get_screen_resources_cookie_t cookie = real(connection, window);
    graft_remember_pending(cookie.sequence);
    return cookie;
}

xcb_randr_get_screen_resources_cookie_t
xcb_randr_get_screen_resources_unchecked(xcb_connection_t *connection,
                                         xcb_window_t window)
{
    static xcb_randr_get_screen_resources_cookie_t (*real)(
        xcb_connection_t *, xcb_window_t) = NULL;
    if (!real)
        real = (xcb_randr_get_screen_resources_cookie_t (*)(
            xcb_connection_t *, xcb_window_t))
            dlsym(RTLD_NEXT, "xcb_randr_get_screen_resources_unchecked");
    if (!real) {
        xcb_randr_get_screen_resources_cookie_t empty = { 0 };
        return empty;
    }
    xcb_randr_get_screen_resources_cookie_t cookie = real(connection, window);
    graft_remember_pending(cookie.sequence);
    return cookie;
}

xcb_randr_get_screen_resources_current_reply_t *
xcb_randr_get_screen_resources_current_reply(
    xcb_connection_t *connection,
    xcb_randr_get_screen_resources_current_cookie_t cookie,
    xcb_generic_error_t **error)
{
    static xcb_randr_get_screen_resources_current_reply_t *(*real)(
        xcb_connection_t *, xcb_randr_get_screen_resources_current_cookie_t,
        xcb_generic_error_t **) = NULL;
    if (!real)
        real = (xcb_randr_get_screen_resources_current_reply_t *(*)(
            xcb_connection_t *, xcb_randr_get_screen_resources_current_cookie_t,
            xcb_generic_error_t **))
            dlsym(RTLD_NEXT, "xcb_randr_get_screen_resources_current_reply");
    if (!real)
        return NULL;
    xcb_randr_get_screen_resources_current_reply_t *reply =
        real(connection, cookie, error);
    if (reply) {
        graft_remember_pending(cookie.sequence);
        graft_fix_xcb_reply(reply);
    }
    return reply;
}

xcb_randr_get_screen_resources_reply_t *
xcb_randr_get_screen_resources_reply(
    xcb_connection_t *connection,
    xcb_randr_get_screen_resources_cookie_t cookie,
    xcb_generic_error_t **error)
{
    static xcb_randr_get_screen_resources_reply_t *(*real)(
        xcb_connection_t *, xcb_randr_get_screen_resources_cookie_t,
        xcb_generic_error_t **) = NULL;
    if (!real)
        real = (xcb_randr_get_screen_resources_reply_t *(*)(
            xcb_connection_t *, xcb_randr_get_screen_resources_cookie_t,
            xcb_generic_error_t **))
            dlsym(RTLD_NEXT, "xcb_randr_get_screen_resources_reply");
    if (!real)
        return NULL;
    xcb_randr_get_screen_resources_reply_t *reply =
        real(connection, cookie, error);
    if (reply) {
        graft_remember_pending(cookie.sequence);
        graft_fix_xcb_reply(reply);
    }
    return reply;
}

void *xcb_wait_for_reply(xcb_connection_t *connection, unsigned int request,
                         xcb_generic_error_t **error)
{
    static void *(*real)(xcb_connection_t *, unsigned int,
                         xcb_generic_error_t **) = NULL;
    if (!real)
        real = (void *(*)(xcb_connection_t *, unsigned int,
                          xcb_generic_error_t **))
            dlsym(RTLD_NEXT, "xcb_wait_for_reply");
    if (!real)
        return NULL;
    void *reply = real(connection, request, error);
    if (reply)
        graft_fix_xcb_reply(reply);
    return reply;
}

void *xcb_wait_for_reply64(xcb_connection_t *connection, uint64_t request,
                           xcb_generic_error_t **error)
{
    static void *(*real)(xcb_connection_t *, uint64_t,
                         xcb_generic_error_t **) = NULL;
    if (!real)
        real = (void *(*)(xcb_connection_t *, uint64_t,
                          xcb_generic_error_t **))
            dlsym(RTLD_NEXT, "xcb_wait_for_reply64");
    if (!real)
        return NULL;
    void *reply = real(connection, request, error);
    if (reply)
        graft_fix_xcb_reply(reply);
    return reply;
}

int xcb_poll_for_reply(xcb_connection_t *connection, unsigned int request,
                       void **reply, xcb_generic_error_t **error)
{
    static int (*real)(xcb_connection_t *, unsigned int, void **,
                       xcb_generic_error_t **) = NULL;
    if (!real)
        real = (int (*)(xcb_connection_t *, unsigned int, void **,
                        xcb_generic_error_t **))
            dlsym(RTLD_NEXT, "xcb_poll_for_reply");
    if (!real)
        return 0;
    int result = real(connection, request, reply, error);
    if (result && reply && *reply)
        graft_fix_xcb_reply(*reply);
    return result;
}

int xcb_poll_for_reply64(xcb_connection_t *connection, uint64_t request,
                         void **reply, xcb_generic_error_t **error)
{
    static int (*real)(xcb_connection_t *, uint64_t, void **,
                       xcb_generic_error_t **) = NULL;
    if (!real)
        real = (int (*)(xcb_connection_t *, uint64_t, void **,
                        xcb_generic_error_t **))
            dlsym(RTLD_NEXT, "xcb_poll_for_reply64");
    if (!real)
        return 0;
    int result = real(connection, request, reply, error);
    if (result && reply && *reply)
        graft_fix_xcb_reply(*reply);
    return result;
}
