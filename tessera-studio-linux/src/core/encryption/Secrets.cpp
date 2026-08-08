#include "Secrets.h"
#include <libsecret/secret.h>
#include <glib.h>

namespace tessera {

static const SecretSchema kTesseraSchema = {
    "org.tessera.Secret",
    SECRET_SCHEMA_NONE,
    {
        {"service", SECRET_SCHEMA_ATTRIBUTE_STRING},
        {"key", SECRET_SCHEMA_ATTRIBUTE_STRING},
        {NULL, SECRET_SCHEMA_ATTRIBUTE_STRING}
    }
};

bool SecretStore::store(const std::string &service, const std::string &key, const std::string &value) {
    if (service.empty() || key.empty()) return false;
    std::string label = service + "/" + key;
    GError *err = nullptr;
    gboolean ok = secret_password_store_sync(
        &kTesseraSchema, SECRET_COLLECTION_DEFAULT,
        label.c_str(), value.c_str(),
        nullptr, &err,
        "service", service.c_str(),
        "key", key.c_str(),
        nullptr);
    if (err) { g_error_free(err); return false; }
    return ok == TRUE;
}

std::string SecretStore::load(const std::string &service, const std::string &key) {
    if (service.empty() || key.empty()) return "";
    GError *err = nullptr;
    gchar *pw = secret_password_lookup_sync(
        &kTesseraSchema, nullptr, &err,
        "service", service.c_str(),
        "key", key.c_str(),
        nullptr);
    if (err) { g_error_free(err); return ""; }
    if (!pw) return "";
    std::string out(pw);
    secret_password_free(pw);
    return out;
}

bool SecretStore::remove(const std::string &service, const std::string &key) {
    if (service.empty() || key.empty()) return false;
    GError *err = nullptr;
    gboolean ok = secret_password_clear_sync(
        &kTesseraSchema, nullptr, &err,
        "service", service.c_str(),
        "key", key.c_str(),
        nullptr);
    if (err) { g_error_free(err); return false; }
    return ok == TRUE;
}

} // namespace tessera
