#!/usr/bin/env bash
# ============================================================================
#  build_dvd.sh — dynamic DVD builder (Movie + Extras)
# ============================================================================
#  What it does:
#   1. Scans MAIN_MOVIE and EXTRAS_DIR for .mpg files.
#   2. Detects PAL/NTSC + resolution from the main movie's own stream data (frame rate + frame size) and authors the whole disc to match.
#   3. For every video, looks for matching subtitle .idx/.sub, .sub.idx, or .sup files, recognizing patterns like _track{n}_{lang}, _track{n}_{lang}_exp, etc.
#   4. Normalizes language names and selects default subtitles based on config (e.g., Dutch) falling back to 'track0' if no config match is found.
#   5. Dynamic VMGM menu & per-titleset subtitle menus.
#   6. Builds dvdauthor.xml structure and compiles the final DVD.
# ============================================================================
set -euo pipefail

# ----------------------------- CONFIG ---------------------------------------
MAIN_MOVIE=""      # Pre-encoded MPEG2 main feature, like './Movie Name_pal.mpg' or falls back to first .mpg in root
EXTRAS_DIR="./extras"                  # Folder optionally containing extra .mpg files
WORK_DIR="./work"                      # Scratch space, safe to delete after success
OUT_DIR="./dvd"                        # Final DVD-Video output structure
DEFAULT_HINT="nl"                      # Substring for default lang (e.g. "nl" or "dutch")
MENU_SECONDS=8                         # Loop duration for static menus
MIN_POINT_SIZE=14                      # Never shrink menu text below this
MAX_POINT_SIZE=36
ASSUME_YES=false # to handle non-interactive runs
# ----------------------------- CLI ARGS ------------------------------------
# Defaults come from the CONFIG block above; CLI flags override them here.
INPUT_DIR="."

print_help() {
  cat <<EOF
Usage: $0 [OPTIONS]

Build a DVD-Video from a main movie .mpg plus optional extras.

Options:
  -i, --input  DIR      Directory to scan for the main movie .mpg (default: .)
  -e, --extras DIR      Directory containing extra .mpg files (default: ./extras)
  -m, --main   FILE     Explicit main movie .mpg (overrides auto-detection)
  -o, --out    DIR      Final DVD-Video output directory (default: ./dvd)
  -w, --work   DIR      Scratch/working directory (default: ./work)
  -d, --default LANG    Default subtitle language hint, e.g. "nl" (default: nl)
  -h, --help            Show this help and exit

Examples:
  $0 -i ./movies -e ./movies/extras
  $0 --input /data/movies --main "/data/movies/Movie Name_pal.mpg"
  $0 -i . -o ./out_dvd
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    -i|--input)   INPUT_DIR="$2";    shift 2 ;;
    -e|--extras)  EXTRAS_DIR="$2";   shift 2 ;;
    -m|--main)    MAIN_MOVIE="$2";   shift 2 ;;
    -o|--out)     OUT_DIR="$2";      shift 2 ;;
    -w|--work)    WORK_DIR="$2";     shift 2 ;;
    -d|--default) DEFAULT_HINT="$2"; shift 2 ;;
    -h|--help)    print_help; exit 0 ;;
    -y|--yes)     ASSUME_YES=true; shift 1 ;;
    --) shift; break ;;
    *) echo "Unknown option: $1" >&2; print_help; exit 1 ;;
  esac
done

# Validate INPUT_DIR early so the user gets a clean error before tool checks.
[ -d "$INPUT_DIR" ] || { echo "ERROR: --input directory not found: $INPUT_DIR" >&2; exit 1; }
# ----------------------------------------------------------------------------

# Source split modules
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/utils.sh"
source "$SCRIPT_DIR/subtitles.sh"
source "$SCRIPT_DIR/html_preview.sh"
source "$SCRIPT_DIR/detect_dvd_format.sh"

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

# 1. Prefer the native bdsup2sub++ executable from PATH.
if command -v bdsup2sub++ >/dev/null 2>&1; then
  BDSUP2SUB_CMD=("$(command -v bdsup2sub++)")

# 2. Look for local development/build copies of bdsup2sub++.
else
  for candidate in "./VobSub-Utilities/bdsup2sub++" "./VobSub-Utilities/build/bdsup2sub++" "./sup2vobsub/bdsup2sub++" "./sup2vobsub/build/bdsup2sub++"; do
    if [ -x "$candidate" ]; then BDSUP2SUB_CMD=("$candidate"); break; fi
  done

  # 3. Fall back to the original Java bdsup2sub wrapper in PATH.
  if [ ${#BDSUP2SUB_CMD[@]} -eq 0 ] && command -v bdsup2sub >/dev/null 2>&1; then
    BDSUP2SUB_CMD=("$(command -v bdsup2sub)")

  # 4. Fall back to a local bdsup2sub.jar.
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

# Define fallback fonts (sans-serif bold preferred)
FALLBACK_FONTS=("Arial-Bold" "DejaVu-Sans-Bold" "Helvetica-Bold" "Ubuntu-Sans-Condensed-Bold" "DejaVu-Sans-Mono-Bold")
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
# HELPER: Build a dynamic menu (Graphics + Video + Spumux logic)
# ---------------------------------------------------------------------------
build_menu() {
  local out_mpg="$1"
  local title_text="$2"
  shift 2
  local labels=("$@")
  local num_items=${#labels[@]}
  local pfx="${out_mpg%.mpg}"

  [ "$num_items" -gt 0 ] || { echo "ERROR: build_menu called with zero labels for $out_mpg" >&2; exit 1; }
  # DVD spec limits to 36 buttons per PGC
  [ "$num_items" -le 36 ] || { echo "ERROR: Too many buttons ($num_items) in menu '$title_text'. Max 36." >&2; exit 1; }

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
  [[ "$title_text" == "Extras Menu" ]] && is_extras_menu=true

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
  echo "     Layout: $num_items items @ ${point_size}pt (title @ ${title_size}pt)"
  [ "$is_extras_menu" = true ] && echo "     (Extras menu: reduced font)"
  echo "     Buttons:"
  for i in "${!labels[@]}"; do
    local tag=""
    for ni in "${nav_indices[@]}"; do
      [ "$i" = "$ni" ] && tag=" [NAV]" && break
    done
    printf "       %d - %s%s\n" "$i" "${labels[$i]}" "$tag"
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

  # ---- Build background with gradient title bar ----
  local third_h=$((title_bar_h / 3))
  run_logged "$LOG_DIR/$(basename "$pfx")_convert_bg0.log" \
    convert -size "${menu_w}x${menu_h}" xc:black \
      -fill "#08081a" -draw "rectangle 0,0 ${menu_w},${third_h}" \
      -fill "#12122a" -draw "rectangle 0,${third_h} ${menu_w},$((third_h * 2))" \
      -fill "#1a1a2e" -draw "rectangle 0,$((third_h * 2)) ${menu_w},${title_bar_h}" \
      -fill "#555577" -draw "rectangle 0,${title_bar_h} ${menu_w},$((title_bar_h + 2))" \
      -gravity NorthWest -fill white -font "$FONT" -pointsize "$title_size" \
      -annotate +${left_margin}+${title1_y} "$title_line1" \
      "${pfx}_bg.png"

  # Second title line (lighter color for visual hierarchy)
  if [ -n "$title_line2" ]; then
    local line2_size=$((title_size - 4))
    [ "$line2_size" -lt "$MIN_POINT_SIZE" ] && line2_size=$MIN_POINT_SIZE
    run_logged "$LOG_DIR/$(basename "$pfx")_convert_bg0b.log" \
      convert "${pfx}_bg.png" \
        -gravity NorthWest -fill "#9999bb" -font "$FONT" -pointsize "$line2_size" \
        -annotate +${left_margin}+${title2_y} "$title_line2" \
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

  # ---- Draw all buttons ----
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

    # Draw on background with appropriate color
    run_logged "$LOG_DIR/$(basename "$pfx")_convert_bg${i}.log" \
      convert "${pfx}_bg.png" \
        -gravity NorthWest -fill "$this_color" -font "$FONT" -pointsize "$this_ps" \
        -annotate +${this_left}+${this_y} "$text" \
        "${pfx}_bg_tmp.png" && mv "${pfx}_bg_tmp.png" "${pfx}_bg.png"

    # Draw on highlight overlay (red fill + blue stroke for spumux 3-color mask)
    run_logged "$LOG_DIR/$(basename "$pfx")_convert_hl${i}.log" \
      convert "${pfx}_hl.png" +antialias \
        -gravity NorthWest -fill red -stroke blue -strokewidth 1 -font "$FONT" -pointsize "$this_ps" \
        -annotate +${this_left}+${this_y} "$text" \
        -colors 3 \
        "${pfx}_hl_tmp.png" && mv "${pfx}_hl_tmp.png" "${pfx}_hl.png"
  done

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
    echo '  </spu>'
    echo '</stream></subpictures>'
  } > "${pfx}_btn.xml"

  # ---- Mux highlights with spumux ----
  run_logged "$LOG_DIR/$(basename "$pfx")_spumux.log" \
    bash -c "spumux -m dvd '${pfx}_btn.xml' < '${pfx}_merged.mpg' > '$out_mpg'"

  [ -s "$out_mpg" ] || { echo "ERROR: spumux produced an empty/missing menu video: $out_mpg" >&2; exit 1; }
}

# ---------------------------------------------------------------------------
# CORE LOGIC GLOBALS
# ---------------------------------------------------------------------------
XML_TITLESETS=""
VMGM_LABELS=()
VMGM_TARGETS=()

CURRENT_SUB_LABELS=()
CURRENT_HAS_SUBS=0
CURRENT_MUXED_MPG=""
CURRENT_DEFAULT_SUBP=62 # 62 = off (DVD convention)
CURRENT_INPUT_FILES=()
CURRENT_DATA_FILES=()

# ---------------------------------------------------------------------------
# HELPER: Generate XML chunk for a single Titleset
# ---------------------------------------------------------------------------
append_titleset_xml() {
  local ts_idx="$1"
  local title_pretty="$2"

  # Snapshot the globals set by [discover_subs]/[mux_subs] for this titleset, since build_menu() below will call other helpers that could otherwise clobber CURRENT_* before we're done using them.
  local has_subs="$CURRENT_HAS_SUBS"
  local muxed_mpg="$CURRENT_MUXED_MPG"
  local default_subp="$CURRENT_DEFAULT_SUBP"
  local sub_labels=("${CURRENT_SUB_LABELS[@]}")

  XML_TITLESETS+="  <titleset>\n"

  if [ "$has_subs" -eq 1 ]; then
    local menu_mpg="$WORK_DIR/ts${ts_idx}_menu.mpg"
    # Build labels: subtitle options + navigation buttons
    local labels=("${sub_labels[@]}" "No subtitles")
    # Add "Back to Extras" for extra titlesets (ts_idx > 1 means it's an extra)
    if [ "$ts_idx" -gt 1 ]; then
      labels+=("Back to Extras")
    fi
    labels+=("Main Menu")

    local menu_title="Subtitles: ${title_pretty}"
    [ "$ts_idx" -eq 1 ] && menu_title="Movie Subtitles"

    build_menu "$menu_mpg" "$menu_title" "${labels[@]}"

    XML_TITLESETS+="    <menus lang=\"en\">\n      <video format=\"${DETECTED_FORMAT}\" resolution=\"${WIDTH}x${HEIGHT}\" />\n"
    # pause="inf" on <vob> holds the still-frame indefinitely. This prevents the cell from looping after MENU_SECONDS, which was causing the DVD VM to reset the button highlight state (visual selection lost).
    XML_TITLESETS+="      <pgc entry=\"root,subtitle\">\n        <vob file=\"$menu_mpg\" pause=\"inf\" />\n"
    local btn_idx=0
    for i in "${!sub_labels[@]}"; do
      local val=$((64 + i))
      # Set g2 = 1 so the title knows we explicitly chose this subtitle
      XML_TITLESETS+="        <button name=\"b$btn_idx\"> { subtitle = $val; g2 = 1; if (g1 eq 1) resume; else jump titleset $ts_idx title 1; } </button>\n"
      btn_idx=$((btn_idx+1))
    done

    # Set g2 = 1 for "No subtitles" as well
    XML_TITLESETS+="        <button name=\"b$btn_idx\"> { subtitle = 62; g2 = 1; if (g1 eq 1) resume; else jump titleset $ts_idx title 1; } </button>\n"
    btn_idx=$((btn_idx+1))

    # "Back to Extras" button (only for extras, ts_idx > 1) which jumps to PGC 2 in the VMGM, which is the Extras Menu.
    if [ "$ts_idx" -gt 1 ]; then
      XML_TITLESETS+="        <button name=\"b$btn_idx\"> { g1 = 0; g2 = 0; jump vmgm menu 2; } </button>\n"
      btn_idx=$((btn_idx+1))
    fi

    XML_TITLESETS+="        <button name=\"b$btn_idx\"> { g1 = 0; g2 = 0; jump vmgm menu entry title; } </button>\n"

    # Explicitly specify the titleset index for the jump
    XML_TITLESETS+="        <post> { if (g1 eq 1) resume; else jump titleset $ts_idx title 1; } </post>\n"
    XML_TITLESETS+="      </pgc>\n    </menus>\n"
  fi

  XML_TITLESETS+="    <titles>\n      <video format=\"${DETECTED_FORMAT}\" resolution=\"${WIDTH}x${HEIGHT}\" />\n"
  if [ "$has_subs" -eq 1 ]; then
    for i in "${!sub_labels[@]}"; do
      XML_TITLESETS+="      <subpicture />\n"
    done
  fi

  # dvdauthor throws "Unknown entry 'title'" if entry attribute is set inside <titles>. Removed `entry="title"`.
  XML_TITLESETS+="      <pgc>\n"
  if [ "$has_subs" -eq 1 ]; then
    # Only apply default subtitle if g2 eq 0 (meaning we didn't come from the subtitle menu)
    XML_TITLESETS+="        <pre> { if (g2 eq 0) { subtitle = ${default_subp}; } g1 = 1; g2 = 0; } </pre>\n"
  else
    XML_TITLESETS+="        <pre> { g1 = 1; g2 = 0; } </pre>\n"
  fi
  XML_TITLESETS+="        <vob file=\"$muxed_mpg\" chapters=\"0\" />\n"
  XML_TITLESETS+="        <post> { g1 = 0; call vmgm menu; } </post>\n"
  XML_TITLESETS+="      </pgc>\n    </titles>\n"
  XML_TITLESETS+="  </titleset>\n\n"
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

# --- Build the ordered list of videos: main movie first, then extras ---
ALL_VIDEOS=("$MAIN_MOVIE")

shopt -s nullglob
if [ -n "${EXTRAS_DIR:-}" ]; then
  extras_array=( "$EXTRAS_DIR"/*.mpg )
else
  extras_array=()
fi
shopt -u nullglob

echo ""
echo "============"
if [ ${#extras_array[@]} -gt 0 ]; then
  echo "== Extras == (${#extras_array[@]} found in $EXTRAS_DIR)"
else
  echo "== Extras ==  (none found)"
fi
echo "============"
for extra_mpg in "${extras_array[@]}"; do
  [ -s "$extra_mpg" ] || { echo "ERROR: extra file is empty: $extra_mpg" >&2; exit 1; }
  verify_matches_main_format "$extra_mpg"
  ALL_VIDEOS+=("$extra_mpg")
done

# Arrays to hold state for HTML preview
ANALYSIS_TITLES=()
ANALYSIS_SUBS_STR=()
ANALYSIS_DEFAULTS=()
ANALYSIS_HAS_SUBS=()
ANALYSIS_SUB_FILES=()   # pipe-separated subtitle entry files (.idx/.sub.idx/.sup/.srt) per title

if [ ${#ALL_VIDEOS[@]} -gt 99 ]; then
  echo "ERROR: too many titlesets (${#ALL_VIDEOS[@]}); DVD-Video supports at most 99." >&2
  exit 1
fi

# --- Discover subtitles for every video (main + extras) up front ---
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
echo "============================================================="
echo " DVD BUILDER — ENCODING & AUTHORING"
echo " Target Format: ${DETECTED_FORMAT^^} (${WIDTH}x${HEIGHT})"
echo "============================================================="
echo ""

# --- Process Titleset 1: Main Movie ---
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

# --- Process Titleset 2..N: Extras ---
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

# Generate Extras Menu if it exists
VMGM_EXTRAS_MPG=""
if [ ${#EXTRAS_MENU_LABELS[@]} -gt 0 ]; then
  echo " Generating VMGM Extras Menu..."
  VMGM_EXTRAS_MPG="$WORK_DIR/vmgm_extras_menu.mpg"
  EXTRAS_MENU_LABELS+=("Main Menu")
  EXTRAS_MENU_TARGETS+=("g1 = 0; g2 = 0; jump vmgm menu entry title;")
  build_menu "$VMGM_EXTRAS_MPG" "Extras Menu" "${EXTRAS_MENU_LABELS[@]}"
fi

XML_FILE="$WORK_DIR/dvdauthor.xml"
printf '<?xml version="1.0"?>\n' > "$XML_FILE"
printf '<dvdauthor dest="%s" jumppad="yes">\n\n' "$OUT_DIR" >> "$XML_FILE"

printf '  <vmgm>\n' >> "$XML_FILE"
# Set g2=0 in FPC as well
printf '    <fpc>\n      { g1 = 0; g2 = 0; subtitle = %d; %s }\n    </fpc>\n' "$MAIN_DEFAULT_SUBP" "$FPC_JUMP" >> "$XML_FILE"
printf '    <menus>\n      <video format="%s" resolution="%sx%s" />\n' "$DETECTED_FORMAT" "$WIDTH" "$HEIGHT" >> "$XML_FILE"

# pause="inf" on <vob> for all menu PGCs ensures that the still-frame holds indefinitely and prevents the cell from looping, which was causing the button highlight (visual selection) to be reset after MENU_SECONDS elapsed.
# PGC 1: Main Menu
printf '      <pgc entry="title">\n' >> "$XML_FILE"
printf '        <vob file="%s" pause="inf" />\n' "$VMGM_MPG" >> "$XML_FILE"
for i in "${!VMGM_TARGETS[@]}"; do
  printf '        <button name="b%i"> { %s } </button>\n' "$i" "${VMGM_TARGETS[$i]}" >> "$XML_FILE"
done
printf '      </pgc>\n' >> "$XML_FILE"

# PGC 2: Extras Menu (only if extras exist)
if [ -n "$VMGM_EXTRAS_MPG" ]; then
  printf '      <pgc>\n' >> "$XML_FILE"
  printf '        <vob file="%s" pause="inf" />\n' "$VMGM_EXTRAS_MPG" >> "$XML_FILE"
  for i in "${!EXTRAS_MENU_TARGETS[@]}"; do
    printf '        <button name="b%i"> { %s } </button>\n' "$i" "${EXTRAS_MENU_TARGETS[$i]}" >> "$XML_FILE"
  done
  printf '      </pgc>\n' >> "$XML_FILE"
fi

printf '    </menus>\n' >> "$XML_FILE"
printf '  </vmgm>\n\n' >> "$XML_FILE"

printf '%b' "$XML_TITLESETS" >> "$XML_FILE"
printf '</dvdauthor>\n' >> "$XML_FILE"

echo "Generated dvdauthor XML structure: $XML_FILE"
# ---------------------------------------------------------------------------
# AUTHOR DVD
# ---------------------------------------------------------------------------
echo "Clearing output directory: $OUT_DIR"
rm -rf "$OUT_DIR"
echo "Authoring DVD (this may take a moment)..."
run_logged "$LOG_DIR/dvdauthor.log" dvdauthor -x "$XML_FILE"

OUT_DIR_ABS="$(cd "$OUT_DIR" && pwd)"

# Normalize current folder name: lowercase, replace spaces/special chars with underscores
CURRENT_FOLDER_NAME="$(basename "$(pwd)")"
NORMALIZED_NAME="$(echo "$CURRENT_FOLDER_NAME" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/_/g' | sed -E 's/^_+|(_)+$//g')"
ISO_PATH="/tmp/${NORMALIZED_NAME}.iso"

echo "============================================================="
echo " DVD BUILD COMPLETE"
echo " Structure: $OUT_DIR_ABS"
echo " Preview:   vlc \"dvd://${OUT_DIR_ABS}\""
echo " Generate .iso: genisoimage -dvd-video -o \"$ISO_PATH\" \"$OUT_DIR_ABS\""
echo "============================================================="
