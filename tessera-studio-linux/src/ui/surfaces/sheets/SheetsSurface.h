#pragma once
#include <gtk/gtk.h>
namespace tessera { GtkWidget* sheets_surface_new(class DataLayer* dl, class SheetStore* store); GtkWidget* slides_surface_new(class DataLayer* dl, class SlideStore* store); }
