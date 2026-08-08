#include "cli_resolver.h"
#include <cstdlib>
#include <filesystem>

namespace tessera {

std::vector<std::filesystem::path> cli_search_paths(const std::string &override_path) {
    std::vector<std::filesystem::path> out;
    if (!override_path.empty()) {
        out.emplace_back(override_path);
    }
    if (const char *home = std::getenv("HOME")) {
        out.emplace_back(std::filesystem::path(home) / ".local/opt/tessera/bin/tessera-cli");
    }
    out.emplace_back("/usr/local/bin/tessera-cli");
    out.emplace_back("/usr/bin/tessera-cli");
    // git-source build dir relative to this file's location or cwd
    out.emplace_back("build/bin/tessera-cli");
    out.emplace_back("build/bin/llama-cli");
    return out;
}

std::filesystem::path resolve_cli_binary(const std::string &override_path) {
    auto paths = cli_search_paths(override_path);
    for (auto &p : paths) {
        std::error_code ec;
        if (std::filesystem::exists(p, ec) && std::filesystem::is_regular_file(p, ec)) {
            return p;
        }
    }
    // fallback: search PATH
    if (const char *path_env = std::getenv("PATH")) {
        std::string s(path_env);
        size_t start = 0;
        while (start < s.size()) {
            size_t end = s.find(':', start);
            if (end == std::string::npos) end = s.size();
            auto dir = s.substr(start, end - start);
            auto cand = std::filesystem::path(dir) / "tessera-cli";
            std::error_code ec;
            if (std::filesystem::exists(cand, ec)) return cand;
            start = end + 1;
        }
    }
    return {};
}

} // namespace tessera
