#pragma once
#include <filesystem>
#include <string>
#include <vector>

namespace tessera {

// Mirrors TesseraCLIBinaryResolver precedence:
// 1. override path, 2. $HOME/.local/opt/tessera/bin/tessera-cli,
// 3. /usr/local/bin/tessera-cli, /usr/bin/tessera-cli,
// 4. build dir, 5. $PATH
std::filesystem::path resolve_cli_binary(const std::string &override_path = "");
std::vector<std::filesystem::path> cli_search_paths(const std::string &override_path);

} // namespace tessera
