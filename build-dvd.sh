#!/usr/bin/env bash
# ============================================================================
#  build-dvd.sh — Create a DVD image from existing videos and subtitles
# ============================================================================
#
#  What this does:
#    - Scans for a main movie .mpg plus optional extras (extras/{Category}/file.mpg is supported for paginated menus).
#    - Auto-detects PAL/NTSC and resolution from the main movie, and verifies that every extra matches.
#    - Discovers subtitles (.idx/.sub, .sup, .srt) per video and picks a default language (see --default).
#    - Generates the VMGM main menu, an Extras menu and per-titleset subtitle menus, with an optional custom or auto-extracted background.
#    - Builds the dvdauthor XML and authors the final DVD-Video structure.
#
#  Usage:
#    ./build-dvd.sh [OPTIONS]
#
#  Common options:
#    -i, --input DIR          Directory to scan for the main movie .mpg
#    -e, --extras DIR         Directory with extra .mpg files (default ./extras)
#    -m, --main FILE          Explicit main movie .mpg
#    -o, --out DIR            DVD-Video output directory (default ./dvd)
#    -w, --work DIR           Scratch directory (default ./work)
#    -d, --default LANG       Default subtitle language hint (default "nl")
#        --bg SPEC            Menu background: image, video, or hex color
#        --bg-time TIME       Timestamp for auto-extracted background still
#        --extras-per-page N  Extras shown per menu page
#    -y, --yes                Skip the confirmation prompt
#    -h, --help               Show the full help of the underlying script
#
#  Examples:
#    ./build-dvd.sh -i ./movies -e ./movies/extras
#    ./build-dvd.sh -i . --bg "#2a1a3e" -y
#    ./build-dvd.sh --help
#
#    All arguments are forwarded unchanged to the actual script inside 
#    ./generate_dvd_with_menus/build_dvd.sh
#
#  Requirements (checked by the underlying script):
#    dvdauthor, spumux, ffmpeg, ffprobe, ImageMagick (convert), bdsup2sub
#
#  Exit status:
#    Propagates the exit status of build_dvd.sh (0 on success).
# ============================================================================
set -euo pipefail

# Resolve the directory containing this wrapper so it works regardless of the caller's current working directory.
# Note: the builder itself treats paths like ./extras, ./work and ./dvd as relative to the CWD, so run this from your project directory (or pass absolute paths).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Forward all arguments verbatim (quoted to preserve spaces in paths)
exec "$SCRIPT_DIR/generate_dvd_with_menus/build_dvd.sh" "$@"
