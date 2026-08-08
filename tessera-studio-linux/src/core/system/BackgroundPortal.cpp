#include "BackgroundPortal.h"
#include <gio/gio.h>
namespace tessera {
bool BackgroundPortal::request(const std::string &reason, bool autostart, bool background, bool dbus_activatable){
    (void)reason; (void)autostart; (void)background; (void)dbus_activatable;
    GDBusConnection *bus = g_bus_get_sync(G_BUS_TYPE_SESSION, nullptr, nullptr);
    if(!bus) { last_error="no session bus"; return false; }
    GVariantBuilder b; g_variant_builder_init(&b, G_VARIANT_TYPE("a{sv}"));
    g_variant_builder_add(&b, "{sv}", "reason", g_variant_new_string(reason.c_str()));
    g_variant_builder_add(&b, "{sv}", "autostart", g_variant_new_boolean(autostart));
    g_variant_builder_add(&b, "{sv}", "background", g_variant_new_boolean(background));
    g_variant_builder_add(&b, "{sv}", "dbus-activatable", g_variant_new_boolean(dbus_activatable));
    GError *err=nullptr;
    GVariant *ret = g_dbus_connection_call_sync(bus, "org.freedesktop.portal.Desktop",
        "/org/freedesktop/portal/desktop","org.freedesktop.portal.Background","RequestBackground",
        g_variant_new("(sa{sv})","", &b), nullptr, G_DBUS_CALL_FLAGS_NONE, 2000, nullptr, &err);
    g_object_unref(bus);
    if(err){ last_error=err->message; g_error_free(err); return false; }
    if(ret) g_variant_unref(ret);
    return true;
}
bool BackgroundPortal::is_supported() const { return true; }
} // namespace
