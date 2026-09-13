#!/usr/bin/env bash
#
# Prove this checkout produces the recorded module, and that it does so repeatably.
#
#   ./verification/verify-build.sh
#
# Four checks, in increasing strength:
#   1. the toolchain is the pinned one
#   2. a build matches the md5 recorded in build/BUILD.md
#   3. two consecutive builds are byte-identical
#   4. a build from a DIFFERENT directory is byte-identical
#
# Check 5 is the substantive one. A build that reproduces only in its own directory is
# repeatable, not reproducible: Motoko records path-derived type suffixes inside the module.
set -u
cd "$(dirname "$0")/.."
ROOT="$(pwd -P)"

EXPECTED_MD5=7dd8a3d10c70929d6fbcc55dd1284c80
EXPECTED_MOC="1.4.1"

pass=0; fail=0
ok(){ if [ "$2" = "$3" ]; then pass=$((pass+1)); printf "  ok   %-50s %s\n" "$1" "$2"
      else fail=$((fail+1)); printf "  FAIL %-50s got=%s want=%s\n" "$1" "$2" "$3"; fi; }

echo "== 1. toolchain =="
MOC=$(moc --version 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
ok "moc version" "$MOC" "$EXPECTED_MOC"

echo "== 2. dependencies resolve from the lockfile =="
mops install >/dev/null 2>&1
for d in .mops/core@2.4.0 .mops/sha2@0.1.9; do
  [ -d "$d" ] && ok "$d present" yes yes || ok "$d present" no yes
done

echo "== 3. the build matches what is recorded =="
mkdir -p build
moc -o /tmp/vb1.wasm $(mops sources) src/Redemption.mo 2>/dev/null
GOT=$(md5sum /tmp/vb1.wasm | cut -d' ' -f1)
ok "module md5" "$GOT" "$EXPECTED_MD5"

echo "== 4. repeatable: two consecutive builds agree =="
moc -o /tmp/vb2.wasm $(mops sources) src/Redemption.mo 2>/dev/null
if cmp -s /tmp/vb1.wasm /tmp/vb2.wasm; then ok "consecutive builds byte-identical" yes yes
else ok "consecutive builds byte-identical" no yes; fi

echo "== 5. reproducible: a build from another directory agrees =="
# This separates a build that happens to work in one location from one that reproduces. If it fails, the module
# has picked up an absolute path, almost always because a stable type is now defined in a
# dependency, or because the source was passed to moc as an absolute path.
ALT=$(mktemp -d)
cp -r "$ROOT"/. "$ALT"/ 2>/dev/null
( cd "$ALT" && moc -o /tmp/vb3.wasm $(mops sources) src/Redemption.mo 2>/dev/null )
if cmp -s /tmp/vb1.wasm /tmp/vb3.wasm; then ok "cross-directory build byte-identical" yes yes
else
  ok "cross-directory build byte-identical" no yes
  echo "       divergent sections:"
  python3 verification/wasm_sections.py /tmp/vb1.wasm 2>/dev/null | head -20
fi
rm -rf "$ALT"

echo
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ] || exit 1
