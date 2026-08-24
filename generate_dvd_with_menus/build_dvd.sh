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
MIN_POINT_SIZE=14                      # Never shrink menu text below this
MAX_POINT_SIZE=36
ASSUME_YES=false                       # to handle non-interactive runs
MENU_BG=""                             # Background: image path, video path, or hex color (e.g. "#1a1a2e")
MENU_BG_TIME=""                        # Timestamp for auto-still extraction (e.g. "00:05:30"); empty = random
EXTRAS_PER_PAGE=10                     # Max extras per paginated menu page
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
need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing required tool: $1" >&2; exit 1; }; }

# ----------------------------- TOOL CHECKS ----------------------------------
# TODO notify user we need to `apt install ffmpeg` etc...
# ---------------------------------------------------------------------------
# BDSUP2SUB TOOL RESOLUTION
# ---------------------------------------------------------------------------
# Ubuntu does not provide ogmrip/subp2pgm/bdsup2sub++ in the standard repositories anymore, even with the Universe repository enabled.
# Therefore, we can not rely on apt and need to look for our own executable.
#
# Resolution order:
#   1. bdsup2sub++ installed in system PATH
#   2. Local bdsup2sub++ development builds
#   3. bdsup2sub (original Java wrapper) in system PATH
#   4. Local bdsup2sub.jar via Java
#
# The resolved command is stored in the BDSUP2SUB_CMD array so it can be
# safely invoked with:
#   "${BDSUP2SUB_CMD[@]}" <arguments>
# ---------------------------------------------------------------------------

BDSUP2SUB_CMD=()

# Prefer the native bdsup2sub++ executable from PATH.
if command -v bdsup2sub++ >/dev/null 2>&1; then
  BDSUP2SUB_CMD=("$(command -v bdsup2sub++)")

# Look for local development/build copies of bdsup2sub++.
else
  for candidate in "./VobSub-Utilities/bdsup2sub++" "./VobSub-Utilities/build/bdsup2sub++" "./sup2vobsub/bdsup2sub++" "./sup2vobsub/build/bdsup2sub++"; do
    if [ -x "$candidate" ]; then BDSUP2SUB_CMD=("$candidate"); break; fi
  done

  # Fall back to the original Java bdsup2sub wrapper in PATH.
  if [ ${#BDSUP2SUB_CMD[@]} -eq 0 ] && command -v bdsup2sub >/dev/null 2>&1; then
    BDSUP2SUB_CMD=("$(command -v bdsup2sub)")

  # Fall back to a local bdsup2sub.jar.
  elif [ ${#BDSUP2SUB_CMD[@]} -eq 0 ] && command -v java >/dev/null 2>&1 && [ -f "./bdsup2sub.jar" ]; then
    BDSUP2SUB_CMD=("java" "-jar" "./bdsup2sub.jar")
  fi
fi

# No supported subtitle conversion tool was found.
if [ ${#BDSUP2SUB_CMD[@]} -eq 0 ]; then
  echo "ERROR: No supported BDSUP2SUB subtitle converter was found." >&2
  echo >&2
  echo "Searched for:" >&2
  echo "  - bdsup2sub++ in system PATH" >&2
  echo "  - ./VobSub-Utilities/bdsup2sub++" >&2
  echo "  - ./VobSub-Utilities/build/bdsup2sub++" >&2
  echo "  - ./sup2vobsub/bdsup2sub++" >&2
  echo "  - ./sup2vobsub/build/bdsup2sub++" >&2
  echo "  - bdsup2sub in system PATH" >&2
  echo "  - ./bdsup2sub.jar via Java" >&2
  echo >&2
  echo "Install or compile bdsup2sub++:" >&2
  echo "git clone https://github.com/prinsbert/VobSub-Utilities && cd ./BDSup2SubPlusPlus && mkdir -p build && cd build && qmake6 ../src/bdsup2sub++.pro" >&2
  echo "make"
  echo "cd ../../"
  echo >&2
  echo "Expected local build locations:" >&2
  echo "  ./sup2vobsub/" >&2
  echo "  ./VobSub-Utilities/" >&2
  exit 1
fi
echo "Using subtitle converter: ${BDSUP2SUB_CMD[*]}"
# ----------------------------------------------------------------------------

for t in dvdauthor spumux ffmpeg ffprobe convert; do need "$t"; done

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

resolve_menu_background() {
  local out_png="$WORK_DIR/_menu_bg_resolved.png"
  local out_vid="$WORK_DIR/_menu_bg_video.mpg"

  # Case 1: Explicit hex color — generate solid gradient background
  if [[ -n "$MENU_BG" && "$MENU_BG" =~ ^#[0-9a-fA-F]{3,8}$ ]]; then
    local base_color="$MENU_BG"
    echo "  -> Menu background: solid color $base_color"

    # Parse hex to RGB for gradient generation
    local hex="${base_color#\#}"
    # Expand 3-char hex to 6-char
    if [ ${#hex} -eq 3 ]; then
      hex="${hex:0:1}${hex:0:1}${hex:1:1}${hex:1:1}${hex:2:1}${hex:2:1}"
    fi
    local r=$((16#${hex:0:2})) g=$((16#${hex:2:2})) b=$((16#${hex:4:2}))

    # Darken for the top band of the title bar gradient
    local dr=$(( r * 40 / 100 ))
    local dg=$(( g * 40 / 100 ))
    local db=$(( b * 40 / 100 ))

    local menu_w=720 menu_h=576
    [ "$DETECTED_FORMAT" = "ntsc" ] && menu_h=480
    local title_bar_h=80
    [ "$DETECTED_FORMAT" = "ntsc" ] && title_bar_h=65
    local third_h=$((title_bar_h / 3))

    # Build gradient title bar over the solid color
    convert -size "${menu_w}x${menu_h}" xc:"rgb($r,$g,$b)" \
      -fill "rgb($dr,$dg,$db)" -draw "rectangle 0,0 ${menu_w},${third_h}" \
      -fill "rgb($((r*60/100)),$((g*60/100)),$((b*60/100)))" -draw "rectangle 0,${third_h} ${menu_w},$((third_h*2))" \
      -fill "rgb($((r*80/100)),$((g*80/100)),$((b*80/100)))" -draw "rectangle 0,$((third_h*2)) ${menu_w},${title_bar_h}" \
      -fill "rgb($((r*120/100 > 255 ? 255 : r*120/100)),$((g*120/100 > 255 ? 255 : g*120/100)),$((b*120/100 > 255 ? 255 : b*120/100)))" \
        -draw "rectangle 0,${title_bar_h} ${menu_w},$((title_bar_h + 2))" \
      "$out_png"
    MENU_BG_RESOLVED="$out_png"
    return
  fi

  # Case 2: Explicit image file
  if [ -n "$MENU_BG" ] && [ -f "$MENU_BG" ]; then
    local ext="${MENU_BG##*.}"
    ext="$(echo "$ext" | tr '[:upper:]' '[:lower:]')"
    if [[ "$ext" =~ ^(mpg|mpeg|m2v|vob|mkv|mp4|avi|mov|ts)$ ]]; then
      echo "  -> Menu background: video file $MENU_BG"
      # Extract a still from the video at the specified or default time
      local seek_time="$MENU_BG_TIME"
      [ -z "$seek_time" ] && seek_time="0"
      run_logged "$LOG_DIR/_bg_from_video.log" \
        ffmpeg -y -ss "$seek_time" -i "$MENU_BG" -vframes 1 \
                -vf "scale=${WIDTH}:${HEIGHT}:force_original_aspect_ratio=decrease,pad=${WIDTH}:${HEIGHT}:(ow-iw)/2:(oh-ih)/2:black" \
                -pix_fmt yuv420p "$out_png"
      MENU_BG_RESOLVED="$out_png"
    else
      echo "  -> Menu background: image file $MENU_BG"
      run_logged "$LOG_DIR/_bg_from_image.log" \
        convert "$MENU_BG" \
                -resize "${WIDTH}x${HEIGHT}^" -gravity center -extent "${WIDTH}x${HEIGHT}" \
                "$out_png"
      MENU_BG_RESOLVED="$out_png"
    fi
    return
  fi

  # Case 3: Auto-extract still from main movie
  local seek_time="$MENU_BG_TIME"
  if [ -z "$seek_time" ]; then
    # Get duration, pick a random moment between 5% and 40% of the movie
    local duration
    duration="$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$MAIN_MOVIE" 2>/dev/null || echo "3600")"
    # Trim to integer seconds
    duration="$(echo "$duration" | grep -oE '^[0-9]+' || echo "3600")"
    [ -z "$duration" ] && duration=3600
    # Random between 5% and 40%
    local min_sec=$(( duration * 5 / 100 ))
    local max_sec=$(( duration * 40 / 100 ))
    [ "$max_sec" -le "$min_sec" ] && max_sec=$((min_sec + 10))
    local range=$(( max_sec - min_sec ))
    # $RANDOM is 0-32767
    seek_time=$(( min_sec + ( RANDOM * range / 32768 ) ))
    echo "  -> Menu background: auto-still from main movie at ${seek_time}s (random)"
  else
    echo "  -> Menu background: auto-still from main movie at $seek_time"
  fi

  run_logged "$LOG_DIR/_bg_auto_still.log" \
    ffmpeg -y -ss "$seek_time" -i "$MAIN_MOVIE" -vframes 1 \
            -vf "scale=${WIDTH}:${HEIGHT},eq=brightness=-0.15:saturation=0.6" \
            -pix_fmt yuv420p "$out_png"
  MENU_BG_RESOLVED="$out_png"
}

# ---------------------------------------------------------------------------
# HELPER: Build a dynamic menu (Graphics + Video + Spumux logic)
# ---------------------------------------------------------------------------
# Optional 5th+ args: pairs of  "label" "vmgm_command"  used by extras
#   pagination to wire "Next page" / "Prev page" buttons.
#   When extra_vmgm_pairs are provided, this menu lives in the VMGM and
#   those button actions are appended to the label list automatically.
# ---------------------------------------------------------------------------
build_menu() {
  local out_mpg="$1"
  local title_text="$2"
  shift 2
  # Remaining positional args are labels, EXCEPT that if the special
  # sentinel "--vmgm-pairs--" appears, everything after it is
  #   "label" "vmgm_cmd" "label" "vmgm_cmd" ...
  local labels=()
  local vmgm_pairs=()
  local collecting_pairs=false

  for arg in "$@"; do
    if [ "$arg" = "--vmgm-pairs--" ]; then
      collecting_pairs=true
      continue
    fi
    if [ "$collecting_pairs" = true ]; then
      vmgm_pairs+=("$arg")
    else
      labels+=("$arg")
    fi
  done
  local num_pairs=$(( ${#vmgm_pairs[@]} / 2 ))

  local num_items=${#labels[@]}
  local pfx="${out_mpg%.mpg}"

  [ "$num_items" -gt 0 ] || { echo "ERROR: build_menu called with zero labels for $out_mpg" >&2; exit 1; }
  # DVD spec limits to 36 buttons per PGC
  local total_buttons=$(( num_items + num_pairs ))
  [ "$total_buttons" -le 36 ] || { echo "ERROR: Too many buttons ($total_buttons) in menu '$title_text'. Max 36." >&2; exit 1; }

  # Hardcode menu dimensions to standard DVD to avoid scaling mismatches with ffmpeg -target
  local menu_w=720
  local menu_h=576
  if [ "$DETECTED_FORMAT" = "ntsc" ]; then
    menu_h=480
  fi

  # ---- Detect menu type for styling ----
  local is_subtitle_menu=false
  local is_extras_menu=false
  [[ "$title_text" == Subtitles:* ]] && is_subtitle_menu=true
  [[ "$title_text" == "Extras Menu" ]] || [[ "$title_text" == "Extras"*"("*")" ]] && is_extras_menu=true

  # ---- Title configuration ----
  local title_line1="" title_line2=""
  local title_size=42
  local title_bar_h=80

  if [ "$is_subtitle_menu" = true ]; then
    # Two-line title: "Subtitles" / "{Title Name}"
    title_line1="Subtitles"
    title_line2="${title_text#Subtitles: }"
    title_size=30
    title_bar_h=100
  else
    title_line1="$title_text"
    title_line2=""
    # Dynamic title font sizing (shrink for long titles like extras)
    if [ ${#title_text} -gt 30 ]; then title_size=36; fi
    if [ ${#title_text} -gt 45 ]; then title_size=30; fi
    if [ ${#title_text} -gt 60 ]; then title_size=26; fi
    if [ ${#title_text} -gt 80 ]; then title_size=22; fi
  fi
  [ "$title_size" -lt "$MIN_POINT_SIZE" ] && title_size=$MIN_POINT_SIZE
  [ "$DETECTED_FORMAT" = "ntsc" ] && title_bar_h=$((title_bar_h - 15))

  # Calculate title y-positions (vertically centered in title bar)
  local title1_y title2_y
  if [ -n "$title_line2" ]; then
    local line2_size=$((title_size - 4))
    [ "$line2_size" -lt "$MIN_POINT_SIZE" ] && line2_size=$MIN_POINT_SIZE
    local total_title_h=$((title_size + line2_size + 6))
    title1_y=$(( (title_bar_h - total_title_h) / 2 ))
    title2_y=$((title1_y + title_size + 6))
  else
    title1_y=$(( (title_bar_h - title_size) / 2 ))
    title2_y=""
  fi

  local top_margin=$((title_bar_h + 30))

  # ---- Classify buttons into content vs navigation ----
  local nav_indices=()
  local content_count=0
  for i in "${!labels[@]}"; do
    if [[ "${labels[$i]}" == "Main Menu" ]] || [[ "${labels[$i]}" == "Back to Extras" ]]; then
      nav_indices+=("$i")
    else
      content_count=$((content_count + 1))
    fi
  done
  local nav_count=${#nav_indices[@]}

  # ---- Calculate layout ----
  # Reserve space at bottom for navigation buttons
  local nav_zone_y=$((menu_h - 55 * nav_count - 30))
  [ "$nav_count" -eq 0 ] && nav_zone_y=$((menu_h - 40))

  local line_h=$(( (nav_zone_y - top_margin) / content_count ))
  [ "$line_h" -gt 70 ] && line_h=70
  [ "$line_h" -lt $((MIN_POINT_SIZE + 6)) ] && line_h=$((MIN_POINT_SIZE + 6))

  local point_size=$(( line_h / 2 + 10 ))
  [ "$point_size" -gt "$MAX_POINT_SIZE" ] && point_size=$MAX_POINT_SIZE
  [ "$point_size" -lt "$MIN_POINT_SIZE" ] && point_size=$MIN_POINT_SIZE

  # Smaller font for extras menu items (they tend to be long filenames)
  if [ "$is_extras_menu" = true ]; then
    point_size=$(( point_size * 3 / 4 ))
    [ "$point_size" -lt "$MIN_POINT_SIZE" ] && point_size=$MIN_POINT_SIZE
    line_h=$(( point_size * 2 + 8 ))
  fi

  # Navigation button styling
  local nav_point_size=$((point_size - 2))
  [ "$nav_point_size" -lt "$MIN_POINT_SIZE" ] && nav_point_size=$MIN_POINT_SIZE
  local nav_line_h=50
  local nav_left_margin=$((menu_w / 4))  # Indented more for visual distinction

  local left_margin=$(( menu_w / 6 ))
  local right_margin=$(( menu_w / 20 ))

  # ---- Overflow warnings ----
  if [ "$content_count" -gt 0 ] && [ $((top_margin + content_count * line_h)) -gt "$nav_zone_y" ]; then
    echo "WARNING: menu '$title_text' content area may overflow." >&2
  fi
  if [ "$nav_count" -gt 0 ] && [ $((nav_zone_y + nav_count * nav_line_h)) -gt "$menu_h" ]; then
    echo "WARNING: menu '$title_text' navigation area may overflow." >&2
  fi

  echo "  -> Building Menu: $title_text"
  echo "     Target: ${menu_w}x${menu_h} (${DETECTED_FORMAT^^})"
  echo "     Layout: $num_items content + $num_pairs pagination = $total_buttons buttons @ ${point_size}pt (title @ ${title_size}pt)"
  [ "$is_extras_menu" = true ] && echo "     (Extras menu: reduced font)"
  echo "     Buttons:"
  for i in "${!labels[@]}"; do
    local tag=""
    for ni in "${nav_indices[@]}"; do
      [ "$i" = "$ni" ] && tag=" [NAV]" && break
    done
    printf "       %d - %s%s\n" "$i" "${labels[$i]}" "$tag"
  done
  for p in $(seq 0 $((num_pairs - 1))); do
    local pidx=$(( p * 2 ))
    printf "       %d - %s [PAGINATION]\n" "$((num_items + p))" "${vmgm_pairs[$pidx]}"
  done
  echo "+-- Muxing menu stream..."

  # ---- Truncate title lines if needed ----
  local title_max_chars=$(( (menu_w - 2 * left_margin) * 10 / (title_size * 6) ))
  [ "$title_max_chars" -lt 10 ] && title_max_chars=10
  if [ ${#title_line1} -gt "$title_max_chars" ]; then
    title_line1="${title_line1:0:$((title_max_chars - 1))}…"
  fi
  if [ -n "$title_line2" ]; then
    local line2_size=$((title_size - 4))
    [ "$line2_size" -lt "$MIN_POINT_SIZE" ] && line2_size=$MIN_POINT_SIZE
    local line2_max_chars=$(( (menu_w - 2 * left_margin) * 10 / (line2_size * 6) ))
    [ "$line2_max_chars" -lt 10 ] && line2_max_chars=10
    if [ ${#title_line2} -gt "$line2_max_chars" ]; then
      title_line2="${title_line2:0:$((line2_max_chars - 1))}…"
    fi
  fi

  # ---- Build background ----
  if [ -n "$MENU_BG_RESOLVED" ] && [ -f "$MENU_BG_RESOLVED" ]; then
    # Start from the resolved background image
    cp "$MENU_BG_RESOLVED" "${pfx}_bg.png"
    # Darken it slightly so text remains readable, then add title bar overlay
    local third_h=$((title_bar_h / 3))
    run_logged "$LOG_DIR/$(basename "$pfx")_convert_bg0.log" \
      convert "${pfx}_bg.png" \
        -fill "rgba(0,0,0,0.75)" -draw "rectangle 0,0 ${menu_w},${title_bar_h}" \
        -fill "#08081a" -draw "rectangle 0,0 ${menu_w},${third_h}" \
        -fill "#12122a" -draw "rectangle 0,${third_h} ${menu_w},$((third_h * 2))" \
        -fill "#1a1a2e" -draw "rectangle 0,$((third_h * 2)) ${menu_w},${title_bar_h}" \
        -fill "#555577" -draw "rectangle 0,${title_bar_h} ${menu_w},$((title_bar_h + 2))" \
        "${pfx}_bg_tmp.png" && mv "${pfx}_bg_tmp.png" "${pfx}_bg.png"
  else
    # Original gradient-only background
    local third_h=$((title_bar_h / 3))
    run_logged "$LOG_DIR/$(basename "$pfx")_convert_bg0.log" \
      convert -size "${menu_w}x${menu_h}" xc:black \
        -fill "#08081a" -draw "rectangle 0,0 ${menu_w},${third_h}" \
        -fill "#12122a" -draw "rectangle 0,${third_h} ${menu_w},$((third_h * 2))" \
        -fill "#1a1a2e" -draw "rectangle 0,$((third_h * 2)) ${menu_w},${title_bar_h}" \
        -fill "#555577" -draw "rectangle 0,${title_bar_h} ${menu_w},$((title_bar_h + 2))" \
        "${pfx}_bg.png"
  fi

  # Draw title text (CENTER aligned)
  local title_gravity="center"
  local title_x=$(( menu_w / 2 ))
  run_logged "$LOG_DIR/$(basename "$pfx")_convert_bg0t.log" \
    convert "${pfx}_bg.png" \
      -gravity "$title_gravity" -fill white -font "$FONT" -pointsize "$title_size" \
      -annotate +0+$(( title1_y + title_size / 2 )) "$title_line1" \
      "${pfx}_bg_tmp.png" && mv "${pfx}_bg_tmp.png" "${pfx}_bg.png"

  # Second title line
  if [ -n "$title_line2" ]; then
    local line2_size=$((title_size - 4))
    [ "$line2_size" -lt "$MIN_POINT_SIZE" ] && line2_size=$MIN_POINT_SIZE
    run_logged "$LOG_DIR/$(basename "$pfx")_convert_bg0b.log" \
      convert "${pfx}_bg.png" \
        -gravity "$title_gravity" -fill "#9999bb" -font "$FONT" -pointsize "$line2_size" \
        -annotate +0+$(( title2_y + line2_size / 2 )) "$title_line2" \
        "${pfx}_bg_tmp.png" && mv "${pfx}_bg_tmp.png" "${pfx}_bg.png"
  fi

  # Separator line before navigation buttons
  if [ "$nav_count" -gt 0 ]; then
    local nav_sep_y=$((nav_zone_y - 15))
    run_logged "$LOG_DIR/$(basename "$pfx")_convert_bg0c.log" \
      convert "${pfx}_bg.png" \
        -fill "#333355" -draw "rectangle $((left_margin - 10)),${nav_sep_y} $((menu_w - left_margin + 10)),$((nav_sep_y + 1))" \
        "${pfx}_bg_tmp.png" && mv "${pfx}_bg_tmp.png" "${pfx}_bg.png"
  fi

  # ---- Build highlight overlay (transparent, only button text) ----
  run_logged "$LOG_DIR/$(basename "$pfx")_convert_hl0.log" \
    convert -size "${menu_w}x${menu_h}" xc:none "${pfx}_hl.png"

  # ---- Draw all content + nav buttons ----
  local y0_arr=() y1_arr=() x0_arr=() x1_arr=()
  local current_y=$top_margin
  local nav_drawn=0

  for i in "${!labels[@]}"; do
    local text="${labels[$i]}"
    local is_nav=false
    for ni in "${nav_indices[@]}"; do
      [ "$i" = "$ni" ] && is_nav=true && break
    done

    local this_left this_y this_ps this_color
    if [ "$is_nav" = true ]; then
      # Navigation button: gold color, indented, separate zone
      this_left=$nav_left_margin
      this_y=$((nav_zone_y + nav_drawn * nav_line_h))
      this_ps=$nav_point_size
      this_color="#ffcc44"
      nav_drawn=$((nav_drawn + 1))
    else
      # Content button: white, normal position
      this_left=$left_margin
      this_y=$current_y
      this_ps=$point_size
      this_color="white"
      current_y=$((current_y + line_h))
    fi

    # Truncate text if too long
    local max_chars=$(( (menu_w - this_left - right_margin) * 10 / (this_ps * 6) ))
    [ "$max_chars" -lt 4 ] && max_chars=4
    if [ "${#text}" -gt "$max_chars" ]; then
      text="${text:0:$((max_chars - 1))}…"
    fi

    # Store button bounds for spumux
    y0_arr[$i]=$((this_y - 5))
    y1_arr[$i]=$((this_y + this_ps + 5))
    x0_arr[$i]=$((this_left - 20))
    x1_arr[$i]=$((menu_w - left_margin))

    # Draw on background with appropriate color (CENTER aligned)
    local text_x=$(( (this_left + menu_w - left_margin) / 2 ))
    run_logged "$LOG_DIR/$(basename "$pfx")_convert_bg${i}.log" \
      convert "${pfx}_bg.png" \
        -gravity NorthWest -fill "$this_color" -font "$FONT" -pointsize "$this_ps" \
        -annotate +${text_x}+${this_y} "$text" \
        "${pfx}_bg_tmp.png" && mv "${pfx}_bg_tmp.png" "${pfx}_bg.png"

    # Draw on highlight overlay (red fill + blue stroke for spumux 3-color mask)
    run_logged "$LOG_DIR/$(basename "$pfx")_convert_hl${i}.log" \
      convert "${pfx}_hl.png" +antialias \
        -gravity NorthWest -fill red -stroke blue -strokewidth 1 -font "$FONT" -pointsize "$this_ps" \
        -annotate +${text_x}+${this_y} "$text" \
        -colors 3 \
        "${pfx}_hl_tmp.png" && mv "${pfx}_hl_tmp.png" "${pfx}_hl.png"
  done

  # ---- Draw pagination buttons (centered at bottom) ----
  if [ "$num_pairs" -gt 0 ]; then
    # Place pagination buttons in a row at the very bottom
    local pag_y=$((menu_h - 40))
    local pag_total_w=$(( num_pairs * 160 ))
    local pag_start_x=$(( (menu_w - pag_total_w) / 2 ))
    local pag_ps=$(( point_size - 2 ))
    [ "$pag_ps" -lt "$MIN_POINT_SIZE" ] && pag_ps=$MIN_POINT_SIZE

    for p in $(seq 0 $((num_pairs - 1))); do
      local pidx=$(( p * 2 ))
      local ptxt="${vmgm_pairs[$pidx]}"
      local pcmd="${vmgm_pairs[$((pidx + 1))]}"
      local btn_global_idx=$((num_items + p))

      local px=$(( pag_start_x + p * 160 ))
      # Center text within its 160px slot
      local ptx=$(( px + 80 ))

      y0_arr[$btn_global_idx]=$((pag_y - 5))
      y1_arr[$btn_global_idx]=$((pag_y + pag_ps + 5))
      x0_arr[$btn_global_idx]=$((px - 10))
      x1_arr[$btn_global_idx]=$((px + 150))

      # Draw on background (cyan-ish for pagination)
      run_logged "$LOG_DIR/$(basename "$pfx")_convert_bg_pag${p}.log" \
        convert "${pfx}_bg.png" \
          -gravity NorthWest -fill "#66ccff" -font "$FONT" -pointsize "$pag_ps" \
          -annotate +${ptx}+${pag_y} "$ptxt" \
          "${pfx}_bg_tmp.png" && mv "${pfx}_bg_tmp.png" "${pfx}_bg.png"

      # Draw on highlight overlay
      run_logged "$LOG_DIR/$(basename "$pfx")_convert_hl_pag${p}.log" \
        convert "${pfx}_hl.png" +antialias \
          -gravity NorthWest -fill red -stroke blue -strokewidth 1 -font "$FONT" -pointsize "$pag_ps" \
          -annotate +${ptx}+${pag_y} "$ptxt" \
          -colors 3 \
          "${pfx}_hl_tmp.png" && mv "${pfx}_hl_tmp.png" "${pfx}_hl.png"
    done
  fi

  # ---- Generate blank menu video ----
  run_logged "$LOG_DIR/$(basename "$pfx")_ffmpeg_blank.log" \
    ffmpeg -y -f lavfi -i "color=c=black:s=${menu_w}x${menu_h}:d=${MENU_SECONDS}:r=${FPS}" \
            -f lavfi -i "anullsrc=r=48000:cl=stereo" \
            -shortest -pix_fmt yuv420p -target "$TARGET" \
            -b:v 6000k -maxrate 9000k -minrate 6000k -bufsize 1835k \
            "${pfx}_blank.mpg"

  # ---- Overlay background onto blank video ----
  run_logged "$LOG_DIR/$(basename "$pfx")_ffmpeg_merge.log" \
    ffmpeg -y -i "${pfx}_blank.mpg" -i "${pfx}_bg.png" \
            -filter_complex "[0:v][1:v]overlay=0:0[v]" -map "[v]" -map 0:a \
            -c:a copy -pix_fmt yuv420p -target "$TARGET" -f dvd \
            -b:v 6000k -maxrate 9000k -minrate 6000k -bufsize 1835k \
            "${pfx}_merged.mpg"

  # ---- Generate spumux XML ----
  {
    echo '<subpictures><stream>'
    # Add end="9999" so buttons don't disappear when the menu video loops
    echo "  <spu start=\"0\" end=\"9999\" force=\"yes\" highlight=\"${pfx}_hl.png\" select=\"${pfx}_hl.png\">"
    for i in "${!labels[@]}"; do
      local up=$(( (i - 1 + num_items) % num_items ))
      local down=$(( (i + 1) % num_items ))
      echo "    <button name=\"b$i\" x0=\"${x0_arr[$i]}\" y0=\"${y0_arr[$i]}\" x1=\"${x1_arr[$i]}\" y1=\"${y1_arr[$i]}\" up=\"b$up\" down=\"b$down\" />"
    done
    for p in $(seq 0 $((num_pairs - 1))); do
      local btn_global_idx=$((num_items + p))
      echo "    <button name=\"b${btn_global_idx}\" x0=\"${x0_arr[$btn_global_idx]}\" y0=\"${y0_arr[$btn_global_idx]}\" x1=\"${x1_arr[$btn_global_idx]}\" y1=\"${y1_arr[$btn_global_idx]}\" up=\"b$(( (btn_global_idx - 1 + total_buttons) % total_buttons ))\" down=\"b$(( (btn_global_idx + 1) % total_buttons ))\" />"
    done
    echo '  </spu>'
    echo '</stream></subpictures>'
  } > "${pfx}_btn.xml"

  # ---- Mux highlights with spumux ----
  run_logged "$LOG_DIR/$(basename "$pfx")_spumux.log" \
    bash -c "spumux -m dvd '${pfx}_btn.xml' < '${pfx}_merged.mpg' > '$out_mpg'"

  [ -s "$out_mpg" ] || { echo "ERROR: spumux produced an empty/missing menu video: $out_mpg" >&2; exit 1; }

  # Export pagination info for caller to use in dvdauthor XML. We use a sidecar file since bash functions can't return arrays cleanly
  if [ "$num_pairs" -gt 0 ]; then
    {
      echo "NUM_ITEMS=$num_items"
      echo "NUM_PAIRS=$num_pairs"
      for p in $(seq 0 $((num_pairs - 1))); do
        local pidx=$(( p * 2 ))
        echo "PAG_LABEL_${p}=${vmgm_pairs[$pidx]}"
        echo "PAG_CMD_${p}=${vmgm_pairs[$((pidx + 1))]}"
      done
    } > "${pfx}_paginfo.sh"
  else
    : > "${pfx}_paginfo.sh"
  fi
}


# ===========================================================================
# ANALYSIS (ffprobe + filesystem scans only; no bdsup2sub, no spumux, no ffmpeg encoding, no dvdauthor)
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
    local cat_display="${extras_categories[$i]}"
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

# ---------------------------------------------------------------------------
# Generate paginated Extras Menus
# ---------------------------------------------------------------------------
# Each page holds at most EXTRAS_PER_PAGE items. If there are multiple pages,
# "Next page" / "Prev page" buttons are added as VMGM-pair buttons that
# jump to the appropriate VMGM PGC.
#
# VMGM PGC layout:
#   PGC 1 = Main Menu (already generated above)
#   PGC 2 = Extras Page 1  (or the only extras page)
#   PGC 3 = Extras Page 2  (if needed)
#   ...
#   PGC N = Extras Page N-1
# ---------------------------------------------------------------------------
EXTRAS_VMGM_PGCS=()  # array of PGC XML blocks for the <vmgm><menus> section

if [ ${#EXTRAS_MENU_LABELS[@]} -gt 0 ]; then
  local_num_extras=${#EXTRAS_MENU_LABELS[@]}
  local_num_pages=$(( (local_num_extras + EXTRAS_PER_PAGE - 1) / EXTRAS_PER_PAGE ))

  echo " Generating VMGM Extras Menus ($local_num_pages page(s), $EXTRAS_PER_PAGE per page)..."

  for page in $(seq 0 $((local_num_pages - 1))); do
    local page_start=$(( page * EXTRAS_PER_PAGE ))
    local page_end=$(( page_start + EXTRAS_PER_PAGE ))
    [ "$page_end" -gt "$local_num_extras" ] && page_end=$local_num_extras

    local page_labels=()
    local page_targets=()
    for i in $(seq "$page_start" $((page_end - 1))); do
      page_labels+=("${EXTRAS_MENU_LABELS[$i]}")
      page_targets+=("${EXTRAS_MENU_TARGETS[$i]}")
    done

    # Always add "Main Menu" at the bottom
    page_labels+=("Main Menu")
    page_targets+=("g1 = 0; g2 = 0; jump vmgm menu entry title;")

    # Build pagination pair args for build_menu
    local pag_args=()
    if [ "$local_num_pages" -gt 1 ]; then
      if [ "$page" -gt 0 ]; then
        pag_args+=("<< Prev page" "jump vmgm menu $((page + 1));")
      fi
      if [ "$page" -lt $((local_num_pages - 1)) ]; then
        pag_args+=("Next page >>" "jump vmgm menu $((page + 3));")
      fi
    fi

    local page_mpg="$WORK_DIR/vmgm_extras_p${page}.mpg"
    local page_title="Extras Menu"
    [ "$local_num_pages" -gt 1 ] && page_title="Extras Menu (Page $((page + 1))/$local_num_pages)"

    # Call build_menu with optional --vmgm-pairs-- sentinel
    if [ ${#pag_args[@]} -gt 0 ]; then
      build_menu "$page_mpg" "$page_title" "${page_labels[@]}" "--vmgm-pairs--" "${pag_args[@]}"
    else
      build_menu "$page_mpg" "$page_title" "${page_labels[@]}"
    fi

    # Source the pagination info sidecar
    local paginfo="${page_mpg%.mpg}_paginfo.sh"
    local pag_num_items=0 pag_num_pairs=0
    if [ -f "$paginfo" ]; then
      source "$paginfo"
    fi

    # Build the PGC XML block
    local pgc_xml=""
    local pgc_num=$(( page + 2 ))  # PGC 1 = main menu, extras start at PGC 2
    pgc_xml+="      <pgc>\n"
    pgc_xml+="        <vob file=\"$page_mpg\" pause=\"inf\" />\n"

    # Regular buttons (content + "Main Menu")
    for i in "${!page_targets[@]}"; do
      pgc_xml+="        <button name=\"b$i\"> { ${page_targets[$i]} } </button>\n"
    done

    # Pagination buttons
    for p in $(seq 0 $((pag_num_pairs - 1))); do
      local btn_idx=$(( ${#page_targets[@]} + p ))
      eval "local pcmd=\"\$PAG_CMD_${p}\""
      pgc_xml+="        <button name=\"b${btn_idx}\"> { $pcmd } </button>\n"
    done

    pgc_xml+="      </pgc>\n"
    EXTRAS_VMGM_PGCS+=("$pgc_xml")
  done
fi

generate_extras_pgc_xml "${EXTRAS_MENU_LABELS[@]}"
assemble_dvdauthor_xml
author_dvd