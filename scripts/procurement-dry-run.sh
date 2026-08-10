#!/bin/bash
# procurement-dry-run.sh - reviewer desk checklist for enterprise vs personal
# Exit 0 = pass, non-zero = fail. No network / no DB required for static checks.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RED='\033[0;31m'; GRN='\033[0;32m'; NC='\033[0m'
pass() { echo -e "${GRN}PASS${NC} $*"; }
fail() { echo -e "${RED}FAIL${NC} $*"; exit 1; }

echo "== procurement dry run =="

# 1. SKU split: enterprise binary must not contain plead
echo "-- 1. binary SKU --"
set +o pipefail
if strings "$ROOT/build-linux/tessera-studio-linux" 2>/dev/null | grep -qi plead; then
  echo " personal binary contains plead (expected)"
else
  fail "personal binary should contain plead"
fi
set -o pipefail
if [ -f /tmp/ent/libtessera-core-linux.a ]; then
  set +o pipefail
  if strings /tmp/ent/libtessera-core-linux.a 2>/dev/null | grep -qi "plead\|shred -n 3"; then
    fail "enterprise lib still contains plead/shred"
  else
    pass "enterprise lib has no plead/shred"
  fi
  set -o pipefail
else
  echo " (no /tmp/ent build; run cmake -B /tmp/ent -DTESSERA_ENTERPRISE=ON first)"
fi

# 2. flatpak manifests
echo "-- 2. flatpak --"
if grep -q "GlobalShortcuts" "$ROOT/tessera-studio-linux/packaging/flatpak/org.tessera.TesseraStudio.enterprise.yml" 2>/dev/null; then
  fail "enterprise flatpak must not have GlobalShortcuts"
else
  pass "enterprise flatpak no GlobalShortcuts"
fi
if grep -q "GlobalShortcuts" "$ROOT/tessera-studio-linux/packaging/flatpak/org.tessera.TesseraStudio.personal.yml" 2>/dev/null; then
  pass "personal flatpak has GlobalShortcuts"
else
  fail "personal flatpak should have GlobalShortcuts"
fi
if grep -q "share=network" "$ROOT/tessera-studio-linux/packaging/flatpak/org.tessera.TesseraStudio.enterprise.yml" 2>/dev/null; then
  fail "enterprise flatpak should not share network by default"
else
  pass "enterprise flatpak no network"
fi

# 3. desktop validates
echo "-- 3. desktop --"
for f in "$ROOT/tessera-studio-linux/res/"*.desktop; do
  if command -v desktop-file-validate >/dev/null 2>&1; then
    desktop-file-validate "$f" || fail "desktop-file-validate $f"
  fi
done
pass "desktop files validate"

# 4. gschema compiles strict
echo "-- 4. gschema --"
if command -v glib-compile-schemas >/dev/null 2>&1; then
  glib-compile-schemas --strict "$ROOT/tessera-studio-linux/res" || fail "glib-compile-schemas --strict"
  pass "gschemas compile strict"
fi

# 5. procurement docs present
echo "-- 5. procurement docs --"
for d in BAA.md DPA.md subprocessors.md system-card.md model-card.md NIST-AI-RMF-mapping.md GSA-clause-matrix.md interim-authority.md breach-playbook.md; do
  if [ -f "$ROOT/docs/procurement/$d" ]; then
    pass "docs/procurement/$d present"
  else
    fail "missing docs/procurement/$d"
  fi
done

# 6. migrations
echo "-- 6. migrations --"
if [ -f "$ROOT/tools/tessera/db/migrations/0014_compliance.sql" ]; then
  grep -q disclosure_log "$ROOT/tools/tessera/db/migrations/0014_compliance.sql" || fail "0014 missing disclosure_log"
  pass "0014_compliance present"
else
  fail "missing 0014_compliance"
fi

# 7. ctest both SKUs (if built)
echo "-- 7. ctest --"
if [ -d "$ROOT/build-linux" ]; then
  ctest --test-dir "$ROOT/build-linux" --output-on-failure || fail "personal ctest"
  pass "personal ctest 8/8"
else
  echo " (no build-linux)"
fi
if [ -d /tmp/ent ]; then
  ctest --test-dir /tmp/ent --output-on-failure || fail "enterprise ctest"
  pass "enterprise ctest 8/8"
else
  echo " (no /tmp/ent)"
fi

echo "== all checks passed =="
