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
# ----------------------------------------------------------------------------

# Source split modules
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/generate_dvd_with_menus/utils.sh"
source "$SCRIPT_DIR/generate_dvd_with_menus/subtitles.sh"
source "$SCRIPT_DIR/generate_dvd_with_menus/html_preview.sh"

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
# - Use configured MAIN_MOVIE when it exists and is non-empty.
# - Otherwise fall back to the first non-empty .mpg in the current directory.
if [ ! -f "$MAIN_MOVIE" ] || [ ! -s "$MAIN_MOVIE" ]; then
  echo "Configured main movie missing or empty: $MAIN_MOVIE"
  shopt -s nullglob
  candidates=( *.mpg )
  shopt -u nullglob
  MAIN_MOVIE=""
  for candidate in "${candidates[@]}"; do
    if [ -s "$candidate" ]; then
      MAIN_MOVIE="$candidate"
      break
    fi
  done
  [ -n "$MAIN_MOVIE" ] || { echo "ERROR: no usable main .mpg file found in current directory." >&2; exit 1; }
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
# ---------------------------------------------------------------------------
# FORMAT DETECTION (PAL vs NTSC, resolution)
# ---------------------------------------------------------------------------
detect_dvd_format() {
  local file="$1"
  local vcodec
  vcodec="$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_name -of csv=p=0 "$file" 2>/dev/null || true)"
  [ -n "$vcodec" ] || { echo "ERROR: no video stream found in $file" >&2; exit 1; }
  # Trim trailing comma
  vcodec="${vcodec%,}"
  # ...Or strip all trailing non-alphanumeric characters (safer for rogue spaces/commas):
  # vcodec=$(echo "$CODEC" | tr -d '[:space:]' | sed 's/[^a-zA-Z0-9]*$//')
  if [ "$vcodec" != "mpeg2video" ]; then
    echo "ERROR: $file is encoded as '$vcodec'; DVD-Video authoring requires mpeg2video." >&2
    exit 1
  fi

  local w h
  w="$(ffprobe -v error -select_streams v:0 -show_entries stream=width -of default=noprint_wrappers=1:nokey=1 "$file" 2>/dev/null || true)"
  h="$(ffprobe -v error -select_streams v:0 -show_entries stream=height -of default=noprint_wrappers=1:nokey=1 "$file" 2>/dev/null || true)"
  if [[ ! "$w" =~ ^[0-9]+$ || ! "$h" =~ ^[0-9]+$ ]]; then
    echo "ERROR: unparsable dimensions '${w}x${h}' from $file" >&2
    exit 1
  fi
  local rate_raw
  rate_raw="$(ffprobe -v error -select_streams v:0 -show_entries stream=r_frame_rate -of default=noprint_wrappers=1:nokey=1 "$file" 2>/dev/null || true)"
  # Remove any accidental whitespace / CR characters.
  rate_raw="$(printf '%s' "$rate_raw" | tr -d '\r\n[:space:]')"

  [[ "$rate_raw" == */* ]] || {
    echo "ERROR: could not read frame rate from $file" >&2
    exit 1
  }
  local num="${rate_raw%/*}"
  local den="${rate_raw#*/}"
  [[ "$num" =~ ^[0-9]+$ && "$den" =~ ^[0-9]+$ && "$den" -ne 0 ]] || {
    echo "ERROR: unparsable frame rate '$rate_raw' from $file" >&2
    exit 1
  }
  local fps_x1000=$(( num * 1000 / den ))

  local fmt=""
  if [ "$fps_x1000" -ge 24900 ] && [ "$fps_x1000" -le 25100 ]; then
    fmt="pal"
  elif [ "$fps_x1000" -ge 29800 ] && [ "$fps_x1000" -le 29980 ]; then
    fmt="ntsc"
  else
    echo "ERROR: unsupported frame rate '$rate_raw' in $file." >&2
    exit 1
  fi

  if [ "$fmt" = "pal" ] && [ "$h" -ne 576 ]; then
    echo "ERROR: PAL frame rate detected but height is ${h}px (expected 576) in $file." >&2
    exit 1
  fi

  if [ "$fmt" = "ntsc" ] && [ "$h" -ne 480 ]; then
    echo "ERROR: NTSC frame rate detected but height is ${h}px (expected 480) in $file." >&2
    exit 1
  fi
  DETECTED_FORMAT="$fmt"
  export VIDEO_FORMAT="${fmt^^}"
  WIDTH="$w"
  HEIGHT="$h"
  if [ "$fmt" = "pal" ]; then
    TARGET="pal-dvd"
    FPS="25"
  else
    TARGET="ntsc-dvd"
    FPS="30000/1001"
  fi
  echo ""
  echo " Video: $(basename "$file") (${fmt^^})"
  echo "  $vcodec $TARGET @ ${w}x${h} ($rate_raw fps)"
}
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

  local top_margin=100
  local line_h=$(( (menu_h - top_margin - 60) / num_items ))
  [ "$line_h" -gt 70 ] && line_h=70
  [ "$line_h" -lt $((MIN_POINT_SIZE + 6)) ] && line_h=$((MIN_POINT_SIZE + 6))
  local point_size=$(( line_h / 2 + 10 ))
  [ "$point_size" -gt "$MAX_POINT_SIZE" ] && point_size=$MAX_POINT_SIZE
  [ "$point_size" -lt "$MIN_POINT_SIZE" ] && point_size=$MIN_POINT_SIZE
  local left_margin=$(( menu_w / 6 ))
  local right_margin=$(( menu_w / 20 ))

  if [ $(( top_margin + num_items * line_h )) -gt "$menu_h" ]; then
    echo "WARNING: menu '$title_text' has $num_items items and may overflow frame." >&2
  fi
  echo "  -> Building Menu: $title_text"
  echo "     Target: ${menu_w}x${menu_h} (${DETECTED_FORMAT^^})"
  echo "     Layout: $num_items items @ ${point_size}pt"
  echo "     Buttons:"
  for i in "${!labels[@]}"; do
    printf "       %d - %s\n" "$i" "${labels[$i]}"
  done
  echo "+-- Muxing menu stream..."
  run_logged "$LOG_DIR/$(basename "$pfx")_convert_bg0.log" \
    convert -size "${menu_w}x${menu_h}" xc:black \
      -gravity NorthWest -fill white -font "$FONT" -pointsize 42 \
      -annotate +${left_margin}+$((top_margin - 60)) "$title_text" \
      "${pfx}_bg.png"

  run_logged "$LOG_DIR/$(basename "$pfx")_convert_hl0.log" \
    convert -size "${menu_w}x${menu_h}" xc:none "${pfx}_hl.png"

  local y0_arr=() y1_arr=()
  for i in "${!labels[@]}"; do
    local text="${labels[$i]}"
    local max_chars=$(( (menu_w - left_margin - right_margin) * 10 / (point_size * 6) ))
    [ "$max_chars" -lt 4 ] && max_chars=4

    if [ "${#text}" -gt "$max_chars" ]; then
      text="${text:0:$((max_chars - 1))}…"
    fi
    local y=$((top_margin + i * line_h))
    # Tightly wrap the text bounding box (text starts at 'y' with NorthWest gravity)
    y0_arr[$i]=$((y - 5))
    y1_arr[$i]=$((y + point_size + 5))
    # Use temporary file for ImageMagick to prevent corruption
    run_logged "$LOG_DIR/$(basename "$pfx")_convert_bg${i}.log" \
      convert "${pfx}_bg.png" \
        -gravity NorthWest -fill white -font "$FONT" -pointsize "$point_size" \
        -annotate +${left_margin}+${y} "$text" \
        "${pfx}_bg_tmp.png" && mv "${pfx}_bg_tmp.png" "${pfx}_bg.png"
    # Use red fill and blue stroke so spumux has 3 distinct colors (transparent, red, blue) to pick masks. Disable anti-aliasing and force 3 colors to satisfy spumux's 16-color limit
    run_logged "$LOG_DIR/$(basename "$pfx")_convert_hl${i}.log" \
      convert "${pfx}_hl.png" +antialias \
        -gravity NorthWest -fill red -stroke blue -strokewidth 1 -font "$FONT" -pointsize "$point_size" \
        -annotate +${left_margin}+${y} "$text" \
        -colors 3 \
        "${pfx}_hl_tmp.png" && mv "${pfx}_hl_tmp.png" "${pfx}_hl.png"
  done
  run_logged "$LOG_DIR/$(basename "$pfx")_ffmpeg_blank.log" \
    ffmpeg -y -f lavfi -i "color=c=black:s=${menu_w}x${menu_h}:d=${MENU_SECONDS}:r=${FPS}" \
            -f lavfi -i "anullsrc=r=48000:cl=stereo" \
            -shortest -pix_fmt yuv420p -target "$TARGET" \
            -b:v 6000k -maxrate 9000k -minrate 6000k -bufsize 1835k \
            "${pfx}_blank.mpg"
  run_logged "$LOG_DIR/$(basename "$pfx")_ffmpeg_merge.log" \
    ffmpeg -y -i "${pfx}_blank.mpg" -i "${pfx}_bg.png" \
            -filter_complex "[0:v][1:v]overlay=0:0[v]" -map "[v]" -map 0:a \
            -c:a copy -pix_fmt yuv420p -target "$TARGET" -f dvd \
            -b:v 6000k -maxrate 9000k -minrate 6000k -bufsize 1835k \
            "${pfx}_merged.mpg"
  {
    echo '<subpictures><stream>'
    echo "  <spu start=\"0\" force=\"yes\" highlight=\"${pfx}_hl.png\" select=\"${pfx}_hl.png\">"
    for i in "${!labels[@]}"; do
      local up=$(( (i - 1 + num_items) % num_items ))
      local down=$(( (i + 1) % num_items ))
      echo "    <button name=\"b$i\" x0=\"$((left_margin - 20))\" y0=\"${y0_arr[$i]}\" x1=\"$((menu_w - left_margin))\" y1=\"${y1_arr[$i]}\" up=\"b$up\" down=\"b$down\" />"
    done
    echo '  </spu>'
    echo '</stream></subpictures>'
  } > "${pfx}_btn.xml"

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

  # Snapshot the globals set by [discover_subs]/[mux_subs] for this titleset,
  # since build_menu() below will call other helpers that could otherwise
  # clobber CURRENT_* before we're done using them.
  local has_subs="$CURRENT_HAS_SUBS"
  local muxed_mpg="$CURRENT_MUXED_MPG"
  local default_subp="$CURRENT_DEFAULT_SUBP"
  local sub_labels=("${CURRENT_SUB_LABELS[@]}")

  XML_TITLESETS+="  <titleset>\n"

  if [ "$has_subs" -eq 1 ]; then
    local menu_mpg="$WORK_DIR/ts${ts_idx}_menu.mpg"
    # TODO "Extras Menu" / "Main Menu"?
    local labels=("${sub_labels[@]}" "No subtitles" "Main Menu")

    local menu_title="Subtitles: ${title_pretty}"
    [ "$ts_idx" -eq 1 ] && menu_title="Movie Subtitles"

    build_menu "$menu_mpg" "$menu_title" "${labels[@]}"

    XML_TITLESETS+="    <menus lang=\"en\">\n      <video format=\"${DETECTED_FORMAT}\" resolution=\"${WIDTH}x${HEIGHT}\" />\n"
    XML_TITLESETS+="      <pgc entry=\"root,subtitle\" pause=\"inf\">\n        <vob file=\"$menu_mpg\" />\n"
    local btn_idx=0
    for i in "${!sub_labels[@]}"; do
      local val=$((64 + i))
      # Explicitly specify the titleset index for the jump
      XML_TITLESETS+="        <button name=\"b$btn_idx\"> { subtitle = $val; if (g1 eq 1) resume; else jump titleset $ts_idx title 1; } </button>\n"
      btn_idx=$((btn_idx+1))
    done

    #  Explicitly specify the titleset index for the jump
    XML_TITLESETS+="        <button name=\"b$btn_idx\"> { subtitle = 62; if (g1 eq 1) resume; else jump titleset $ts_idx title 1; } </button>\n"
    btn_idx=$((btn_idx+1))
    XML_TITLESETS+="        <button name=\"b$btn_idx\"> { g1 = 0; jump vmgm menu entry title; } </button>\n"

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
    # Each titleset gets its own default subtitle stream applied on entry, rather than silently inheriting whatever the VMGM fpc set for the main movie (or whatever the viewer last left the register at).
    XML_TITLESETS+="        <pre> { g1 = 1; subtitle = ${default_subp}; } </pre>\n"
  else
    XML_TITLESETS+="        <pre> { g1 = 1; } </pre>\n"
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
  else
    ANALYSIS_SUBS_STR+=("")
  fi
done

# Generate the HTML Preview
generate_html_preview

echo ""
echo "============================================================="
read -r -p "Analysis complete. Proceed with encoding and DVD authoring? [Y/n] " CONFIRM_REPLY
case "${CONFIRM_REPLY,,}" in
  ""|y|yes) ;;
  *) echo "Aborted — no encoding was performed." >&2; exit 1 ;;
esac
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
  # Set g1=0 so we don't resume an old title. If g1 was left at 1 from some earlier call, jumping into an extra's subtitle menu would misread that stale value and resume back into whatever was last call'd (the main movie) instead of jumping fresh into the extra.
  VMGM_TARGETS+=("g1 = 0; jump titleset 1 menu;")
  MAIN_DEFAULT_SUBP=$CURRENT_DEFAULT_SUBP
  FPC_JUMP="g1 = 0; jump titleset 1 menu entry root;"
else
  VMGM_TARGETS+=("g1 = 0; jump titleset 1 title 1;")
  MAIN_DEFAULT_SUBP=62
  FPC_JUMP="g1 = 0; jump titleset 1 title 1;"
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
      # Set g1=0 so we don't resume the main movie
      EXTRAS_MENU_TARGETS+=("g1 = 0; jump titleset $TS_IDX menu;")
    else
      EXTRAS_MENU_TARGETS+=("g1 = 0; jump titleset $TS_IDX title 1;")
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
  # Set g1=0 (extras)
  VMGM_TARGETS+=("g1 = 0; jump vmgm menu 2;")
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
  # Set g1=0 (extras)
  EXTRAS_MENU_TARGETS+=("g1 = 0; jump vmgm menu entry title;")
  build_menu "$VMGM_EXTRAS_MPG" "Extras Menu" "${EXTRAS_MENU_LABELS[@]}"
fi
XML_FILE="$WORK_DIR/dvdauthor.xml"
printf '<?xml version="1.0"?>\n' > "$XML_FILE"
printf '<dvdauthor dest="%s" jumppad="yes">\n\n' "$OUT_DIR" >> "$XML_FILE"

printf '  <vmgm>\n' >> "$XML_FILE"
printf '    <fpc>\n      { g1 = 0; subtitle = %d; %s }\n    </fpc>\n' "$MAIN_DEFAULT_SUBP" "$FPC_JUMP" >> "$XML_FILE"
printf '    <menus>\n      <video format="%s" resolution="%sx%s" />\n' "$DETECTED_FORMAT" "$WIDTH" "$HEIGHT" >> "$XML_FILE"

# PGC 1: Main Menu
printf '      <pgc entry="title" pause="inf">\n' >> "$XML_FILE"
printf '        <vob file="%s" />\n' "$VMGM_MPG" >> "$XML_FILE"
for i in "${!VMGM_TARGETS[@]}"; do
  printf '        <button name="b%i"> { %s } </button>\n' "$i" "${VMGM_TARGETS[$i]}" >> "$XML_FILE"
done
printf '      </pgc>\n' >> "$XML_FILE"

# PGC 2: Extras Menu (only if extras exist)
if [ -n "$VMGM_EXTRAS_MPG" ]; then
  printf '      <pgc pause="inf">\n' >> "$XML_FILE"
  printf '        <vob file="%s" />\n' "$VMGM_EXTRAS_MPG" >> "$XML_FILE"
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
echo "============================================================="
echo " DVD BUILD COMPLETE"
echo " Structure: $OUT_DIR_ABS"
echo " Preview:   vlc \"dvd://${OUT_DIR_ABS}\""
echo "============================================================="