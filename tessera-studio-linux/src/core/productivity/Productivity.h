#pragma once
#include <string>
#include <vector>
namespace tessera {
// Contacts: libEBook/libedataserver + CardDAV + VCard
struct Contact{ std::string id, name, email, vcard; };
// Calendar: libedataserver + CalDAV + libical
struct CalendarEvent{ std::string id, title, ical; };
// Reminders: CalDAV VTODO + libnotify/GNotification
struct Reminder{ std::string id, title; bool done=false; };
// Mail: libetpan SMTP+IMAP RFC822
struct Email{ std::string id, subject, body; };
class ProductivityStore{
public:
    std::vector<Contact> contacts();
    std::vector<CalendarEvent> events();
    std::vector<Reminder> reminders();
    std::vector<Email> emails();
    // sync on worker thread, never GTK thread — spec 7.3
    void sync_all();
};
} // namespace tessera
