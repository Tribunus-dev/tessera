#pragma once
#include <gtk/gtk.h>
namespace tessera {
GtkWidget* models_surface_new();
GtkWidget* models_fetch_dialog_new(GtkWindow *parent);
}
