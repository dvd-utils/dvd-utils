#!/usr/bin/env bash

# HTML Preview Generator

generate_html_preview() {
  local html_file="dvd_preview.html"

  {
    echo '<!DOCTYPE html><html><head><meta charset="UTF-8">'
    echo '<style>'
    echo '  body { background: #121212; color: #d4d4d4; font-family: Arial, sans-serif; display: flex; flex-direction: column; align-items: center; padding: 20px; }'
    echo '  h1 { color: #fff; margin-bottom: 5px; }'
    echo '  .meta { color: #888; margin-bottom: 20px; font-size: 0.9em; }'
    echo '  .dvd-frame { width: 100%; max-width: 800px; aspect-ratio: 4/3; background: #000; border: 2px solid #333; position: relative; overflow: hidden; box-shadow: 0 0 20px rgba(0,0,0,0.5); }'
    echo '  .screen { position: absolute; top: 0; left: 0; width: 100%; height: 100%; display: none; flex-direction: column; padding: 40px; box-sizing: border-box; }'
    echo '  .screen.active { display: flex; }'
    echo '  .title { color: #fff; font-size: 24px; margin-bottom: 30px; font-weight: bold; }'
    echo '  .btn { background: none; border: none; color: #ccc; font-size: 18px; text-align: left; cursor: pointer; padding: 8px 0; display: block; width: 100%; transition: all 0.1s; }'
    echo '  .btn:hover, .btn:focus { color: #ff0000; outline: none; transform: translateX(10px); }'
    echo '  .btn::before { content: "▶ "; opacity: 0; color: #ff0000; }'
    echo '  .btn:hover::before { opacity: 1; }'
    echo '  .movie-placeholder { display: flex; flex-direction: column; justify-content: center; align-items: center; height: 100%; }'
    echo '  .movie-placeholder h2 { color: #fff; }'
    echo '  .movie-placeholder .controls { margin-top: 20px; font-size: 14px; color: #666; }'
    echo '  .remote { margin-top: 15px; display: flex; gap: 10px; }'
    echo '  .remote button { background: #333; color: #fff; border: none; padding: 8px 16px; border-radius: 4px; cursor: pointer; }'
    echo '  .remote button:hover { background: #555; }'
    echo '</style></head><body>'

    echo "<h1>DVD Preview</h1>"
    echo "<div class='meta'>Format: ${DETECTED_FORMAT^^} ${WIDTH}x${HEIGHT} @ ${FPS}fps</div>"
    echo "<div class='dvd-frame'>"

    # JavaScript for navigation
    echo '<script>
      function showScreen(id) {
        document.querySelectorAll(".screen").forEach(s => s.classList.remove("active"));
        document.getElementById(id).classList.add("active");
      }
    </script>'

    # VMGM Main Menu
    echo '<div id="vmgm" class="screen active">'
    echo "<div class=\"title\">${ANALYSIS_TITLES[0]}</div>"
    echo '<button class="btn" onclick="showScreen('\''ts1_movie'\'')">Play movie</button>'

    # Add Extras button if extras exist
    if [ ${#ANALYSIS_TITLES[@]} -gt 1 ]; then
      echo '<button class="btn" onclick="showScreen('\''vmgm_extras'\'')">Extras Menu</button>'
    fi
    echo '</div>'

    # VMGM Extras Menu
    if [ ${#ANALYSIS_TITLES[@]} -gt 1 ]; then
      echo '<div id="vmgm_extras" class="screen">'
      echo '<div class="title">Extras Menu</div>'
      for i in "${!ANALYSIS_TITLES[@]}"; do
        local ts_idx=$((i + 1))
        if [ "$ts_idx" -gt 1 ]; then
          local title="${ANALYSIS_TITLES[$i]}"
          echo "<button class='btn' onclick=\"showScreen('ts${ts_idx}_movie')\">$title</button>"
        fi
      done
      echo "<button class='btn' onclick=\"showScreen('vmgm')\">Main menu</button>"
      echo '</div>'
    fi

    # Titleset Screens (Subtitle Menus + Movie Play Screens)
    for i in "${!ANALYSIS_TITLES[@]}"; do
      local ts_idx=$((i + 1))
      local title="${ANALYSIS_TITLES[$i]}"
      local has_subs="${ANALYSIS_HAS_SUBS[$i]}"
      local subs_str="${ANALYSIS_SUBS_STR[$i]}"
      local default_idx=$(( ANALYSIS_DEFAULTS[$i] - 64 ))

      # Subtitle Menu
      if [ "$has_subs" -eq 1 ]; then
        echo "<div id='ts${ts_idx}_menu' class='screen'>"
        local menu_title="Subtitles: $title"
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
        echo '</div>'
      fi

      # Movie Playing Screen
      echo "<div id='ts${ts_idx}_movie' class='screen'>"
      echo "<div class='movie-placeholder'>"
      echo "<h2>▶ Playing: $title</h2>"
      if [ "$has_subs" -eq 1 ]; then
        echo "<button class='btn' style='max-width:200px; margin-top:20px; text-align:center;' onclick=\"showScreen('ts${ts_idx}_menu')\">Subtitle Menu</button>"
      fi
      echo "<button class='btn' style='max-width:200px; margin-top:10px; text-align:center;' onclick=\"showScreen('vmgm')\">Return to Main Menu</button>"
      echo "</div>"
      echo '</div>'
    done

    echo '</div>' # End dvd-frame

    # Fake DVD Remote
    echo '<div class="remote">'
    echo '<button onclick="showScreen('\''vmgm'\'')">DVD Menu</button>'
    echo '</div>'

    echo '</body></html>'
  } > "$html_file"

  echo "============================================================="
  echo " 🌐 HTML Preview generated at file://$(pwd)/$html_file"
  echo "============================================================="
}