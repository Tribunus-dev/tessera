#pragma once
#include <gtk/gtk.h>
#include <string>
#include "core/provider.h"

namespace tessera {

// iMessage-inspired, Fedora-native — Adwaita palette only (taste anti-slop)
// user: @accent_bg_color pill with tail (18/18/4/18), assistant: @view_bg_color with border + tail (18/18/18/4)
// centered timestamp pills between groups, avatar 24px, status caption below bubble
GtkWidget* chat_bubble_new(ChatRole role, const std::string &content, bool is_streaming, const std::string &stream_text="Generating...");
GtkWidget* chat_timestamp_new(const std::string &text);
void chat_bubble_set_streaming(GtkWidget *bubble, bool streaming);
// Group chat tool call — funny, engaging, Adwaita card with left accent (no emoji overload)
GtkWidget* chat_tool_call_new(ChatRole role, const std::string &tool, const std::string &funny_detail, bool running);
std::string funny_tool_line(ChatRole role, const std::string &tool, const std::string &prompt_hint);

} // namespace tessera
