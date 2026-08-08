#pragma once
#include <gtk/gtk.h>
namespace tessera { class DataLayer; class TasksSurface{public:void show();}; GtkWidget* tasks_surface_new(DataLayer *dl=nullptr); }
