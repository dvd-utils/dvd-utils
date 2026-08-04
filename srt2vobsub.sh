#!/usr/bin/env bash
#
# srt2vobsub.sh — Convert an .srt file into a VobSub (.sub/.idx) pair.
#
# spumux (from the dvdauthor package) was built with freetype + fribidi + fontconfig support,
# which means it has a <textsub> element that reads an .srt file and rasterizes it internally.
#
# Requires:
#   sudo apt install dvdauthor mencoder
#
# Usage:
#   ./srt2vobsub.sh <input.srt> <output_basename> [options]
#
# Run with --help to see all styling options.

set -euo pipefail

# ---------------------------------------------------------------------------
# Defaults. Every one of these can be overridden with a matching --flag
# (see the case statement further down).
# ---------------------------------------------------------------------------
FORMAT="pal"                          # ntsc | pal
FONT="/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf" # Assumes this font to exist
FONTSIZE="28.0"
CHARSET="UTF-8"
FILL_COLOR="rgba(255,255,255,255)"     # white text
OUTLINE_COLOR="rgba(0,0,0,255)"        # black outline
OUTLINE_THICKNESS="2.0"
SHADOW_COLOR="rgba(0,0,0,255)"
SHADOW_OFFSET="+1, +1"                 # spumux wants this exact "+N, +N" form
HALIGN="center"                        # left | center | right
VALIGN="bottom"                        # top | center | bottom
ASPECT="4:3"                           # spumux only accepts 4:3 or 16:9

usage() {
  cat <<EOF
Usage: $0 <input.srt> <output_basename> [options]

  --format ntsc|pal            DVD frame format (default: $FORMAT)
                                VobSub is a DVD subpicture format, so it only
                                comes in these two sizes:
                                - NTSC 720x480 @ 29.97fps
                                - PAL 720x576 @ 25fps)
                                Players scale the bitmap to your actual video
                                at playback time, so pick whichever matches
                                your source's frame-rate family.
  --font PATH                  TTF/OTF font file (default: $FONT)
  --fontsize POINTS            Font size in points (default: $FONTSIZE)
  --charset NAME               Subtitle file's text encoding (default: $CHARSET)
  --fill-color rgba(r,g,b,a)   Text fill color (default: $FILL_COLOR)
  --outline-color rgba(r,g,b,a) Text outline color (default: $OUTLINE_COLOR)
  --outline-thickness N        Outline thickness in px (default: $OUTLINE_THICKNESS)
  --shadow-color rgba(r,g,b,a) Drop-shadow color (default: $SHADOW_COLOR)
  --shadow-offset "+N, +N"     Drop-shadow offset, exact format required
                                (default: "$SHADOW_OFFSET")
  --align left|center|right    Horizontal alignment (default: $HALIGN)
  --valign top|center|bottom   Vertical alignment (default: $VALIGN)
  --aspect 4:3|16:9            Target display aspect ratio (default: $ASPECT)

Example:
  $0 spa.srt spa --format ntsc --fill-color 'rgba(255,255,0,255)'
EOF
  exit 1
}

[ $# -ge 2 ] || usage
SRT="$1"; OUT="$2"; shift 2

while [ $# -gt 0 ]; do
  case "$1" in
    --format)             FORMAT="$2"; shift 2 ;;
    --font)               FONT="$2"; shift 2 ;;
    --fontsize)           FONTSIZE="$2"; shift 2 ;;
    --charset)            CHARSET="$2"; shift 2 ;;
    --fill-color)         FILL_COLOR="$2"; shift 2 ;;
    --outline-color)      OUTLINE_COLOR="$2"; shift 2 ;;
    --outline-thickness)  OUTLINE_THICKNESS="$2"; shift 2 ;;
    --shadow-color)       SHADOW_COLOR="$2"; shift 2 ;;
    --shadow-offset)      SHADOW_OFFSET="$2"; shift 2 ;;
    --align)              HALIGN="$2"; shift 2 ;;
    --valign)             VALIGN="$2"; shift 2 ;;
    --aspect)             ASPECT="$2"; shift 2 ;;
    -h|--help)            usage ;;
    *) echo "Unknown option: $1" >&2; usage ;;
  esac
done

case "$FORMAT" in
  ntsc) WIDTH=720; HEIGHT=480; FPS="30000/1001"; DVD_TARGET="ntsc-dvd"; SPU_FORMAT="NTSC"; FPS_INT=30 ;;
  pal)  WIDTH=720; HEIGHT=576; FPS=25;            DVD_TARGET="pal-dvd"; SPU_FORMAT="PAL";  FPS_INT=25 ;;
  *) echo "--format must be 'ntsc' or 'pal', got: $FORMAT" >&2; exit 1 ;;
esac

[ -f "$SRT" ]  || { echo "No such file: $SRT" >&2; exit 1; }
[ -f "$FONT" ] || { echo "Font not found: $FONT" >&2; exit 1; }
command -v spumux   >/dev/null || { echo "'spumux' not found. sudo apt install dvdauthor" >&2; exit 1; }
command -v mencoder >/dev/null || { echo "'mencoder' not found. sudo apt install mencoder" >&2; exit 1; }

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT
XML="$WORKDIR/spumux.xml"

# spumux resolves the textsub filename relative to its own working directory,
# not relative to the XML file. Use an absolute path so it works no matter
# where this script is run from.
SRT_ABS="$(cd "$(dirname "$SRT")" && pwd)/$(basename "$SRT")"

# ---------------------------------------------------------------------------
# Step 1: Write the spumux XML. This will be used by spumux to mux the
# subtitles with an .mpg file (we generate a dummy mpg if none was
# provided).
#
# This is the whole "conversion recipe" to rasterize the subtitle text into a
# DVD picture stream.
# <filename> is the subtitle file relative to spumux's own working directory,
# so use an absolute path.
# Every styling attribute below is passed straight through to spumux's
# own text renderer.
# ---------------------------------------------------------------------------
cat > "$XML" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<subpictures format="${SPU_FORMAT}">
  <stream>
    <textsub
      filename="${SRT_ABS}"
      characterset="${CHARSET}"
      font="${FONT}"
      fontsize="${FONTSIZE}"
      fill-color="${FILL_COLOR}"
      outline-color="${OUTLINE_COLOR}"
      outline-thickness="${OUTLINE_THICKNESS}"
      shadow-color="${SHADOW_COLOR}"
      shadow-offset="${SHADOW_OFFSET}"
      horizontal-alignment="${HALIGN}"
      vertical-alignment="${VALIGN}"
      movie-width="${WIDTH}"
      movie-height="${HEIGHT}"
      aspect="${ASPECT}"
    />
  </stream>
</subpictures>
EOF
echo "==> spumux.xml generated:"
sed 's/^/    /' "$XML"
# ---------------------------------------------------------------------------
# Step 2: Build (or find) a blank DVD-compliant video to carry the subtitle stream.
#
# spumux inserts subtitles into an existing MPEG-PS stream, not as an isolated
# picture stream. Since we don't have a real source video at this stage, we
# generate a dummy clip just long enough to cover the last subtitle's end
# time (+3s of padding).
# ---------------------------------------------------------------------------
echo "==> Determining required video duration..."
# Locate the last timecode in the .srt file
LAST_END_LINE=$(grep -oE '[0-9]{2}:[0-9]{2}:[0-9]{2},[0-9]{3} --> [0-9]{2}:[0-9]{2}:[0-9]{2},[0-9]{3}' "$SRT" | tail -1 || true)
[ -n "$LAST_END_LINE" ] || { echo "Couldn't find any timecodes in $SRT" >&2; exit 1; }

LAST_END=$(echo "$LAST_END_LINE" | awk '{print $3}' | tr ',' '.')
# - ${LAST_END%.*} strips the .fff milliseconds off the end (e.g. 01:02:03.450 → 01:02:03)
# - prefixing `read` with `IFS=:` tells `read` to split only for that one command on colons instead of whitespace, so '01:02:03' → H='01' M='02' S='03'
#   (Because the assignment is a prefix on a single command rather than a separate IFS=: statement, it doesn't leak into the rest of the script: bare IFS=: on its own line would silently break every later word-split until we reset it)
IFS=: read -r H M S <<< "${LAST_END%.*}"
# Duration in seconds
DURATION=$(( 10#$H * 3600 + 10#$M * 60 + 10#$S + 3 ))
FRAMES=$(( DURATION * FPS_INT ))

echo "    Required: ${DURATION}s (~${FRAMES} frames) (last subtitle ends at ${LAST_END})"
SUITABLE_DUMMY=""
# Look for a cached dummy video in the current directory (e.g., dummy_pal_5000s.mpg)
for vid in dummy_${FORMAT}_*s.mpg; do
  [ -e "$vid" ] || continue
  # Extract duration in seconds using native bash substitution
  VID_DUR="${vid#dummy_${FORMAT}_}"
  VID_DUR="${VID_DUR%s.mpg}"
  if [[ "$VID_DUR" =~ ^[0-9]+$ ]] && [ "$VID_DUR" -ge "$DURATION" ]; then
    SUITABLE_DUMMY="$vid"
    break
  fi
done
if [ -n "$SUITABLE_DUMMY" ]; then
  echo "==> Found existing cached dummy video: $SUITABLE_DUMMY"
  DUMMY_VIDEO="$SUITABLE_DUMMY"
else
  DUMMY_VIDEO="dummy_${FORMAT}_${DURATION}s.mpg"
  echo "==> Generating new dummy video ($DUMMY_VIDEO) with mencoder..."
# We trick mencoder into reading an endless stream of null bytes from /dev/zero,
# interpreting them as raw YV12 video (which produces a solid green frame).
# We encode exactly enough frames to cover the subtitle duration.
  mencoder /dev/zero -demuxer rawvideo -rawvideo w="${WIDTH}":h="${HEIGHT}":fps="${FPS}":format=yv12 -ovc lavc -lavcopts vcodec=mpeg2video -of mpeg -mpegopts format=dvd:tsaf -frames "${FRAMES}" -nosound -quiet -o "$DUMMY_VIDEO" 2>/dev/null
fi

# Old ffmpeg solution, for reference:
#
# # We use ffmpeg's "-target ntsc-dvd/pal-dvd" preset rather than a hand-rolled
# # mux: spumux requires the real DVD 2048-byte sector pack-header structure,
# # and a generic ffmpeg mux doesn't produce that (confirmed by trial and
# # error: a plain "-f mpeg" mux gets rejected with "Incorrect pack header").
# # ---------------------------------------------------------------------------
# # Generate the black dummy video
# ffmpeg -y -loglevel error -f lavfi -i "color=c=black:s=${WIDTH}x${HEIGHT}:r=${FPS}:d=${DURATION}" -target "$DVD_TARGET" "$WORKDIR/dummy.mpg"

# ---------------------------------------------------------------------------
# Step 3: Mux the subtitles into the dummy video.
# spumux reads spumux.xml, rasterizes every line of the .srt using the
# styling attributes we gave it, and writes a real DVD subpicture (SPU)
# stream into a copy of the dummy video.
# ---------------------------------------------------------------------------
echo "==> Muxing subtitles with spumux..."
spumux "$XML" < "$DUMMY_VIDEO" > "$WORKDIR/muxed.mpg" 2>/dev/null

# ---------------------------------------------------------------------------
# Step 4: Extract the standalone VobSub .sub/.idx pair.
# ---------------------------------------------------------------------------
echo "==> Extracting standalone VobSub .sub/.idx..."
mencoder "$WORKDIR/muxed.mpg" -o /dev/null -nosound -ovc copy -vobsubout "$OUT" -vobsuboutindex 0 -sid 0 -quiet >/dev/null 2>&1

echo "==> Done: ${OUT}.sub / ${OUT}.idx"