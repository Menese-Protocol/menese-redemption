#!/usr/bin/env bash
#
# Reproduce the redemption module.
#
#   docker build -t redemption-builder -f docker/Dockerfile .
#   docker run --rm -v "$PWD":/menese-redemption -w /menese-redemption \
#     redemption-builder ./docker/build.sh
#
# It also runs natively if your dfx is 0.32.0 / moc 1.4.1. The image exists to pin that,
# not to pin the directory, see below.
#
# WHAT ACTUALLY DETERMINES THE HASH, measured on this canister
# -----------------------------------------------------------------------
# moc writes an `icp:private motoko:stable-types` section naming every stable type with a
# numeric disambiguator, `Entry__449410820`. The widely-held rule is that
# the disambiguator is derived from ABSOLUTE paths, so the checkout directory and every
# `.mops/` path have to be reproduced exactly. That is very nearly right, and the part it
# gets wrong is the part that matters here.
#
# The disambiguator follows the path of the file DEFINING each stable type, exactly as moc
# is given it. Every stable type in this canister (Entry, Payout, Progress, Source,
# Status) is defined in `src/Types.mo`, and none comes from a package. Measured:
#
#   relative source + relative packages -> 8196485adbba80dade277961d2436a32
#   relative source + ABSOLUTE packages -> 8196485adbba80dade277961d2436a32   (identical)
#   ABSOLUTE source + relative packages -> 29b6fb36f0fcc832d872076f2e013477   (differs)
#
# and a relative-path build is byte-identical from three different directories.
#
# So: **pass the entry source as a RELATIVE path and this module reproduces from anywhere.**
# Package paths are irrelevant while no stable type comes from a package, but that is a
# property of today's source, not a guarantee. If a stable type is ever imported from a
# dependency, the absolute `.mops/` path re-enters the hash and the mount point starts to
# matter again. The canonical path below costs nothing and keeps that door shut.
#
set -euo pipefail

CANONICAL=/menese-redemption
EXPECTED_MD5=8196485adbba80dade277961d2436a32

if [ "$(pwd -P)" != "$CANONICAL" ]; then
  echo "note: building at $(pwd -P), not the canonical $CANONICAL." >&2
  echo "      Fine today: every stable type is defined in src/Types.mo and is referenced" >&2
  echo "      relatively, so the hash does not depend on this directory. Verified below." >&2
  echo >&2
fi

# Resolve dependencies from the committed lockfile.
mops install

mkdir -p build
# `mops sources` emits relative --package paths when run from the project root, and the
# entry source is relative. Both are deliberate; see above.
moc -o build/redemption.wasm $(mops sources) src/Redemption.mo

GOT=$(md5sum build/redemption.wasm | cut -d' ' -f1)

echo
echo "── redemption ──────────────────────────────────────────────────────"
echo "module md5    : $GOT"
echo "module sha256 : $(sha256sum build/redemption.wasm | cut -d' ' -f1)"
echo "size          : $(stat -c%s build/redemption.wasm) bytes"
echo "moc           : $(moc --version 2>&1 | head -1)"
echo

if [ "$GOT" = "$EXPECTED_MD5" ]; then
  echo "REPRODUCED: matches the module recorded in build/BUILD.md."
else
  echo "MISMATCH: expected $EXPECTED_MD5"
  echo
  echo "Find out WHERE before concluding the source differs:"
  echo "  python3 verification/wasm_sections.py build/redemption.wasm"
  echo "A difference confined to motoko:stable-types means the code is identical and only"
  echo "the recorded build paths differ, check you passed a RELATIVE source path."
  exit 1
fi
