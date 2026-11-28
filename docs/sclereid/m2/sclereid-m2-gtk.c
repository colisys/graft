#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>

typedef struct GtkWidget GtkWidget;
#define LOAD(name) do { *(void **)(&name) = dlsym(gtk, #name); if (!name) { fprintf(stderr, "%s\n", dlerror()); return 1; } } while (0)

static int (*gdk_event_get_keyval)(void *, unsigned *);
static int (*gdk_event_get_button)(void *, unsigned *);
static int (*gdk_event_get_state)(void *, unsigned *);
static GtkWidget *menu;
static void (*gtk_menu_popup_at_pointer)(GtkWidget *, void *);
static void hidden(GtkWidget *w, void *data) { (void)w; (void)data; fputs("GTK_MENU_HIDDEN\n",stderr); }
static int observed(GtkWidget *w, void *event, void *label) {
    (void)w;
    unsigned value=0, state=0;
    if (!gdk_event_get_keyval(event,&value)) gdk_event_get_button(event,&value);
    gdk_event_get_state(event,&state);
    fprintf(stderr,"GTK_EVENT %s %d %u %u\n",(char *)label,*(int *)event,value,state&1);
    if (menu && *(int *)event == 4 && value == 3 && *(char *)label == 'A')
        gtk_menu_popup_at_pointer(menu,event);
    return 1;
}

struct animation { unsigned phase; int blue; };
static void (*gtk_widget_queue_draw)(GtkWidget *);
static void (*cairo_set_source_rgb)(void *, double, double, double);
static void (*cairo_paint)(void *);
static void (*gtk_main_quit)(void);
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

int main(void) {
    int (*gtk_init_check)(int *, char ***);
    GtkWidget *(*gtk_window_new)(int);
    void (*gtk_window_set_title)(GtkWidget *, const char *);
    void (*gtk_window_set_default_size)(GtkWidget *, int, int);
    void (*gtk_window_set_decorated)(GtkWidget *, int);
    void (*gtk_widget_show)(GtkWidget *);
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
    unsigned long (*g_signal_connect_data)(void *,const char *,int (*)(GtkWidget *,void *,void *),void *,void *,int);
    void (*gtk_widget_add_events)(GtkWidget *, int);
    LOAD(g_signal_connect_data); LOAD(gtk_widget_add_events);
    LOAD(gdk_event_get_keyval); LOAD(gdk_event_get_button); LOAD(gdk_event_get_state);
    if (!gtk_init_check(NULL, NULL)) { fputs("GTK_WAYLAND_INIT_FAILED\n", stderr); return 1; }
    fputs("GTK_WAYLAND_CONNECTED\n", stderr);
    const char *titles[] = {"Sclereid GTK A", "Sclereid GTK B"};
    unsigned (*gtk_widget_add_tick_callback)(GtkWidget *,int (*)(GtkWidget *,void *,void *),void *,void *);
    LOAD(gtk_widget_add_tick_callback); LOAD(gtk_widget_queue_draw); LOAD(gtk_main_quit);
    LOAD(cairo_set_source_rgb); LOAD(cairo_paint);
    struct animation state[2] = {{0,0},{0,1}};
    for (int i = 0; i < 2; ++i) {
        GtkWidget *window = gtk_window_new(0);
        gtk_window_set_title(window, titles[i]);
        gtk_window_set_default_size(window, 128 + i * 32, 96);
        gtk_window_set_decorated(window, 0);
        gtk_widget_add_events(window,(1<<8)|(1<<9)|(1<<10)|(1<<11)|(1<<21)|(1<<23));
        const char *signals[]={"button-press-event","button-release-event","key-press-event","key-release-event","scroll-event"};
        for(unsigned j=0;j<5;j++) g_signal_connect_data(window,signals[j],observed,i?"B":"A",NULL,0);
        g_signal_connect_data(window,"draw",draw,&state[i],NULL,0);
        gtk_widget_add_tick_callback(window,tick,&state[i],NULL);
        g_signal_connect_data(window,"delete-event",deleted,i?"B":"A",NULL,0);
        if (!i && getenv("M2_MENU")) {
            GtkWidget *(*gtk_menu_new)(void), *(*gtk_menu_item_new)(void);
            void (*gtk_menu_shell_append)(GtkWidget *,GtkWidget *);
            void (*gtk_menu_attach_to_widget)(GtkWidget *,GtkWidget *,void *);
            void (*gtk_widget_set_size_request)(GtkWidget *,int,int);
            LOAD(gtk_menu_new); LOAD(gtk_menu_item_new); LOAD(gtk_menu_shell_append);
            LOAD(gtk_menu_attach_to_widget); LOAD(gtk_menu_popup_at_pointer); LOAD(gtk_widget_set_size_request);
            menu=gtk_menu_new();
            unsigned long (*connect_hide)(void *,const char *,void (*)(GtkWidget *,void *),void *,void *,int);
            *(void **)(&connect_hide)=dlsym(gtk,"g_signal_connect_data");
            connect_hide(menu,"hide",hidden,NULL,NULL,0);
            GtkWidget *item=gtk_menu_item_new();
            gtk_widget_set_size_request(item,64,24);
            gtk_menu_shell_append(menu,item); gtk_widget_show(item);
            gtk_menu_attach_to_widget(menu,window,NULL);
        }
        gtk_widget_show(window);
    }
    gtk_main();
    return 0;
}
