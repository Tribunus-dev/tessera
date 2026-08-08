#pragma once
#include <string>
namespace tessera {
// OAuth2 for major email providers — spec: Gmail, iCloud, Microsoft first-class
enum class EmailProvider { Generic, Gmail, ICloud, Outlook };
EmailProvider detect_email_provider(const std::string &email_or_url);
std::string oauth_token_for(const std::string &provider_id); // e.g. gmail, icloud, outlook
bool store_oauth_token(const std::string &provider_id, const std::string &access_token, const std::string &refresh_token="");
struct OAuthCreds { std::string access_token; std::string refresh_token; std::string email; };
OAuthCreds load_oauth_creds(const std::string &provider_id);
std::string xoauth2_string(const std::string &email, const std::string &access_token);
// Refresh flow — first-class per user decision (gmail, outlook, icloud)
std::string refresh_oauth_token(const std::string &provider_id);
std::string get_valid_access_token(const std::string &provider_id); // refresh if expired
bool is_token_expired(const std::string &provider_id);
} // namespace tessera
