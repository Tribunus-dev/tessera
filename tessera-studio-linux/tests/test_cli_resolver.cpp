#include "../src/core/cli_resolver.h"
#include <cassert>
int main(){ auto p=tessera::resolve_cli_binary("/nonexistent"); (void)p; auto v=tessera::cli_search_paths(""); assert(!v.empty()); return 0; }
