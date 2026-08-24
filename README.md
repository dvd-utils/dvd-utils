# DVD utilities

Some utilities to generate a DVD with with dynamic menus, subtitles, and extras from a bag of video and subtitle files.

## Prerequisites

You must have the following tools installed and available in your $PATH:

   - Video Processing: ffmpeg, ffprobe
   - DVD Authoring: `dvdauthor`, `spumux` (part of `dvdauthor`/`libdvdcss`)
   - Graphics Generation: `convert` / `montage` (ImageMagick v7)
   - Subtitle Processing: `bdsup2sub` (optional, only required if you have .sup PGS subtitles)

On Debian/Ubuntu, you can install most of these via `sudo apt install ffmpeg dvdauthor imagemagick bdsup2sub`.

## Usage
```
# This project depends on some submodules; initialize them
git submodule update --init --depth=1

# Make all bash scripts executable
find . -type f -name '*.sh' -exec chmod +x {} + 

# 1) Pre-encode any .mkv/.mp4/... in ./movies into DVD-compliant .mpg
./encode_to_dvd_mpeg2.sh -i ./movies -f pal

# 2) Author the disc, pointing at the converted .mpg files (-e for optional Extras folder)
./generate_dvd_with_menus/build_dvd.sh -i ./movies -e ./movies/extras -o ./dvd
```

## Detailed CLI Options (`build_dvd.sh`)
```
Usage: build_dvd.sh [OPTIONS]

Options:
  -i, --input       DIR      Directory to scan for the main movie .mpg (default: .)
  -e, --extras      DIR      Directory containing extra .mpg files (default: ./extras)
                             Supports subfolders for grouping: extras/{Category}/file.mpg
  -m, --main        FILE     Explicit main movie .mpg (overrides auto-detection)
  -o, --out         DIR      Final DVD-Video output directory (default: ./dvd)
  -w, --work        DIR      Scratch/working directory (default: ./work)
  -d, --default     LANG     Default subtitle language hint, e.g. "nl" or "dutch" (default: nl)
  --bg              SPEC     Menu background: image path, video path, or hex color (e.g. "#1a1a2e")
                             If not set, a still is auto-extracted from the main movie.
  --bg-time         TIME     Timestamp for still extraction when using auto background
                             (e.g. "00:05:30"). Default: random moment between 5% and 40%.
  --extras-per-page N        Number of extras per paginated menu page (default: 6, max: 36)
  -y, --yes                  Skip confirmation prompt (useful for cronjobs/pipelines)
  -h, --help                 Show help and exit
```

## Advanced Usage Examples

### Custom Menu Backgrounds  
 
```bash
# Use a dark blue solid color
./generate_dvd_with_menus/build_dvd.sh -i ./movies --bg "#1a1a2e" -o ./dvd

# Use a specific image (will be scaled/cropped to fit DVD resolution)
./generate_dvd_with_menus/build_dvd.sh -i ./movies --bg "./assets/background.png" -o ./dvd

# Pull a still from the main movie at exactly 12 minutes
./generate_dvd_with_menus/build_dvd.sh -i ./movies --bg-time "00:12:00" -o ./dvd
```

### Organizing Extras with Subfolders

If your extras directory is structured like this:  
 
```
extras/
├── Behind_the_Scenes/
│   ├── making_of.mpg
│   └── interviews.mpg
└── Deleted_Scenes/
    ├── scene_01.mpg
    └── scene_02.mpg
``` 

The script will automatically detect the subfolders, label the buttons as [Behind_the_Scenes] making_of, and include them in the paginated Extras menu.

### Setting Default Subtitles

If your main movie has movie_track0_eng.sub and movie_track1_nl.sub:

```bash
# Set Dutch as the default subtitle track
./generate_dvd_with_menus/build_dvd.sh -i ./movies -d "nl" -o ./dvd

# Force subtitles off by default
./generate_dvd_with_menus/build_dvd.sh -i ./movies -d "off" -o ./dvd
```
 
### Non-interactive / Automation

If you are running this in a CI/CD pipeline or cronjob where there is no TTY:
```bash
# The -y flag bypasses the "Proceed with encoding? [Y/n]" prompt
./generate_dvd_with_menus/build_dvd.sh -i ./movies -y -o ./dvd
```
 
### Output & Playback

Once complete, the -o directory (default ./dvd) will contain a standard DVD-Video file structure (VIDEO_TS/).

Preview with VLC: 
     
```bash
    vlc "dvd:///absolute/path/to/./dvd"
```     
     
     Burn to disc (e.g., with growisofs):
```bash
growisofs -dvd-compat -Z /dev/sr0 ./dvd
```     
     
     Create an .iso file (e.g., with genisoimage):
```bash
genisoimage -dvd-video -o "my_movie.iso" ./dvd
```

## How Subtitles Are Discovered

The script looks for subtitle files in the same directory as the .mpg file, sharing the same base name. It supports:

    - VobSub: basename.idx + basename.sub
    - Raw VobSub: basename.sub.idx + basename.sub
    - PGS (Blu-ray): basename.sup (requires bdsup2sub)
    - Text (SRT): basename.srt

It intelligently parses patterns like _track0_eng, _track1_nl, or _forced to properly label the subtitle streams in the DVD menu.
