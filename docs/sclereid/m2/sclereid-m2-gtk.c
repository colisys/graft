#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>

typedef struct GtkWidget GtkWidget;
#define LOAD(name) do { *(void **)(&name) = dlsym(gtk, #name); if (!name) { fprintf(stderr, "%s\n", dlerror()); return 1; } } while (0)

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
    if (!gtk_init_check(NULL, NULL)) { fputs("GTK_WAYLAND_INIT_FAILED\n", stderr); return 1; }
    fputs("GTK_WAYLAND_CONNECTED\n", stderr);
    const char *titles[] = {"Sclereid GTK A", "Sclereid GTK B"};
    for (int i = 0; i < 2; ++i) {
        GtkWidget *window = gtk_window_new(0);
        gtk_window_set_title(window, titles[i]);
        gtk_window_set_default_size(window, 128 + i * 32, 96);
        gtk_window_set_decorated(window, 0);
        gtk_widget_show(window);
    }
    gtk_main();
    return 0;
}
