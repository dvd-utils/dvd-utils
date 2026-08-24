#!/usr/bin/env bash

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