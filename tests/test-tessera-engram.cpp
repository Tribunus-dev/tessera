#include "engram_hash.h"

#include <cstdint>
#include <vector>

// This project's default CMake build is Release (-DNDEBUG), which compiles
// a plain assert() to nothing - the checks below would silently never run.
// Force live assertions the same way tests/test-tessera-config.cpp does:
// undef NDEBUG and re-include <cassert> so its macro re-expands to the
// checking form regardless of the command-line -DNDEBUG.
#undef NDEBUG
#include <cassert>

int main() {
    const tessera::engram_hash_spec spec = {
        2,
        { 9223372036854775783ULL, 6364136223846793005ULL, 1442695040888963407ULL },
        { { 1000003, 1000033 }, { 1000037, 1000039 } },
    };
    const std::vector<int64_t> tokens = { 11, 29, 7, 101 };
    const std::vector<std::vector<int64_t>> expected = {
        { 878069, 36645, 698767, 77576 },
        { 344386, 424009, 913775, 773338 },
        { 625000, 156591, 440802, 282000 },
        { 588704, 351169, 55449, 302372 },
    };
    for (size_t position = 0; position < tokens.size(); ++position) {
        assert(tessera::engram_hash_position(tokens.data(), position, spec) == expected[position]);
    }
    return 0;
}
