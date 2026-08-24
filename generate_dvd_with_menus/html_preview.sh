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
# HELPER: Find a subtitle file for a given video suitable for burning.
# Looks for .sub / .sup files matching the video base name, prefers the
# DEFAULT_HINT language, falls back to first found or embedded streams.
# Echoes: "path/to/file.sub"  |  "embedded:STREAM_INDEX"  |  (empty)
# ---------------------------------------------------------------------------
find_subtitle_for_preview() {
  local video="$1"
  local base="${video%.*}"

  shopt -s nullglob
  local -a candidates=()

  # Scan for .sub and .sup files matching the video base name
  for f in "${base}"*.sub "${base}"*.sup; do
    [ -s "$f" ] && candidates+=("$f")
  done

  # Also try _track patterns in the same directory
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
    # Check for embedded subtitle streams in the source MPEG
    local sub_streams
    sub_streams=$(ffprobe -v error -select_streams s -show_entries stream=index -of csv=p=0 "$video" 2>/dev/null)
    if [ -n "$sub_streams" ]; then
      local first_idx
      first_idx=$(echo "$sub_streams" | head -1)
      echo "embedded:${first_idx}"
      return 0
    fi
    return 1
  fi

  # Deduplicate and sort
  local -a sorted=()
  while IFS= read -r line; do
    sorted+=("$line")
  done < <(printf '%s\n' "${candidates[@]}" | sort -u)

  # Prefer a file matching DEFAULT_HINT
  for f in "${sorted[@]}"; do
    if [[ "$f" == *"$DEFAULT_HINT"* ]]; then
      echo "$f"
      return 0
    fi
  done

  # Fallback to first sorted candidate
  echo "${sorted[0]}"
  return 0
}

# ---------------------------------------------------------------------------
# HELPER: Generate (and cache) small muted H.264 proxy clips + poster frame.
# If subtitles are available, generates TWO clips:
#   ts{N}_preview.mp4       — plain (no subtitles)
#   ts{N}_preview_sub.mp4   — with default subtitle burned in
# Echoes "plain_path|sub_path|poster_path" (any field may be empty on failure).
# ---------------------------------------------------------------------------
generate_preview_clip() {
  local src="$1" ts_idx="$2" has_subs="${3:-0}"

  mkdir -p "$PREVIEW_CACHE_DIR"
  local out="$PREVIEW_CACHE_DIR/ts${ts_idx}_preview.mp4"
  local out_sub="$PREVIEW_CACHE_DIR/ts${ts_idx}_preview_sub.mp4"
  local poster="$PREVIEW_CACHE_DIR/ts${ts_idx}_poster.jpg"

  # Cache hit: both plain clip and poster exist, and either no subs needed or sub clip exists
  if [ -s "$out" ] && [ -s "$poster" ]; then
    if [ "$has_subs" -eq 0 ] || [ -s "$out_sub" ]; then
      local sub_path=""
      [ "$has_subs" -eq 1 ] && [ -s "$out_sub" ] && sub_path="$out_sub"
      echo "${out}|${sub_path}|${poster}"
      return 0
    fi
  fi

  if ! command -v ffmpeg >/dev/null 2>&1; then
    echo "Note: ffmpeg not found, falling back to text-only preview for ts${ts_idx}." >&2
    echo "||"
    return 1
  fi

  # Figure out source duration so we don't seek past the end of a short extra
  local dur start
  dur=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$src" 2>/dev/null)
  dur=${dur%.*}
  [ -z "$dur" ] && dur=0

  start="$PREVIEW_CLIP_START"
  if [ "$dur" -gt 0 ] && [ "$start" -ge "$dur" ]; then
    start=$(( dur / 4 ))
  fi

  local scale_filter="scale=${PREVIEW_CLIP_WIDTH}:-2"

  # ---- Generate plain clip (no subtitles) ----
  if [ ! -s "$out" ]; then
    echo "  -> Generating plain preview clip for ts${ts_idx} (${PREVIEW_CLIP_SECONDS}s)..." >&2
    ffmpeg -y -ss "$start" -i "$src" -t "$PREVIEW_CLIP_SECONDS" \
      -vf "$scale_filter" -an \
      -c:v libx264 -preset veryfast -crf 28 -movflags +faststart \
      "$out" >/dev/null 2>&1

    if [ ! -s "$out" ]; then
      echo "  -> Warning: plain clip generation failed for $src" >&2
    fi
  fi

  # Generate subtitled clip (if subtitles available)
  local sub_path=""

  if [ "$has_subs" -eq 1 ] && [ ! -s "$out_sub" ]; then
    local sub_file=""
    sub_file=$(find_subtitle_for_preview "$src" 2>/dev/null || true)

    if [ -n "$sub_file" ]; then
      local sub_filter=""

      if [[ "$sub_file" == embedded:* ]]; then
        local sub_idx="${sub_file#embedded:}"
        sub_filter="subtitles='${src}':si=${sub_idx}"
        echo "  -> Burning embedded subtitle stream $sub_idx into preview for ts${ts_idx}" >&2
      elif [[ "$sub_file" == *.sub ]]; then
        # VobSub: needs original_size for correct bitmap scaling
        sub_filter="subtitles='${sub_file}':original_size=${WIDTH}x${HEIGHT}"
        echo "  -> Burning VobSub $(basename "$sub_file") into preview for ts${ts_idx}" >&2
      elif [[ "$sub_file" == *.sup ]]; then
        # PGS: contains its own resolution info
        sub_filter="subtitles='${sub_file}'"
        echo "  -> Burning PGS $(basename "$sub_file") into preview for ts${ts_idx}" >&2
      fi
      if [ -n "$sub_filter" ]; then
        # Use -copyts so the subtitles filter sees correct PTS values after input seeking, otherwise subs may not appear.
        ffmpeg -y -ss "$start" -copyts -i "$src" -t "$PREVIEW_CLIP_SECONDS" \
          -vf "${sub_filter},${scale_filter}" -an \
          -c:v libx264 -preset veryfast -crf 28 -movflags +faststart \
          "$out_sub" >/dev/null 2>&1

        if [ -s "$out_sub" ]; then
          sub_path="$out_sub"
        else
          echo "  -> Subtitle burning failed for ts${ts_idx}, falling back to plain clip" >&2
        fi
      fi
    else
      echo "  -> No subtitle file found for burning into preview for ts${ts_idx}" >&2
    fi
  elif [ "$has_subs" -eq 1 ] && [ -s "$out_sub" ]; then
    sub_path="$out_sub"
  fi

  # ---- Generate poster frame ----
  if [ ! -s "$poster" ]; then
    local poster_start=$(( start + PREVIEW_CLIP_SECONDS / 2 ))
    [ "$dur" -gt 0 ] && [ "$poster_start" -ge "$dur" ] && poster_start="$start"

    if [ -n "$sub_path" ]; then
      # Poster from subtitled clip (shows subtitle text)
      ffmpeg -y -ss 2 -i "$sub_path" -vframes 1 \
        -vf "$scale_filter" "$poster" >/dev/null 2>&1
    fi

    # Fallback: poster from source
    if [ ! -s "$poster" ]; then
      ffmpeg -y -ss "$poster_start" -i "$src" -vframes 1 \
        -vf "$scale_filter" "$poster" >/dev/null 2>&1
    fi
  fi

  local plain_out=""
  [ -s "$out" ] && plain_out="$out"
  local poster_out=""
  [ -s "$poster" ] && poster_out="$poster"

  echo "${plain_out}|${sub_path}|${poster_out}"
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

  # Convert to percentages for CSS (relative to menu dimensions)
  local title_bar_pct=$(( (title_bar_h * 100) / menu_h ))
  local top_margin_pct=$(( (top_margin * 100) / menu_h ))
  local left_margin_pct=$(( (left_margin * 100) / menu_w ))
  local btn_area_right_pct=$left_margin_pct

  # Pre-generate proxy clips/posters up front
  declare -a CLIP_PLAIN CLIP_SUB POSTER_PATH

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
    CLIP_SUB[$i]="${rest%%|*}"
    POSTER_PATH[$i]="${rest##*|}"
  done

  # Determine if we have extras
  local has_extras=0
  [ ${#ANALYSIS_TITLES[@]} -gt 1 ] && has_extras=1

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

  /* === DVD frame — 4:3 aspect ratio === */
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

  .screen {
    position: absolute;
    inset: 0;
    display: none;
    flex-direction: column;
  }
  .screen.active { display: flex; }

  /* Background media (video/poster) for menu screens */
  .bg-media {
    position: absolute;
    inset: 0;
    width: 100%;
    height: 100%;
    object-fit: cover;
    z-index: 0;
    filter: brightness(0.35) saturate(0.7);
  }
  .bg-scrim {
    position: absolute;
    inset: 0;
    z-index: 1;
    background: linear-gradient(180deg, rgba(0,0,0,0.15) 0%, rgba(0,0,0,0.55) 100%);
  }

  /* === Menu screen layout (faithful to build_menu) === */

  /* Title bar — dark navy band, matching #1a1a2e from build_menu */
  .menu-screen .title-bar {
    position: absolute;
    top: 0; left: 0; right: 0;
    height: ${title_bar_pct}%;
    background: #1a1a2e;
    z-index: 2;
    display: flex;
    align-items: center;
    padding-left: ${left_margin_pct}%;
    padding-right: ${left_margin_pct}%;
  }

  /* Separator line — gray, matching #555555 from build_menu */
  .menu-screen .separator {
    position: absolute;
    top: ${title_bar_pct}%;
    left: 0; right: 0;
    height: 3px;
    background: #555555;
    z-index: 2;
  }

  /* Title text — white, bold, sized dynamically */
  .menu-screen .title-text {
    color: #ffffff;
    font-weight: bold;
    text-shadow: 0 2px 6px rgba(0,0,0,0.9);
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
    width: 100%;
  }

  /* Buttons container */
  .menu-screen .button-area {
    position: absolute;
    top: ${top_margin_pct}%;
    left: ${left_margin_pct}%;
    right: ${btn_area_right_pct}%;
    bottom: 5%;
    z-index: 3;
    display: flex;
    flex-direction: column;
    justify-content: flex-start;
    gap: 2px;
  }

  /* Button — matches DVD button text styling */
  .btn {
    background: none;
    border: none;
    color: #ffffff;
    font-size: 1em;
    text-align: left;
    cursor: pointer;
    padding: 6px 12px;
    display: block;
    width: 100%;
    transition: all 0.12s ease;
    text-shadow: 0 1px 4px rgba(0,0,0,0.9);
    font-family: inherit;
    border-radius: 2px;
    line-height: 1.4;
  }

  /* Selected/active button — red highlight matching spumux behavior */
  .btn:hover, .btn.active {
    color: #ff3333;
    background: rgba(255, 0, 0, 0.08);
    text-shadow: 0 0 8px rgba(255, 0, 0, 0.4);
  }

  .btn::before {
    content: "\\25B6 ";
    opacity: 0;
    color: #ff3333;
    transition: opacity 0.12s;
    font-size: 0.8em;
  }
  .btn:hover::before, .btn.active::before { opacity: 1; }

  /* === Movie playback screen === */
  .movie-screen .video-container {
    position: absolute;
    inset: 0;
    z-index: 0;
    background: #000;
  }
  .movie-screen .video-container video,
  .movie-screen .video-container img {
    width: 100%;
    height: 100%;
    object-fit: contain;
  }

  .movie-screen .overlay {
    position: absolute;
    inset: 0;
    z-index: 2;
    display: flex;
    flex-direction: column;
    justify-content: flex-end;
    align-items: center;
    padding-bottom: 7%;
    background: linear-gradient(0deg, rgba(0,0,0,0.7) 0%, transparent 35%, transparent 100%);
    pointer-events: none;
  }
  .movie-screen .overlay > * { pointer-events: auto; }

  .now-playing-badge {
    display: inline-flex;
    align-items: center;
    gap: 6px;
    color: #ff5555;
    font-size: 0.65em;
    letter-spacing: 2px;
    margin-bottom: 6px;
    text-transform: uppercase;
  }
  .now-playing-badge .dot {
    width: 8px; height: 8px;
    border-radius: 50%;
    background: #ff0000;
    animation: pulse 1.4s infinite;
  }
  @keyframes pulse { 0%,100% { opacity: 1; } 50% { opacity: 0.3; } }

  .movie-screen h2 {
    color: #fff;
    font-size: 1.1em;
    text-shadow: 0 2px 8px rgba(0,0,0,1);
    margin-bottom: 10px;
    text-align: center;
    max-width: 80%;
  }

  .movie-screen .nav-buttons {
    display: flex;
    gap: 10px;
    flex-wrap: wrap;
    justify-content: center;
  }
  .movie-screen .nav-buttons .btn {
    width: auto;
    padding: 5px 16px;
    border: 1px solid rgba(255,255,255,0.2);
    border-radius: 4px;
    font-size: 0.8em;
    background: rgba(0,0,0,0.5);
    backdrop-filter: blur(4px);
  }
  .movie-screen .nav-buttons .btn:hover,
  .movie-screen .nav-buttons .btn.active {
    border-color: rgba(255, 80, 80, 0.6);
    background: rgba(255, 0, 0, 0.15);
  }

  /* Subtitle indicator badge */
  .sub-badge {
    position: absolute;
    top: 8px; right: 10px;
    background: rgba(0,0,0,0.7);
    color: #ffd700;
    font-size: 0.6em;
    padding: 3px 8px;
    border-radius: 3px;
    z-index: 3;
    display: none;
    letter-spacing: 1px;
    border: 1px solid rgba(255, 215, 0, 0.3);
  }
  .sub-badge.visible { display: block; }

  /* Remote control panel */
  .remote-panel {
    margin-top: 16px;
    display: flex;
    gap: 12px;
    align-items: center;
    flex-wrap: wrap;
  }
  .remote-panel button {
    background: #2a2a2a;
    color: #ddd;
    border: 1px solid #444;
    padding: 8px 16px;
    border-radius: 4px;
    cursor: pointer;
    font-size: 0.85em;
    transition: all 0.15s;
  }
  .remote-panel button:hover {
    background: #3a3a3a;
    border-color: #666;
    color: #fff;
  }
  .remote-panel .hint { color: #666; font-size: 0.8em; }

  .proxy-note {
    max-width: 720px;
    margin-top: 14px;
    font-size: 0.75em;
    color: #555;
    text-align: center;
    line-height: 1.5;
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
  # Per-Titleset Screens (Subtitle Menu + Movie Playback)
  # ================================================================
  for i in "${!ANALYSIS_TITLES[@]}"; do
    ts_idx=$((i + 1))
    local title="${ANALYSIS_TITLES[$i]}"
    local has_subs="${ANALYSIS_HAS_SUBS[$i]}"
    local subs_str="${ANALYSIS_SUBS_STR[$i]}"
    local default_idx=$(( ANALYSIS_DEFAULTS[$i] - 64 ))
    local clip_plain="${CLIP_PLAIN[$i]:-}"
    local clip_sub="${CLIP_SUB[$i]:-}"
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

      # Subtitle option buttons
      IFS='|' read -ra subs <<< "$subs_str"
      for j in "${!subs[@]}"; do
        local sub_label="${subs[$j]}"
        local btn_class="btn"
        local data_subs="on"
        if [ "$j" -eq "$default_idx" ]; then
          btn_class="btn active"
        fi
        echo "        <button class='${btn_class}' data-target='ts${ts_idx}_movie' data-subs='on' data-sub-label='${sub_label}'>${sub_label}</button>" >> "$html_file"
      done

      # "No subtitles" button
      echo "        <button class='btn' data-target='ts${ts_idx}_movie' data-subs='off'>No subtitles</button>" >> "$html_file"

      # "Back to Extras" for extras (ts_idx > 1), matching build_menu
      if [ "$ts_idx" -gt 1 ] && [ "$has_extras" -eq 1 ]; then
        echo "        <button class='btn' data-target='vmgm_extras'>Back to Extras</button>" >> "$html_file"
      fi

      # "Main Menu" button
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

    # Determine which clip to use as default source
    local default_clip="$clip_plain"
    local sub_available=0
    if [ -n "$clip_sub" ]; then
      default_clip="$clip_sub"
      sub_available=1
    fi

    if [ -n "$default_clip" ]; then
      echo "        <video autoplay muted loop playsinline" >> "$html_file"
      [ -n "$poster" ] && echo "          poster='$poster'" >> "$html_file"
      echo "          data-plain-src='${clip_plain}'" >> "$html_file"
      [ -n "$clip_sub" ] && echo "          data-sub-src='${clip_sub}'" >> "$html_file"
      echo "          data-sub-available='${sub_available}'>" >> "$html_file"
      echo "          <source src='${default_clip}' type='video/mp4'>" >> "$html_file"
      echo "        </video>" >> "$html_file"
    elif [ -n "$poster" ]; then
      echo "        <img src='$poster' alt=''>" >> "$html_file"
    else
      echo "        <div style='display:flex;align-items:center;justify-content:center;height:100%;color:#666;font-size:0.8em;'>No preview available</div>" >> "$html_file"
    fi

    cat <<HTMLEOF >> "$html_file"
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

    # "Back to Extras" on movie screen for extras (matching the DVD's post-command behavior)
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
  # Close DVD frame, add controls and JavaScript
  # ================================================================
  cat <<HTMLEOF >> "$html_file"
  </div>

  <div class="remote-panel">
    <button onclick="showScreen('vmgm')">DVD Menu</button>
    <span class="hint">Arrow Keys = navigate &middot; Enter = select &middot; Esc/M = Menu</span>
  </div>

  <div class="proxy-note">
    Background videos are throwaway H.264 proxies (${PREVIEW_CLIP_SECONDS}s @ ${PREVIEW_CLIP_WIDTH}px) generated by ffmpeg for preview only.<br>
HTMLEOF

  local sub_count=0
  for i in "${!ANALYSIS_TITLES[@]}"; do
    [ -n "${CLIP_SUB[$i]:-}" ] && sub_count=$((sub_count + 1))
  done

  if [ "$sub_count" -gt 0 ]; then
    echo "Subtitles are burned into ${sub_count} preview clip(s). Use the Subtitle Menu to toggle." >> "$html_file"
  else
    echo "No subtitle files were found for burning into preview clips." >> "$html_file"
  fi

  cat <<HTMLEOF >> "$html_file"
    <br>They have no effect on the actual DVD-Video encode.
  </div>

  <script>
    let currentButtons = [];
    let selectedIndex = 0;

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

      // Handle video source switching (subtitles on/off)
      const video = target.querySelector("video");
      if (video) {
        const plainSrc = video.getAttribute("data-plain-src");
        const subSrc = video.getAttribute("data-sub-src");
        const subAvailable = video.getAttribute("data-sub-available") === "1";
        const currentSource = video.querySelector("source");
        const subBadge = target.querySelector(".sub-badge");

        let useSubs = subAvailable;
        if (options && options.subs === "off") useSubs = false;
        if (options && options.subs === "on") useSubs = true;

        const desiredSrc = useSubs && subSrc ? subSrc : plainSrc;
        if (currentSource && currentSource.getAttribute("src") !== desiredSrc) {
          currentSource.setAttribute("src", desiredSrc);
          video.load();
        }

        video.currentTime = 0;
        video.play().catch(() => {});

        if (subBadge) {
          subBadge.classList.toggle("visible", useSubs && subAvailable);
        }
      }

      // Update button tracking for keyboard navigation
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

    // Initialize at main menu
    showScreen("vmgm");
  </script>
</body>
</html>
HTMLEOF

  echo "============================================================="
  echo " 🌐 HTML Preview generated at file://$(pwd)/$html_file"
  echo "    ${#ANALYSIS_TITLES[@]} titles · ${DETECTED_FORMAT^^} ${WIDTH}x${HEIGHT}"
  echo "    Clips: ${PREVIEW_CLIP_SECONDS}s @ ${PREVIEW_CLIP_WIDTH}px wide"
  echo "    Subtitles burned: ${sub_count}/${#ANALYSIS_TITLES[@]}"
  echo "============================================================="
}