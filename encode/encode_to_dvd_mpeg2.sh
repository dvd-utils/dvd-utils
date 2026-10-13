#!/usr/bin/env bash
# ============================================================================
#  convert_to_dvd.sh — Pre-encode source videos to MPEG-2 PS (DVD-Video)
# ============================================================================
#  What it does:
#   1. Scans INPUT_DIR for video files (.mkv, .mp4, .avi, .mov, .webm, ...).
#   2. For each file, skips conversion if a matching _pal.mpg / _ntsc.mpg
#      output already exists AND is DVD-compliant (use --force to override).
#   3. Detects the source's display aspect ratio (4:3 or 16:9) via ffprobe
#      using width, height, and sample_aspect_ratio.
#   4. Encodes to MPEG-2 video + AC-3 audio in an MPEG-PS (.mpg) container,
#      padding with black bars so the picture is never distorted, then
#      squeezing into the mandatory 720x576 (PAL) or 720x480 (NTSC) DVD
#      storage resolution and flagging the correct DAR for playback.
#
#  Usage:
#   ./convert_to_dvd.sh [-i DIR] [-f pal|ntsc] [-r] [--force] [-h]
#
#  Examples:
#   ./convert_to_dvd.sh                            # ., PAL, top-level only
#   ./convert_to_dvd.sh -i ./movies -f ntsc        # ./movies, NTSC
#   ./convert_to_dvd.sh -i ./movies -r --force     # recursive, re-encode all
# ============================================================================
set -euo pipefail

# ----------------------------- CONFIG ---------------------------------------
INPUT_DIR="."
FORMAT="pal"          # pal | ntsc
RECURSIVE=0
FORCE=0
GOP_SIZE=15
VIDEO_BITRATE="6000k"
VIDEO_MAXRATE="9000k"
VIDEO_BUFSIZE="1835k"
AUDIO_CHANNELS="2"
AUDIO_BITRATE="192k"
# Source container extensions we will pick up. We deliberately exclude
# .mpg / .mpg2 / .m2v / .vob because those are typically already DVD-PS.
VIDEO_EXTS=(mkv mp4 avi mov m4v webm wmv ts m2ts mts flv ogv)
# ----------------------------------------------------------------------------

need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing required tool: $1" >&2; exit 1; }; }
for t in ffmpeg ffprobe; do need "$t"; done

print_help() {
  cat <<EOF
Usage: $0 [OPTIONS]

Converts non-MPEG-2 video files in a directory into DVD-Video compliant
MPEG-2 Program Streams (.mpg) so build_dvd.sh can author them.

Options:
  -i, --input DIR      Directory to scan for source videos (default: .)
  -f, --format FMT     Target DVD format: pal or ntsc (default: pal)
  -r, --recursive       Recursively search subdirectories
      --force           Re-encode even if an output .mpg already exists
  -g, --gop N           GOP size (default: 15)
      --v-bitrate RATE  Video bitrate, e.g. 6000k (default: 6000k)
      --v-maxrate RATE  Video maxrate (default: 9000k)
      --v-bufsize SIZE  Video bufsize (default: 1835k)
      --a-channels N    Audio channels: 1, 2, or 6 (default: 2)
      --a-bitrate RATE  Audio bitrate, e.g. 192k (default: 192k)
  -h, --help            Show this help and exit

Subsequent runs skip files whose _pal.mpg / _ntsc.mpg output already exists
and is DVD-compliant; use --force to override.
EOF
}

# Parse arguments
while [ $# -gt 0 ]; do
  case "$1" in
    -i|--input)     INPUT_DIR="$2"; shift 2 ;;
    -f|--format)    FORMAT="$2"; shift 2 ;;
    -r|--recursive) RECURSIVE=1; shift ;;
    --force)        FORCE=1; shift ;;
    -g|--gop)       GOP_SIZE="$2"; shift 2 ;;
    --v-bitrate)    VIDEO_BITRATE="$2"; shift 2 ;;
    --v-maxrate)    VIDEO_MAXRATE="$2"; shift 2 ;;
    --v-bufsize)    VIDEO_BUFSIZE="$2"; shift 2 ;;
    --a-channels)   AUDIO_CHANNELS="$2"; shift 2 ;;
    --a-bitrate)    AUDIO_BITRATE="$2"; shift 2 ;;
    -h|--help)      print_help; exit 0 ;;
    --) shift; break ;;
    *) echo "Unknown option: $1" >&2; print_help; exit 1 ;;
  esac
done

case "$FORMAT" in
  pal|ntsc) ;;
  *) echo "ERROR: --format must be 'pal' or 'ntsc' (got: $FORMAT)" >&2; exit 1 ;;
esac

[ -d "$INPUT_DIR" ] || { echo "ERROR: input directory not found: $INPUT_DIR" >&2; exit 1; }

# Target constants
if [ "$FORMAT" = "pal" ]; then
  TARGET_H=576
  FPS="25"
  SUFFIX="pal"
else
  TARGET_H=480
  FPS="30000/1001"
  SUFFIX="ntsc"
fi

# ---------------------------------------------------------------------------
# Scan INPUT_DIR for source video files (case-insensitive ext match).
# ---------------------------------------------------------------------------
VIDEO_FILES=()
shopt -s nullglob nocaseglob
[ "$RECURSIVE" -eq 1 ] && shopt -s globstar
for ext in "${VIDEO_EXTS[@]}"; do
  if [ "$RECURSIVE" -eq 1 ]; then
    for f in "$INPUT_DIR"/**/*."$ext"; do
      [ -f "$f" ] && VIDEO_FILES+=("$f")
    done
  else
    for f in "$INPUT_DIR"/*."$ext"; do
      [ -f "$f" ] && VIDEO_FILES+=("$f")
    done
  fi
done
shopt -u nullglob nocaseglob globstar 2>/dev/null || true

# ---------------------------------------------------------------------------
# Helper: is a file already a DVD-compliant MPEG-2 PS for our target format?
# ---------------------------------------------------------------------------
is_already_dvd() {
  local file="$1"
  local vcodec w h rate
  vcodec="$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_name \
            -of default=noprint_wrappers=1:nokey=1 "$file" 2>/dev/null || true)"
  vcodec="$(printf '%s' "$vcodec" | tr -d '\r\n[:space:]')"
  [ "$vcodec" = "mpeg2video" ] || return 1

  w="$(ffprobe -v error -select_streams v:0 -show_entries stream=width \
       -of default=noprint_wrappers=1:nokey=1 "$file" 2>/dev/null || true)"
  h="$(ffprobe -v error -select_streams v:0 -show_entries stream=height \
       -of default=noprint_wrappers=1:nokey=1 "$file" 2>/dev/null || true)"
  w="$(printf '%s' "$w" | tr -d '\r\n[:space:]')"
  h="$(printf '%s' "$h" | tr -d '\r\n[:space:]')"
  [ "$w" = "720" ] && [ "$h" = "$TARGET_H" ] || return 1

  rate="$(ffprobe -v error -select_streams v:0 -show_entries stream=r_frame_rate \
          -of default=noprint_wrappers=1:nokey=1 "$file" 2>/dev/null || true)"
  rate="$(printf '%s' "$rate" | tr -d '\r\n[:space:]')"
  if [ "$FORMAT" = "pal" ]; then
    [ "$rate" = "25/1" ] || return 1
  else
    [ "$rate" = "30000/1001" ] || return 1
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Helper: detect target aspect ratio (4:3 or 16:9) from W/H + SAR.
#   Threshold: DAR > 1.5  -> 16:9   (cleanly separates 4:3=1.33 and 16:9=1.78)
# ---------------------------------------------------------------------------
detect_target_aspect() {
  local file="$1"
  local w h sar sar_num sar_den dar_x dar_y
  w="$(ffprobe -v error -select_streams v:0 -show_entries stream=width \
       -of default=noprint_wrappers=1:nokey=1 "$file" 2>/dev/null || true)"
  h="$(ffprobe -v error -select_streams v:0 -show_entries stream=height \
       -of default=noprint_wrappers=1:nokey=1 "$file" 2>/dev/null || true)"
  sar="$(ffprobe -v error -select_streams v:0 -show_entries stream=sample_aspect_ratio \
         -of default=noprint_wrappers=1:nokey=1 "$file" 2>/dev/null || true)"
  w="$(printf '%s' "$w" | tr -d '\r\n[:space:]')"
  h="$(printf '%s' "$h" | tr -d '\r\n[:space:]')"
  sar="$(printf '%s' "$sar" | tr -d '\r\n[:space:]')"

  [[ "$w" =~ ^[0-9]+$ && "$h" =~ ^[0-9]+$ && "$h" -ne 0 ]] || return 1

  sar_num=1; sar_den=1
  if [[ "$sar" == *":"* ]]; then
    sar_num="${sar%:*}"
    sar_den="${sar#*:}"
    [[ "$sar_num" =~ ^[0-9]+$ && "$sar_num" -gt 0 ]] || sar_num=1
    [[ "$sar_den" =~ ^[0-9]+$ && "$sar_den" -gt 0 ]] || sar_den=1
  fi

  # DAR = (w * sar_num) / (h * sar_den)
  dar_x=$(( w * sar_num ))
  dar_y=$(( h * sar_den ))

  # Compare DAR to 3/2:  2*dar_x > 3*dar_y  ->  DAR > 1.5  -> 16:9
  if [ $(( 2 * dar_x )) -gt $(( 3 * dar_y )) ]; then
    echo "16:9"
  else
    echo "4:3"
  fi
}

echo ""
echo "============================================================="
echo " CONVERT_TO_DVD — Pre-encode sources to MPEG-2 DVD-Video"
echo " Input dir : $INPUT_DIR   (recursive: $RECURSIVE)"
echo " Format    : ${FORMAT^^} (720x${TARGET_H} @ ${FPS}fps)"
echo " Force     : $FORCE"
echo " Found     : ${#VIDEO_FILES[@]} candidate video(s)"
echo "============================================================="
echo ""

if [ ${#VIDEO_FILES[@]} -eq 0 ]; then
  echo "Nothing to do. No source videos found in $INPUT_DIR."
  exit 0
fi

processed=0
skipped=0
failed=0

for f in "${VIDEO_FILES[@]}"; do
  echo "==================================================="
  echo "Source: $f"
  echo "==================================================="

  base="${f%.*}"
  # Strip an existing _pal/_ntsc suffix from the base so we don't end up
  # with names like "Movie_pal_pal.mpg" when re-encoding sources that
  # were already named with the format suffix.
  case "$base" in
    *_pal|*_ntsc) base="${base%_*}" ;;
  esac
  out_video="${base}_${SUFFIX}.mpg"

  # Skip on subsequent runs if output already exists and is DVD-compliant.
  if [ "$FORCE" -eq 0 ] && [ -s "$out_video" ]; then
    if is_already_dvd "$out_video"; then
      echo "  -> Already converted (DVD-compliant): $(basename "$out_video")"
      echo "     (use --force to re-encode)"
      skipped=$((skipped+1))
      echo ""
      continue
    else
      echo "  -> Existing output is not DVD-compliant; re-encoding."
    fi
  fi

  # Detect aspect ratio
  target_ar="$(detect_target_aspect "$f")" || {
    echo "  -> ERROR: could not probe aspect ratio of '$f'. Skipping." >&2
    failed=$((failed+1))
    echo ""
    continue
  }

  if [ "$target_ar" = "16:9" ]; then
    DAR="16/9"
    # LOGICAL_W = TARGET_H * 16/9 (unsqueezed reference width used for padding math)
    if [ "$FORMAT" = "pal" ]; then
      LOGICAL_W=1024    # 576 * 16/9
    else
      LOGICAL_W=854     # 480 * 16/9 ≈ 853.33 -> 854
    fi
  else
    DAR="4/3"
    if [ "$FORMAT" = "pal" ]; then
      LOGICAL_W=768     # 576 * 4/3
    else
      LOGICAL_W=640    # 480 * 4/3
    fi
  fi
  echo "  -> Detected source aspect -> targeting ${target_ar} DVD container"
  echo "  -> Logical canvas: ${LOGICAL_W}x${TARGET_H} (DAR=${DAR})"

  # Check for an audio stream; if absent, feed silent stereo from lavfi.
  has_audio="$(ffprobe -v error -select_streams a:0 -show_entries stream=codec_type \
               -of default=noprint_wrappers=1:nokey=1 "$f" 2>/dev/null || true)"
  has_audio="$(printf '%s' "$has_audio" | tr -d '\r\n[:space:]')"

  extra_input=()
  map_args=()
  audio_args=()
  shortest_args=()

  echo "  -> Encoding to 720x${TARGET_H} ${FORMAT^^} MPEG-2 / AC-3 for DVD authoring..."
  if [ "$has_audio" = "audio" ]; then
      map_args=(-map 0:v:0 -map 0:a:0)
      audio_args=(-c:a ac3 -ar 48000 -ac "$AUDIO_CHANNELS" -b:a "$AUDIO_BITRATE")
  else
      echo "  -> WARNING: no audio stream detected; using silent stereo track." >&2
      extra_input=(-f lavfi -i "anullsrc=r=48000:cl=stereo")
      map_args=(-map 0:v:0 -map 1:a:0)
      audio_args=(-c:a ac3 -ar 48000 -ac "$AUDIO_CHANNELS" -b:a "$AUDIO_BITRATE")
      shortest_args=(-shortest)
  fi

  # -map 0:v:0 / 0:a:0 : explicitly pick the first video/audio stream so
  #   nothing is silently dropped from multi-track sources. Subtitles are
  #   handled separately by build_dvd.sh (BDSUP2SUB workflow), so they are
  #   intentionally NOT mapped here.
  # -vf scale,pad,scale,setdar : fit the source into a canvas matching its
  #   OWN aspect ratio (scale+pad = black bars, no distortion), sized to the
  #   chosen 16:9/4:3 target, then squeeze that padded canvas down to the
  #   mandatory 720x576/480 DVD storage resolution and flag the correct DAR.
  # -r / -pix_fmt / -c:v / -g / -bf / -b:v / -maxrate / -bufsize : DVD-spec.
  # -c:a ac3 -ar 48000 : mandatory DVD-Video audio codec + sample rate.
  # -f dvd : forces MPEG-PS (program stream) muxing per the DVD spec.
  if ! ffmpeg -y -i "$f" "${extra_input[@]}" "${map_args[@]}" \
      -vf "scale=${LOGICAL_W}:${TARGET_H}:force_original_aspect_ratio=decrease,pad=${LOGICAL_W}:${TARGET_H}:(ow-iw)/2:(oh-ih)/2:color=black,scale=720:${TARGET_H},setdar=${DAR}" \
      -r "$FPS" -pix_fmt yuv420p -c:v mpeg2video -g "$GOP_SIZE" -bf 2 \
      -b:v "$VIDEO_BITRATE" -maxrate "$VIDEO_MAXRATE" -bufsize "$VIDEO_BUFSIZE" \
      "${audio_args[@]}" \
      "${shortest_args[@]}" \
      -f dvd \
      "$out_video"; then
    echo "  -> ERROR: ffmpeg failed for '$f'. Skipping to next file." >&2
    rm -f "$out_video"   # don't leave a half-written file we'd skip next time
    failed=$((failed+1))
    echo ""
    continue
  fi

  echo "  -> Done: $(basename "$out_video")"
  processed=$((processed+1))
  echo ""
done

echo "============================================================="
echo " SUMMARY"
echo "  Processed : $processed"
echo "  Skipped   : $skipped  (already DVD-compliant)"
echo "  Failed    : $failed"
echo "============================================================="

[ "$failed" -eq 0 ] || exit 1
exit 0