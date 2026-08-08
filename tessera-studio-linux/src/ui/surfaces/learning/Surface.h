#pragma once
#include <gtk/gtk.h>
namespace tessera {
class DataLayer;
GtkWidget* learning_dashboard_new(DataLayer *dl);
} // namespace tessera
