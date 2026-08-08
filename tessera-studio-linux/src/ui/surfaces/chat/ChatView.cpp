#include "ChatView.h"

#ifdef HAVE_GTK
#include <gtk/gtk.h>
#include <adwaita.h>
#endif

namespace tessera {
#ifdef HAVE_GTK
static void on_send(GtkButton *, gpointer) {}
#endif
} // namespace tessera
