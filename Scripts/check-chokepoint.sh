#!/bin/bash
# Single-deletion-site invariant: file-removal APIs may appear ONLY in
#   CruftKit/Sources/CruftKit/SafeDeleter.swift   (the production choke point)
#   CruftKit/Sources/CruftKitTestSupport/FixtureHome.swift
#     (test fixture teardown; its destroy() is itself guarded to temp areas)
# Everything else — including the Cruft/ GUI target — must route deletion
# through SafeDeleter. Run from the repo root. Exit 0 = invariant holds.
set -u
cd "$(dirname "$0")/.." || exit 2

dirs=()
[ -d "CruftKit/Sources" ] && dirs+=("CruftKit/Sources")
[ -d "Cruft" ] && dirs+=("Cruft")
if [ ${#dirs[@]} -eq 0 ]; then
  echo "check-chokepoint: no source directories found" >&2
  exit 2
fi

matches=$(grep -rn --include='*.swift' -E 'removeItem|trashItem|unlink\(|/bin/rm' "${dirs[@]}" 2>/dev/null \
  | grep -v 'Sources/CruftKit/SafeDeleter\.swift' \
  | grep -v 'Sources/CruftKitTestSupport/FixtureHome\.swift')

if [ -n "$matches" ]; then
  echo "CHOKEPOINT VIOLATION — deletion API outside SafeDeleter:"
  echo "$matches"
  exit 1
fi

echo "chokepoint OK"
exit 0
