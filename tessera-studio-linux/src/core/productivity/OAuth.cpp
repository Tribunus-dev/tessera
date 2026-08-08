#include "OAuth.h"
#include "core/encryption/Secrets.h"
#include <cstdlib>
#include <algorithm>
#include <ctime>
#include <cstdio>
#ifdef HAVE_LIBSOUP
#include <libsoup/soup.h>
#endif
namespace tessera {
EmailProvider detect_email_provider(const std::string &s){
    std::string t=s; for(char &c:t) c=tolower(c);
    if(t.find("gmail.com")!=std::string::npos || t.find("googlemail")!=std::string::npos) return EmailProvider::Gmail;
    if(t.find("icloud.com")!=std::string::npos || t.find("me.com")!=std::string::npos || t.find("mac.com")!=std::string::npos) return EmailProvider::ICloud;
    if(t.find("outlook.com")!=std::string::npos || t.find("hotmail.com")!=std::string::npos || t.find("office365")!=std::string::npos || t.find("microsoft")!=std::string::npos) return EmailProvider::Outlook;
    return EmailProvider::Generic;
}
std::string oauth_token_for(const std::string &pid){
    if(pid.empty()) return "";
    SecretStore ss;
    std::string tok = ss.load("tessera", "oauth-" + pid);
    if(!tok.empty()) return tok;
    // env fallback: TESSERA_GMAIL_TOKEN, etc
    std::string env = "TESSERA_" + pid + "_TOKEN";
    for(char &c: env) c=toupper(c);
    if(const char *v=getenv(env.c_str())) return v;
    if(pid=="gmail" && getenv("GMAIL_ACCESS_TOKEN")) return getenv("GMAIL_ACCESS_TOKEN");
    if(pid=="outlook" && getenv("OUTLOOK_ACCESS_TOKEN")) return getenv("OUTLOOK_ACCESS_TOKEN");
    if(pid=="icloud" && getenv("ICLOUD_TOKEN")) return getenv("ICLOUD_TOKEN");
    return "";
}
bool store_oauth_token(const std::string &pid, const std::string &access, const std::string &refresh){
    if(pid.empty() || access.empty()) return false;
    SecretStore ss;
    bool ok = ss.store("tessera", "oauth-" + pid, access);
    if(!refresh.empty()) ss.store("tessera", "oauth-" + pid + "-refresh", refresh);
    return ok;
}
OAuthCreds load_oauth_creds(const std::string &pid){
    OAuthCreds c;
    SecretStore ss;
    c.access_token = ss.load("tessera", "oauth-" + pid);
    c.refresh_token = ss.load("tessera", "oauth-" + pid + "-refresh");
    c.email = ss.load("tessera", "oauth-" + pid + "-email");
    if(c.access_token.empty()){
        c.access_token = oauth_token_for(pid);
    }
    if(c.email.empty()){
        if(const char *e=getenv("TESSERA_EMAIL")) c.email=e;
        else if(pid=="gmail" && getenv("GMAIL_EMAIL")) c.email=getenv("GMAIL_EMAIL");
        else if(pid=="outlook" && getenv("OUTLOOK_EMAIL")) c.email=getenv("OUTLOOK_EMAIL");
    }
    return c;
}
std::string xoauth2_string(const std::string &email, const std::string &token){
    // XOAUTH2 format: base64("user=" + email + "\x01auth=Bearer " + token + "\x01\x01")
    std::string raw = "user=" + email + "\x01auth=Bearer " + token + "\x01\x01";
    // simple base64
    static const char tbl[]="ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    std::string out;
    int val=0, bits=-6;
    for(unsigned char c: raw){
        val = (val<<8) + c; bits+=8;
        while(bits>=0){ out.push_back(tbl[(val>>bits)&0x3F]); bits-=6; }
    }
    if(bits>-6) out.push_back(tbl[((val<<8)>>(bits+8))&0x3F]);
    while(out.size()%4) out.push_back('=');
    return out;
}
bool is_token_expired(const std::string &pid){
    SecretStore ss;
    std::string exp = ss.load("tessera", "oauth-" + pid + "-expiry");
    if(exp.empty()) return false; // no expiry stored — assume valid
    try{
        long long expiry = std::stoll(exp);
        long long now = time(nullptr);
        return now >= expiry - 60; // refresh 60s before expiry
    } catch(...){ return false; }
}
std::string refresh_oauth_token(const std::string &pid){
    if(pid.empty()) return "";
    // iCloud uses app-specific password — no refresh (handled above, but keep early exit)
    if(pid=="icloud") return oauth_token_for(pid);
    SecretStore ss;
    std::string refresh = ss.load("tessera", "oauth-" + pid + "-refresh");
    if(refresh.empty()){
        // try env
        std::string env = "TESSERA_" + pid + "_REFRESH_TOKEN";
        for(char &c: env) c=toupper(c);
        if(const char *v=getenv(env.c_str())) refresh=v;
        else if(pid=="gmail" && getenv("GMAIL_REFRESH_TOKEN")) refresh=getenv("GMAIL_REFRESH_TOKEN");
        else if(pid=="outlook" && getenv("OUTLOOK_REFRESH_TOKEN")) refresh=getenv("OUTLOOK_REFRESH_TOKEN");
    }
    if(refresh.empty()) return "";
    std::string client_id, client_secret;
    // Try libsecret first, then env
    client_id = ss.load("tessera", "oauth-" + pid + "-client-id");
    client_secret = ss.load("tessera", "oauth-" + pid + "-client-secret");
    if(client_id.empty()){
        std::string env = "TESSERA_" + pid + "_CLIENT_ID";
        for(char &c: env) c=toupper(c);
        if(const char *v=getenv(env.c_str())) client_id=v;
        else if(pid=="gmail" && getenv("GMAIL_CLIENT_ID")) client_id=getenv("GMAIL_CLIENT_ID");
        else if(pid=="outlook" && getenv("OUTLOOK_CLIENT_ID")) client_id=getenv("OUTLOOK_CLIENT_ID");
    }
    if(client_secret.empty()){
        std::string env = "TESSERA_" + pid + "_CLIENT_SECRET";
        for(char &c: env) c=toupper(c);
        if(const char *v=getenv(env.c_str())) client_secret=v;
        else if(pid=="gmail" && getenv("GMAIL_CLIENT_SECRET")) client_secret=getenv("GMAIL_CLIENT_SECRET");
        else if(pid=="outlook" && getenv("OUTLOOK_CLIENT_SECRET")) client_secret=getenv("OUTLOOK_CLIENT_SECRET");
    }
    std::string token_url, body;
    if(pid=="gmail"){
        token_url = "https://oauth2.googleapis.com/token";
        body = "client_id=" + client_id + "&client_secret=" + client_secret + "&refresh_token=" + refresh + "&grant_type=refresh_token";
    } else if(pid=="outlook"){
        token_url = "https://login.microsoftonline.com/common/oauth2/v2.0/token";
        std::string scope = "https://outlook.office365.com/.default";
        if(const char *s=getenv("OUTLOOK_SCOPE")) scope=s;
        body = "client_id=" + client_id + "&refresh_token=" + refresh + "&grant_type=refresh_token&scope=" + scope;
        if(!client_secret.empty()) body += "&client_secret=" + client_secret;
    } else if(pid=="icloud"){
        // iCloud app-specific password has no refresh — treat as static
        return oauth_token_for(pid);
    } else {
        return "";
    }
    // HTTP POST via libsoup if available, else fallback to empty
#ifdef HAVE_LIBSOUP
    SoupSession *session = soup_session_new();
    SoupMessage *msg = soup_message_new("POST", token_url.c_str());
    soup_message_set_request_body_from_bytes(msg, "application/x-www-form-urlencoded", g_bytes_new(body.c_str(), body.size()));
    GError *err=nullptr;
    GBytes *resp = soup_session_send_and_read(session, msg, nullptr, &err);
    std::string new_access;
    if(!err && resp){
        size_t sz; const char *data = (const char*)g_bytes_get_data(resp, &sz);
        std::string raw(data?data:"", sz);
        // naive JSON parse: find "access_token":"..."
        auto p = raw.find("\"access_token\"");
        if(p!=std::string::npos){
            auto colon = raw.find(':', p);
            auto q1 = raw.find('"', colon+1);
            auto q2 = raw.find('"', q1+1);
            if(q1!=std::string::npos && q2!=std::string::npos){
                new_access = raw.substr(q1+1, q2-q1-1);
                // also try to get expires_in
                long long expires_in = 3600;
                auto pe = raw.find("\"expires_in\"");
                if(pe!=std::string::npos){
                    auto ce = raw.find(':', pe);
                    auto end = raw.find_first_of(",}", ce+1);
                    try{ expires_in = std::stoll(raw.substr(ce+1, end-ce-1)); } catch(...){}
                }
                long long expiry = time(nullptr) + expires_in;
                ss.store("tessera", "oauth-" + pid, new_access);
                ss.store("tessera", "oauth-" + pid + "-expiry", std::to_string(expiry));
                // optionally store new refresh_token if rotated
                auto pr = raw.find("\"refresh_token\"");
                if(pr!=std::string::npos){
                    auto cr = raw.find(':', pr);
                    auto qr1 = raw.find('"', cr+1);
                    auto qr2 = raw.find('"', qr1+1);
                    if(qr1!=std::string::npos && qr2!=std::string::npos){
                        std::string new_refresh = raw.substr(qr1+1, qr2-qr1-1);
                        ss.store("tessera", "oauth-" + pid + "-refresh", new_refresh);
                    }
                }
            }
        }
        g_bytes_unref(resp);
    }
    if(err) g_error_free(err);
    g_object_unref(msg);
    g_object_unref(session);
    if(!new_access.empty()) return new_access;
#endif
    // Fallback: try curl via popen if libsoup not available
    std::string cmd = "curl -s -X POST -d '" + body + "' '" + token_url + "' 2>/dev/null";
    FILE *pp = popen(cmd.c_str(), "r");
    if(pp){
        char buf[2048]; std::string out;
        while(fgets(buf,sizeof(buf),pp)) out+=buf;
        pclose(pp);
        auto p2 = out.find("\"access_token\"");
        if(p2!=std::string::npos){
            auto colon = out.find(':', p2);
            auto q1 = out.find('"', colon+1);
            auto q2 = out.find('"', q1+1);
            if(q1!=std::string::npos && q2!=std::string::npos){
                std::string new_access = out.substr(q1+1, q2-q1-1);
                ss.store("tessera", "oauth-" + pid, new_access);
                return new_access;
            }
        }
    }
    return "";
}
std::string get_valid_access_token(const std::string &pid){
    if(pid.empty()) return "";
    std::string tok = oauth_token_for(pid);
    if(tok.empty()) return "";
    if(is_token_expired(pid)){
        std::string refreshed = refresh_oauth_token(pid);
        if(!refreshed.empty()) return refreshed;
    }
    return tok;
}
} // namespace tessera
