#!/usr/bin/env bash

# HTML Preview Generator

# ---------------------------------------------------------------------------
# Config for background preview clips (override via env before sourcing)
# ---------------------------------------------------------------------------
PREVIEW_CACHE_DIR="${PREVIEW_CACHE_DIR:-preview_cache}"
PREVIEW_CLIP_SECONDS="${PREVIEW_CLIP_SECONDS:-5}"     # length of looping bg clip
PREVIEW_CLIP_START="${PREVIEW_CLIP_START:-120}"       # seek-in point (skip logos/black)
PREVIEW_CLIP_WIDTH="${PREVIEW_CLIP_WIDTH:-480}"       # keep it small, it's just a preview

# ---------------------------------------------------------------------------
# HELPER: Generate (and cache) a small muted H.264 proxy clip + poster frame for one source .mpg. Browsers can't play raw MPEG-2 .mpg, so this is a throwaway preview asset only. It has no bearing on the real DVD encode.
# Echoes "clip_path|poster_path" (either half may be empty on failure) so the caller can fall back gracefully.
# ---------------------------------------------------------------------------
generate_preview_clip() {
  local src="$1" ts_idx="$2"
  mkdir -p "$PREVIEW_CACHE_DIR"
  local out="$PREVIEW_CACHE_DIR/ts${ts_idx}_preview.mp4"
  local poster="$PREVIEW_CACHE_DIR/ts${ts_idx}_poster.jpg"

  # Cache hit: reuse what we already generated for this titleset
  if [ -s "$out" ] && [ -s "$poster" ]; then
    echo "$out|$poster"
    return 0
  fi

  if ! command -v ffmpeg >/dev/null 2>&1; then
    echo "Note: ffmpeg not found, falling back to text-only preview for ts${ts_idx}." >&2
    echo "|"
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

  ffmpeg -y -ss "$start" -i "$src" -t "$PREVIEW_CLIP_SECONDS" \
    -vf "scale=${PREVIEW_CLIP_WIDTH}:-2" -an \
    -c:v libx264 -preset veryfast -crf 28 -movflags +faststart \
    "$out" >/dev/null 2>&1

  ffmpeg -y -ss "$start" -i "$src" -vframes 1 \
    -vf "scale=${PREVIEW_CLIP_WIDTH}:-2" "$poster" >/dev/null 2>&1

  if [ ! -s "$out" ]; then
    echo "Warning: preview clip generation failed for $src, falling back to poster/text." >&2
  fi

  local clip_out="" poster_out=""
  [ -s "$out" ] && clip_out="$out"
  [ -s "$poster" ] && poster_out="$poster"
  echo "${clip_out}|${poster_out}"
}

generate_html_preview() {
  local html_file="dvd_preview.html"

  # Pre-generate proxy clips/posters up front
  declare -a CLIP_PATH POSTER_PATH
  for i in "${!ANALYSIS_TITLES[@]}"; do
    ts_idx=$((i + 1))
    info=$(generate_preview_clip "${ALL_VIDEOS[$i]}" "$ts_idx")
    CLIP_PATH[$i]="${info%%|*}"
    POSTER_PATH[$i]="${info##*|}"
  done

  cat <<EOF > "$html_file"
<!DOCTYPE html>
<html>
<head>
<meta charset="UTF-8">
<style>
  * { box-sizing: border-box; }
  body { background: #121212; color: #d4d4d4; font-family: Arial, sans-serif; display: flex; flex-direction: column; align-items: center; padding: 20px; }
  h1 { color: #fff; margin-bottom: 5px; }
  .meta { color: #888; margin-bottom: 20px; font-size: 0.9em; }
  .dvd-frame { width: 100%; max-width: 800px; aspect-ratio: 4/3; background: #000; border: 2px solid #333; position: relative; overflow: hidden; box-shadow: 0 0 20px rgba(0,0,0,0.5); }
  .screen { position: absolute; inset: 0; display: none; flex-direction: column; }
  .screen.active { display: flex; }
  .screen-content { position: relative; z-index: 2; flex: 1; display: flex; flex-direction: column; padding: 40px; }
  .bg-media { position: absolute; inset: 0; width: 100%; height: 100%; object-fit: cover; z-index: 0; filter: brightness(0.45) saturate(0.8); }
  .bg-scrim { position: absolute; inset: 0; z-index: 1; background: linear-gradient(180deg, rgba(0,0,0,0.2) 0%, rgba(0,0,0,0.6) 100%); }
  .title { color: #fff; font-size: 24px; margin-bottom: 30px; font-weight: bold; text-shadow: 0 2px 6px rgba(0,0,0,0.9); }
  .btn { background: none; border: none; color: #ccc; font-size: 18px; text-align: left; cursor: pointer; padding: 8px 15px; display: block; width: 100%; transition: all 0.1s; text-shadow: 0 1px 3px rgba(0,0,0,0.9); }
  .btn:hover, .btn.active { color: #ff0000; outline: none; transform: translateX(10px); background: rgba(255,0,0,0.1); }
  .btn::before { content: "▶ "; opacity: 0; color: #ff0000; }
  .btn:hover::before, .btn.active::before { opacity: 1; }
  .movie-placeholder { display: flex; flex-direction: column; justify-content: flex-end; align-items: center; height: 100%; text-align: center; }
  .movie-placeholder h2 { color: #fff; text-shadow: 0 2px 6px rgba(0,0,0,0.9); }
  .movie-placeholder .btn { max-width: 220px; text-align: center; margin-top: 8px; }
  .now-playing-badge { display: inline-flex; align-items: center; gap: 6px; color: #ff5555; font-size: 12px; letter-spacing: 1px; margin-bottom: 10px; text-transform: uppercase; }
  .now-playing-badge .dot { width: 8px; height: 8px; border-radius: 50%; background: #ff0000; animation: pulse 1.4s infinite; }
  @keyframes pulse { 0%,100% { opacity: 1; } 50% { opacity: 0.3; } }
  .remote { margin-top: 15px; display: flex; gap: 10px; }
  .remote button { background: #333; color: #fff; border: none; padding: 8px 16px; border-radius: 4px; cursor: pointer; }
  .remote button:hover { background: #555; }
  .proxy-note { max-width: 800px; margin-top: 12px; font-size: 0.8em; color: #666; text-align: center; }
</style>
</head>
<body>
  <h1>DVD Preview</h1>
  <div class="meta">Format: ${DETECTED_FORMAT^^} ${WIDTH}x${HEIGHT} @ ${FPS}fps</div>
  <div class="dvd-frame">
EOF

  # Generate Screens
  # VMGM Main Menu
  cat <<EOF >> "$html_file"
    <div id="vmgm" class="screen active">
      $([ -n "${POSTER_PATH[0]:-}" ] && echo "<img class='bg-media' src='${POSTER_PATH[0]}' alt=''><div class='bg-scrim'></div>")
      <div class="screen-content">
        <div class="title">${ANALYSIS_TITLES[0]}</div>
        <button class="btn" data-target="ts1_movie">Play movie</button>
EOF

  if [ ${#ANALYSIS_TITLES[@]} -gt 1 ]; then
    echo '<button class="btn" data-target="vmgm_extras">Extras Menu</button>' >> "$html_file"
  fi

  cat <<EOF >> "$html_file"
      </div>
    </div>
EOF

  # VMGM Extras Menu
  if [ ${#ANALYSIS_TITLES[@]} -gt 1 ]; then
    cat <<EOF >> "$html_file"
    <div id="vmgm_extras" class="screen">
      <div class="screen-content">
        <div class="title">Extras Menu</div>
EOF
    for i in "${!ANALYSIS_TITLES[@]}"; do
      ts_idx=$((i + 1))
      if [ "$ts_idx" -gt 1 ]; then
        echo "<button class='btn' data-target='ts${ts_idx}_movie'>${ANALYSIS_TITLES[$i]}</button>" >> "$html_file"
      fi
    done
    echo "<button class='btn' data-target='vmgm'>Main menu</button>" >> "$html_file"
    echo "</div></div>" >> "$html_file"
  fi

  # Titleset Screens
  for i in "${!ANALYSIS_TITLES[@]}"; do
    local ts_idx=$((i + 1))
    local title="${ANALYSIS_TITLES[$i]}"
    local has_subs="${ANALYSIS_HAS_SUBS[$i]}"
    local subs_str="${ANALYSIS_SUBS_STR[$i]}"
    local default_idx=$(( ANALYSIS_DEFAULTS[$i] - 64 ))
    local clip="${CLIP_PATH[$i]:-}"
    local poster="${POSTER_PATH[$i]:-}"

    # Subtitle Menu
    if [ "$has_subs" -eq 1 ]; then
      cat <<EOF >> "$html_file"
      <div id='ts${ts_idx}_menu' class='screen'>
        $([ -n "$poster" ] && echo "<img class='bg-media' src='$poster' alt=''><div class='bg-scrim'></div>")
        <div class="screen-content">
          <div class="title">Subtitles: $title</div>
EOF
      IFS='|' read -ra subs <<< "$subs_str"
      for j in "${!subs[@]}"; do
        local sub_label="${subs[$j]}"
        local btn_class="btn"
        if [ "$j" -eq "$default_idx" ]; then
          btn_class="btn active"
        fi
        echo "<button class='$btn_class' data-target='ts${ts_idx}_movie'>$sub_label</button>" >> "$html_file"
      done
      echo "<button class='btn' data-target='ts${ts_idx}_movie'>No subtitles</button>" >> "$html_file"
      echo "<button class='btn' data-target='vmgm'>Main Menu</button>" >> "$html_file"
      echo "</div></div>" >> "$html_file"
    fi

    # Movie Playing Screen
    cat <<EOF >> "$html_file"
    <div id='ts${ts_idx}_movie' class='screen'>
      $([ -n "$clip" ] && echo "<video class='bg-media' autoplay muted loop playsinline poster='$poster'><source src='$clip' type='video/mp4'></video>" || ([ -n "$poster" ] && echo "<img class='bg-media' src='$poster' alt=''>"))
      <div class="bg-scrim"></div>
      <div class="screen-content">
        <div class="movie-placeholder">
          <div class="now-playing-badge"><span class="dot"></span>Now Playing</div>
          <h2>$title</h2>
EOF
    if [ "$has_subs" -eq 1 ]; then
      echo "<button class='btn' data-target='ts${ts_idx}_menu'>Subtitle Menu</button>" >> "$html_file"
    fi
    echo "<button class='btn' data-target='vmgm'>Return to Main Menu</button>" >> "$html_file"
    echo '</div></div></div>' >> "$html_file"
  done

  # Close HTML and add Javascript for Navigation
  cat <<EOF >> "$html_file"
  </div>
  <div class="remote">
    <button onclick="showScreen('vmgm')">DVD Menu</button>
    <span style="color:#666; align-self:center; font-size:0.8em;">Tip: Use Arrow Keys & Enter to navigate</span>
  </div>

  <div class="proxy-note">Background video/posters are throwaway H.264 proxies generated by ffmpeg for preview only.<br>They have no effect on the actual DVD-Video encode.</div>

  <script>
    let currentButtons = [];
    let selectedIndex = 0;

    function showScreen(id) {
      document.querySelectorAll(".screen").forEach(s => {
        s.classList.remove("active");
        const v = s.querySelector("video");
        if (v) v.pause();
      });

      const target = document.getElementById(id);
      target.classList.add("active");

      const v = target.querySelector("video");
      if (v) { v.currentTime = 0; v.play().catch(() => {}); }

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

    // Handle Keyboard Navigation (Like a real DVD player)
    document.addEventListener('keydown', (e) => {
      if (currentButtons.length === 0) return;

      if (e.key === 'ArrowDown' || e.key === 'ArrowRight') {
        e.preventDefault();
        selectedIndex = (selectedIndex + 1) % currentButtons.length;
        updateButtonStates();
      } else if (e.key === 'ArrowUp' || e.key === 'ArrowLeft') {
        e.preventDefault();
        selectedIndex = (selectedIndex - 1 + currentButtons.length) % currentButtons.length;
        updateButtonStates();
      } else if (e.key === 'Enter') {
        e.preventDefault();
        const btn = currentButtons[selectedIndex];
        const target = btn.getAttribute('data-target');
        if (target) showScreen(target);
      }
    });

    // Attach click handlers to data-target buttons
    document.querySelectorAll('.btn').forEach(btn => {
      btn.addEventListener('click', () => {
        const target = btn.getAttribute('data-target');
        if (target) showScreen(target);
      });
    });
  </script>
</body>
</html>
EOF

  echo "============================================================="
  echo " 🌐 HTML Preview generated at file://$(pwd)/$html_file"
  echo "============================================================="
}