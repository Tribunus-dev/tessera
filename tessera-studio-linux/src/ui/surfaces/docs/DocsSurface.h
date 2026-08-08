#pragma once
#include <gtk/gtk.h>
namespace tessera {
GtkWidget* docs_surface_new(class DataLayer* dl, class DocStore* store);
}
