#!/usr/bin/env bash
# ============================================================================
#  build_dvd.sh — dynamic DVD builder (Movie + Extras)
# ============================================================================
#  What it does:
#   1. Scans MAIN_MOVIE and EXTRAS_DIR for .mpg files.
#   2. Detects PAL/NTSC + resolution from the main movie's own stream data
#      (frame rate + frame size) and authors the whole disc to match.
#   3. For every video, looks for matching subtitle .idx/.sub, .sub.idx, or .sup
#      files, recognizing patterns like _track{n}_{lang}, _track{n}_{lang}_exp, etc.
#   4. Normalizes language names and selects default subtitles based on config
#      (e.g., Dutch) falling back to 'track0' if no config match is found.
#   5. Dynamic VMGM menu & per-titleset subtitle menus.
#   6. Builds dvdauthor.xml structure and compiles the final DVD.
# ============================================================================
set -euo pipefail

# ----------------------------- CONFIG ---------------------------------------
MAIN_MOVIE=""      # Pre-encoded MPEG2 main feature, like './Movie Name_pal.mpg' or else falls back to the first .mpg file in root folder if not specified
EXTRAS_DIR="./extras"                  # Folder optionally containing extra .mpg files
WORK_DIR="./work"                      # Scratch space, safe to delete after success
OUT_DIR="./dvd"                        # Final DVD-Video output structure
DEFAULT_HINT="nl"                      # Substring for default lang (e.g. "nl" or "dutch")
MENU_SECONDS=8                         # Loop duration for static menus
MIN_POINT_SIZE=14                      # Never shrink menu text below this
MAX_POINT_SIZE=36
# ----------------------------------------------------------------------------

need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing required tool: $1" >&2; exit 1; }; }
# TODO notify user we need to `apt install ffmpeg` etc...
# ---------------------------------------------------------------------------
# BULLET-PROOF BDSUP2SUB / SUBTITLE TOOL RESOLUTION
# ---------------------------------------------------------------------------
# Ubuntu 24.04 (Noble) does not provide ogmrip in the standard repositories,
# even with the Universe repository enabled. Therefore, do not rely on ogmrip/subp2pgm being available through apt.
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
  for candidate in "./VobSub-Utilities/bdsup2sub++" "./VobSub-Utilities/build/bdsup2sub++" "./sup2vobsub/bdsup2sub++" "./sup2vobsub/build/bdsup2sub++"
  do
    if [ -x "$candidate" ]; then
      BDSUP2SUB_CMD=("$candidate")
      break
    fi
  done

  # 3. Fall back to the original Java bdsup2sub wrapper in PATH.
  if [ ${#BDSUP2SUB_CMD[@]} -eq 0 ] && command -v bdsup2sub >/dev/null 2>&1; then
    BDSUP2SUB_CMD=("$(command -v bdsup2sub)")

  # 4. Fall back to a local bdsup2sub.jar.
  elif [ ${#BDSUP2SUB_CMD[@]} -eq 0 ] &&
       command -v java >/dev/null 2>&1 &&
       [ -f "./bdsup2sub.jar" ]; then
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
FONT="$IM_FONT"                # convert -list font

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

  [ -n "$MAIN_MOVIE" ] || {
    echo "ERROR: no usable main .mpg file found in current directory." >&2
    exit 1
  }

  echo "Using fallback main movie: $MAIN_MOVIE"
fi

# Extras are optional. A missing/empty extras directory simply means no extras menu.
if [ ! -d "$EXTRAS_DIR" ]; then
  echo "Extras directory not found: $EXTRAS_DIR (continuing without extras)"
  EXTRAS_DIR=""
fi

rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR" "$OUT_DIR"

LOG_DIR="$WORK_DIR/logs"
mkdir -p "$LOG_DIR"

run_logged() {
  local log="$1"; shift
  if ! "$@" >"$log" 2>&1; then
    echo "ERROR: command failed: $* " >&2
    echo "----- last 20 lines of $log -----" >&2
    tail -n 20 "$log" >&2
    return 1
  fi
}

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
  echo "Video dimensions: ${w}x${h}"

  local rate_raw
  rate_raw="$(
    ffprobe -v error -select_streams v:0 -show_entries stream=r_frame_rate -of default=noprint_wrappers=1:nokey=1 "$file" 2>/dev/null || true
  )"

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
  WIDTH="$w"
  HEIGHT="$h"
  if [ "$fmt" = "pal" ]; then
    TARGET="pal-dvd"
    FPS="25"
  else
    TARGET="ntsc-dvd"
    FPS="30000/1001"
  fi
}
detect_dvd_format "$MAIN_MOVIE"
echo "Detected format: ${DETECTED_FORMAT^^} (${WIDTH}x${HEIGHT} @ ${FPS}fps)"
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

normalize_language() {
  local raw="$1"
  local lang_lower="${raw,,}"
  lang_lower="${lang_lower//-/_}"
  lang_lower="${lang_lower// /_}"

  case "$lang_lower" in
    dutch|nl|nld|dut)
      NORM_LANG_CODE="nl"
      NORM_LANG_LABEL="Dutch"
      ;;
    eng|en)
      NORM_LANG_CODE="en"
      NORM_LANG_LABEL="English"
      ;;
    eng_sdh|en_sdh)
      NORM_LANG_CODE="en"
      NORM_LANG_LABEL="English (SDH)"
      ;;
    spa_latin_american|spa_la|es_la|spanish_latin_american)
      NORM_LANG_CODE="es"
      NORM_LANG_LABEL="Spanish (Latin American)"
      ;;
    spa|es|esl|spanish)
      NORM_LANG_CODE="es"
      NORM_LANG_LABEL="Spanish"
      ;;
    fra|fre|fr|french)
      NORM_LANG_CODE="fr"
      NORM_LANG_LABEL="French"
      ;;
    ger|deu|de|german)
      NORM_LANG_CODE="de"
      NORM_LANG_LABEL="German"
      ;;
    *)
      NORM_LANG_CODE="${lang_lower%%_*}"
      NORM_LANG_CODE="${NORM_LANG_CODE%%-*}"

      local clean_label="${raw//_/ }"
      clean_label="${clean_label//-/ }"

      if [[ "$lang_lower" == *sdh* ]]; then
        clean_label="$(echo "$clean_label" | sed -E 's/[sS][dD][hH]//g' | xargs)"
        clean_label="${clean_label} (SDH)"
      fi

      local words=($clean_label)
      NORM_LANG_LABEL="${words[@]^}"
      ;;
  esac
}

prettify_filename() {
  local file="$1"
  local base="$(basename "$file" .mpg)"
  base="${base%_pal}"
  base="${base%_PAL}"
  local words=(${base//_/ })
  echo "${words[@]^}"
}

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

  local top_margin=100
  local line_h=$(( (HEIGHT - top_margin - 60) / num_items ))
  [ "$line_h" -gt 70 ] && line_h=70
  [ "$line_h" -lt $((MIN_POINT_SIZE + 6)) ] && line_h=$((MIN_POINT_SIZE + 6))
  local point_size=$(( line_h / 2 + 10 ))
  [ "$point_size" -gt "$MAX_POINT_SIZE" ] && point_size=$MAX_POINT_SIZE
  [ "$point_size" -lt "$MIN_POINT_SIZE" ] && point_size=$MIN_POINT_SIZE
  local left_margin=$(( WIDTH / 6 ))
  local right_margin=$(( WIDTH / 20 ))

  if [ $(( top_margin + num_items * line_h )) -gt "$HEIGHT" ]; then
    echo "WARNING: menu '$title_text' has $num_items items and may overflow frame." >&2
  fi

  echo "Building menu: $title_text ($num_items items, ${point_size}pt)"

  run_logged "$LOG_DIR/$(basename "$pfx")_convert_bg0.log" \
    convert -size "${WIDTH}x${HEIGHT}" xc:black \
      -gravity NorthWest -fill white -font "$FONT" -pointsize 42 \
      -annotate +${left_margin}+$((top_margin - 60)) "$title_text" \
      "${pfx}_bg.png"

  run_logged "$LOG_DIR/$(basename "$pfx")_convert_hl0.log" \
    convert -size "${WIDTH}x${HEIGHT}" xc:none "${pfx}_hl.png"

  local y0_arr=() y1_arr=()
  for i in "${!labels[@]}"; do
    local text="${labels[$i]}"
    local max_chars=$(( (WIDTH - left_margin - right_margin) * 10 / (point_size * 6) ))
    [ "$max_chars" -lt 4 ] && max_chars=4

    if [ "${#text}" -gt "$max_chars" ]; then
      text="${text:0:$((max_chars - 1))}…"
    fi
    local y=$((top_margin + i * line_h))
    y0_arr[$i]=$((y - (point_size + 10)))
    y1_arr[$i]=$((y + 15))

    run_logged "$LOG_DIR/$(basename "$pfx")_convert_bg${i}.log" \
      convert "${pfx}_bg.png" \
        -gravity NorthWest -fill white -font "$FONT" -pointsize "$point_size" \
        -annotate +${left_margin}+${y} "$text" \
        "${pfx}_bg.png"

    run_logged "$LOG_DIR/$(basename "$pfx")_convert_hl${i}.log" \
      convert "${pfx}_hl.png" \
        -gravity NorthWest -fill yellow -font "$FONT" -pointsize "$point_size" \
        -annotate +${left_margin}+${y} "$text" \
        "${pfx}_hl.png"
  done

  run_logged "$LOG_DIR/$(basename "$pfx")_ffmpeg_blank.log" \
    ffmpeg -y -f lavfi -i "color=c=black:s=${WIDTH}x${HEIGHT}:d=${MENU_SECONDS}:r=${FPS}" \
            -f lavfi -i "anullsrc=r=48000:cl=stereo" \
            -shortest -pix_fmt yuv420p -target "$TARGET" \
            "${pfx}_blank.mpg"

  run_logged "$LOG_DIR/$(basename "$pfx")_ffmpeg_merge.log" \
    ffmpeg -y -i "${pfx}_blank.mpg" -i "${pfx}_bg.png" \
            -filter_complex "[0:v][1:v]overlay=0:0" \
            -c:a copy -pix_fmt yuv420p -target "$TARGET" -f dvd \
            "${pfx}_merged.mpg"

  {
    echo '<subpictures><stream>'
    echo "  <spu force=\"yes\" highlight=\"${pfx}_hl.png\" select=\"${pfx}_hl.png\">"
    for i in "${!labels[@]}"; do
      local up=$(( (i - 1 + num_items) % num_items ))
      local down=$(( (i + 1) % num_items ))
      echo "    <button name=\"b$i\" x0=\"$((left_margin - 20))\" y0=\"${y0_arr[$i]}\" x1=\"$((WIDTH - left_margin))\" y1=\"${y1_arr[$i]}\" up=\"b$up\" down=\"b$down\" />"
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
CURRENT_DEFAULT_SUBP=62 # 62 = off

# ---------------------------------------------------------------------------
# HELPER: Discover and Mux Subtitles for a given Title
# ---------------------------------------------------------------------------
process_video_and_subs() {
  local in_mpg="$1"
  local ts_idx="$2"

  CURRENT_SUB_LABELS=()
  CURRENT_HAS_SUBS=0
  CURRENT_MUXED_MPG="$in_mpg"
  CURRENT_DEFAULT_SUBP=62

  local base_path="${in_mpg%.mpg}"
  local base_clean="${base_path%_pal}"
  base_clean="${base_clean%_PAL}"

  shopt -s nullglob
  local raw_sub_files=(
    "${base_path}"_*.idx
    "${base_path}"_*.sub.idx
    "${base_path}"_*.sup
  )
  if [ "$base_path" != "$base_clean" ]; then
    raw_sub_files+=(
      "${base_clean}"_*.idx
      "${base_clean}"_*.sub.idx
      "${base_clean}"_*.sup
    )
  fi
  shopt -u nullglob

  if [ ${#raw_sub_files[@]} -eq 0 ]; then
    echo "    -> No subtitles found for $(basename "$in_mpg")"
    return 0
  fi

  # Deduplicate discovered files
  local input_files=()
  local seen_files=" "
  for f in "${raw_sub_files[@]}"; do
    if [[ "$seen_files" != *" $f "* ]]; then
      seen_files+="$f "
      input_files+=("$f")
    fi
  done
  # DVD-Video allows 32 subpicture streams.
  if [ ${#input_files[@]} -gt 32 ]; then
    echo "ERROR: $(basename "$in_mpg") has ${#input_files[@]} subtitle files; max 32 streams allowed." >&2
    exit 1
  fi

  # Verify companion .sub files exist (NOTE: subtitle files may be suffixed by standard .sub/.idx and .sub.sub/.sub.idx.)
  local input_files_clean=()
  local data_files=()
  for f in "${input_files[@]}"; do
    if [[ "$f" == *.sup ]]; then
      # .sup is self-contained
      input_files_clean+=("$f")
      data_files+=("$f")
      continue
    fi

    local sub=""
    # 1. Standard double extension: file.sub.idx -> file.sub.sub
    if [[ "$f" == *.sub.idx ]] && [ -f "${f%.sub.idx}.sub.sub" ]; then
      sub="${f%.sub.idx}.sub.sub"
    # 2. Standard single extension: file.idx -> file.sub
    elif [[ "$f" == *.idx ]] && [ -f "${f%.idx}.sub" ]; then
      sub="${f%.idx}.sub"
    # 3. Fallback double check: file.idx -> file.sub.sub
    elif [[ "$f" == *.idx ]] && [ -f "${f%.idx}.sub.sub" ]; then
      sub="${f%.idx}.sub.sub"
    fi

    if [ -z "$sub" ] || [ ! -f "$sub" ]; then
      echo "ERROR: missing companion .sub file for index '$f'" >&2
      echo "       Expected either '${f%.idx}.sub' or '${f%.sub.idx}.sub.sub'" >&2
      exit 1
    fi

    [ -s "$f" ] || { echo "ERROR: subtitle index file is empty: $f" >&2; exit 1; }
    [ -s "$sub" ] || { echo "ERROR: subtitle data file is empty: $sub" >&2; exit 1; }

    input_files_clean+=("$f")
    data_files+=("$sub")
  done

  # Reassign checked input files
  input_files=("${input_files_clean[@]}")

  CURRENT_HAS_SUBS=1
  CURRENT_MUXED_MPG="$WORK_DIR/ts${ts_idx}_muxed.mpg"

  local default_index=-1
  local track0_index=-1
  local seen_labels=""

  local video_stem="$(basename "$base_path")"
  local video_stem_clean="$(basename "$base_clean")"

  for i in "${!input_files[@]}"; do
    local f="${input_files[$i]}"
    local fname="$(basename "$f")"

    # Strip extension (.sub.idx, .idx, or .sup) cleanly to isolate track suffix
    local stem=""
    if [[ "$fname" == *.sub.idx ]]; then
      stem="${fname%.sub.idx}"
    elif [[ "$fname" == *.sup ]]; then
      stem="${fname%.sup}"
    else
      stem="${fname%.idx}"
    fi

    # Extract suffix after video prefix
    local suffix="$stem"
    if [[ "$suffix" == "${video_stem}_"* ]]; then
      suffix="${suffix#"${video_stem}_"}"
    elif [[ "$suffix" == "${video_stem_clean}_"* ]]; then
      suffix="${suffix#"${video_stem_clean}_"}"
    else
      suffix="${suffix#"${video_stem}"}"
      suffix="${suffix#"${video_stem_clean}"}"
      suffix="${suffix#_}"
    fi

    # Strip trailing _exp
    suffix="${suffix%_exp}"
    suffix="${suffix%.exp}"
    suffix="${suffix%-exp}"

    # Check for track0 / track{n}
    local is_track0=0
    if [[ "$suffix" =~ ^track0(_|-|$) ]]; then
      is_track0=1
      suffix="${suffix#track0}"
      suffix="${suffix#_}"
      suffix="${suffix#-}"
    elif [[ "$suffix" =~ ^track[0-9]+(_|-|$) ]]; then
      local trk="${BASH_REMATCH[0]}"
      suffix="${suffix#"$trk"}"
      suffix="${suffix#_}"
      suffix="${suffix#-}"
    fi

    local raw_lang="$suffix"
    [ -n "$raw_lang" ] || raw_lang="Language $((i+1))"

    normalize_language "$raw_lang"
    local label_name="$NORM_LANG_LABEL"
    local lang_code="$NORM_LANG_CODE"

    if [[ " $seen_labels " == *" $label_name "* ]]; then
      label_name="${label_name} ($((i+1)))"
    fi
    seen_labels+=" $label_name "
    CURRENT_SUB_LABELS+=("$label_name")

    # Priority 1: Check configured DEFAULT_HINT (e.g. Dutch/nl)
    local matches_hint=0
    if [ -n "${DEFAULT_HINT:-}" ]; then
      local hint_lower="${DEFAULT_HINT,,}"
      if [[ "${raw_lang,,}" == *"$hint_lower"* ]] || \
         [[ "${lang_code,,}" == *"$hint_lower"* ]] || \
         [[ "${label_name,,}" == *"$hint_lower"* ]]; then
        matches_hint=1
      fi
    fi

    if [ "$matches_hint" -eq 1 ] && [ "$default_index" -eq -1 ]; then
      default_index=$i
    fi

    if [ "$is_track0" -eq 1 ] && [ "$track0_index" -eq -1 ]; then
      track0_index=$i
    fi
  done

  # Default selection order: Config DEFAULT_HINT > track0 > first track
  if [ "$default_index" -eq -1 ]; then
    if [ "$track0_index" -ne -1 ]; then
      default_index=$track0_index
    else
      default_index=0
    fi
  fi

  CURRENT_DEFAULT_SUBP=$((64 + default_index))

echo "  ----------------------------------------"
echo " | -> Found ${#input_files[@]} sub track(s)"
echo " | Labels:"
for lbl in "${CURRENT_SUB_LABELS[@]}"; do
  echo " |   - ${lbl}"
done
echo " | Default: stream ${default_index} (${CURRENT_SUB_LABELS[$default_index]})"
echo "  ----------------------------------------"

  local current_vid="$in_mpg"
  for i in "${!input_files[@]}"; do
    local f="${input_files[$i]}"
    local data_file="${data_files[$i]}"
    local pfx="$WORK_DIR/ts${ts_idx}_sub_${i}"
    local stage_base="$WORK_DIR/ts${ts_idx}_sub_${i}_input"
    local bdsup_in=""

    # Stage files into clean paths for bdsup2sub.
    # Preserve exact companion basename matching so the internal .idx reference resolves properly.
    if [[ "$f" == *.sup ]]; then
      cp "$f" "${stage_base}.sup"
      bdsup_in="${stage_base}.sup"
    else
      cp "$f" "${stage_base}.idx"
      if [[ "$data_file" == *.sub.sub ]]; then
        cp "$data_file" "${stage_base}.sub.sub"
      # Create a symlink/copy so bdsup2sub can find it regardless of whether it expects .sub or .sub.sub
        cp "$data_file" "${stage_base}.sub"
      else
        cp "$data_file" "${stage_base}.sub"
      fi
      bdsup_in="${stage_base}.idx"
    fi

    # Conditionally execute depending on whether we resolved the Qt C++ fork or the Java version
    # Utilizing array expansion for BDSUP2SUB_CMD to safely preserve path/arguments
    if [[ "${BDSUP2SUB_CMD[*]}" == *"bdsup2sub++"* ]]; then
      run_logged "$LOG_DIR/ts${ts_idx}_bdsup2sub_${i}.log" \
        env QT_QPA_PLATFORM=offscreen "${BDSUP2SUB_CMD[@]}" --no-verbose -o "${pfx}_bdn.xml" "$bdsup_in"
    else
      run_logged "$LOG_DIR/ts${ts_idx}_bdsup2sub_${i}.log" \
        "${BDSUP2SUB_CMD[@]}" --no-verbose -o "${pfx}_bdn.xml" "$bdsup_in"
    fi

    # Verify that bdsup2sub successfully generated the images
    shopt -s nullglob
    local pngs=( "${pfx}_bdn"*.png )
    shopt -u nullglob
    if [ ${#pngs[@]} -eq 0 ]; then
      echo "ERROR: bdsup2sub produced no .png frames for $f — subtitle file may be malformed." >&2
      exit 1
    fi
    # When bdsup2sub++ exports XML subtitles, its root tag is <BDN>:
    #   <BDN Version="0.28" defaultSubtitleStreamName="...">
    # However, spumux is designed specifically for DVD authoring and expects a <subpictures> root tag:
    #   <subpictures>
    #     <stream>
    #       <spu start="..." end="..." image="...">
    # Convert BDN XML -> DVDAuthor spumux XML format
    awk '
      BEGIN { print "<subpictures>\n  <stream>" }
      /<Event / {
        for (i = 1; i <= NF; i++) {
          if ($i ~ /^InTC=/)  { split($i, a, "\""); start = a[2] }
          if ($i ~ /^OutTC=/) { split($i, b, "\""); end = b[2] }
        }
      }
      /<Graphic/ {
        sub(/.*<Graphic[^>]*>/, "")
        sub(/<\/Graphic>.*/, "")
        print "    <spu start=\"" start "\" end=\"" end "\" image=\"" $0 "\" />"
      }
      END { print "  </stream>\n</subpictures>" }
    ' "${pfx}_bdn.xml" > "${pfx}.xml"
    local next_vid="$WORK_DIR/ts${ts_idx}_mux_${i}.mpg"
    # Mux directly using the generated DVDAuthor-formatted XML
    run_logged "$LOG_DIR/ts${ts_idx}_spumux_${i}.log" \
      bash -c "spumux -s '$i' '${pfx}.xml' < '$current_vid' > '$next_vid'"

    [ -s "$next_vid" ] || { echo "ERROR: spumux produced an empty output muxing subtitle track $i into $(basename "$in_mpg")." >&2; exit 1; }
    current_vid="$next_vid"
  done

  cp "$current_vid" "$CURRENT_MUXED_MPG"
}
# ---------------------------------------------------------------------------
# HELPER: Generate XML chunk for a single Titleset
# ---------------------------------------------------------------------------
append_titleset_xml() {
  local ts_idx="$1"
  local title_pretty="$2"

  # Snapshot the globals set by process_video_and_subs for this titleset,
  # since build_menu() below will call other helpers that could otherwise
  # clobber CURRENT_* before we're done using them.
  local has_subs="$CURRENT_HAS_SUBS"
  local muxed_mpg="$CURRENT_MUXED_MPG"
  local default_subp="$CURRENT_DEFAULT_SUBP"
  local sub_labels=("${CURRENT_SUB_LABELS[@]}")

  XML_TITLESETS+="  <titleset>\n"

  if [ "$has_subs" -eq 1 ]; then
    local menu_mpg="$WORK_DIR/ts${ts_idx}_menu.mpg"
    local labels=("${sub_labels[@]}" "No subtitles" "Extras Menu")

    local menu_title="Subtitles: ${title_pretty}"
    [ "$ts_idx" -eq 1 ] && menu_title="Movie Subtitles"

    build_menu "$menu_mpg" "$menu_title" "${labels[@]}"

    XML_TITLESETS+="    <menus lang=\"en\">\n      <video format=\"${DETECTED_FORMAT}\" resolution=\"${WIDTH}x${HEIGHT}\" />\n"
    XML_TITLESETS+="      <pgc entry=\"root,subtitle\">\n        <vob file=\"$menu_mpg\" />\n"

    local btn_idx=0
    for i in "${!sub_labels[@]}"; do
      local val=$((64 + i))
      XML_TITLESETS+="        <button name=\"b$btn_idx\"> { subtitle = $val; if (g1 eq 1) resume; else jump title 1 chapter 1; } </button>\n"
      btn_idx=$((btn_idx+1))
    done

    XML_TITLESETS+="        <button name=\"b$btn_idx\"> { subtitle = 62; if (g1 eq 1) resume; else jump title 1 chapter 1; } </button>\n"
    btn_idx=$((btn_idx+1))
    XML_TITLESETS+="        <button name=\"b$btn_idx\"> { g1 = 0; jump vmgm menu entry title; } </button>\n"

    XML_TITLESETS+="        <post> { if (g1 eq 1) resume; else jump title 1 chapter 1; } </post>\n"
    XML_TITLESETS+="      </pgc>\n    </menus>\n"
  fi

  XML_TITLESETS+="    <titles>\n      <video format=\"${DETECTED_FORMAT}\" resolution=\"${WIDTH}x${HEIGHT}\" />\n"
  if [ "$has_subs" -eq 1 ]; then
    for i in "${!sub_labels[@]}"; do
      XML_TITLESETS+="      <subpicture />\n"
    done
  fi

  XML_TITLESETS+="      <pgc entry=\"title\">\n"
  if [ "$has_subs" -eq 1 ]; then
    # Each titleset gets its own default subtitle stream applied on entry,
    # rather than silently inheriting whatever the VMGM fpc set for the
    # main movie (or whatever the viewer last left the register at).
    XML_TITLESETS+="        <pre> { g1 = 1; subtitle = ${default_subp}; } </pre>\n"
  else
    XML_TITLESETS+="        <pre> { g1 = 1; } </pre>\n"
  fi
  XML_TITLESETS+="        <vob file=\"$muxed_mpg\" chapters=\"0\" />\n"
  XML_TITLESETS+="        <post> { g1 = 0; call vmgm menu entry title; } </post>\n"
  XML_TITLESETS+="      </pgc>\n    </titles>\n"
  XML_TITLESETS+="  </titleset>\n\n"
}

# ===========================================================================
# ORCHESTRATION PIPELINE
# ===========================================================================

echo "Menu graphics will be built at ${WIDTH}x${HEIGHT} (${DETECTED_FORMAT^^}, target=${TARGET})"

# --- Process Titleset 1: Main Movie ---
echo "Processing Main Movie: $MAIN_MOVIE"
process_video_and_subs "$MAIN_MOVIE" 1
movie_pretty="$(prettify_filename "$MAIN_MOVIE")"
append_titleset_xml 1 "$movie_pretty"

VMGM_LABELS+=("Play Main Movie")
if [ "$CURRENT_HAS_SUBS" -eq 1 ]; then
  VMGM_TARGETS+=("jump titleset 1 menu;")
  MAIN_DEFAULT_SUBP=$CURRENT_DEFAULT_SUBP
  FPC_JUMP="jump titleset 1 menu entry root;"
else
  VMGM_TARGETS+=("jump titleset 1 title 1;")
  MAIN_DEFAULT_SUBP=62
  FPC_JUMP="jump titleset 1 title 1;"
fi

# --- Process Titleset 2..N: Extras ---
TS_IDX=2
shopt -s nullglob
if [ -n "${EXTRAS_DIR:-}" ]; then
  extras_array=( "$EXTRAS_DIR"/*.mpg )
else
  extras_array=()
fi
shopt -u nullglob

if [ ${#extras_array[@]} -gt 0 ]; then
  for extra_mpg in "${extras_array[@]}"; do
    [ -s "$extra_mpg" ] || { echo "ERROR: extra file is empty: $extra_mpg" >&2; exit 1; }
    verify_matches_main_format "$extra_mpg"

    pretty_name="$(prettify_filename "$extra_mpg")"

    echo "Processing Extra $TS_IDX: $pretty_name"
    process_video_and_subs "$extra_mpg" "$TS_IDX"
    append_titleset_xml "$TS_IDX" "$pretty_name"

    VMGM_LABELS+=("Extra: $pretty_name")
    if [ "$CURRENT_HAS_SUBS" -eq 1 ]; then
      VMGM_TARGETS+=("jump titleset $TS_IDX menu;")
    else
      VMGM_TARGETS+=("jump titleset $TS_IDX title 1;")
    fi

    TS_IDX=$((TS_IDX + 1))
  done
else
  echo "No extras found in $EXTRAS_DIR"
fi

if [ "$TS_IDX" -gt 100 ]; then
  echo "ERROR: too many titlesets ($((TS_IDX - 1))); DVD-Video supports at most 99." >&2
  exit 1
fi

# --- Generate VMGM Menu (Top Level) ---
echo "Generating VMGM Extras Menu..."
VMGM_MPG="$WORK_DIR/vmgm_menu.mpg"
build_menu "$VMGM_MPG" "Main Menu" "${VMGM_LABELS[@]}"

VMGM_BUTTONS_XML=""
for i in "${!VMGM_TARGETS[@]}"; do
  VMGM_BUTTONS_XML+="        <button name=\"b$i\"> { ${VMGM_TARGETS[$i]} } </button>\n"
done

# --- Assemble final dvdauthor.xml ---
XML_FILE="$WORK_DIR/dvdauthor.xml"
printf '<?xml version="1.0"?>\n' > "$XML_FILE"
printf '<dvdauthor dest="%s" jumppad="yes" format="%s">\n\n' "$OUT_DIR" "$DETECTED_FORMAT" >> "$XML_FILE"

printf '  <vmgm>\n' >> "$XML_FILE"
printf '    <fpc>\n      { g1 = 0; subtitle = %d; %s }\n    </fpc>\n' "$MAIN_DEFAULT_SUBP" "$FPC_JUMP" >> "$XML_FILE"
printf '    <menus>\n      <video format="%s" resolution="%sx%s" />\n' "$DETECTED_FORMAT" "$WIDTH" "$HEIGHT" >> "$XML_FILE"
# printf '      <pgc entry="title">\n' >> "$XML_FILE" ERR:  Unknown entry 'title'
printf '      <pgc>\n' >> "$XML_FILE"
printf '        <vob file="%s" />\n' "$VMGM_MPG" >> "$XML_FILE"
printf '%b' "$VMGM_BUTTONS_XML" >> "$XML_FILE"
printf '      </pgc>\n    </menus>\n' >> "$XML_FILE"
printf '  </vmgm>\n\n' >> "$XML_FILE"

printf '%b' "$XML_TITLESETS" >> "$XML_FILE"
printf '</dvdauthor>\n' >> "$XML_FILE"

echo "Generated $XML_FILE"

# ---------------------------------------------------------------------------
# AUTHOR DVD
# ---------------------------------------------------------------------------
rm -rf "$OUT_DIR"
run_logged "$LOG_DIR/dvdauthor.log" dvdauthor -x "$XML_FILE"

echo
echo "=========================================================================="
echo "Done. DVD-Video file structure is in: $OUT_DIR"
echo "Preview it with: vlc dvd://$OUT_DIR"
echo "=========================================================================="