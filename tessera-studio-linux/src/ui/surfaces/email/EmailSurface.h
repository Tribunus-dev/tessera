#pragma once
#include <gtk/gtk.h>
namespace tessera { class DataLayer; class ProductivityStore; GtkWidget* email_surface_new(DataLayer *dl=nullptr, ProductivityStore *pstore=nullptr); GtkWidget* runs_surface_new(DataLayer *dl=nullptr); GtkWidget* learning_surface_new(DataLayer *dl=nullptr); }
