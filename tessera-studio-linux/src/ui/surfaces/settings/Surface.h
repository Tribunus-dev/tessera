#pragma once
#include <gtk/gtk.h>
namespace tessera {
GtkWidget* settings_window_new(GtkWindow *parent);
GtkWidget* settings_surface_new();
void show_settings(GtkWindow *parent);
void show_shortcuts(GtkWindow *parent);
void show_about(GtkWindow *parent);
} // namespace tessera
