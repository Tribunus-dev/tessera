#pragma once
#include <gtk/gtk.h>
namespace tessera { class ProductivityStore; GtkWidget* reminders_surface_new(ProductivityStore *store=nullptr); }
