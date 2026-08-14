#!/usr/bin/env bash

# HTML Preview Generator

# ---------------------------------------------------------------------------
# Config for background preview clips (override via env before sourcing)
# ---------------------------------------------------------------------------
PREVIEW_CACHE_DIR="${PREVIEW_CACHE_DIR:-preview_cache}"
PREVIEW_CLIP_SECONDS="${PREVIEW_CLIP_SECONDS:-5}"     # length of looping bg clip
PREVIEW_CLIP_START="${PREVIEW_CLIP_START:-120}"        # seek-in point (skip logos/black)
PREVIEW_CLIP_WIDTH="${PREVIEW_CLIP_WIDTH:-480}"        # keep it small, it's just a preview

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

  {
    echo '<!DOCTYPE html><html><head><meta charset="UTF-8">'
    echo '<style>'
    echo '  * { box-sizing: border-box; }'
    echo '  body { background: #121212; color: #d4d4d4; font-family: Arial, sans-serif; display: flex; flex-direction: column; align-items: center; padding: 20px; }'
    echo '  h1 { color: #fff; margin-bottom: 5px; }'
    echo '  .meta { color: #888; margin-bottom: 20px; font-size: 0.9em; }'
    echo '  .dvd-frame { width: 100%; max-width: 800px; aspect-ratio: 4/3; background: #000; border: 2px solid #333; position: relative; overflow: hidden; box-shadow: 0 0 20px rgba(0,0,0,0.5); }'
    echo '  .screen { position: absolute; inset: 0; display: none; flex-direction: column; }'
    echo '  .screen.active { display: flex; }'
    echo '  .screen-content { position: relative; z-index: 2; flex: 1; display: flex; flex-direction: column; padding: 40px; }'
  # echo '  .bg-media { position: absolute; inset: 0; width: 100%; height: 100%; object-fit: cover; z-index: 0; filter: brightness(0.35) saturate(0.9); }'
    echo '  .bg-media { position: absolute; inset: 0; width: 100%; height: 100%; object-fit: cover; z-index: 0; }'
    echo '  .bg-scrim { position: absolute; inset: 0; z-index: 1; background: linear-gradient(180deg, rgba(0,0,0,0.05) 0%, rgba(0,0,0,0.15) 100%); }'
    echo '  .title { color: #fff; font-size: 24px; margin-bottom: 30px; font-weight: bold; text-shadow: 0 2px 6px rgba(0,0,0,0.8); }'
    echo '  .btn { background: none; border: none; color: #ccc; font-size: 18px; text-align: left; cursor: pointer; padding: 8px 0; display: block; width: 100%; transition: all 0.1s; text-shadow: 0 1px 3px rgba(0,0,0,0.8); }'
    echo '  .btn:hover, .btn:focus { color: #ff0000; outline: none; transform: translateX(10px); }'
    echo '  .btn::before { content: "▶ "; opacity: 0; color: #ff0000; }'
    echo '  .btn:hover::before { opacity: 1; }'
    echo '  .movie-placeholder { display: flex; flex-direction: column; justify-content: flex-end; align-items: center; height: 100%; text-align: center; }'
    echo '  .movie-placeholder h2 { color: #fff; text-shadow: 0 2px 6px rgba(0,0,0,0.8); }'
    echo '  .movie-placeholder .btn { max-width: 220px; text-align: center; margin-top: 8px; }'
    echo '  .now-playing-badge { display: inline-flex; align-items: center; gap: 6px; color: #ff5555; font-size: 12px; letter-spacing: 1px; margin-bottom: 10px; text-transform: uppercase; }'
    echo '  .now-playing-badge .dot { width: 8px; height: 8px; border-radius: 50%; background: #ff0000; animation: pulse 1.4s infinite; }'
    echo '  @keyframes pulse { 0%,100% { opacity: 1; } 50% { opacity: 0.3; } }'
    echo '  .remote { margin-top: 15px; display: flex; gap: 10px; }'
    echo '  .remote button { background: #333; color: #fff; border: none; padding: 8px 16px; border-radius: 4px; cursor: pointer; }'
    echo '  .remote button:hover { background: #555; }'
    echo '  .proxy-note { max-width: 800px; margin-top: 12px; font-size: 0.8em; color: #666; text-align: center; }'
    echo '</style></head><body>'

    echo "<h1>DVD Preview</h1>"
    echo "<div class='meta'>Format: ${DETECTED_FORMAT^^} ${WIDTH}x${HEIGHT} @ ${FPS}fps</div>"
    echo "<div class='dvd-frame'>"

    echo '<script>
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
      }
    </script>'

    # Pre-generate proxy clips/posters for every titleset up front so we can reuse the same poster behind menus as well as the movie screen.
    declare -a CLIP_PATH POSTER_PATH
    for i in "${!ANALYSIS_TITLES[@]}"; do
      ts_idx=$((i + 1))
      info=$(generate_preview_clip "${ALL_VIDEOS[$i]}" "$ts_idx")
      CLIP_PATH[$i]="${info%%|*}"
      POSTER_PATH[$i]="${info##*|}"
    done

    # VMGM Main Menu (use the main movie's poster as backdrop)
    echo '<div id="vmgm" class="screen active">'
    if [ -n "${POSTER_PATH[0]:-}" ]; then
      echo "<img class='bg-media' src='${POSTER_PATH[0]}' alt=''>"
      echo "<div class='bg-scrim'></div>"
    fi
    echo '<div class="screen-content">'
    echo "<div class=\"title\">${ANALYSIS_TITLES[0]}</div>"
    echo '<button class="btn" onclick="showScreen('\''ts1_movie'\'')">Play movie</button>'
    if [ ${#ANALYSIS_TITLES[@]} -gt 1 ]; then
      echo '<button class="btn" onclick="showScreen('\''vmgm_extras'\'')">Extras Menu</button>'
    fi
    echo '</div></div>'

    # VMGM Extras Menu
    if [ ${#ANALYSIS_TITLES[@]} -gt 1 ]; then
      echo '<div id="vmgm_extras" class="screen">'
      echo '<div class="screen-content">'
      echo '<div class="title">Extras Menu</div>'
      for i in "${!ANALYSIS_TITLES[@]}"; do
        ts_idx=$((i + 1))
        if [ "$ts_idx" -gt 1 ]; then
          title="${ANALYSIS_TITLES[$i]}"
          echo "<button class='btn' onclick=\"showScreen('ts${ts_idx}_movie')\">$title</button>"
        fi
      done
      echo "<button class='btn' onclick=\"showScreen('vmgm')\">Main menu</button>"
      echo '</div></div>'
    fi

    # Titleset Screens (Subtitle Menus + Movie Play Screens)
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
        echo "<div id='ts${ts_idx}_menu' class='screen'>"
        if [ -n "$poster" ]; then
          echo "<img class='bg-media' src='$poster' alt=''>"
          echo "<div class='bg-scrim'></div>"
        fi
        echo '<div class="screen-content">'
        menu_title="Subtitles: $title"
        [ "$ts_idx" -eq 1 ] && menu_title="Movie Subtitles"
        echo "<div class='title'>$menu_title</div>"

        IFS='|' read -ra subs <<< "$subs_str"
        for j in "${!subs[@]}"; do
          local sub_label="${subs[$j]}"
          local btn_style=""
          if [ "$j" -eq "$default_idx" ]; then
            btn_style="style='color: #ff0000; font-weight: bold;'"
          fi
          echo "<button class='btn' $btn_style onclick=\"showScreen('ts${ts_idx}_movie')\">$sub_label</button>"
        done
        echo "<button class='btn' onclick=\"showScreen('ts${ts_idx}_movie')\">No subtitles</button>"
        echo "<button class='btn' onclick=\"showScreen('vmgm')\">Main Menu</button>"
        echo '</div></div>'
      fi

      # Movie Playing Screen
      echo "<div id='ts${ts_idx}_movie' class='screen'>"
      if [ -n "$clip" ]; then
        echo "<video class='bg-media' autoplay muted loop playsinline poster='$poster'><source src='$clip' type='video/mp4'></video>"
      elif [ -n "$poster" ]; then
        echo "<img class='bg-media' src='$poster' alt=''>"
      fi
      echo "<div class='bg-scrim'></div>"
      echo '<div class="screen-content">'
      echo '<div class="movie-placeholder">'
      echo '<div class="now-playing-badge"><span class="dot"></span>Now Playing</div>'
      echo "<h2>$title</h2>"
      if [ "$has_subs" -eq 1 ]; then
        echo "<button class='btn' onclick=\"showScreen('ts${ts_idx}_menu')\">Subtitle Menu</button>"
      fi
      echo "<button class='btn' onclick=\"showScreen('vmgm')\">Return to Main Menu</button>"
      echo '</div></div></div>'
    done

    echo '</div>' # End dvd-frame

    # Fake DVD Remote
    echo '<div class="remote">'
    echo '<button onclick="showScreen('\''vmgm'\'')">DVD Menu</button>'
    echo '</div>'

    echo '<div class="proxy-note">Background video/posters are throwaway H.264 proxies generated by ffmpeg for preview only. <br>They have no effect on the actual DVD-Video encode.</div>'

    echo '</body></html>'
  } > "$html_file"

  echo "============================================================="
  echo " 🌐 HTML Preview generated at file://$(pwd)/$html_file"
  echo "============================================================="
}