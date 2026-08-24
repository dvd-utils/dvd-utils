#!/usr/bin/env bash
# generates both PAL and NTSC pre-encoded MPEG-2 video files, formatted to match standard DVD specifications
set -euo pipefail

# Check for input file argument
if [ "$#" -ne 1 ]; then
    echo "Usage: $0 <input_video>"
    exit 1
fi

INPUT="$1"
BASENAME="${INPUT%.*}"

# Output filenames
PAL_OUT="${BASENAME}_PAL.mpg"
NTSC_OUT="${BASENAME}_NTSC.mpg"

echo "=== Encoding DVD PAL Video ==="
ffmpeg -y -i "$INPUT" -target pal-dvd  -aspect 16:9 -b:v 6000k -maxrate:v 8000k -bufsize:v 1835008 -b:a 192k -ar 48000 "$PAL_OUT"

echo "=== Encoding DVD NTSC Video ==="
ffmpeg -y -i "$INPUT" -target ntsc-dvd -aspect 16:9 -b:v 6000k -maxrate:v 8000k -bufsize:v 1835008 -b:a 192k -ar 48000 "$NTSC_OUT"

echo "Done! Generated:"
echo " - $PAL_OUT"
echo " - $NTSC_OUT"