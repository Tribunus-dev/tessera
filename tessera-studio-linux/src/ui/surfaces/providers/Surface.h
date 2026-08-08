#pragma once
#include <gtk/gtk.h>
namespace tessera {
GtkWidget* providers_surface_new();
void providers_surface_refresh(GtkWidget *view);
}
