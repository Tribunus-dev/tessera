#pragma once
#include <gtk/gtk.h>
namespace tessera {
class DataLayer;
// Force-directed graph viz — GTK-native, no Grape simd/KDTree, Adwaita palette only
// 60fps g_thread sim → g_idle queue_draw, click selects node for inspector
GtkWidget* graph_view_new(DataLayer *dl);
void graph_view_refresh(GtkWidget *view);
} // namespace tessera
