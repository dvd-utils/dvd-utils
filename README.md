# DVD utilities

Some utilities to generate a DVD with menus and subtitles from a bag of video and subtitle files.

## Usage
```
# 0) This project depends on some submodules; initialize them
git submodule update --init --depth=1

# 1) Pre-encode any .mkv/.mp4/... in ./movies into DVD-compliant .mpg
./encode_to_dvd_mpeg2.sh -i ./movies -f pal

# 2) Author the disc, pointing at the converted .mpg files (-e for optional Extras folder)
./generate_dvd_with_menus/build_dvd.sh -i ./movies -e ./movies/extras -o ./dvd
```