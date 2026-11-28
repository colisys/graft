#define _POSIX_C_SOURCE 200809L
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct GtkWidget GtkWidget;
#define LOAD(name) do { *(void **)(&name) = dlsym(gtk, #name); if (!name) { fprintf(stderr, "%s\n", dlerror()); return 1; } } while (0)

typedef void (*SignalHandler)(void);
static int (*gdk_event_get_event_type)(const void *);
static int (*gdk_event_get_coords)(const void *, double *, double *);
static int (*gdk_event_get_button)(const void *, unsigned *);
static int (*gdk_event_get_scroll_deltas)(const void *,double *,double *);
static int (*gdk_event_get_keyval)(const void *, unsigned *);

static GtkWidget *menu, *controls[2];
static int keyboard_mode;
static void (*gtk_window_begin_move_drag)(GtkWidget *, int, int, int, unsigned);
static unsigned (*gdk_event_get_time)(const void *);
static void focus_changed(GtkWidget *window, GtkWidget *focus, void *data) {
    (void)window; (void)data;
    fprintf(stderr,"GTK_FOCUS %s\n", focus==controls[0] ? "FIRST" : focus==controls[1] ? "SECOND" : "NONE");
}
static void (*gtk_menu_popup_at_pointer)(GtkWidget *, const void *);
static void (*gtk_menu_shell_select_first)(GtkWidget *,int);
static void (*gtk_main_quit)(void);
static void log_signal(GtkWidget *widget, void *line) {
    (void)widget;
    fprintf(stderr, "%s\n", (const char *)line);
}
static int hover_event(GtkWidget *widget, void *event, void *name) {
    (void)widget;
    int type = gdk_event_get_event_type(event);
    double x, y;
    enum { GDK_MOTION_NOTIFY = 3, GDK_ENTER_NOTIFY = 10, GDK_LEAVE_NOTIFY = 11 };
    const char *kind = type == GDK_MOTION_NOTIFY ? "MOVE" : type == GDK_ENTER_NOTIFY ? "ENTER" :
                       type == GDK_LEAVE_NOTIFY ? "LEAVE" : NULL;
    if (kind && gdk_event_get_coords(event, &x, &y))
        fprintf(stderr, "GTK_HOVER %s %s %g %g\n", (const char *)name, kind, x, y);
    return 0;
}
/* A childless GtkMenuItem is a separator. Use a visible, font-independent
 * child in the offline keyboard probe so GTK can select the item normally. */
static GtkWidget *(*gtk_menu_item_new)(void), *(*gtk_drawing_area_new)(void);
static void (*gtk_container_add)(GtkWidget *,GtkWidget *), (*gtk_widget_set_size_request)(GtkWidget *,int,int);
static GtkWidget *compact_item(void (*show)(GtkWidget *)) {
    GtkWidget *item=gtk_menu_item_new(), *child=gtk_drawing_area_new();
    gtk_widget_set_size_request(child,16,20);
    gtk_container_add(item,child);
    show(child);
    return item;
}
static void quit(GtkWidget *widget, void *data) {
    (void)widget; (void)data; gtk_main_quit();
}

static int input(GtkWidget *widget, void *event, void *name) {
    (void)widget;
    int type = gdk_event_get_event_type(event);
    unsigned value;
    double x, y;
    if (gdk_event_get_button(event, &value) && gdk_event_get_coords(event, &x, &y)) {
        if (gtk_window_begin_move_drag && type == 4 && value == 1 && y >= 78) {
            gtk_window_begin_move_drag(widget, 1, (int)x, (int)y, gdk_event_get_time(event));
            return 1;
        }
        if (menu && type == 4 && value == 3) { /* GDK_BUTTON_PRESS */
            fputs("GTK_MENU OPEN\n", stderr);
            gtk_menu_popup_at_pointer(menu, event);
            if (keyboard_mode) gtk_menu_shell_select_first(menu,1);
            return 1;
        }
        fprintf(stderr, "GTK_INPUT %s button %d %u %g %g\n", (char *)name, type, value, x, y);
        if (keyboard_mode) return 0;
    } else if (keyboard_mode && gdk_event_get_scroll_deltas(event,&x,&y)) {
        fprintf(stderr,"GTK_INPUT %s scroll %g %g\n",(char *)name,x,y);
        return 0;
    } else if (gdk_event_get_keyval(event, &value)) {
        fprintf(stderr, "GTK_INPUT %s key %d %u\n", (char *)name, type, value);
        if (keyboard_mode) return 0; /* GTK handles traversal and menu bindings. */
    } else
        return 0;
    return 1; /* Consume the probe event; don't propagate it a second time. */
}

static int (*gdk_event_get_state)(const void *, unsigned *);
static void hidden(GtkWidget *w, void *data) { (void)w; (void)data; fputs("GTK_MENU_HIDDEN\n",stderr); }
static int observed(GtkWidget *w, void *event, void *label) {
    (void)w;
    unsigned value=0, state=0;
    if (!gdk_event_get_keyval(event,&value)) gdk_event_get_button(event,&value);
    gdk_event_get_state(event,&state);
    int type = gdk_event_get_event_type(event);
    fprintf(stderr,"GTK_EVENT %s %d %u %u\n",(char *)label,type,value,state&1);
    if (menu && type == 4 && value == 3 && *(char *)label == 'A')
        gtk_menu_popup_at_pointer(menu,event);
    return 1;
}

struct animation { unsigned phase; int blue; };
static void (*gtk_widget_queue_draw)(GtkWidget *);
static void (*cairo_set_source_rgb)(void *, double, double, double);
static void (*cairo_paint)(void *);
static int remaining = 2;
static int tick(GtkWidget *w, void *clock, void *data) {
    (void)clock;
    ((struct animation *)data)->phase++;
    gtk_widget_queue_draw(w);
    return 1;
}
static int draw(GtkWidget *w, void *cr, void *data) {
    (void)w;
    struct animation *a = data;
    cairo_set_source_rgb(cr, !a->blue, ((a->phase * 37) % 256) / 255., a->blue);
    cairo_paint(cr);
    return 1;
}
static int deleted(GtkWidget *w, void *event, void *label) {
    (void)w; (void)event;
    fprintf(stderr,"GTK_DELETE %s\n",(char *)label);
    if (!--remaining) gtk_main_quit();
    return 0;
}

int main(int argc, char **argv) {
    keyboard_mode = getenv("M2_GTK_KEYBOARD") && !strcmp(getenv("M2_GTK_KEYBOARD"), "1");
    int tree = keyboard_mode || (getenv("M2_GTK_MENU_TREE") && !strcmp(getenv("M2_GTK_MENU_TREE"), "1"));
    /* Fixture capacity only: eight shared slots minus the owning window.
     * Other framed surfaces or pending ACKs can reduce available slots further. */
    enum { MAX_MENU_DEPTH=7 };
    static struct { char show[40], hide[40], name[16]; } logs[MAX_MENU_DEPTH];
    int depth=2;
    const char *setting=getenv("M2_GTK_MENU_DEPTH");
    if (tree && setting) {
        char *end;
        long n=strtol(setting,&end,10);
        if (*end || n<1 || n>MAX_MENU_DEPTH) {
            fprintf(stderr,"M2_GTK_MENU_DEPTH must be 1..%d\n",MAX_MENU_DEPTH);
            return 1;
        }
        depth=(int)n;
    }
    int hover = tree && getenv("M2_GTK_MENU_HOVER");
    int menu_mode = tree || (argc == 2 && !strcmp(argv[1], "--gtk-menu")) ||
        (getenv("M2_GTK_MENU") && !strcmp(getenv("M2_GTK_MENU"), "1"));
    int (*gtk_init_check)(int *, char ***);
    GtkWidget *(*gtk_window_new)(int);
    void (*gtk_window_set_title)(GtkWidget *, const char *);
    void (*gtk_window_set_default_size)(GtkWidget *, int, int);
    void (*gtk_window_set_decorated)(GtkWidget *, int);
    void (*gtk_widget_show)(GtkWidget *);

    void (*gtk_widget_add_events)(GtkWidget *, int);
    unsigned long (*g_signal_connect_data)(void *, const char *, SignalHandler, void *, void (*)(void *, void *), int);
    void (*gtk_main)(void);
    if (setenv("GDK_BACKEND", "wayland", 1)) return 1;
    void *gtk = dlopen("libgtk-3.so.0", RTLD_NOW | RTLD_LOCAL);
    if (!gtk) { fprintf(stderr, "%s\n", dlerror()); return 1; }
    LOAD(gtk_init_check);
    LOAD(gtk_window_new);
    LOAD(gtk_window_set_title);
    LOAD(gtk_window_set_default_size);
    LOAD(gtk_window_set_decorated);
    LOAD(gtk_widget_show);
    LOAD(gtk_main);

    LOAD(gtk_widget_add_events);
    LOAD(g_signal_connect_data);
    LOAD(gdk_event_get_event_type);
    if (menu_mode) LOAD(gdk_event_get_coords);
    LOAD(gdk_event_get_button);
    LOAD(gdk_event_get_keyval);
    if (keyboard_mode) LOAD(gdk_event_get_scroll_deltas);
    if (keyboard_mode && getenv("M2_GTK_MOVE")) {
        LOAD(gtk_window_begin_move_drag);
        LOAD(gdk_event_get_time);
    }
    if (!gtk_init_check(NULL, NULL)) { fputs("GTK_WAYLAND_INIT_FAILED\n", stderr); return 1; }
    fputs("GTK_WAYLAND_CONNECTED\n", stderr);
    const char *titles[] = {"Sclereid GTK A", "Sclereid GTK B"};
    struct animation state[2] = {{0,0},{0,1}};
    unsigned (*gtk_widget_add_tick_callback)(GtkWidget *,int (*)(GtkWidget *,void *,void *),void *,void (*)(void *));
    if (!menu_mode) {
        LOAD(gdk_event_get_state);
        LOAD(gtk_widget_add_tick_callback); LOAD(gtk_widget_queue_draw); LOAD(gtk_main_quit);
        LOAD(cairo_set_source_rgb); LOAD(cairo_paint);
    }
    for (int i = 0; i < (menu_mode ? 1 : 2); ++i) {
        GtkWidget *window = gtk_window_new(0);
        gtk_window_set_title(window, titles[i]);
        gtk_window_set_default_size(window, 128 + i * 32, 96);
        gtk_window_set_decorated(window, 0);
        /* Keep the shared GTK probe and the interactive menu fixture independent. */
        if (!menu_mode) {
            gtk_widget_add_events(window,(1<<8)|(1<<9)|(1<<10)|(1<<11)|(1<<21)|(1<<23));
            const char *signals[]={"button-press-event","button-release-event","key-press-event","key-release-event","scroll-event"};
            for(unsigned j=0;j<5;j++) g_signal_connect_data(window,signals[j],(SignalHandler)observed,i?"B":"A",NULL,0);
            g_signal_connect_data(window,"draw",(SignalHandler)draw,&state[i],NULL,0);
            gtk_widget_add_tick_callback(window,tick,&state[i],NULL);
            g_signal_connect_data(window,"delete-event",(SignalHandler)deleted,i?"B":"A",NULL,0);
            if (!i && getenv("M2_MENU")) {
                GtkWidget *(*gtk_menu_new)(void), *(*gtk_menu_item_new)(void);
                void (*gtk_menu_shell_append)(GtkWidget *,GtkWidget *);
                void (*gtk_menu_attach_to_widget)(GtkWidget *,GtkWidget *,void (*)(GtkWidget *, GtkWidget *));
                void (*gtk_widget_set_size_request)(GtkWidget *,int,int);
                LOAD(gtk_menu_new); LOAD(gtk_menu_item_new); LOAD(gtk_menu_shell_append);
                LOAD(gtk_menu_attach_to_widget); LOAD(gtk_menu_popup_at_pointer); LOAD(gtk_widget_set_size_request);
                menu=gtk_menu_new();
                g_signal_connect_data(menu,"hide",(SignalHandler)hidden,NULL,NULL,0);
                GtkWidget *item=gtk_menu_item_new();
                gtk_widget_set_size_request(item,64,24);
                gtk_menu_shell_append(menu,item); gtk_widget_show(item);
                gtk_menu_attach_to_widget(menu,window,NULL);
            }
        } else {
            gtk_widget_add_events(window, (1 << 8) | (1 << 9)); /* GDK button press/release */
            if (keyboard_mode) gtk_widget_add_events(window,(1 << 21) | (1 << 23)); /* scroll / smooth scroll */
            g_signal_connect_data(window, "event", (SignalHandler)input, i ? "B" : "A", NULL, 0);
            if (keyboard_mode) {
                GtkWidget *(*gtk_box_new)(int, int), *(*gtk_button_new)(void);
                void (*gtk_widget_grab_focus)(GtkWidget *);
                LOAD(gtk_box_new); LOAD(gtk_button_new); LOAD(gtk_container_add); LOAD(gtk_widget_grab_focus);
                GtkWidget *box=gtk_box_new(1,0);
                gtk_container_add(window,box);
                for (int j=0;j<2;j++) {
                    controls[j]=gtk_button_new();
                    gtk_container_add(box,controls[j]);
                    gtk_widget_show(controls[j]);
                }
                gtk_widget_show(box);
                g_signal_connect_data(window,"set-focus",(SignalHandler)focus_changed,NULL,NULL,0);
                gtk_widget_grab_focus(controls[0]);
            }
            GtkWidget *(*gtk_menu_new)(void), *(*gtk_menu_item_new_with_label)(const char *);
            void (*gtk_menu_shell_append)(GtkWidget *, GtkWidget *);
            void (*gtk_menu_attach_to_widget)(GtkWidget *, GtkWidget *, void (*)(GtkWidget *, GtkWidget *));
            LOAD(gtk_menu_new); LOAD(gtk_menu_item_new_with_label); LOAD(gtk_menu_shell_append);
            LOAD(gtk_menu_attach_to_widget); LOAD(gtk_menu_popup_at_pointer); LOAD(gtk_main_quit);
            if (keyboard_mode) LOAD(gtk_menu_shell_select_first);
            if (tree) { LOAD(gtk_menu_item_new); LOAD(gtk_drawing_area_new); LOAD(gtk_container_add); LOAD(gtk_widget_set_size_request); }
            menu = gtk_menu_new();
            GtkWidget *item = tree ? compact_item(gtk_widget_show) : gtk_menu_item_new_with_label("Action");
            GtkWidget *leaf_menu = menu;
            if (tree) {
                void (*gtk_menu_item_set_submenu)(GtkWidget *, GtkWidget *);
                LOAD(gtk_menu_item_set_submenu);

                if (keyboard_mode) {
                    GtkWidget *first=compact_item(gtk_widget_show);
                    gtk_menu_shell_append(menu,first);
                    gtk_widget_show(first);
                    g_signal_connect_data(first,"select",(SignalHandler)log_signal,"GTK_MENU SELECT FIRST",NULL,0);
                }

                g_signal_connect_data(menu, "show", (SignalHandler)log_signal, "GTK_MENU ROOT SHOW", NULL, 0);
                for (int level=2;level<=depth;level++) {
                    GtkWidget *branch=compact_item(gtk_widget_show);
                    GtkWidget *sub=gtk_menu_new();
                    gtk_menu_item_set_submenu(branch,sub);
                    gtk_menu_shell_append(leaf_menu,branch);
                    gtk_widget_show(branch);
                    leaf_menu=sub;
                    snprintf(logs[level-1].name,sizeof logs[0].name,"LEVEL%d",level);
                    snprintf(logs[level-1].show,sizeof logs[0].show,"GTK_MENU LEVEL%d SHOW",level);
                    snprintf(logs[level-1].hide,sizeof logs[0].hide,"GTK_MENU LEVEL%d HIDE",level);
                    g_signal_connect_data(sub,"show",(SignalHandler)log_signal,level==2 ? "GTK_MENU SUBMENU SHOW" : logs[level-1].show,NULL,0);
                    g_signal_connect_data(sub,"hide",(SignalHandler)log_signal,level==2 ? "GTK_MENU SUBMENU HIDE" : logs[level-1].hide,NULL,0);
                    char *name=level==depth ? "LEAF" : logs[level-1].name;
                    if (keyboard_mode) {
                        g_signal_connect_data(branch,"select",(SignalHandler)log_signal,"GTK_MENU SELECT BRANCH",NULL,0);
                        g_signal_connect_data(sub,"key-press-event",(SignalHandler)input,name,NULL,0);
                    }
                    if (hover) g_signal_connect_data(sub,"event",(SignalHandler)hover_event,name,NULL,0);
                }
                if (keyboard_mode) {
                    g_signal_connect_data(item,"select",(SignalHandler)log_signal,"GTK_MENU SELECT ACTION",NULL,0);
                    g_signal_connect_data(menu,"key-press-event",(SignalHandler)input,"ROOT",NULL,0);

                }
                if (hover) {
                    gtk_widget_add_events(window, 1 << 2); /* GDK_POINTER_MOTION_MASK */
                    g_signal_connect_data(window, "motion-notify-event", (SignalHandler)hover_event, "PARENT", NULL, 0);
                    g_signal_connect_data(menu, "event", (SignalHandler)hover_event, "ROOT", NULL, 0);

                }
            }
            gtk_menu_shell_append(leaf_menu, item);
            gtk_widget_show(item);
            gtk_menu_attach_to_widget(menu, window, NULL);
            g_signal_connect_data(item, "activate", (SignalHandler)log_signal, "GTK_MENU ACTION", NULL, 0);
            g_signal_connect_data(menu, "hide", (SignalHandler)log_signal, tree ? "GTK_MENU ROOT HIDE" : "GTK_MENU DISMISS", NULL, 0);
            g_signal_connect_data(window, "destroy", (SignalHandler)quit, NULL, NULL, 0);
        }
        gtk_widget_show(window);
    }
    gtk_main();
    return 0;
}
