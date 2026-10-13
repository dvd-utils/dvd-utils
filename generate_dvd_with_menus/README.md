# DVD menu authoring

`build_dvd.sh` creates an authored DVD-Video directory from DVD-compliant MPEG-2 `.mpg` files. It detects the main movie's video format, checks extras against it, discovers supported subtitles, and generates menus for the main movie and optional extras.

The repository-root [`build-dvd.sh`](../build-dvd.sh) forwards its arguments to this script.

## Table of contents

- [Requirements](#requirements)
- [Usage](#usage)
- [Options](#options)
- [Examples](#examples)
- [Input files and subtitles](#input-files-and-subtitles)
- [Output and playback](#output-and-playback)

## Requirements

The authoring script expects the following commands to be available:

- `ffmpeg` and `ffprobe` for video processing and metadata
- `dvdauthor` and `spumux` for DVD authoring
- ImageMagick's `convert` for menu graphics
- A supported BDSup2Sub subtitle converter; see [`resolve_bdsup2sub.sh`](resolve_bdsup2sub.sh) for supported commands and search locations

The converter is resolved at startup. BDSup2Sub++ is available from the [`dvd-subtitle-utils` submodule](../dvd-subtitle-utils/README.md).

## Usage

From the repository root, run:

```bash
./build-dvd.sh -i ./movies -e ./movies/extras -o ./dvd
```

To invoke the implementation directly:

```bash
./generate_dvd_with_menus/build_dvd.sh -i ./movies -e ./movies/extras -o ./dvd
```

Input, work, and output paths are interpreted relative to the current working directory. The root wrapper may also be run from a different directory using its full path.

## Options

```text
-i, --input DIR          Directory containing the main movie .mpg (default: .)
-e, --extras DIR         Directory containing extra .mpg files (default: ./extras)
                         Supports category subfolders
-m, --main FILE          Explicit main movie .mpg (overrides auto-detection)
-o, --out DIR            DVD-Video output directory (default: ./dvd)
-w, --work DIR           Scratch directory (default: ./work)
-d, --default LANG       Default subtitle language hint (default: nl)
    --bg SPEC            Menu background image, video, or hex color
    --bg-time TIME       Timestamp for extracting an automatic background still
    --extras-per-page N  Extras per menu page (default: 5; range: 1-36)
-y, --yes                Skip the confirmation prompt
-h, --help               Show help and exit
```

If `--bg` is omitted, the script extracts a still from the main movie. Use `--bg-time` to choose the extraction timestamp; otherwise, a timestamp is selected automatically.

## Examples

Set a solid-color background or use an image:

```bash
./build-dvd.sh -i ./movies --bg "#1a1a2e" -o ./dvd
./build-dvd.sh -i ./movies --bg ./assets/background.png -o ./dvd
```

Set the automatic background still's timestamp, or disable subtitles by default:

```bash
./build-dvd.sh -i ./movies --bg-time "00:12:00" -o ./dvd
./build-dvd.sh -i ./movies -d off -o ./dvd
```

Organize extras into subfolders to group them in the paginated Extras menu:

```text
extras/
├── Behind_the_Scenes/
│   ├── making_of.mpg
│   └── interviews.mpg
└── Deleted_Scenes/
    └── scene_01.mpg
```

For unattended runs, skip the confirmation prompt:

```bash
./build-dvd.sh -i ./movies -y -o ./dvd
```

## Input files and subtitles

Provide a DVD-compliant MPEG-2 `.mpg` for the main title. The script selects the first `.mpg` in the input directory unless `--main` specifies one. Extra `.mpg` files are optional. Their video format and resolution must match the main title.

Subtitle files should share the corresponding video's base name. Supported formats are:

- VobSub: `.idx` and `.sub` files
- Raw VobSub: `.sub.idx` and `.sub` files
- Blu-ray PGS: `.sup`
- SubRip text: `.srt`

Track and language suffixes can be used in file names (for example, `_track0_eng` or `_track1_nl`). The `--default` option selects a preferred language hint; use `off` to disable subtitles by default.

## Output and playback

The output directory (default `./dvd`) contains a DVD-Video structure, including `VIDEO_TS/`. Preview it with VLC:

```bash
vlc "dvd:///absolute/path/to/dvd"
```

To create an ISO image:

```bash
genisoimage -dvd-video -o movie.iso ./dvd
```

To burn the authored directory, see [`burn-dvd.sh`](../burn-dvd.sh) in the repository root.
