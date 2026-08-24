#!/usr/bin/env bash

# HTML Preview Generator

# ---------------------------------------------------------------------------
# Config for background preview clips (override via env before sourcing)
# ---------------------------------------------------------------------------
PREVIEW_CACHE_DIR="${PREVIEW_CACHE_DIR:-preview_cache}"
PREVIEW_CLIP_SECONDS="${PREVIEW_CLIP_SECONDS:-15}"      # length of looping bg clip
PREVIEW_CLIP_START="${PREVIEW_CLIP_START:-120}"         # seek-in point (skip logos/black)
PREVIEW_CLIP_WIDTH="${PREVIEW_CLIP_WIDTH:-640}"         # keep it small, it's just a preview

# ---------------------------------------------------------------------------
# HELPER: Find a subtitle file for a given video suitable for overlay.
# Looks for .sub / .sup files matching the video base name, prefers the
# DEFAULT_HINT language, falls back to first found or embedded streams.
# Echoes: "path/to/file.sub"  |  "embedded:STREAM_INDEX"  |  (empty)
# ---------------------------------------------------------------------------
find_subtitle_for_preview() {
  local video="$1"
  local base="${video%.*}"

  shopt -s nullglob
  local -a candidates=()

  for f in "${base}"*.sub "${base}"*.sup; do
    [ -s "$f" ] && candidates+=("$f")
  done

  if [ ${#candidates[@]} -eq 0 ]; then
    local vid_basename vid_dir
    vid_basename="$(basename "$base")"
    vid_dir="$(dirname "$video")"
    for f in "$vid_dir"/${vid_basename}*.sub "$vid_dir"/${vid_basename}*.sup; do
      [ -s "$f" ] && candidates+=("$f")
    done
  fi

  shopt -u nullglob

  if [ ${#candidates[@]} -eq 0 ]; then
    local sub_streams
    sub_streams=$(ffprobe -v error -select_streams s -show_entries stream=index -of csv=p=0 "$video" 2>/dev/null)
    if [ -n "$sub_streams" ]; then
      echo "embedded:$(echo "$sub_streams" | head -1)"
      return 0
    fi
    return 1
  fi

  local -a sorted=()
  while IFS= read -r line; do sorted+=("$line"); done < <(printf '%s\n' "${candidates[@]}" | sort -u)

  for f in "${sorted[@]}"; do
    if [[ "$f" == *"$DEFAULT_HINT"* ]]; then
      echo "$f"
      return 0
    fi
  done

  echo "${sorted[0]}"
  return 0
}

# ---------------------------------------------------------------------------
# HELPER: Convert various time formats to seconds (float).
# Handles: "HH:MM:SS.mmm", "HH:MM:SS:mmm", "SS.mmm", "MMMM" (ms integer)
# ---------------------------------------------------------------------------
convert_time_to_seconds() {
  local tc="$1"
  tc="${tc//[$'\t\r\n ']/}"

  # HH:MM:SS.mmm or HH:MM:SS,mmm or HH:MM:SS:mmm
  if [[ "$tc" =~ ^([0-9]{1,2}):([0-9]{2}):([0-9]{2})[\.:,]([0-9]{1,3})$ ]]; then
    local h="${BASH_REMATCH[1]}" m="${BASH_REMATCH[2]}" s="${BASH_REMATCH[3]}" ms="${BASH_REMATCH[4]}"
    while [ ${#ms} -lt 3 ]; do ms="${ms}0"; done
    awk "BEGIN { printf \"%.3f\", $h * 3600 + $m * 60 + $s + $ms / 1000 }"
    return
  fi

  # HH:MM:SS (no fractional)
  if [[ "$tc" =~ ^([0-9]{1,2}):([0-9]{2}):([0-9]{2})$ ]]; then
    local h="${BASH_REMATCH[1]}" m="${BASH_REMATCH[2]}" s="${BASH_REMATCH[3]}"
    awk "BEGIN { printf \"%.3f\", $h * 3600 + $m * 60 + $s }"
    return
  fi

  # MM:SS.mmm
  if [[ "$tc" =~ ^([0-9]{1,2}):([0-9]{2})[\.:,]([0-9]{1,3})$ ]]; then
    local m="${BASH_REMATCH[1]}" s="${BASH_REMATCH[2]}" ms="${BASH_REMATCH[3]}"
    while [ ${#ms} -lt 3 ]; do ms="${ms}0"; done
    awk "BEGIN { printf \"%.3f\", $m * 60 + $s + $ms / 1000 }"
    return
  fi

  # Pure integer — if large, assume milliseconds
  if [[ "$tc" =~ ^[0-9]+$ ]]; then
    if [ "$tc" -gt 100000 ]; then
      awk "BEGIN { printf \"%.3f\", $tc / 1000 }"
    else
      awk "BEGIN { printf \"%.3f\", $tc }"
    fi
    return
  fi

  # Float seconds
  if [[ "$tc" =~ ^[0-9]+\.?[0-9]*$ ]]; then
    awk "BEGIN { printf \"%.3f\", $tc }"
    return
  fi

  echo "0"
}

# ---------------------------------------------------------------------------
# HELPER: Extract subtitle frames as PNG images + timing JSON using bdsup2sub.
# Creates a JSON file with [{start, end, image}] entries, timing adjusted
# for the preview clip's seek-in point.
#
# Tries multiple bdsup2sub CLI patterns (C++ and Java versions differ).
# Falls back to ffmpeg frame extraction for PGS (.sup) files.
# Echoes: path to JSON file, or empty string on failure.
# ---------------------------------------------------------------------------
extract_subtitle_frames() {
  local sub_file="$1" output_dir="$2" clip_start="$3" clip_duration="$4"

  mkdir -p "$output_dir"

  local sub_ext="${sub_file##*.}"
  local sub_base="$(basename "${sub_file%.*}")"
  local xml_file=""
  local xml_dir=""

  # ------------------------------------------------------------------
  # Strategy 1: bdsup2sub XML+PNG export
  # Try multiple CLI patterns since C++ and Java versions differ
  # ------------------------------------------------------------------
  if [ ${#BDSUP2SUB_CMD[@]} -gt 0 ]; then

    # Attempt 1: --output-dir <dir> --xml <input>
    if [ -z "$xml_file" ]; then
      "${BDSUP2SUB_CMD[@]}" --output-dir "$output_dir" --xml "$sub_file" >/dev/null 2>&1 || true
      xml_file=$(find "$output_dir" -maxdepth 1 -type f \( -name "*.xml" -o -name "*.XML" \) | head -1)
    fi

    # Attempt 2: -o <dir> --xml <input>
    if [ -z "$xml_file" ]; then
      "${BDSUP2SUB_CMD[@]}" -o "$output_dir" --xml "$sub_file" >/dev/null 2>&1 || true
      xml_file=$(find "$output_dir" -maxdepth 1 -type f \( -name "*.xml" -o -name "*.XML" \) | head -1)
    fi

    # Attempt 3: <input> --xml -o <dir>
    if [ -z "$xml_file" ]; then
      "${BDSUP2SUB_CMD[@]}" "$sub_file" --xml -o "$output_dir" >/dev/null 2>&1 || true
      xml_file=$(find "$output_dir" -maxdepth 1 -type f \( -name "*.xml" -o -name "*.XML" \) | head -1)
    fi

    # Attempt 4: <input> -o <dir/subtitles.xml> --xml
    if [ -z "$xml_file" ]; then
      "${BDSUP2SUB_CMD[@]}" "$sub_file" -o "$output_dir/subtitles.xml" --xml >/dev/null 2>&1 || true
      xml_file="$output_dir/subtitles.xml"
      [ -s "$xml_file" ] || xml_file=""
    fi

    # Attempt 5: --xml <input> -o <dir/subtitles.xml>
    if [ -z "$xml_file" ]; then
      "${BDSUP2SUB_CMD[@]}" --xml "$sub_file" -o "$output_dir/subtitles.xml" >/dev/null 2>&1 || true
      xml_file="$output_dir/subtitles.xml"
      [ -s "$xml_file" ] || xml_file=""
    fi
  fi

  # ------------------------------------------------------------------
  # Parse XML if we got one
  # ------------------------------------------------------------------
  if [ -n "$xml_file" ] && [ -s "$xml_file" ]; then
    xml_dir="$(dirname "$xml_file")"
    local png_count
    png_count=$(find "$output_dir" -maxdepth 1 -type f -name "*.png" | wc -l)

    if [ "$png_count" -gt 0 ]; then
      # Parse the XML — handle multiple attribute orders and tag names
      local json_file="$output_dir/subs.json"
      local entries=()

      # Extract subtitle/spu elements with their attributes
      # Try <subtitle ... start="..." end="..." image="..." />
      # Try <subtitle ... start="..." end="..." file="..." />
      # Try <spu ... start="..." end="..." image="..." />
      local parsed
      parsed=$(
        # Pattern 1: <subtitle start="..." end="..." image="..." />
        sed -n 's/.*<subtitle[^>]*start="\([^"]*\)"[^>]*end="\([^"]*\)"[^>]*image="\([^"]*\)".*/\1|\2|\3/p' "$xml_file"
        sed -n 's/.*<subtitle[^>]*start="\([^"]*\)"[^>]*end="\([^"]*\)"[^>]*file="\([^"]*\)".*/\1|\2|\3/p' "$xml_file"
        # image before start/end
        sed -n 's/.*<subtitle[^>]*image="\([^"]*\)"[^>]*start="\([^"]*\)"[^>]*end="\([^"]*\)".*/\2|\3|\1/p' "$xml_file"
        # spu variant
        sed -n 's/.*<spu[^>]*start="\([^"]*\)"[^>]*end="\([^"]*\)"[^>]*image="\([^"]*\)".*/\1|\2|\3/p' "$xml_file"
        # start/end with file attribute
        sed -n 's/.*<spu[^>]*start="\([^"]*\)"[^>]*end="\([^"]*\)"[^>]*file="\([^"]*\)".*/\1|\2|\3/p' "$xml_file"
      )

      if [ -n "$parsed" ]; then
        echo "[" > "$json_file"
        local first=1
        while IFS='|' read -r start_tc end_tc image_name; do
          [ -z "$start_tc" ] && continue
          [ -z "$end_tc" ] && continue
          [ -z "$image_name" ] && continue

          # Resolve image path
          local image_path="$image_name"
          if [[ "$image_name" != /* && "$image_name" != *:* ]]; then
            image_path="$xml_dir/$image_name"
          fi
          # Make path relative to cwd for HTML
          image_path="${image_path#./}"

          # Convert timing to seconds
          local start_sec end_sec
          start_sec=$(convert_time_to_seconds "$start_tc")
          end_sec=$(convert_time_to_seconds "$end_tc")

          # Adjust for clip seek-in point
          local adj_start adj_end
          adj_start=$(awk "BEGIN { printf \"%.3f\", $start_sec - $clip_start }")
          adj_end=$(awk "BEGIN { printf \"%.3f\", $end_sec - $clip_start }")

          # Only include subtitles within the clip's time range
          local in_range
          in_range=$(awk "BEGIN { print ($adj_end > 0 && $adj_start < $clip_duration) ? 1 : 0 }")
          [ "$in_range" -eq 1 ] || continue

          # Clamp to clip range
          local clamped_start clamped_end
          clamped_start=$(awk "BEGIN { printf \"%.3f\", ($adj_start < 0 ? 0 : $adj_start) }")
          clamped_end=$(awk "BEGIN { printf \"%.3f\", ($adj_end > $clip_duration ? $clip_duration : $adj_end) }")

          if [ "$first" -eq 0 ]; then echo "," >> "$json_file"; fi
          printf '  {"start": %s, "end": %s, "image": "%s"}' "$clamped_start" "$clamped_end" "$image_path" >> "$json_file"
          first=0
        done <<< "$parsed"

        echo "" >> "$json_file"
        echo "]" >> "$json_file"

        if [ "$first" -eq 0 ]; then
          echo "$json_file"
          return 0
        fi
      fi
    fi
  fi

  # ------------------------------------------------------------------
  # Strategy 2: For VobSub (.sub), parse .idx for timing, no images
  # This gives us timing only — we'll show a CSS placeholder in the overlay
  # ------------------------------------------------------------------
  if [ "$sub_ext" = "sub" ] || [ "$sub_ext" = "idx" ]; then
    local idx_file=""
    if [ "$sub_ext" = "idx" ]; then
      idx_file="$sub_file"
    else
      idx_file="${sub_file%.*}.idx"
    fi

    if [ -s "$idx_file" ]; then
      local json_file="$output_dir/subs.json"
      local entries=()
      local sub_index=0

      # VobSub .idx has lines like:
      # timestamp: 00:01:23:456, filepos: 0000000001234
      # Each timestamp marks the START of a subtitle.
      # The END is the start of the NEXT subtitle (or start + default duration).
      local prev_start=""
      local prev_idx=""

      while IFS= read -r line; do
        if [[ "$line" =~ ^timestamp:\ ([0-9:]+) ]]; then
          local tc="${BASH_REMATCH[1]}"
          local start_sec
          start_sec=$(convert_time_to_seconds "$tc")

          if [ -n "$prev_start" ]; then
            local adj_start adj_end
            adj_start=$(awk "BEGIN { printf \"%.3f\", $prev_start - $clip_start }")
            adj_end=$(awk "BEGIN { printf \"%.3f\", $start_sec - $clip_start }")

            local in_range
            in_range=$(awk "BEGIN { print ($adj_end > 0 && $adj_start < $clip_duration) ? 1 : 0 }")
            if [ "$in_range" -eq 1 ]; then
              local clamped_start clamped_end
              clamped_start=$(awk "BEGIN { printf \"%.3f\", ($adj_start < 0 ? 0 : $adj_start) }")
              clamped_end=$(awk "BEGIN { printf \"%.3f\", ($adj_end > $clip_duration ? $clip_duration : $adj_end) }")
              entries+=("{\"start\": $clamped_start, \"end\": $clamped_end, \"image\": \"\"}")
            fi
          fi
          prev_start="$start_sec"
          prev_idx="$tc"
        fi
      done < "$idx_file"

      # Handle last subtitle (end = start + default 3 seconds)
      if [ -n "$prev_start" ]; then
        local adj_start adj_end
        adj_start=$(awk "BEGIN { printf \"%.3f\", $prev_start - $clip_start }")
        adj_end=$(awk "BEGIN { printf \"%.3f\", $prev_start + 3 - $clip_start }")

        local in_range
        in_range=$(awk "BEGIN { print ($adj_end > 0 && $adj_start < $clip_duration) ? 1 : 0 }")
        if [ "$in_range" -eq 1 ]; then
          local clamped_start clamped_end
          clamped_start=$(awk "BEGIN { printf \"%.3f\", ($adj_start < 0 ? 0 : $adj_start) }")
          clamped_end=$(awk "BEGIN { printf \"%.3f\", ($adj_end > $clip_duration ? $clip_duration : $adj_end) }")
          entries+=("{\"start\": $clamped_start, \"end\": $clamped_end, \"image\": \"\"}")
        fi
      fi

      if [ ${#entries[@]} -gt 0 ]; then
        echo "[" > "$json_file"
        for i in "${!entries[@]}"; do
          [ "$i" -gt 0 ] && echo "," >> "$json_file"
          echo "  ${entries[$i]}" >> "$json_file"
        done
        echo "]" >> "$json_file"
        echo "$json_file"
        return 0
      fi
    fi
  fi

  # ------------------------------------------------------------------
  # Strategy 3: For PGS (.sup), try ffmpeg to extract packet timing
  # ------------------------------------------------------------------
  if [ "$sub_ext" = "sup" ]; then
    local json_file="$output_dir/subs.json"
    local timing_raw
    timing_raw=$(ffprobe -v error -select_streams s -show_entries packet=pts_time,duration_time -of csv=p=0 "$sub_file" 2>/dev/null)

    if [ -n "$timing_raw" ]; then
      local entries=()
      while IFS=',' read -r pts dur; do
        [ -z "$pts" ] && continue
        [ -z "$dur" ] && dur="3"
        local adj_start adj_end
        adj_start=$(awk "BEGIN { printf \"%.3f\", $pts - $clip_start }")
        adj_end=$(awk "BEGIN { printf \"%.3f\", $pts + $dur - $clip_start }")
        local in_range
        in_range=$(awk "BEGIN { print ($adj_end > 0 && $adj_start < $clip_duration) ? 1 : 0 }")
        if [ "$in_range" -eq 1 ]; then
          local clamped_start clamped_end
          clamped_start=$(awk "BEGIN { printf \"%.3f\", ($adj_start < 0 ? 0 : $adj_start) }")
          clamped_end=$(awk "BEGIN { printf \"%.3f\", ($adj_end > $clip_duration ? $clip_duration : $adj_end) }")
          entries+=("{\"start\": $clamped_start, \"end\": $clamped_end, \"image\": \"\"}")
        fi
      done <<< "$timing_raw"

      if [ ${#entries[@]} -gt 0 ]; then
        echo "[" > "$json_file"
        for i in "${!entries[@]}"; do
          [ "$i" -gt 0 ] && echo "," >> "$json_file"
          echo "  ${entries[$i]}" >> "$json_file"
        done
        echo "]" >> "$json_file"
        echo "$json_file"
        return 0
      fi
    fi
  fi

  # All strategies failed
  return 1
}

# ---------------------------------------------------------------------------
# HELPER: Generate (and cache) a small muted H.264 proxy clip + poster frame.
# Does NOT burn subtitles into the video — subtitles are handled as a
# transparent PNG overlay via JavaScript in the HTML.
#
# If subtitles are available, also extracts subtitle frames + timing JSON.
# Echoes "plain_clip|sub_json_path|poster_path" (sub_json may be empty).
# ---------------------------------------------------------------------------
generate_preview_clip() {
  local src="$1" ts_idx="$2" has_subs="${3:-0}"

  mkdir -p "$PREVIEW_CACHE_DIR"
  local out="$PREVIEW_CACHE_DIR/ts${ts_idx}_preview.mp4"
  local poster="$PREVIEW_CACHE_DIR/ts${ts_idx}_poster.jpg"
  local sub_dir="$PREVIEW_CACHE_DIR/ts${ts_idx}_subs"
  local sub_json=""

  # Cache hit
  if [ -s "$out" ] && [ -s "$poster" ]; then
    if [ "$has_subs" -eq 0 ]; then
      echo "${out}||${poster}"
      return 0
    fi
    # Check for cached subtitle JSON
    if [ -s "$sub_dir/subs.json" ]; then
      echo "${out}|${sub_dir}/subs.json|${poster}"
      return 0
    fi
  fi

  if ! command -v ffmpeg >/dev/null 2>&1; then
    echo "Note: ffmpeg not found, falling back to text-only preview for ts${ts_idx}." >&2
    echo "||"
    return 1
  fi

  # Source duration for seek clamping
  local dur start
  dur=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$src" 2>/dev/null)
  dur=${dur%.*}
  [ -z "$dur" ] && dur=0

  start="$PREVIEW_CLIP_START"
  if [ "$dur" -gt 0 ] && [ "$start" -ge "$dur" ]; then
    start=$(( dur / 4 ))
  fi

  local scale_filter="scale=${PREVIEW_CLIP_WIDTH}:-2"

  # ---- Generate plain clip (no subtitles burned in) ----
  if [ ! -s "$out" ]; then
    echo "  -> Generating preview clip for ts${ts_idx} (${PREVIEW_CLIP_SECONDS}s)..." >&2
    ffmpeg -y -ss "$start" -i "$src" -t "$PREVIEW_CLIP_SECONDS" \
      -vf "$scale_filter" -an \
      -c:v libx264 -preset veryfast -crf 28 -movflags +faststart \
      "$out" >/dev/null 2>&1

    if [ ! -s "$out" ]; then
      echo "  -> Warning: clip generation failed for $src" >&2
    fi
  fi

  # ---- Generate poster frame ----
  if [ ! -s "$poster" ]; then
    local poster_start=$(( start + PREVIEW_CLIP_SECONDS / 2 ))
    [ "$dur" -gt 0 ] && [ "$poster_start" -ge "$dur" ] && poster_start="$start"
    ffmpeg -y -ss "$poster_start" -i "$src" -vframes 1 \
      -vf "$scale_filter" "$poster" >/dev/null 2>&1
  fi

  # ---- Extract subtitle frames as transparent PNG overlay ----
  if [ "$has_subs" -eq 1 ]; then
    local sub_file=""
    sub_file=$(find_subtitle_for_preview "$src" 2>/dev/null || true)

    if [ -n "$sub_file" ]; then
      echo "  -> Extracting subtitle frames for ts${ts_idx}..." >&2
      sub_json=$(extract_subtitle_frames "$sub_file" "$sub_dir" "$start" "$PREVIEW_CLIP_SECONDS" 2>/dev/null || true)

      if [ -n "$sub_json" ] && [ -s "$sub_json" ]; then
        local sub_count
        sub_count=$(grep -c '"start"' "$sub_json" 2>/dev/null || echo "0")
        echo "  -> Found $sub_count subtitle entries for ts${ts_idx}" >&2
      else
        echo "  -> Subtitle frame extraction failed for ts${ts_idx}" >&2
        sub_json=""
      fi
    else
      echo "  -> No subtitle file found for ts${ts_idx}" >&2
    fi
  fi

  local clip_out=""
  [ -s "$out" ] && clip_out="$out"
  local poster_out=""
  [ -s "$poster" ] && poster_out="$poster"

  echo "${clip_out}|${sub_json}|${poster_out}"
}

# ---------------------------------------------------------------------------
# HELPER: Compute the title font size for a given text length.
# Mirrors the logic in build_menu() so the preview matches the actual DVD.
# ---------------------------------------------------------------------------
compute_title_size() {
  local text="$1"
  local size=42
  if [ ${#text} -gt 30 ]; then size=36; fi
  if [ ${#text} -gt 45 ]; then size=30; fi
  if [ ${#text} -gt 60 ]; then size=26; fi
  if [ ${#text} -gt 80 ]; then size=22; fi
  [ "$size" -lt "$MIN_POINT_SIZE" ] && size=$MIN_POINT_SIZE
  echo "$size"
}

# ---------------------------------------------------------------------------
# HELPER: Generate the complete HTML DVD preview
# ---------------------------------------------------------------------------
generate_html_preview() {
  local html_file="dvd_preview.html"

  # Compute DVD layout parameters (must match build_menu)
  local menu_w=720
  local menu_h=576
  local top_margin=120
  if [ "$DETECTED_FORMAT" = "ntsc" ]; then
    menu_h=480
    top_margin=100
  fi
  local left_margin=$((menu_w / 6))
  local title_bar_h=$((top_margin - 15))

  local title_bar_pct=$(( (title_bar_h * 100) / menu_h ))
  local top_margin_pct=$(( (top_margin * 100) / menu_h ))
  local left_margin_pct=$(( (left_margin * 100) / menu_w ))

  # Pre-generate proxy clips/posters/subtitle-data up front
  declare -a CLIP_PLAIN SUB_JSON POSTER_PATH

  echo "" >&2
  echo "  Generating preview clips..." >&2

  for i in "${!ANALYSIS_TITLES[@]}"; do
    ts_idx=$((i + 1))
    local video="${ALL_VIDEOS[$i]}"
    local has_subs="${ANALYSIS_HAS_SUBS[$i]}"
    local default_subp="${ANALYSIS_DEFAULTS[$i]}"

    info=$(generate_preview_clip "$video" "$ts_idx" "$has_subs")
    CLIP_PLAIN[$i]="${info%%|*}"
    local rest="${info#*|}"
    SUB_JSON[$i]="${rest%%|*}"
    POSTER_PATH[$i]="${rest##*|}"
  done

  local has_extras=0
  [ ${#ANALYSIS_TITLES[@]} -gt 1 ] && has_extras=1

  # Count how many titles have subtitle data
  local sub_count=0
  for i in "${!ANALYSIS_TITLES[@]}"; do
    [ -n "${SUB_JSON[$i]:-}" ] && [ -s "${SUB_JSON[$i]}" ] && sub_count=$((sub_count + 1))
  done

  # ---- Build HTML ----
  cat <<HTMLEOF > "$html_file"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>DVD Preview</title>
<style>
  * { box-sizing: border-box; margin: 0; padding: 0; }
  body {
    background: #0a0a0a;
    color: #d4d4d4;
    font-family: 'Segoe UI', Arial, sans-serif;
    display: flex;
    flex-direction: column;
    align-items: center;
    min-height: 100vh;
    padding: 20px;
  }
  h1 { color: #fff; font-size: 1.4em; margin-bottom: 4px; }
  .meta { color: #888; margin-bottom: 20px; font-size: 0.85em; }

  .dvd-frame {
    width: 100%;
    max-width: 720px;
    aspect-ratio: 4/3;
    background: #000;
    border: 2px solid #2a2a2a;
    border-radius: 4px;
    position: relative;
    overflow: hidden;
    box-shadow: 0 0 30px rgba(0,0,0,0.6), inset 0 0 60px rgba(0,0,0,0.3);
  }

  .screen { position: absolute; inset: 0; display: none; flex-direction: column; }
  .screen.active { display: flex; }

  .bg-media {
    position: absolute; inset: 0;
    width: 100%; height: 100%;
    object-fit: cover; z-index: 0;
    filter: brightness(0.35) saturate(0.7);
  }
  .bg-scrim {
    position: absolute; inset: 0; z-index: 1;
    background: linear-gradient(180deg, rgba(0,0,0,0.15) 0%, rgba(0,0,0,0.55) 100%);
  }

  /* === Menu screen layout (faithful to build_menu) === */

  .menu-screen .title-bar {
    position: absolute; top: 0; left: 0; right: 0;
    height: ${title_bar_pct}%;
    background: #1a1a2e; z-index: 2;
    display: flex; align-items: center;
    padding-left: ${left_margin_pct}%; padding-right: ${left_margin_pct}%;
  }
  .menu-screen .separator {
    position: absolute; top: ${title_bar_pct}%;
    left: 0; right: 0; height: 3px;
    background: #555555; z-index: 2;
  }
  .menu-screen .title-text {
    color: #fff; font-weight: bold;
    text-shadow: 0 2px 6px rgba(0,0,0,0.9);
    white-space: nowrap; overflow: hidden;
    text-overflow: ellipsis; width: 100%;
  }
  .menu-screen .button-area {
    position: absolute; top: ${top_margin_pct}%;
    left: ${left_margin_pct}%; right: ${left_margin_pct}%;
    bottom: 5%; z-index: 3;
    display: flex; flex-direction: column;
    justify-content: flex-start; gap: 2px;
  }

  .btn {
    background: none; border: none; color: #fff;
    font-size: 1em; text-align: left; cursor: pointer;
    padding: 6px 12px; display: block; width: 100%;
    transition: all 0.12s ease;
    text-shadow: 0 1px 4px rgba(0,0,0,0.9);
    font-family: inherit; border-radius: 2px; line-height: 1.4;
  }
  .btn:hover, .btn.active {
    color: #ff3333; background: rgba(255,0,0,0.08);
    text-shadow: 0 0 8px rgba(255,0,0,0.4);
  }
  .btn::before {
    content: "\\25B6 "; opacity: 0; color: #ff3333;
    transition: opacity 0.12s; font-size: 0.8em;
  }
  .btn:hover::before, .btn.active::before { opacity: 1; }

  /* === Movie playback screen === */
  .movie-screen .video-container {
    position: absolute; inset: 0; z-index: 0; background: #000;
  }
  .movie-screen .video-container video,
  .movie-screen .video-container img {
    width: 100%; height: 100%; object-fit: contain;
  }

  /* === Subtitle overlay (transparent PNG) === */
  .sub-overlay {
    position: absolute; inset: 0; z-index: 1;
    display: flex; justify-content: center; align-items: flex-end;
    padding-bottom: 8%; padding-left: 5%; padding-right: 5%;
    pointer-events: none;
  }
  .sub-overlay img {
    max-width: 90%; max-height: 35%;
    width: auto; height: auto;
    opacity: 0; transition: opacity 0.15s;
    filter: drop-shadow(0 2px 4px rgba(0,0,0,0.8));
  }
  .sub-overlay img.visible { opacity: 1; }
  .sub-overlay .sub-placeholder {
    color: #ffff00; font-size: 1em;
    text-shadow: 0 0 3px #000, 1px 1px 2px #000, -1px -1px 2px #000;
    opacity: 0; transition: opacity 0.15s;
    text-align: center; line-height: 1.3;
    background: rgba(0,0,0,0.6); padding: 4px 12px; border-radius: 4px;
  }
  .sub-overlay .sub-placeholder.visible { opacity: 1; }

  .movie-screen .overlay {
    position: absolute; inset: 0; z-index: 2;
    display: flex; flex-direction: column;
    justify-content: flex-end; align-items: center;
    padding-bottom: 7%;
    background: linear-gradient(0deg, rgba(0,0,0,0.7) 0%, transparent 35%, transparent 100%);
    pointer-events: none;
  }
  .movie-screen .overlay > * { pointer-events: auto; }

  .now-playing-badge {
    display: inline-flex; align-items: center; gap: 6px;
    color: #ff5555; font-size: 0.65em; letter-spacing: 2px;
    margin-bottom: 6px; text-transform: uppercase;
  }
  .now-playing-badge .dot {
    width: 8px; height: 8px; border-radius: 50%;
    background: #ff0000; animation: pulse 1.4s infinite;
  }
  @keyframes pulse { 0%,100% { opacity: 1; } 50% { opacity: 0.3; } }

  .movie-screen h2 {
    color: #fff; font-size: 1.1em;
    text-shadow: 0 2px 8px rgba(0,0,0,1);
    margin-bottom: 10px; text-align: center; max-width: 80%;
  }
  .movie-screen .nav-buttons {
    display: flex; gap: 10px; flex-wrap: wrap; justify-content: center;
  }
  .movie-screen .nav-buttons .btn {
    width: auto; padding: 5px 16px;
    border: 1px solid rgba(255,255,255,0.2); border-radius: 4px;
    font-size: 0.8em; background: rgba(0,0,0,0.5); backdrop-filter: blur(4px);
  }
  .movie-screen .nav-buttons .btn:hover,
  .movie-screen .nav-buttons .btn.active {
    border-color: rgba(255,80,80,0.6); background: rgba(255,0,0,0.15);
  }

  .sub-badge {
    position: absolute; top: 8px; right: 10px;
    background: rgba(0,0,0,0.7); color: #ffd700;
    font-size: 0.6em; padding: 3px 8px; border-radius: 3px;
    z-index: 3; display: none; letter-spacing: 1px;
    border: 1px solid rgba(255,215,0,0.3);
  }
  .sub-badge.visible { display: block; }

  .remote-panel {
    margin-top: 16px; display: flex; gap: 12px;
    align-items: center; flex-wrap: wrap;
  }
  .remote-panel button {
    background: #2a2a2a; color: #ddd; border: 1px solid #444;
    padding: 8px 16px; border-radius: 4px; cursor: pointer;
    font-size: 0.85em; transition: all 0.15s;
  }
  .remote-panel button:hover {
    background: #3a3a3a; border-color: #666; color: #fff;
  }
  .remote-panel .hint { color: #666; font-size: 0.8em; }

  .proxy-note {
    max-width: 720px; margin-top: 14px;
    font-size: 0.75em; color: #555;
    text-align: center; line-height: 1.5;
  }
</style>
</head>
<body>
  <h1>DVD Preview</h1>
  <div class="meta">
    Format: ${DETECTED_FORMAT^^} ${WIDTH}×${HEIGHT} @ ${FPS}fps &middot;
    Titles: ${#ANALYSIS_TITLES[@]} &middot;
    Generated: $(date '+%Y-%m-%d %H:%M')
  </div>

  <div class="dvd-frame">
HTMLEOF

  # ================================================================
  # VMGM Main Menu Screen
  # ================================================================
  local main_title_size
  main_title_size=$(compute_title_size "${ANALYSIS_TITLES[0]}")

  cat <<HTMLEOF >> "$html_file"
    <!-- VMGM Main Menu -->
    <div id="vmgm" class="screen active menu-screen">
HTMLEOF

  if [ -n "${POSTER_PATH[0]:-}" ]; then
    echo "      <img class='bg-media' src='${POSTER_PATH[0]}' alt=''>" >> "$html_file"
    echo "      <div class='bg-scrim'></div>" >> "$html_file"
  fi

  cat <<HTMLEOF >> "$html_file"
      <div class="title-bar">
        <span class="title-text" style="font-size: ${main_title_size}px;">${ANALYSIS_TITLES[0]}</span>
      </div>
      <div class="separator"></div>
      <div class="button-area">
        <button class="btn" data-target="ts1_movie">Play movie</button>
HTMLEOF

  if [ "$has_extras" -eq 1 ]; then
    echo '        <button class="btn" data-target="vmgm_extras">Extras Menu</button>' >> "$html_file"
  fi

  echo '      </div>' >> "$html_file"
  echo '    </div>' >> "$html_file"

  # ================================================================
  # VMGM Extras Menu Screen
  # ================================================================
  if [ "$has_extras" -eq 1 ]; then
    cat <<HTMLEOF >> "$html_file"
    <!-- VMGM Extras Menu -->
    <div id="vmgm_extras" class="screen menu-screen">
      <div class="title-bar">
        <span class="title-text" style="font-size: 42px;">Extras Menu</span>
      </div>
      <div class="separator"></div>
      <div class="button-area">
HTMLEOF

    for i in "${!ANALYSIS_TITLES[@]}"; do
      ts_idx=$((i + 1))
      if [ "$ts_idx" -gt 1 ]; then
        echo "        <button class='btn' data-target='ts${ts_idx}_movie'>${ANALYSIS_TITLES[$i]}</button>" >> "$html_file"
      fi
    done

    echo '        <button class="btn" data-target="vmgm">Main Menu</button>' >> "$html_file"
    echo '      </div>' >> "$html_file"
    echo '    </div>' >> "$html_file"
  fi

  # ================================================================
  # Per-Titleset Screens
  # ================================================================
  for i in "${!ANALYSIS_TITLES[@]}"; do
    ts_idx=$((i + 1))
    local title="${ANALYSIS_TITLES[$i]}"
    local has_subs="${ANALYSIS_HAS_SUBS[$i]}"
    local subs_str="${ANALYSIS_SUBS_STR[$i]}"
    local default_idx=$(( ANALYSIS_DEFAULTS[$i] - 64 ))
    local clip="${CLIP_PLAIN[$i]:-}"
    local sub_json="${SUB_JSON[$i]:-}"
    local poster="${POSTER_PATH[$i]:-}"

    # ---- Subtitle Menu Screen ----
    if [ "$has_subs" -eq 1 ]; then
      local sub_menu_title="Subtitles: $title"
      [ "$ts_idx" -eq 1 ] && sub_menu_title="Movie Subtitles"
      local sub_title_size
      sub_title_size=$(compute_title_size "$sub_menu_title")

      cat <<HTMLEOF >> "$html_file"
    <!-- TS${ts_idx} Subtitle Menu -->
    <div id='ts${ts_idx}_menu' class='screen menu-screen'>
HTMLEOF

      if [ -n "$poster" ]; then
        echo "      <img class='bg-media' src='$poster' alt=''>" >> "$html_file"
        echo "      <div class='bg-scrim'></div>" >> "$html_file"
      fi

      cat <<HTMLEOF >> "$html_file"
      <div class="title-bar">
        <span class="title-text" style="font-size: ${sub_title_size}px;">${sub_menu_title}</span>
      </div>
      <div class="separator"></div>
      <div class="button-area">
HTMLEOF

      IFS='|' read -ra subs <<< "$subs_str"
      for j in "${!subs[@]}"; do
        local sub_label="${subs[$j]}"
        local btn_class="btn"
        if [ "$j" -eq "$default_idx" ]; then
          btn_class="btn active"
        fi
        echo "        <button class='${btn_class}' data-target='ts${ts_idx}_movie' data-subs='on' data-sub-label='${sub_label}'>${sub_label}</button>" >> "$html_file"
      done

      echo "        <button class='btn' data-target='ts${ts_idx}_movie' data-subs='off'>No subtitles</button>" >> "$html_file"

      if [ "$ts_idx" -gt 1 ] && [ "$has_extras" -eq 1 ]; then
        echo "        <button class='btn' data-target='vmgm_extras'>Back to Extras</button>" >> "$html_file"
      fi

      echo "        <button class='btn' data-target='vmgm'>Main Menu</button>" >> "$html_file"

      echo '      </div>' >> "$html_file"
      echo '    </div>' >> "$html_file"
    fi

    # ---- Movie Playback Screen ----
    cat <<HTMLEOF >> "$html_file"
    <!-- TS${ts_idx} Movie Playback -->
    <div id='ts${ts_idx}_movie' class='screen movie-screen'>
      <div class="video-container">
HTMLEOF

    if [ -n "$clip" ]; then
      echo "        <video autoplay muted loop playsinline" >> "$html_file"
      [ -n "$poster" ] && echo "          poster='$poster'" >> "$html_file"
      echo "          id='video_${ts_idx}'>" >> "$html_file"
      echo "          <source src='$clip' type='video/mp4'>" >> "$html_file"
      echo "        </video>" >> "$html_file"
    elif [ -n "$poster" ]; then
      echo "        <img src='$poster' alt=''>" >> "$html_file"
    else
      echo "        <div style='display:flex;align-items:center;justify-content:center;height:100%;color:#666;font-size:0.8em;'>No preview available</div>" >> "$html_file"
    fi

    cat <<HTMLEOF >> "$html_file"
      </div>
      <div class="sub-overlay" id="sub_overlay_${ts_idx}">
        <img id="sub_img_${ts_idx}" src="" alt="">
      </div>
      <div class="sub-badge" id="ts${ts_idx}_sub_badge">SUB</div>
      <div class="overlay">
        <div class="now-playing-badge"><span class="dot"></span>Now Playing</div>
        <h2>${title}</h2>
        <div class="nav-buttons">
HTMLEOF

    if [ "$has_subs" -eq 1 ]; then
      echo "          <button class='btn' data-target='ts${ts_idx}_menu'>Subtitle Menu</button>" >> "$html_file"
    fi

    if [ "$ts_idx" -gt 1 ] && [ "$has_extras" -eq 1 ]; then
      echo "          <button class='btn' data-target='vmgm_extras'>Back to Extras</button>" >> "$html_file"
    fi

    echo "          <button class='btn' data-target='vmgm'>Main Menu</button>" >> "$html_file"

    cat <<HTMLEOF >> "$html_file"
        </div>
      </div>
    </div>
HTMLEOF

  done

  # ================================================================
  # Close DVD frame, add controls, JavaScript
  # ================================================================

  # Build inline subtitle JSON data for each titleset
  local sub_data_blocks=""
  for i in "${!ANALYSIS_TITLES[@]}"; do
    ts_idx=$((i + 1))
    local sub_json="${SUB_JSON[$i]:-}"
    if [ -n "$sub_json" ] && [ -s "$sub_json" ]; then
      local json_content
      json_content=$(cat "$sub_json" 2>/dev/null || echo "[]")
      sub_data_blocks+="        ts${ts_idx}: ${json_content},\n"
    fi
  done

  cat <<HTMLEOF >> "$html_file"
  </div>

  <div class="remote-panel">
    <button onclick="showScreen('vmgm')">DVD Menu</button>
    <span class="hint">Arrow Keys = navigate &middot; Enter = select &middot; Esc/M = Menu</span>
  </div>

  <div class="proxy-note">
    Preview clips: ${PREVIEW_CLIP_SECONDS}s @ ${PREVIEW_CLIP_WIDTH}px (H.264 proxy).<br>
    Subtitles rendered as transparent PNG overlays extracted via bdsup2sub (${sub_count}/${#ANALYSIS_TITLES[@]} titles).<br>
    They have no effect on the actual DVD-Video encode.
  </div>

  <script>
    // ---- Subtitle data per titleset ----
    const subtitleData = {
 $(echo -e "$sub_data_blocks" | sed 's/,$//' | sed '/^$/d')
    };

    let currentButtons = [];
    let selectedIndex = 0;
    let currentTsIdx = 0;
    let subsEnabled = false;
    let timeupdateHandler = null;

    function showScreen(id, options) {
      // Deactivate all screens, pause videos
      document.querySelectorAll(".screen").forEach(s => {
        s.classList.remove("active");
        const v = s.querySelector("video");
        if (v) v.pause();
      });

      const target = document.getElementById(id);
      if (!target) return;
      target.classList.add("active");

      // Extract ts_idx from the ID (e.g., "ts3_movie" → 3)
      const match = id.match(/^ts(\\d+)_movie$/);
      currentTsIdx = match ? parseInt(match[1]) : 0;

      // Determine subtitle state
      if (options && options.subs === "off") subsEnabled = false;
      if (options && options.subs === "on") subsEnabled = true;

      // Set up video and subtitle overlay
      const video = target.querySelector("video");
      const subOverlay = target.querySelector(".sub-overlay img");
      const subBadge = target.querySelector(".sub-badge");

      // Remove old timeupdate listener
      if (timeupdateHandler && video) {
        video.removeEventListener("timeupdate", timeupdateHandler);
      }

      if (video) {
        video.currentTime = 0;
        video.play().catch(() => {});

        // Set up subtitle overlay
        const subs = subtitleData["ts" + currentTsIdx] || [];

        timeupdateHandler = () => {
          if (!subsEnabled || subs.length === 0) {
            if (subOverlay) { subOverlay.classList.remove("visible"); subOverlay.src = ""; }
            if (subBadge) subBadge.classList.remove("visible");
            return;
          }

          if (subBadge) subBadge.classList.add("visible");

          const t = video.currentTime;
          const sub = subs.find(s => t >= s.start && t <= s.end);

          if (sub) {
            if (sub.image && sub.image.length > 0) {
              // PNG bitmap subtitle
              if (subOverlay.src.indexOf(sub.image) === -1) {
                subOverlay.src = sub.image;
              }
              subOverlay.classList.add("visible");
            } else {
              // No image — show placeholder
              if (subOverlay) subOverlay.classList.remove("visible");
            }
          } else {
            if (subOverlay) subOverlay.classList.remove("visible");
          }
        };

        video.addEventListener("timeupdate", timeupdateHandler);

        // Initial state
        if (!subsEnabled) {
          if (subOverlay) subOverlay.classList.remove("visible");
          if (subBadge) subBadge.classList.remove("visible");
        }
      }

      // Update button tracking
      currentButtons = Array.from(target.querySelectorAll(".btn"));
      selectedIndex = currentButtons.findIndex(b => b.classList.contains("active"));
      if (selectedIndex === -1) selectedIndex = 0;
      updateButtonStates();
    }

    function updateButtonStates() {
      currentButtons.forEach((b, i) => {
        if (i === selectedIndex) b.classList.add("active");
        else b.classList.remove("active");
      });
    }

    // Keyboard navigation (like a DVD remote)
    document.addEventListener("keydown", (e) => {
      if (currentButtons.length === 0) return;

      if (e.key === "ArrowDown" || e.key === "ArrowRight") {
        e.preventDefault();
        selectedIndex = (selectedIndex + 1) % currentButtons.length;
        updateButtonStates();
      } else if (e.key === "ArrowUp" || e.key === "ArrowLeft") {
        e.preventDefault();
        selectedIndex = (selectedIndex - 1 + currentButtons.length) % currentButtons.length;
        updateButtonStates();
      } else if (e.key === "Enter" || e.key === " ") {
        e.preventDefault();
        const btn = currentButtons[selectedIndex];
        const target = btn.getAttribute("data-target");
        const subs = btn.getAttribute("data-subs");
        if (target) showScreen(target, { subs: subs });
      } else if (e.key === "Escape" || e.key.toLowerCase() === "m") {
        showScreen("vmgm");
      }
    });

    // Click handlers
    document.querySelectorAll(".btn").forEach(btn => {
      btn.addEventListener("click", () => {
        const target = btn.getAttribute("data-target");
        const subs = btn.getAttribute("data-subs");
        if (target) showScreen(target, { subs: subs });
      });
    });

    // Initialize
    showScreen("vmgm");
  </script>
</body>
</html>
HTMLEOF

  echo "============================================================="
  echo " 🌐 HTML Preview generated at file://$(pwd)/$html_file"
  echo "    ${#ANALYSIS_TITLES[@]} titles · ${DETECTED_FORMAT^^} ${WIDTH}x${HEIGHT}"
  echo "    Clips: ${PREVIEW_CLIP_SECONDS}s @ ${PREVIEW_CLIP_WIDTH}px"
  echo "    Subtitles: ${sub_count}/${#ANALYSIS_TITLES[@]} titles with overlay data"
  echo "============================================================="
}