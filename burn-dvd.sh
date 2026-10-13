#!/bin/bash

# =============================================================================
#  burn-dvd.sh  -  burn a disc from .iso image or DVD folder dump
# =============================================================================
#
#  DESCRIPTION
#  -----------
#  Burns a DVD image or an authored DVD folder to a disc using the first optical drive found on the system. 
#  
#  Accepted inputs:
#
#    - .iso file                     -> burned as a raw disc image
#    - folder containing VIDEO_TS/   -> burned as a DVD-Video disc
#    - folder containing AUDIO_TS/   -> burned as a data disc with Rock Ridge + Joliet extensions (only used when VIDEO_TS is absent)
#
#  USAGE
#  -----
#    ./burn-dvd.sh <path-to-iso-or-dvd-folder>
#
#  EXAMPLES
#  --------
#    ./burn-dvd.sh movie.iso
#    ./burn-dvd.sh /home/user/MyMovie
#
#  If called without arguments, the script prints the usage line and, when it finds a .iso file in the current directory (or in /tmp), suggests it as an example command.
#
#  REQUIREMENTS
#  ------------
#    - Linux with util-linux (lsblk), awk, growisofs (dvd+rw-tools): sudo apt install util-linux gawk dvd+rw-tools
#    - DVD writer and a blank, writable disc inserted
#    - Permission to access the drive (root, or membership of the "cdrom" group, depending on the distribution)
#
#  NOTES
#  -----
#    - Only the first detected drive is used. With several burners, edit the DRIVE detection below or set DRIVE manually.
#    - `-dvd-compat` closes the disc so it plays in standalone DVD players, but no more sessions can be added afterwards.
#    - `-Z` starts a new session: any existing content on a rewritable disc will be overwritten.
# =============================================================================

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
