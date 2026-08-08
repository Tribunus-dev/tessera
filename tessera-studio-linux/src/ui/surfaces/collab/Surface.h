#pragma once
#include <gtk/gtk.h>
namespace tessera {
GtkWidget* collab_surface_new();
void collab_log_append(const char* from, const char* text);
}
