/* Wire metadata for the stable xdg-shell v1 request subset used by simple-shm.
 * Keep XML opcode order; unsupported trailing requests aren't advertised here.
 * Dispatch by opcode so no scanner or generated library is needed at build time. */
#ifndef SCLEREID_M2_XDG_H
#define SCLEREID_M2_XDG_H
#include <wayland-server.h>

static const struct wl_interface shell_surface, shell_top;
static const struct wl_interface shell_positioner = { .name = "xdg_positioner", .version = 1 };
static const struct wl_interface shell_popup = { .name = "xdg_popup", .version = 1 };
static const struct wl_interface *positioner_types[] = { &shell_positioner };
static const struct wl_interface *surface_types[] = { &shell_surface, &wl_surface_interface };
static const struct wl_interface *top_types[] = { &shell_top };
static const struct wl_interface *popup_types[] = { &shell_popup, &shell_surface, &shell_positioner };
static const struct wl_message shell_requests[] = {
    {"destroy", "", NULL}, {"create_positioner", "n", positioner_types},
    {"get_xdg_surface", "no", surface_types}, {"pong", "u", NULL}
};
static const struct wl_message shell_events[] = { {"ping", "u", NULL} };
static const struct wl_message surface_requests[] = {
    {"destroy", "", NULL}, {"get_toplevel", "n", top_types},
    {"get_popup", "n?oo", popup_types}, {"set_window_geometry", "iiii", NULL},
    {"ack_configure", "u", NULL}
};
static const struct wl_message surface_events[] = { {"configure", "u", NULL} };
static const struct wl_message top_requests[] = {
    {"destroy", "", NULL}, {"set_parent", "?o", top_types},
    {"set_title", "s", NULL}, {"set_app_id", "s", NULL},
    {"show_window_menu", "ouii", (const struct wl_interface *[]){ &wl_seat_interface, NULL, NULL, NULL }},
    {"move", "ou", (const struct wl_interface *[]){ &wl_seat_interface, NULL }},
    {"resize", "ouu", (const struct wl_interface *[]){ &wl_seat_interface, NULL, NULL }},
    {"set_max_size", "ii", NULL}, {"set_min_size", "ii", NULL}
};
static const struct wl_message top_events[] = { {"configure", "iia", NULL}, {"close", "", NULL} };
#define SHELL_INTERFACE(name, requests, events) \
    {name, 1, sizeof(requests)/sizeof(*(requests)), requests, sizeof(events)/sizeof(*(events)), events}
static const struct wl_interface shell_base = SHELL_INTERFACE("xdg_wm_base", shell_requests, shell_events);
static const struct wl_interface shell_surface = SHELL_INTERFACE("xdg_surface", surface_requests, surface_events);
static const struct wl_interface shell_top = SHELL_INTERFACE("xdg_toplevel", top_requests, top_events);
#undef SHELL_INTERFACE
#endif
