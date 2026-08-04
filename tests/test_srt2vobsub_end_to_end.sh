#!/usr/bin/env bash
set -euo pipefail

# End-to-end regression test for the SRT -> VobSub conversion flow.
#
# Purpose:
#   - Use the repository's sample subtitle and MPEG assets.
#   - Run srt2vobsub.sh to render subtitles into a real DVD-compatible stream.
#   - Verify that the expected .sub and .idx files are produced.
#
# This script is meant to be run manually by humans on a machine with the
# required subtitle tooling installed (dvdauthor, mencoder, and spumux).

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

SRT="$REPO_ROOT/tests/chicken.srt"
PAL_VIDEO="$REPO_ROOT/tests/chicken_PAL.mpg"
NTSC_VIDEO="$REPO_ROOT/tests/chicken_NTSC.mpg"
OUT_DIR="$(mktemp -d)"
trap 'rm -rf "$OUT_DIR"' EXIT

OUTPUT_BASE="$OUT_DIR/chicken"

if [ -f "$PAL_VIDEO" ]; then
  VIDEO="$PAL_VIDEO"
  FORMAT="pal"
else
  VIDEO="$NTSC_VIDEO"
  FORMAT="ntsc"
fi

set -x

echo "[test] Repository root: $REPO_ROOT"
echo "[test] Sample subtitle: $SRT"
echo "[test] Selected MPEG input: $VIDEO"
echo "[test] Selected format: $FORMAT"
echo "[test] Temporary output directory: $OUT_DIR"
echo "[test] Starting SRT to VobSub conversion"
./srt2vobsub.sh "$SRT" "$OUTPUT_BASE" --format "$FORMAT" --video "$VIDEO"

echo "[test] Checking generated outputs"
for output in "$OUTPUT_BASE.sub" "$OUTPUT_BASE.idx"; do
  if [ ! -s "$output" ]; then
    echo "[test] ERROR: expected output was not created: $output" >&2
    exit 1
  fi
  echo "[test] Verified output: $output"
done

echo "[test] End-to-end test completed successfully"
echo "[test] Generated files:"
echo "[test]   $OUTPUT_BASE.sub"
echo "[test]   $OUTPUT_BASE.idx"
