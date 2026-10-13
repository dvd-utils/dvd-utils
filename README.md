# DVD utilities

Utilities for preparing DVD-compliant video, authoring a DVD-Video structure with dynamic menus and subtitles, and burning it to disc.

## Table of contents

- [Quick start](#quick-start)
- [Utilities](#utilities)
  - [`build-dvd.sh`](#build-dvdsh)
  - [`burn-dvd.sh`](#burn-dvdsh)
- [Submodules](#submodules)
  - [`dvd-subtitle-utils`](#dvd-subtitle-utils)
  - [`dvdauthor`](#dvdauthor)

## Quick start

Initialize the submodules:

```bash
git submodule update --init --depth=1
find . -type f -name '*.sh' -exec chmod +x {} +
```

Install the tools required for the operations you plan to run. DVD authoring uses `ffmpeg`, `ffprobe`, `dvdauthor` (including `spumux`), ImageMagick's `convert`, and a supported BDSup2Sub subtitle converter. Burning additionally requires `growisofs` and `lsblk`. See the [DVD builder guide](generate_dvd_with_menus/README.md#requirements) for details.

Place DVD-compliant MPEG-2 `.mpg` files in an input directory, then author and burn the DVD:

```bash
./build-dvd.sh -i ./movies -e ./movies/extras -o ./dvd
./burn-dvd.sh ./dvd
```

For builder options, subtitle handling, menu backgrounds, and output details, see the [DVD builder guide](generate_dvd_with_menus/README.md).

## Utilities

### `build-dvd.sh`

Authors a DVD-Video directory with a main movie, optional extras, dynamic menus, and available subtitles. It is a wrapper for [`generate_dvd_with_menus/build_dvd.sh`](generate_dvd_with_menus/build_dvd.sh). See the [dedicated guide](generate_dvd_with_menus/README.md) for setup and usage.

### `burn-dvd.sh`

Burns an ISO image or an authored DVD folder to the first optical drive detected on the system:

```bash
./burn-dvd.sh movie.iso
./burn-dvd.sh ./dvd
```

Requires Linux, `growisofs` (from `dvd+rw-tools`), and `lsblk` (from `util-linux`). Burning with `-dvd-compat` finalizes the disc, and writing to rewritable media replaces its existing content.

## Submodules

### `dvd-subtitle-utils`

Provides subtitle conversion tools, including `srt2vobsub.sh` for converting SRT subtitles to VobSub and BDSup2Sub++ for converting image-based subtitle formats such as Blu-ray SUP to DVD VobSub. The DVD builder can use BDSup2Sub++ when processing bitmap subtitles. See the [submodule README](dvd-subtitle-utils/README.md) for build and usage instructions.

### `dvdauthor`

Provides the `dvdauthor` and `spumux` programs used to assemble DVD-Video titlesets, menus, and subtitle streams. The builder uses these tools to create the authored DVD structure. See the [submodule README](dvdauthor/README.md) for build and usage instructions.
