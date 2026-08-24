#!/bin/bash

# ISO_PATH should be passed as the first argument.
# It can be either:
#   - a .iso file, or
#   - a folder containing VIDEO_TS (and optionally AUDIO_TS)
ISO_PATH="$1"

if [ -z "$ISO_PATH" ]; then
    echo "Usage: $0 <path-to-iso-or-dvd-folder>"

    # Look for a .iso file to suggest as an example
    EXAMPLE_ISO="$(find . -maxdepth 1 -iname '*.iso' -print -quit 2>/dev/null)"

    if [ -z "$EXAMPLE_ISO" ]; then
        EXAMPLE_ISO="$(find /tmp -maxdepth 1 -iname '*.iso' -print -quit 2>/dev/null)"
    fi

    if [ -n "$EXAMPLE_ISO" ]; then
        echo "Example: $0 \"$EXAMPLE_ISO\""
    fi

    exit 1
fi

# Determine whether ISO_PATH is a file or a DVD folder
if [ -f "$ISO_PATH" ]; then
    MODE="iso"
elif [ -d "$ISO_PATH" ]; then
    if [ -d "$ISO_PATH/VIDEO_TS" ]; then
        MODE="dvd-video"
    elif [ -d "$ISO_PATH/AUDIO_TS" ]; then
        MODE="dvd-audio"
    else
        echo "Error: '$ISO_PATH' is a folder but contains no VIDEO_TS or AUDIO_TS subfolder."
        exit 1
    fi
else
    echo "Error: '$ISO_PATH' not found (not a file or folder)."
    exit 1
fi

# Automatically detect the optical drive (usually /dev/sr0)
DRIVE="$(lsblk -dn -o NAME,TYPE | awk '$2=="rom"{print "/dev/"$1; exit}')"
if [ -z "$DRIVE" ]; then
    echo "Error: No optical drive detected."
    exit 1
fi
echo "Detected DVD burner at: $DRIVE"

# Burn according to detected mode
case "$MODE" in
    iso)
        echo "Burning ISO $ISO_PATH to $DRIVE..."
        growisofs -dvd-compat -Z "$DRIVE"="$ISO_PATH"
        ;;
    dvd-video)
        echo "Burning DVD-Video folder $ISO_PATH to $DRIVE..."
        growisofs -dvd-compat -Z "$DRIVE" -dvd-video "$ISO_PATH"
        ;;
    dvd-audio)
        echo "Burning DVD-Audio folder $ISO_PATH to $DRIVE..."
        growisofs -dvd-compat -Z "$DRIVE" -r -J "$ISO_PATH"
        ;;
esac
