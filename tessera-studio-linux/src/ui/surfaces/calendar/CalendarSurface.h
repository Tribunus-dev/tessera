#pragma once
#include <gtk/gtk.h>
namespace tessera { class ProductivityStore; GtkWidget* calendar_surface_new(ProductivityStore *store=nullptr); }
