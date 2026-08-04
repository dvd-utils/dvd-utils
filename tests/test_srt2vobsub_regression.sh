#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

OUT_DIR="$(mktemp -d)"
trap 'rm -rf "$OUT_DIR"' EXIT

OUT_BASE="$OUT_DIR/chicken"

if ! command -v spumux >/dev/null 2>&1; then
  echo "spumux not found; skipping regression test" >&2
  exit 0
fi

if ! command -v mencoder >/dev/null 2>&1; then
  echo "mencoder not found; skipping regression test" >&2
  exit 0
fi

./srt2vobsub.sh tests/chicken.srt "$OUT_BASE" --format pal --video tests/chicken_PAL.mpg

for output in "$OUT_BASE.sub" "$OUT_BASE.idx"; do
  if [ ! -s "$output" ]; then
    echo "Expected output was not created: $output" >&2
    exit 1
  fi
done

echo "SRT-to-VobSub regression test passed"
