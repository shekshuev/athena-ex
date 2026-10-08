#!/usr/bin/env bash
# Builds a self-contained directory to copy to the prod host:
#
#   scripts/quiz_import/pack.sh            # -> tmp/quiz_import_pack/ and tmp/quiz_import_pack.tar.gz
#
# Run the parser first (see README.md); every bundle under tmp/quiz_bundle is included.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="$ROOT/tmp/quiz_import_pack"

[[ -d "$ROOT/tmp/quiz_bundle" ]] || { echo "no bundles in tmp/quiz_bundle - run parse.exs first" >&2; exit 1; }

rm -rf "$OUT" "$OUT.tar.gz"
mkdir -p "$OUT/bundles"
cp "$ROOT/scripts/quiz_import/import.exs" "$ROOT/scripts/quiz_import/prod_import.sh" "$OUT/"
chmod +x "$OUT/prod_import.sh"

for dir in "$ROOT"/tmp/quiz_bundle/*/; do
  name="$(basename "$dir")"
  cp -r "$dir" "$OUT/bundles/$name"
  rm -f "$OUT/bundles/$name/report.txt"
done

tar -C "$ROOT/tmp" -czf "$OUT.tar.gz" quiz_import_pack
echo "packed: $OUT ($(du -sh "$OUT" | cut -f1)), archive: $OUT.tar.gz"
