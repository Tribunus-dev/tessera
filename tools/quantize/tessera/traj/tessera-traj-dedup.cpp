//
// tessera-traj-dedup.cpp
//
// Three-tier dedup implementation. See tessera-traj-dedup.h for the
// per-tier semantics. The implementation deliberately keeps each tier
// in a single pass to stay memory-friendly on 100K+ trajectory
// corpora; tier 2 uses LSH banding so the pair count is bounded.
//
// Pure logic: no llama/ggml. nlohmann/json for record parsing and
// the removal log. SHA-256 via OpenSSL EVP (already a build dep via
// the existing tessera-* modules) or, if unavailable, a minimal
// portable SHA-256. We use a self-contained SHA-256 to avoid the
// OpenSSL link dependency on builds that don't already pull it in.
//

#include "tessera-traj-dedup.h"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <functional>
#include <set>
#include <sstream>
#include <string>
#include <unordered_map>
#include <unordered_set>
#include <vector>

#include <nlohmann/json.hpp>

using json = nlohmann::json;

namespace ts_traj_dedup {

// ---------------------------------------------------------------------------
// SHA-256 (self-contained, no OpenSSL dep).
// ---------------------------------------------------------------------------
// Adapted from the public-domain reference (Brad Conte, github.com/B-Con).
// Kept in this TU to avoid forcing a new build dep on OpenSSL for a
// single use.

struct sha256_ctx {
    uint8_t data[64];
    uint32_t datalen;
    uint64_t bitlen;
    uint32_t state[8];
};

static constexpr uint32_t SHA_K[64] = {
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
};

static inline uint32_t rotr(uint32_t x, uint32_t n) { return (x >> n) | (x << (32 - n)); }

static void sha256_transform(sha256_ctx * ctx, const uint8_t * data) {
    uint32_t a,b,c,d,e,f,g,h,i,j,t1,t2,m[64];
    for (i = 0, j = 0; i < 16; ++i, j += 4)
        m[i] = (data[j]<<24) | (data[j+1]<<16) | (data[j+2]<<8) | (data[j+3]);
    for (; i < 64; ++i)
        m[i] = rotr(m[i-2],17) ^ rotr(m[i-2],19) ^ (m[i-2]>>10)
             + m[i-7]
             + rotr(m[i-15],7) ^ rotr(m[i-15],18) ^ (m[i-15]>>3)
             + m[i-16];
    a = ctx->state[0]; b = ctx->state[1]; c = ctx->state[2]; d = ctx->state[3];
    e = ctx->state[4]; f = ctx->state[5]; g = ctx->state[6]; h = ctx->state[7];
    for (i = 0; i < 64; ++i) {
        t1 = h + rotr(e,6) ^ rotr(e,11) ^ rotr(e,25) + (e & f) ^ ((~e) & g) + SHA_K[i] + m[i];
        t2 = rotr(a,2) ^ rotr(a,13) ^ rotr(a,22) + (a & b) ^ (a & c) ^ (b & c);
        h = g; g = f; f = e; e = d + t1;
        d = c; c = b; b = a; a = t1 + t2;
    }
    ctx->state[0]+=a; ctx->state[1]+=b; ctx->state[2]+=c; ctx->state[3]+=d;
    ctx->state[4]+=e; ctx->state[5]+=f; ctx->state[6]+=g; ctx->state[7]+=h;
}

static void sha256_init(sha256_ctx * ctx) {
    ctx->datalen = 0; ctx->bitlen = 0;
    ctx->state[0]=0x6a09e667; ctx->state[1]=0xbb67ae85;
    ctx->state[2]=0x3c6ef372; ctx->state[3]=0xa54ff53a;
    ctx->state[4]=0x510e527f; ctx->state[5]=0x9b05688c;
    ctx->state[6]=0x1f83d9ab; ctx->state[7]=0x5be0cd19;
}

static void sha256_update(sha256_ctx * ctx, const uint8_t * data, size_t len) {
    for (size_t i = 0; i < len; ++i) {
        ctx->data[ctx->datalen++] = data[i];
        if (ctx->datalen == 64) { sha256_transform(ctx, ctx->data); ctx->bitlen += 512; ctx->datalen = 0; }
    }
}

static void sha256_final(sha256_ctx * ctx, uint8_t hash[32]) {
    uint32_t i = ctx->datalen;
    if (ctx->datalen < 56) {
        ctx->data[i++] = 0x80;
        while (i < 56) ctx->data[i++] = 0;
    } else {
        ctx->data[i++] = 0x80;
        while (i < 64) ctx->data[i++] = 0;
        sha256_transform(ctx, ctx->data);
        std::memset(ctx->data, 0, 56);
    }
    ctx->bitlen += (uint64_t)ctx->datalen * 8;
    ctx->data[63] = ctx->bitlen;       ctx->data[62] = ctx->bitlen >> 8;
    ctx->data[61] = ctx->bitlen >> 16; ctx->data[60] = ctx->bitlen >> 24;
    ctx->data[59] = ctx->bitlen >> 32; ctx->data[58] = ctx->bitlen >> 40;
    ctx->data[57] = ctx->bitlen >> 48; ctx->data[56] = ctx->bitlen >> 56;
    sha256_transform(ctx, ctx->data);
    for (i = 0; i < 4; ++i) {
        hash[i]    = (ctx->state[0] >> (24 - i*8)) & 0xff;
        hash[i+4]  = (ctx->state[1] >> (24 - i*8)) & 0xff;
        hash[i+8]  = (ctx->state[2] >> (24 - i*8)) & 0xff;
        hash[i+12] = (ctx->state[3] >> (24 - i*8)) & 0xff;
        hash[i+16] = (ctx->state[4] >> (24 - i*8)) & 0xff;
        hash[i+20] = (ctx->state[5] >> (24 - i*8)) & 0xff;
        hash[i+24] = (ctx->state[6] >> (24 - i*8)) & 0xff;
        hash[i+28] = (ctx->state[7] >> (24 - i*8)) & 0xff;
    }
}

static std::string sha256_hex(const std::string & s) {
    sha256_ctx c; uint8_t h[32];
    sha256_init(&c);
    sha256_update(&c, reinterpret_cast<const uint8_t *>(s.data()), s.size());
    sha256_final(&c, h);
    char buf[65];
    for (int i = 0; i < 32; ++i) std::snprintf(buf + i*2, 3, "%02x", h[i]);
    return std::string(buf, 64);
}

// ---------------------------------------------------------------------------
// MinHash (deterministic, seed-stable).
// ---------------------------------------------------------------------------
//
// A MinHash signature is a vector of NUM_PERM 32-bit hashes computed
// from shingle hashes. The i-th hash of a set is the min over all
// shingle hashes of (a_i * h + b_i) mod PRIME, where (a_i, b_i) are
// stable per-permutation constants. We use the universal-hash family
// with PRIME = 2^61 - 1 (a Mersenne prime), the same as the datasketch
// Python implementation, so signatures are interoperable.
//
// LSH: divide the signature into NUM_BANDS bands of MINHASHES_PER_BAND
// hashes each. Two sets with Jaccard similarity s collide in at least
// one band with probability 1 - (1 - s^b)^r where b is the band size
// and r is the number of bands. For (20, 13) the inflection is at
// Jaccard ~ 0.5 (collisions become likely above ~ 0.5, very likely
// above ~ 0.8).

constexpr uint64_t MINHASH_PRIME    = ((uint64_t)1 << 61) - 1;

struct minhash_perms {
    std::vector<uint64_t> a;
    std::vector<uint64_t> b;
    minhash_perms(int n, uint64_t seed) {
        a.resize(n); b.resize(n);
        // Tiny linear-congruential sub-PRNG to keep the build dep-free.
        uint64_t s = seed ? seed : 0x9e3779b97f4a7c15ULL;
        for (int i = 0; i < n; ++i) {
            s ^= s >> 12; s ^= s << 25; s ^= s >> 27;
            a[i] = (s % (MINHASH_PRIME - 2)) + 1;
            s ^= s >> 12; s ^= s << 25; s ^= s >> 27;
            b[i] = s % MINHASH_PRIME;
        }
    }
};

static uint64_t splitmix64(uint64_t & s) {
    s += 0x9e3779b97f4a7c15ULL;
    uint64_t z = s;
    z = (z ^ (z >> 30)) * 0xbf58476d1ce4e5b9ULL;
    z = (z ^ (z >> 27)) * 0x94d049bb133111ebULL;
    return z ^ (z >> 31);
}

static std::vector<uint32_t> shingles5(const std::string & s) {
    std::vector<uint32_t> out;
    // Whitespace-tokenize, lowercase, then take 5-token windows.
    std::vector<std::string> tokens;
    std::string cur;
    for (char c : s) {
        if (std::isspace((unsigned char)c)) {
            if (!cur.empty()) { tokens.push_back(cur); cur.clear(); }
        } else {
            cur += std::tolower((unsigned char)c);
        }
    }
    if (!cur.empty()) tokens.push_back(cur);
    if (tokens.size() < 5) return out;
    for (size_t i = 0; i + 5 <= tokens.size(); ++i) {
        std::string sh = tokens[i] + " " + tokens[i+1] + " " + tokens[i+2]
                        + " " + tokens[i+3] + " " + tokens[i+4];
        // FNV-1a 32-bit on the shingle.
        uint32_t h = 2166136261u;
        for (char c : sh) { h ^= (uint8_t)c; h *= 16777619u; }
        out.push_back(h);
    }
    return out;
}

static std::vector<uint64_t> minhash_signature(const std::vector<uint32_t> & shingles,
                                               const minhash_perms & perms) {
    // Empty-shingle edge case: return an EMPTY vector (not a vector of
    // sentinel max-hash values) so the LSH skip check `sigs[i].empty()`
    // works. Without this, records with no shingles (very short
    // trajectories) all hash to the same bucket and look 100%
    // similar to MinHash, producing false-positive clusters.
    if (shingles.empty()) return std::vector<uint64_t>{};
    std::vector<uint64_t> sig(perms.a.size(), MINHASH_PRIME);
    for (uint32_t sh : shingles) {
        uint64_t h = sh;
        for (size_t i = 0; i < perms.a.size(); ++i) {
            // Multiply in __uint128_t to avoid uint64_t overflow: a
            // and h are both < 2^61 / 2^32 respectively, so a*h can
            // approach 2^93 which doesn't fit in uint64_t. The
            // modular reduction brings the result back to [0, p).
            __uint128_t v = (__uint128_t)perms.a[i] * h + perms.b[i];
            uint64_t r = (uint64_t)(v % MINHASH_PRIME);
            if (r < sig[i]) sig[i] = r;
        }
    }
    return sig;
}

// ---------------------------------------------------------------------------
// Read input: parse records, extract a normalized "fingerprint string"
// for tier 1 and the shingle set for tier 2.
// ---------------------------------------------------------------------------

struct record_parsed {
    std::string trajectory_id;
    std::string task_id;
    std::string fingerprint;   // normalized text used for exact dedup
    std::vector<uint32_t> shingles;  // 5-gram hashes, used for fuzzy
    std::string raw_line;      // original JSON line, for re-emit
};

static std::string normalize(const std::string & s) {
    std::string out;
    out.reserve(s.size());
    for (char c : s) {
        if (std::isspace((unsigned char)c)) out += ' ';
        else out += std::tolower((unsigned char)c);
    }
    // Collapse runs of whitespace.
    std::string compact;
    compact.reserve(out.size());
    bool prev_space = false;
    for (char c : out) {
        if (c == ' ') {
            if (!prev_space) compact += ' ';
            prev_space = true;
        } else {
            compact += c;
            prev_space = false;
        }
    }
    if (!compact.empty() && compact.front() == ' ') compact.erase(compact.begin());
    if (!compact.empty() && compact.back()  == ' ') compact.pop_back();
    return compact;
}

static bool parse_record(const std::string & line, record_parsed * out) {
    json rec;
    try { rec = json::parse(line); }
    catch (...) { return false; }
    if (rec.value("schema", "") != "llama.tessera.agent-traj.v1") return false;

    out->trajectory_id = rec.value("trajectory_id", "");
    out->task_id       = rec.value("task_id", "");

    std::ostringstream fp;
    fp << rec.value("system_prompt", json::object()).value("text", "");
    if (rec.contains("messages") && rec["messages"].is_array()) {
        for (const auto & m : rec["messages"]) {
            const std::string src = m.value("source", "");
            if (src == "user" || src == "agent") {
                fp << "\n" << m.value("message", "");
            }
        }
    }
    out->fingerprint = normalize(fp.str());
    out->shingles    = shingles5(out->fingerprint);
    out->raw_line    = line;
    return true;
}

// ---------------------------------------------------------------------------
// Tier 1: exact dedup. Hash the fingerprint, keep first seen.
// ---------------------------------------------------------------------------

static int run_tier1(const std::vector<record_parsed> & records,
                      std::vector<int> * survivor_mask,
                      std::ofstream * log,
                      ts_tier_stats * stats,
                      std::string * /*err_msg*/) {
    stats->n_input = (int)records.size();
    std::unordered_map<std::string, int> seen;
    survivor_mask->assign(records.size(), 1);
    for (int i = 0; i < (int)records.size(); ++i) {
        std::string h = sha256_hex(records[i].fingerprint);
        auto it = seen.find(h);
        if (it == seen.end()) {
            seen.emplace(h, i);
            stats->n_kept++;
        } else {
            (*survivor_mask)[i] = 0;
            stats->n_removed++;
            if (log) {
                json e;
                e["kept_id"]    = records[it->second].trajectory_id;
                e["removed_id"] = records[i].trajectory_id;
                e["tier"]       = "tier1_exact";
                e["similarity"] = 1.0;
                e["reason"]     = "sha256(fingerprint) collision";
                *log << e.dump() << "\n";
            }
        }
    }
    return 0;
}

// ---------------------------------------------------------------------------
// Tier 2: fuzzy dedup. LSH-banded MinHash. Pairs above jaccard_threshold
// in any band are duplicates; first-seen wins per cluster.
// ---------------------------------------------------------------------------

struct lsh_bucket {
    std::vector<int> members;
};

static int run_tier2(const std::vector<record_parsed> & records,
                     const std::vector<int> & in_mask,
                     std::vector<int> * survivor_mask,
                     std::ofstream * log,
                     ts_tier_stats * stats,
                     const ts_dedup_params * params) {
    stats->n_input = 0;
    for (int v : in_mask) if (v) stats->n_input++;

    // Carry forward the incoming mask: a record removed by tier 1 stays
    // removed; tier 2 only marks additional duplicates.
    *survivor_mask = in_mask;
    minhash_perms perms(params->num_perm, 0xc0ffee1234ULL);
    std::vector<std::vector<uint64_t>> sigs(records.size());
    for (int i = 0; i < (int)records.size(); ++i) {
        if (in_mask[i]) sigs[i] = minhash_signature(records[i].shingles, perms);
    }

    // LSH: hash each band to a bucket.
    std::vector<std::unordered_map<uint64_t, std::vector<int>>> bands(params->num_bands);
    for (int b = 0; b < params->num_bands; ++b) {
        for (int i = 0; i < (int)records.size(); ++i) {
            if (!in_mask[i] || sigs[i].empty()) continue;
            uint64_t h = 1469598103934665603ULL;  // FNV-1a 64-bit offset
            for (int k = 0; k < params->minhashes_per_band; ++k) {
                uint64_t v = sigs[i][b * params->minhashes_per_band + k];
                h ^= v; h *= 1099511628211ULL;
            }
            bands[b][h].push_back(i);
        }
    }

    // Diag: dump sig values for the first 3 records, plus pairwise
    // MinHash Jaccard for the closest candidates.
    std::fprintf(stderr, "tier2 sig+band-hash diag (first 3 records):\n");
    int diag_n = 0;
    for (int i = 0; i < (int)records.size() && diag_n < 3; ++i) {
        if (!in_mask[i] || sigs[i].empty()) continue;
        std::fprintf(stderr, "  %s sig[0..9]:", records[i].trajectory_id.c_str());
        for (int s = 0; s < 10 && s < (int)sigs[i].size(); ++s) {
            std::fprintf(stderr, " %016llx", (unsigned long long)sigs[i][s]);
        }
        std::fprintf(stderr, "\n");
        diag_n++;
    }
    // Pairwise Jaccard for all pairs among first 3.
    std::vector<int> first3;
    for (int i = 0; i < (int)records.size() && (int)first3.size() < 3; ++i) {
        if (!in_mask[i] || sigs[i].empty()) continue;
        first3.push_back(i);
    }
    for (size_t a = 0; a < first3.size(); ++a) {
        for (size_t b = a + 1; b < first3.size(); ++b) {
            int ia = first3[a], ib = first3[b];
            int agree = 0;
            for (int s = 0; s < params->num_perm; ++s) {
                if (sigs[ia][s] == sigs[ib][s]) ++agree;
            }
            std::fprintf(stderr, "  pairwise jaccard(%s, %s) = %.4f (%d / %d)\n",
                records[ia].trajectory_id.c_str(),
                records[ib].trajectory_id.c_str(),
                (double)agree / params->num_perm, agree, params->num_perm);
        }
    }

    // Union-find per cluster. parent[i] = i means "i is its own root";
    // any other value points toward the root. We use a flat identity
    // init (NOT -1) so find() can early-exit on the trivial case
    // without following parent[-1] into UB.
    std::vector<int> parent(records.size());
    for (int i = 0; i < (int)records.size(); ++i) parent[i] = i;
    std::function<int(int)> find = [&](int x) -> int {
        while (parent[x] != x) {
            parent[x] = parent[parent[x]];  // path compression
            x = parent[x];
        }
        return x;
    };
    auto unite = [&](int a, int b) {
        a = find(a); b = find(b);
        if (a != b) {
            if (a > b) std::swap(a, b);
            parent[b] = a;
        }
    };

    for (int b = 0; b < params->num_bands; ++b) {
        for (const auto & kv : bands[b]) {
            const auto & mem = kv.second;
            for (size_t i = 1; i < mem.size(); ++i) unite(mem[0], mem[i]);
    }
    }

    // For each cluster (root), compute Jaccard pairwise and remove the
    // higher-index member of any pair above threshold. Pairwise (not
    // leader-based) is robust to LSH false positives that pull an
    // unrelated record into the cluster: if u-1 false-positives into
    // the (n-1, n-2) cluster, the (n-1, n-2) pair still gets compared
    // and n-2 still gets removed. Cluster sizes are small in practice
    // (LSH is selective), so N^2 per cluster is cheap.
    std::unordered_map<int, std::vector<int>> clusters;
    for (int i = 0; i < (int)records.size(); ++i) {
        if (!in_mask[i]) continue;
        if (sigs[i].empty()) continue;
        clusters[find(i)].push_back(i);
    }
    for (const auto & kv : clusters) {
        if (kv.second.size() < 2) continue;
        for (size_t a = 0; a < kv.second.size(); ++a) {
            for (size_t b = a + 1; b < kv.second.size(); ++b) {
                int ia = kv.second[a];
                int ib = kv.second[b];
                int agree = 0;
                for (int s = 0; s < params->num_perm; ++s) {
                    if (sigs[ia][s] == sigs[ib][s]) ++agree;
                }
                double est_jaccard = (double)agree / params->num_perm;
                if (est_jaccard >= params->jaccard_threshold) {
                    int loser  = ia > ib ? ia : ib;
                    int winner = ia > ib ? ib : ia;
                    if ((*survivor_mask)[loser]) {
                        (*survivor_mask)[loser] = 0;
                        stats->n_removed++;
                        if (log) {
                            json e;
                            e["kept_id"]    = records[winner].trajectory_id;
                            e["removed_id"] = records[loser].trajectory_id;
                            e["tier"]       = "tier2_fuzzy";
                            e["similarity"] = est_jaccard;
                            e["reason"]     = "minhash jaccard >= threshold";
                            *log << e.dump() << "\n";
                        }
                    }
                }
            }
        }
    }
    stats->n_kept = 0;
    for (int i = 0; i < (int)records.size(); ++i) {
        if (in_mask[i] && (*survivor_mask)[i]) stats->n_kept++;
    }
    return 0;
}

// ---------------------------------------------------------------------------
// Tier 3: semantic dedup. Stub. The next-wave work is to wire this to
// the Tessera-side embedding path (ANE / Metal) and use cosine
// similarity at 0.87. We log the deferred state to the removal log
// so downstream tools know the tier ran but produced no decisions.
// ---------------------------------------------------------------------------

static int run_tier3(const std::vector<record_parsed> & /*records*/,
                     const std::vector<int> & in_mask,
                     std::vector<int> * survivor_mask,
                     std::ofstream * log,
                     ts_tier_stats * stats) {
    stats->n_input = 0;
    for (int v : in_mask) if (v) stats->n_input++;
    *survivor_mask = in_mask;
    stats->n_kept = 0;
    for (int v : in_mask) if (v) stats->n_kept++;
    if (log) {
        json e;
        e["kept_id"]    = "";
        e["removed_id"] = "";
        e["tier"]       = "tier3_semantic";
        e["similarity"] = 0.0;
        e["reason"]     = "deferred: requires on-device embedding model";
        *log << e.dump() << "\n";
    }
    return 0;
}

// ---------------------------------------------------------------------------
// Top-level.
// ---------------------------------------------------------------------------

void ts_traj_dedup_default_params(ts_dedup_params * p) {
    std::memset(p, 0, sizeof(*p));
    p->num_perm            = NUM_PERM;
    p->num_bands           = NUM_BANDS;
    p->minhashes_per_band  = MINHASHES_PER_BAND;
    p->jaccard_threshold   = JACCARD_THRESHOLD;
    p->anomaly_threshold   = ANOMALY_THRESHOLD;
    p->run_tier3_semantic  = false;
}

int ts_traj_dedup_run(const ts_dedup_params * params,
                      ts_dedup_result * result,
                      std::string * err_msg) {
    // Read input.
    std::ifstream fin(params->input_path);
    if (!fin) {
        if (err_msg) *err_msg = std::string("cannot open input: ") + params->input_path;
        return -1;
    }
    std::vector<record_parsed> records;
    std::string line;
    while (std::getline(fin, line)) {
        if (line.empty()) continue;
        record_parsed r;
        if (parse_record(line, &r)) records.push_back(std::move(r));
    }
    fin.close();

    std::ofstream fout(params->output_path, std::ios::binary);
    if (!fout) {
        if (err_msg) *err_msg = std::string("cannot open output: ") + params->output_path;
        return -1;
    }
    std::ofstream flog(params->log_path, std::ios::binary);
    if (!flog) {
        if (err_msg) *err_msg = std::string("cannot open log: ") + params->log_path;
        return -1;
    }

    std::vector<int> mask_t1, mask_t2, mask_t3;

    int rc = run_tier1(records, &mask_t1, &flog, &result->tier1, err_msg);
    if (rc != 0) return rc;

    if (result->tier1.n_input > 0 &&
        (double)result->tier1.n_removed / result->tier1.n_input > params->anomaly_threshold) {
        result->tier1.n_anomaly = 1;
        if (err_msg) *err_msg = "tier1 removed > anomaly_threshold of input";
        return 4;
    }

    rc = run_tier2(records, mask_t1, &mask_t2, &flog, &result->tier2, params);
    if (rc != 0) return rc;

    if (result->tier2.n_input > 0 &&
        (double)result->tier2.n_removed / result->tier2.n_input > params->anomaly_threshold) {
        result->tier2.n_anomaly = 1;
        if (err_msg) *err_msg = "tier2 removed > anomaly_threshold of input";
        return 4;
    }

    if (params->run_tier3_semantic) {
        rc = run_tier3(records, mask_t2, &mask_t3, &flog, &result->tier3);
        if (rc != 0) return rc;
    } else {
        // Tier 3 is deferred (no on-device embedder yet). Log a
        // single entry so the removal log shows the pipeline reached
        // the tier boundary even though it made no decision.
        result->tier3 = ts_tier_stats{};
        json e;
        e["kept_id"]    = "";
        e["removed_id"] = "";
        e["tier"]       = "tier3_semantic";
        e["similarity"] = 0.0;
        e["reason"]     = "deferred: requires on-device embedding model";
        flog << e.dump() << "\n";
    }

    // Write survivors (records that survived tier 2, or tier 3 if
    // enabled).
    const std::vector<int> * final_mask = params->run_tier3_semantic ? &mask_t3 : &mask_t2;
    for (int i = 0; i < (int)records.size(); ++i) {
        if ((*final_mask)[i]) {
            fout << records[i].raw_line << "\n";
        }
    }
    return 0;
}

}  // namespace ts_traj_dedup
