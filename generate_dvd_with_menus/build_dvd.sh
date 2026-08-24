#!/usr/bin/env bash
# ============================================================================
#  build_dvd.sh — dynamic DVD builder (Movie + Extras)
# ============================================================================
#  What it does:
#   1. Scans MAIN_MOVIE and EXTRAS_DIR for .mpg files (extras support subfolder pagination: extras/{Category}/file.mpg).
#   2. Detects PAL/NTSC + resolution from the main movie's own stream data (frame rate + frame size) and authors the whole disc to match.
#   3. For every video, looks for matching subtitle .idx/.sub, .sub.idx, .sup, or .srt files, recognizing patterns like _track{n}_{lang}, _track{n}_{lang}_exp, etc.
#   4. Normalizes language names and selects default subtitles based on config (e.g. Dutch) falling back to 'track0' if no config match.
#   5. Dynamic VMGM menu & per-titleset subtitle menus.
#   6. Builds dvdauthor.xml structure and compiles the final DVD.
#   7. Optional menu background: explicit image/video, hex solid color, or auto-generated still from the main movie at a random (or specified) timestamp.
# ============================================================================
set -euo pipefail

# ----------------------------- CONFIG ---------------------------------------
MAIN_MOVIE=""      # Pre-encoded MPEG2 main feature, like './Movie Name_pal.mpg' or falls back to first .mpg in root
EXTRAS_DIR="./extras"                  # Folder optionally containing extra .mpg files (may have subfolders)
WORK_DIR="./work"                      # Scratch space, safe to delete after success
OUT_DIR="./dvd"                        # Final DVD-Video output structure
DEFAULT_HINT="nl"                      # Substring for default lang (e.g. "nl" or "dutch")
MENU_SECONDS=8                         # Loop duration for static menus
MIN_POINT_SIZE=12                      # Never shrink menu text below this
MAX_POINT_SIZE=36
ASSUME_YES=false                       # to handle non-interactive runs
MENU_BG=""                             # Background: image path, video path, or hex color (e.g. "#1a1a2e")
MENU_BG_TIME=""                        # Timestamp for auto-still extraction (e.g. "00:05:30"); empty = random
EXTRAS_PER_PAGE=5                      # Max extras per paginated menu page
# ----------------------------- CLI ARGS ------------------------------------
INPUT_DIR="."

print_help() {
  cat <<EOF
Usage: $0 [OPTIONS]

Build a DVD-Video from a main movie .mpg plus optional extras.

Options:
  -i, --input       DIR      Directory to scan for the main movie .mpg (default: .)
  -e, --extras      DIR      Directory containing extra .mpg files (default: ./extras)
                             Supports subfolders for pagination: extras/{Category}/file.mpg
  -m, --main        FILE     Explicit main movie .mpg (overrides auto-detection)
  -o, --out         DIR      Final DVD-Video output directory (default: ./dvd)
  -w, --work        DIR      Scratch/working directory (default: ./work)
  -d, --default     LANG     Default subtitle language hint, e.g. "nl" (default: nl)
  --bg              SPEC     Menu background: image path, video path, or hex color (e.g. "#1a1a2e")
                             If not set, a still is auto-extracted from the main movie.
  --bg-time         TIME     Timestamp for still extraction when using auto background
                             (e.g. "00:05:30"). Default: random moment.
  --extras-per-page N        Number of extras per paginated menu page (default: 10)
  -y, --yes                  Skip confirmation prompt
  -h, --help                 Show this help and exit

Examples:
  $0 -i ./movies -e ./movies/extras
  $0 --input /data/movies --main "/data/movies/Movie Name_pal.mpg" --bg "#2a1a3e"
  $0 -i . -o ./out_dvd --bg "./background.jpg"
  $0 -i . --bg-time "00:12:00"
  $0 -e ./extras --extras-per-page 8
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    -i|--input)       INPUT_DIR="$2";       shift 2 ;;
    -e|--extras)      EXTRAS_DIR="$2";      shift 2 ;;
    -m|--main)        MAIN_MOVIE="$2";      shift 2 ;;
    -o|--out)         OUT_DIR="$2";         shift 2 ;;
    -w|--work)        WORK_DIR="$2";        shift 2 ;;
    -d|--default)     DEFAULT_HINT="$2";    shift 2 ;;
    --bg)             MENU_BG="$2";         shift 2 ;;
    --bg-time)        MENU_BG_TIME="$2";    shift 2 ;;
    --extras-per-page) EXTRAS_PER_PAGE="$2"; shift 2 ;;
    -y|--yes)         ASSUME_YES=true;      shift 1 ;;
    -h|--help)        print_help; exit 0 ;;
    --) shift; break ;;
    *) echo "Unknown option: $1" >&2; print_help; exit 1 ;;
  esac
done

# Validate INPUT_DIR early so the user gets a clean error before tool checks.
[ -d "$INPUT_DIR" ] || { echo "ERROR: --input directory not found: $INPUT_DIR" >&2; exit 1; }
# Validate EXTRAS_PER_PAGE
if ! [[ "$EXTRAS_PER_PAGE" =~ ^[0-9]+$ ]] || [ "$EXTRAS_PER_PAGE" -lt 1 ] || [ "$EXTRAS_PER_PAGE" -gt 36 ]; then
  echo "ERROR: --extras-per-page must be a number between 1 and 36." >&2; exit 1
fi
# Validate MENU_BG if it looks like a hex color
if [[ -n "$MENU_BG" && "$MENU_BG" =~ ^#[0-9a-fA-F]{3,8}$ ]]; then
  : # valid hex
elif [ -n "$MENU_BG" ]; then
  if [ ! -f "$MENU_BG" ]; then
    echo "ERROR: --bg file not found: $MENU_BG" >&2; exit 1
  fi
fi
# ----------------------------------------------------------------------------
# Source split modules
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/utils.sh"
source "$SCRIPT_DIR/subtitles.sh"
source "$SCRIPT_DIR/html_preview.sh"
source "$SCRIPT_DIR/detect_dvd_format.sh"
source "$SCRIPT_DIR/dvd_xml.sh"
source "$SCRIPT_DIR/resolve_bdsup2sub.sh"

need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing required tool: $1" >&2; exit 1; }; }

# ----------------------------- TOOL CHECKS ----------------------------------
for t in dvdauthor spumux ffmpeg ffprobe convert; do need "$t"; done
resolve_bdsup2sub

# Define fallback fonts (prefer condensed/narrow variants for tighter menu text)
FALLBACK_FONTS=(
  "Ubuntu-Sans-Condensed-Bold"
  "Arial-Narrow-Bold"
  "DejaVu-Sans-Condensed-Bold"
  "Arial-Bold"
  "DejaVu-Sans-Bold"
  "Helvetica-Bold"
  "DejaVu-Sans-Mono-Bold"
)
IM_FONT=""
for font in "${FALLBACK_FONTS[@]}"; do
    if convert -list font | grep -q "^[[:space:]]*Font: $font$"; then
        IM_FONT="$font"
        break
    fi
done
if [ -z "$IM_FONT" ]; then
  echo "ERROR: No suitable fallback font found in ImageMagick (check 'convert -list font')." >&2
  exit 1
fi
FONT="$IM_FONT" # convert -list font

# Resolve main movie:
# - Use configured MAIN_MOVIE (from CONFIG or --main) when it exists and is non-empty.
# - Otherwise fall back to the first non-empty .mpg in INPUT_DIR.
if [ -z "$MAIN_MOVIE" ] || [ ! -f "$MAIN_MOVIE" ] || [ ! -s "$MAIN_MOVIE" ]; then
  if [ -n "$MAIN_MOVIE" ]; then
    echo "Configured main movie missing or empty: $MAIN_MOVIE"
  fi
  shopt -s nullglob
  candidates=( "$INPUT_DIR"/*.mpg )
  shopt -u nullglob
  MAIN_MOVIE=""
  for candidate in "${candidates[@]}"; do
    if [ -s "$candidate" ]; then
      MAIN_MOVIE="$candidate"
      break
    fi
  done
  [ -n "$MAIN_MOVIE" ] || { echo "ERROR: no usable main .mpg file found in '$INPUT_DIR'." >&2; exit 1; }
  echo "Using fallback main movie: $MAIN_MOVIE"
fi

# Extras are optional. A missing/empty extras directory simply means no extras menu.
if [ ! -d "$EXTRAS_DIR" ]; then
  echo "Extras directory not found @ $EXTRAS_DIR. Continuing without extras."
  EXTRAS_DIR=""
fi
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR" "$OUT_DIR"
LOG_DIR="$WORK_DIR/logs"
mkdir -p "$LOG_DIR"

detect_dvd_format "$MAIN_MOVIE"
echo ""
echo "Assuming format: ${DETECTED_FORMAT^^} (${WIDTH}x${HEIGHT} @ ${FPS}fps)"
#echo "Using subtitle processor: $BDSUP2SUB_CMD"

verify_matches_main_format() {
  local file="$1"
  local saved_fmt="$DETECTED_FORMAT" saved_w="$WIDTH" saved_h="$HEIGHT" saved_t="$TARGET" saved_f="$FPS"
  detect_dvd_format "$file"
  local this_fmt="$DETECTED_FORMAT" this_w="$WIDTH" this_h="$HEIGHT"
  DETECTED_FORMAT="$saved_fmt"; WIDTH="$saved_w"; HEIGHT="$saved_h"; TARGET="$saved_t"; FPS="$saved_f"

  if [ "$this_fmt" != "$saved_fmt" ] || [ "$this_w" -ne "$saved_w" ] || [ "$this_h" -ne "$saved_h" ]; then
    echo "ERROR: $file is ${this_fmt^^} ${this_w}x${this_h}, but main movie is ${saved_fmt^^} ${saved_w}x${saved_h}." >&2
    exit 1
  fi
}

# ---------------------------------------------------------------------------
# LANGUAGE NORMALIZATION & PRETTIFY HELPERS
# ---------------------------------------------------------------------------
NORM_LANG_CODE=""
NORM_LANG_LABEL=""

# ---------------------------------------------------------------------------
# MENU BACKGROUND HANDLING
# ---------------------------------------------------------------------------
# Resolves MENU_BG into a single background image at DVD resolution.
# Sets MENU_BG_RESOLVED to the path of a PNG file (or empty if none).
# ---------------------------------------------------------------------------
MENU_BG_RESOLVED=""
MENU_BG_IS_VIDEO=false

# ===========================================================================
# ANALYSIS (ffprobe + filesystem scans only)
# ===========================================================================

echo ""
echo "============================================================="
echo " DVD BUILDER — ANALYSIS"
echo " Target Format: ${DETECTED_FORMAT^^} (${WIDTH}x${HEIGHT})"
echo " Output Directory: $OUT_DIR"
echo "============================================================="

# --- Scan extras: support extras/{subfolder}/*.mpg structure ---
ALL_VIDEOS=("$MAIN_MOVIE")

# extras_array stores the full paths; extras_categories stores the category name (or "" for flat)
extras_array=()
extras_categories=()

shopt -s nullglob
if [ -n "${EXTRAS_DIR:-}" ]; then
  # First: check for direct .mpg files in EXTRAS_DIR (flat structure, backward compatible)
  for f in "$EXTRAS_DIR"/*.mpg; do
    [ -s "$f" ] && extras_array+=("$f") && extras_categories+=("")
  done

  # Second: scan subfolders (extras/{Category}/*.mpg)
  for subdir in "$EXTRAS_DIR"/*/; do
    [ -d "$subdir" ] || continue
    local_cat="$(basename "$subdir")"
    # Skip if it looks like a hidden dir
    [[ "$local_cat" == .* ]] && continue
    for f in "$subdir"*.mpg; do
      [ -s "$f" ] && extras_array+=("$f") && extras_categories+=("$local_cat")
    done
  done
fi
shopt -u nullglob

echo ""
echo "============"
if [ ${#extras_array[@]} -gt 0 ]; then
  echo "== Extras == (${#extras_array[@]} found in $EXTRAS_DIR)"
  for i in "${!extras_array[@]}"; do
    cat_display="${extras_categories[$i]}"
    [ -n "$cat_display" ] && cat_display=" [$cat_display]"
    echo "   ${extras_array[$i]}${cat_display}"
  done
else
  echo "== Extras ==  (none found)"
fi
echo "============"
for extra_mpg in "${extras_array[@]}"; do
  verify_matches_main_format "$extra_mpg"
  ALL_VIDEOS+=("$extra_mpg")
done

# Arrays for HTML preview
ANALYSIS_TITLES=()
ANALYSIS_SUBS_STR=()
ANALYSIS_DEFAULTS=()
ANALYSIS_HAS_SUBS=()
ANALYSIS_SUB_FILES=()   # pipe-separated subtitle entry files (.idx/.sub.idx/.sup/.srt) per title

if [ ${#ALL_VIDEOS[@]} -gt 99 ]; then
  echo "ERROR: too many titlesets (${#ALL_VIDEOS[@]}); DVD-Video supports at most 99." >&2
  exit 1
fi

# Discover subtitles for every video (main + extras) up front
echo ""
echo "------------------------------------"
echo "Scanning subtitles for all titles..."
echo "------------------------------------"

for idx in "${!ALL_VIDEOS[@]}"; do
  ts_idx=$((idx + 1))
  video="${ALL_VIDEOS[$idx]}"
  if [ "$ts_idx" -eq 1 ]; then
    discover_subs "$video" "$ts_idx" "[MAIN]"
  else
    discover_subs "$video" "$ts_idx" "[EXTRA $((ts_idx-1))]"
  fi
  # Save state for preview
  ANALYSIS_TITLES+=("$(prettify_filename "$video")")
  ANALYSIS_HAS_SUBS+=("$CURRENT_HAS_SUBS")
  ANALYSIS_DEFAULTS+=("$CURRENT_DEFAULT_SUBP")
  if [ "$CURRENT_HAS_SUBS" -eq 1 ]; then
    ANALYSIS_SUBS_STR+=("$(IFS='|'; echo "${CURRENT_SUB_LABELS[*]}")")
    ANALYSIS_SUB_FILES+=("$(IFS='|'; echo "${CURRENT_INPUT_FILES[*]}")")
  else
    ANALYSIS_SUBS_STR+=("")
    ANALYSIS_SUB_FILES+=("")
  fi
done

# Generate the HTML Preview
generate_html_preview

echo ""
echo "============================================================="
if [ "$ASSUME_YES" = true ] || [ ! -t 0 ]; then
  echo "Non-interactive session detected. Proceeding automatically..."
else
  read -r -p "Analysis complete. Proceed with encoding and DVD authoring? [Y/n] " CONFIRM_REPLY
  case "${CONFIRM_REPLY,,}" in
    ""|y|yes) ;;
    *) echo "Aborted." >&2; exit 1 ;;
  esac
fi
echo "============================================================="
echo ""

# ===========================================================================
# HEAVY LIFTING (bdsup2sub, spumux, ffmpeg encoding, dvdauthor)
# ===========================================================================

echo ""
echo "Menu graphics will be built at standard DVD resolution ${WIDTH}x${HEIGHT} (${DETECTED_FORMAT^^}, target=${TARGET})"
echo ""

# Resolve menu background ONCE before any menu building
echo "Resolving menu background..."
resolve_menu_background
echo ""

echo "============================================================="
echo " DVD BUILDER — ENCODING & AUTHORING"
echo " Target Format: ${DETECTED_FORMAT^^} (${WIDTH}x${HEIGHT})"
echo "============================================================="
echo ""

# Process Titleset 1: Main Movie
echo "[MAIN] Processing: $(prettify_filename "$MAIN_MOVIE")"
discover_subs "$MAIN_MOVIE" 1 "[MAIN]"
mux_subs "$MAIN_MOVIE" 1
movie_name_pretty="$(prettify_filename "$MAIN_MOVIE")"
append_titleset_xml 1 "$movie_name_pretty"

VMGM_LABELS+=("Play movie")
if [ "$CURRENT_HAS_SUBS" -eq 1 ]; then
  # Set g2=0 so the default subtitle is applied. If g1 was left at 1 from some earlier call, jumping into an extra's subtitle menu would misread that stale value and resume back into whatever was last call'd (the main movie) instead of jumping fresh into the extra.
  VMGM_TARGETS+=("g1 = 0; g2 = 0; jump titleset 1 menu;")
  MAIN_DEFAULT_SUBP=$CURRENT_DEFAULT_SUBP
  # Send the viewer to the VMGM Main Menu on disc insertion, not the subtitle menu
  FPC_JUMP="g1 = 0; g2 = 0; jump vmgm menu entry title;"
else
  VMGM_TARGETS+=("g1 = 0; g2 = 0; jump titleset 1 title 1;")
  MAIN_DEFAULT_SUBP=62
  FPC_JUMP="g1 = 0; g2 = 0; jump vmgm menu entry title;"
fi

# Process Titleset 2..N: Extras
TS_IDX=2
EXTRAS_MENU_LABELS=()
EXTRAS_MENU_TARGETS=()

if [ ${#extras_array[@]} -gt 0 ]; then
  for extra_mpg in "${extras_array[@]}"; do
    pretty_name="$(prettify_filename "$extra_mpg")"
    echo ""
    echo "[EXTRA $((TS_IDX-1))] Processing: $pretty_name"

    discover_subs "$extra_mpg" "$TS_IDX" "[EXTRA $((TS_IDX-1))]"
    mux_subs "$extra_mpg" "$TS_IDX"
    append_titleset_xml "$TS_IDX" "$pretty_name"

    EXTRAS_MENU_LABELS+=("$pretty_name") #"Extra: "
    if [ "$CURRENT_HAS_SUBS" -eq 1 ]; then
      # Set g2=0 so the default subtitle is applied
      EXTRAS_MENU_TARGETS+=("g1 = 0; g2 = 0; jump titleset $TS_IDX menu;")
    else
      EXTRAS_MENU_TARGETS+=("g1 = 0; g2 = 0; jump titleset $TS_IDX title 1;")
    fi

    TS_IDX=$((TS_IDX + 1))
  done
fi

if [ "$TS_IDX" -gt 100 ]; then
  echo "ERROR: too many titlesets ($((TS_IDX - 1))); DVD-Video supports at most 99." >&2
  exit 1
fi

# Add Extras button to Main Menu if extras exist
if [ ${#EXTRAS_MENU_LABELS[@]} -gt 0 ]; then
  VMGM_LABELS+=("Extras Menu")
  VMGM_TARGETS+=("g1 = 0; g2 = 0; jump vmgm menu 2;")
fi

echo " Generating VMGM Root Menu..."
VMGM_MPG="$WORK_DIR/vmgm_menu.mpg"
build_menu "$VMGM_MPG" "$movie_name_pretty" "${VMGM_LABELS[@]}"

# ===========================================================================
# XML ASSEMBLY & DVD AUTHORING (Now delegated to dvd_xml.sh)
# ===========================================================================

generate_extras_pgc_xml "${EXTRAS_MENU_LABELS[@]}"
assemble_dvdauthor_xml
author_dvd
