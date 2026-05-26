#!/usr/bin/env bash
# openapi-diff.sh
# -----------------------------------------------------------------------------
# Detect breaking changes in OpenAPI specifications by comparing the working
# tree against a baseline (default: origin/main). Uses the open-source
# `openapi-diff` CLI from Tufin via npx so contributors don't need a global
# install.
#
# Usage:
#   ./scripts/openapi-diff.sh                       # compare against origin/main
#   ./scripts/openapi-diff.sh main                  # explicit baseline ref
#   BASELINE_REF=release/1.0 ./scripts/openapi-diff.sh
#
# Exits non-zero if breaking changes are found.
# -----------------------------------------------------------------------------
set -euo pipefail

BASELINE_REF="${1:-${BASELINE_REF:-origin/main}}"
SPEC_DIR="${SPEC_DIR:-openapi}"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

if ! git rev-parse --verify "$BASELINE_REF" >/dev/null 2>&1; then
  echo "Baseline ref '$BASELINE_REF' not found locally — skipping diff." >&2
  exit 0
fi

shopt -s nullglob
specs=("$SPEC_DIR"/*.yaml "$SPEC_DIR"/*.yml "$SPEC_DIR"/*.json)
if [[ ${#specs[@]} -eq 0 ]]; then
  echo "No OpenAPI specs found under '$SPEC_DIR'." >&2
  exit 0
fi

status=0
for spec in "${specs[@]}"; do
  rel="${spec#./}"
  baseline_copy="$TMP_DIR/$(basename "$spec")"

  # If the file does not exist on the baseline, this is a brand-new spec.
  if ! git show "$BASELINE_REF:$rel" >"$baseline_copy" 2>/dev/null; then
    echo "[new] $rel — no baseline, skipping."
    continue
  fi

  echo "--- Diffing $rel against $BASELINE_REF ---"
  if ! npx --yes @tufin/oasdiff breaking "$baseline_copy" "$spec"; then
    echo "Breaking changes detected in $rel" >&2
    status=1
  fi
done

exit "$status"
