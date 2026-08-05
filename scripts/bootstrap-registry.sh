#!/bin/sh
# Seed registry/projects.md with an index row for every project directory not yet listed.
# Usage: bootstrap-registry.sh <code-dir>
# Idempotent: existing rows (and their hand-enriched keywords) are never touched.
# Cards are created at onboarding; the index alone is enough to route and gate.
set -eu
[ $# -eq 1 ] || { echo "usage: $0 <code-dir>" >&2; exit 2; }
CODE_DIR=${1%/}
[ -d "$CODE_DIR" ] || { echo "not a directory: $CODE_DIR" >&2; exit 2; }
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
REG="$ROOT/registry/projects.md"
added=0
for d in "$CODE_DIR"/*/; do
  [ -d "$d" ] || continue
  [ "${d%/}" = "$ROOT" ] && continue
  slug=$(basename "$d")
  grep -q "^| $slug |" "$REG" && continue
  printf '| %s | %s | no | %s |\n' "$slug" "${d%/}" "$slug" >> "$REG"
  added=$((added + 1))
done
echo "added $added rows; total $(grep -c '^| ' "$REG") (incl. header)"
