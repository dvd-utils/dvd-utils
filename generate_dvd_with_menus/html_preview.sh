#!/usr/bin/env bash

# HTML Preview Generator

generate_html_preview() {
  local html_file="dvd_preview.html"
  {
    echo '<!DOCTYPE html><html><head><meta charset="UTF-8">'
    echo '<style>'
    echo '  body { font-family: Arial, sans-serif; background: #1e1e1e; color: #d4d4d4; padding: 20px; }'
    echo '  h1 { color: #fff; border-bottom: 2px solid #569cd6; padding-bottom: 10px; }'
    echo '  .format-badge { background: #569cd6; color: #000; padding: 4px 8px; border-radius: 4px; font-weight: bold; }'
    echo '  .structure { background: #252526; padding: 20px; border-radius: 8px; display: inline-block; }'
    echo '  .titleset { margin-bottom: 15px; padding: 15px; background: #2d2d2d; border-left: 5px solid #4ec9b0; border-radius: 4px; }'
    echo '  .title-name { font-size: 1.2em; font-weight: bold; color: #4ec9b0; margin-bottom: 10px; }'
    echo '  .sub-list { list-style-type: none; padding: 0; margin: 0; }'
    echo '  .sub-item { padding: 4px 0 4px 20px; color: #ccc; }'
    echo '  .default-sub { color: #dcdcaa; font-weight: bold; }'
    echo '  .default-sub::before { content: "▶ "; color: #dcdcaa; }'
    echo '  .no-subs { color: #999; font-style: italic; padding-left: 20px; }'
    echo '</style></head><body>'

    echo "<h1>DVD Build Preview</h1>"
    echo "<p><span class='format-badge'>${DETECTED_FORMAT^^}</span> ${WIDTH}x${HEIGHT} @ ${FPS}fps</p>"
    echo '<div class="structure">'

    for i in "${!ANALYSIS_TITLES[@]}"; do
      local title="${ANALYSIS_TITLES[$i]}"
      local subs_str="${ANALYSIS_SUBS_STR[$i]}"
      local has_subs="${ANALYSIS_HAS_SUBS[$i]}"
      local default_idx=$(( ANALYSIS_DEFAULTS[$i] - 64 ))

      echo "<div class='titleset'>"
      echo "<div class='title-name'>Titleset $((i+1)): $title</div>"

      if [ "$has_subs" -eq 1 ] && [ -n "$subs_str" ]; then
        echo '<ul class="sub-list">'
        IFS='|' read -ra subs <<< "$subs_str"
        for j in "${!subs[@]}"; do
          local class="sub-item"
          if [ "$j" -eq "$default_idx" ]; then
            class="sub-item default-sub"
          fi
          echo "<li class='$class'>${subs[$j]}</li>"
        done
        echo '</ul>'
      else
        echo '<div class="no-subs">No subtitles found</div>'
      fi
      echo "</div>"
    done

    echo '</div>'
    echo '</body></html>'
  } > "$html_file"

  echo "============================================================="
  echo " 🌐 HTML Preview generated: $(pwd)/$html_file"
  echo "============================================================="
}