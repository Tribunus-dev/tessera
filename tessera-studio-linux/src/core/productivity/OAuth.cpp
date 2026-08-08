#include "OAuth.h"
#include "core/encryption/Secrets.h"
#include <cstdlib>
#include <algorithm>
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
} // namespace tessera
