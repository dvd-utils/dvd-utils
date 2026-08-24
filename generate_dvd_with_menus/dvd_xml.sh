#!/usr/bin/env bash
# ============================================================================
#  dvd_xml.sh — dvdauthor XML generation & authoring module
# ============================================================================
#  This script is designed to be sourced by build_dvd.sh.
#  It relies on the following globals being set by the parent script:
#    - DETECTED_FORMAT, WIDTH, HEIGHT, TARGET, FPS
#    - WORK_DIR, OUT_DIR, LOG_DIR
#    - EXTRAS_PER_PAGE, EXTRAS_MENU_LABELS, EXTRAS_MENU_TARGETS
# ============================================================================

# ---------------------------------------------------------------------------
# CORE LOGIC GLOBALS (Required for XML assembly)
# ---------------------------------------------------------------------------
XML_TITLESETS=""
VMGM_LABELS=()
VMGM_TARGETS=()

CURRENT_SUB_LABELS=()
CURRENT_HAS_SUBS=0
CURRENT_MUXED_MPG=""
CURRENT_DEFAULT_SUBP=62 # 62 = off (DVD convention)
CURRENT_INPUT_FILES=()
CURRENT_DATA_FILES=()

# Defaults for VMGM/FPC assembly (overwritten by the main script during processing)
MAIN_DEFAULT_SUBP=62
FPC_JUMP="g1 = 0; g2 = 0; jump vmgm menu entry title;"

# Array to hold extras PGC XML blocks
EXTRAS_VMGM_PGCS=()

# ---------------------------------------------------------------------------
# HELPER: Generate XML chunk for a single Titleset
# ---------------------------------------------------------------------------
# Optional 5th+ args: pairs of  "label" "vmgm_command"  used by extras
#   pagination to wire "Next page" / "Prev page" buttons.
#   When extra_vmgm_pairs are provided, this menu lives in the VMGM and
#   those button actions are appended to the label list automatically.
# ---------------------------------------------------------------------------
append_titleset_xml() {
  local ts_idx="$1"
  local title_pretty="$2"

  # Snapshot the globals set by [discover_subs]/[mux_subs] for this titleset
  local has_subs="$CURRENT_HAS_SUBS"
  local muxed_mpg="$CURRENT_MUXED_MPG"
  local default_subp="$CURRENT_DEFAULT_SUBP"
  local sub_labels=("${CURRENT_SUB_LABELS[@]}")

  XML_TITLESETS+="  <titleset>\n"

  if [ "$has_subs" -eq 1 ]; then
    local menu_mpg="$WORK_DIR/ts${ts_idx}_menu.mpg"
    # Build labels: subtitle options + navigation buttons
    local labels=("${sub_labels[@]}" "No subtitles")
    # Add "Back to Extras" for extra titlesets (ts_idx > 1 means it's an extra)
    if [ "$ts_idx" -gt 1 ]; then
      labels+=("Back to Extras")
    fi
    labels+=("Main Menu")

    local menu_title="Subtitles: ${title_pretty}"
    [ "$ts_idx" -eq 1 ] && menu_title="Movie Subtitles"

    build_menu "$menu_mpg" "$menu_title" "${labels[@]}"

    XML_TITLESETS+="    <menus lang=\"en\">\n"
    XML_TITLESETS+="      <video format=\"${DETECTED_FORMAT}\" resolution=\"${WIDTH}x${HEIGHT}\" />\n"
    # pause="inf" on <vob> holds the still-frame indefinitely to prevent the 
    # DVD VM from resetting the button highlight state when the cell loops.
    XML_TITLESETS+="      <pgc entry=\"root,subtitle\">\n"
    XML_TITLESETS+="        <vob file=\"$menu_mpg\" pause=\"inf\" />\n"
    
    local btn_idx=0
    for i in "${!sub_labels[@]}"; do
      local val=$((64 + i))
      # Set g2 = 1 so the title knows we explicitly chose this subtitle
      XML_TITLESETS+="        <button name=\"b$btn_idx\"> { subtitle = $val; g2 = 1; if (g1 eq 1) resume; else jump titleset $ts_idx title 1; } </button>\n"
      btn_idx=$((btn_idx+1))
    done

    # Set g2 = 1 for "No subtitles" as well
    XML_TITLESETS+="        <button name=\"b$btn_idx\"> { subtitle = 62; g2 = 1; if (g1 eq 1) resume; else jump titleset $ts_idx title 1; } </button>\n"
    btn_idx=$((btn_idx+1))

    # "Back to Extras" button (only for extras, ts_idx > 1) jumps to PGC 2 in VMGM
    if [ "$ts_idx" -gt 1 ]; then
      XML_TITLESETS+="        <button name=\"b$btn_idx\"> { g1 = 0; g2 = 0; jump vmgm menu 2; } </button>\n"
      btn_idx=$((btn_idx+1))
    fi

    XML_TITLESETS+="        <button name=\"b$btn_idx\"> { g1 = 0; g2 = 0; jump vmgm menu entry title; } </button>\n"

    # Explicitly specify the titleset index for the jump
    XML_TITLESETS+="        <post> { if (g1 eq 1) resume; else jump titleset $ts_idx title 1; } </post>\n"
    XML_TITLESETS+="      </pgc>\n    </menus>\n"
  fi

  XML_TITLESETS+="    <titles>\n"
  XML_TITLESETS+="      <video format=\"${DETECTED_FORMAT}\" resolution=\"${WIDTH}x${HEIGHT}\" />\n"
  
  if [ "$has_subs" -eq 1 ]; then
    for i in "${!sub_labels[@]}"; do
      XML_TITLESETS+="      <subpicture />\n"
    done
  fi

  # dvdauthor throws "Unknown entry 'title'" if entry attribute is set inside <titles>
  XML_TITLESETS+="      <pgc>\n"
  if [ "$has_subs" -eq 1 ]; then
    # Only apply default subtitle if g2 eq 0 (meaning we didn't come from the subtitle menu)
    XML_TITLESETS+="        <pre> { if (g2 eq 0) { subtitle = ${default_subp}; } g1 = 1; g2 = 0; } </pre>\n"
  else
    XML_TITLESETS+="        <pre> { g1 = 1; g2 = 0; } </pre>\n"
  fi
  XML_TITLESETS+="        <vob file=\"$muxed_mpg\" chapters=\"0\" />\n"
  XML_TITLESETS+="        <post> { g1 = 0; call vmgm menu; } </post>\n"
  XML_TITLESETS+="      </pgc>\n    </titles>\n"
  XML_TITLESETS+="  </titleset>\n\n"
}

# ---------------------------------------------------------------------------
# Generate paginated Extras Menus XML blocks
# ---------------------------------------------------------------------------
generate_extras_pgc_xml() {
  local extras_labels=("$@")
  # Reset array of PGC XML blocks for the <vmgm><menus> section
  EXTRAS_VMGM_PGCS=()

  if [ ${#extras_labels[@]} -eq 0 ]; then
    return
  fi

  local local_num_extras=${#extras_labels[@]}
    # Note: EXTRAS_PER_PAGE and EXTRAS_MENU_TARGETS are expected to be in scope from the parent script
  local local_num_pages=$(( (local_num_extras + EXTRAS_PER_PAGE - 1) / EXTRAS_PER_PAGE ))

  echo " Generating VMGM Extras Menus ($local_num_pages page(s), $EXTRAS_PER_PAGE per page)..."

  for page in $(seq 0 $((local_num_pages - 1))); do
    local page_start=$(( page * EXTRAS_PER_PAGE ))
    local page_end=$(( page_start + EXTRAS_PER_PAGE ))
    [ "$page_end" -gt "$local_num_extras" ] && page_end=$local_num_extras

    local page_labels=()
    local page_targets=()
    for i in $(seq "$page_start" $((page_end - 1))); do
      page_labels+=("${EXTRAS_MENU_LABELS[$i]}")
      page_targets+=("${EXTRAS_MENU_TARGETS[$i]}")
    done

    # Always add "Main Menu" at the bottom
    page_labels+=("Main Menu")
    page_targets+=("g1 = 0; g2 = 0; jump vmgm menu entry title;")

    # Build pagination pair args for build_menu
    local pag_args=()
    if [ "$local_num_pages" -gt 1 ]; then
      if [ "$page" -gt 0 ]; then
        pag_args+=("<< Prev page" "jump vmgm menu $((page + 1));")
      fi
      if [ "$page" -lt $((local_num_pages - 1)) ]; then
        pag_args+=("Next page >>" "jump vmgm menu $((page + 3));")
      fi
    fi

    local page_mpg="$WORK_DIR/vmgm_extras_p${page}.mpg"
    local page_title="Extras Menu"
    [ "$local_num_pages" -gt 1 ] && page_title="Extras Menu (Page $((page + 1))/$local_num_pages)"

    # Call build_menu with optional --vmgm-pairs-- sentinel
    if [ ${#pag_args[@]} -gt 0 ]; then
      build_menu "$page_mpg" "$page_title" "${page_labels[@]}" "--vmgm-pairs--" "${pag_args[@]}"
    else
      build_menu "$page_mpg" "$page_title" "${page_labels[@]}"
    fi

    # Source the pagination info sidecar
    local paginfo="${page_mpg%.mpg}_paginfo.sh"
    local pag_num_items=0 pag_num_pairs=0
    if [ -f "$paginfo" ]; then
      source "$paginfo"
    fi

    # Build the PGC XML block
    local pgc_xml=""
    local pgc_num=$(( page + 2 ))  # PGC 1 = main menu, extras start at PGC 2
    pgc_xml+="      <pgc>\n"
    pgc_xml+="        <vob file=\"$page_mpg\" pause=\"inf\" />\n"

    # Regular buttons (content + "Main Menu")
    for i in "${!page_targets[@]}"; do
      pgc_xml+="        <button name=\"b$i\"> { ${page_targets[$i]} } </button>\n"
    done

    # Pagination buttons
    for p in $(seq 0 $((pag_num_pairs - 1))); do
      local btn_idx=$(( ${#page_targets[@]} + p ))
      eval "local pcmd=\"\$PAG_CMD_${p}\""
      pgc_xml+="        <button name=\"b${btn_idx}\"> { $pcmd } </button>\n"
    done

    pgc_xml+="      </pgc>\n"
    EXTRAS_VMGM_PGCS+=("$pgc_xml")
  done
}

# ---------------------------------------------------------------------------
# Assemble dvdauthor.xml
# ---------------------------------------------------------------------------
assemble_dvdauthor_xml() {
  local xml_file="$WORK_DIR/dvdauthor.xml"
  
  printf '<?xml version="1.0"?>\n' > "$xml_file"
  printf '<dvdauthor dest="%s" jumppad="yes">\n\n' "$OUT_DIR" >> "$xml_file"

  printf '  <vmgm>\n' >> "$xml_file"
  # Set g2=0 in FPC as well
  printf '    <fpc>\n      { g1 = 0; g2 = 0; subtitle = %d; %s }\n    </fpc>\n' "$MAIN_DEFAULT_SUBP" "$FPC_JUMP" >> "$xml_file"
  printf '    <menus>\n' >> "$xml_file"
  printf '      <video format="%s" resolution="%sx%s" />\n' "$DETECTED_FORMAT" "$WIDTH" "$HEIGHT" >> "$xml_file"

  # pause="inf" on <vob> for all menu PGCs ensures that the still-frame holds 
  # indefinitely and prevents the button highlight from resetting.
  
  # PGC 1: Main Menu
  printf '      <pgc entry="title">\n' >> "$xml_file"
  printf '        <vob file="%s" pause="inf" />\n' "$VMGM_MPG" >> "$xml_file"
  for i in "${!VMGM_TARGETS[@]}"; do
    printf '        <button name="b%i"> { %s } </button>\n' "$i" "${VMGM_TARGETS[$i]}" >> "$xml_file"
  done
  printf '      </pgc>\n' >> "$xml_file"

  # PGC 2..N: Extras Pages
  for pgc_block in "${EXTRAS_VMGM_PGCS[@]}"; do
    printf '%b' "$pgc_block" >> "$xml_file"
  done

  printf '    </menus>\n' >> "$xml_file"
  printf '  </vmgm>\n\n' >> "$xml_file"

  # Append all previously generated titlesets
  printf '%b' "$XML_TITLESETS" >> "$xml_file"
  
  printf '</dvdauthor>\n' >> "$xml_file"

  echo "Generated dvdauthor XML structure: $xml_file"
}

# ---------------------------------------------------------------------------
# AUTHOR DVD
# ---------------------------------------------------------------------------
author_dvd() {
  local xml_file="$WORK_DIR/dvdauthor.xml"
  
  echo "Clearing output directory: $OUT_DIR"
  rm -rf "$OUT_DIR"
  
  echo "Authoring DVD (this may take a moment)..."
  run_logged "$LOG_DIR/dvdauthor.log" dvdauthor -x "$xml_file"

  local out_dir_abs
  out_dir_abs="$(cd "$OUT_DIR" && pwd)"

  # Normalize current folder name: lowercase, replace spaces/special chars with underscores
  local current_folder_name normalized_name iso_path
  current_folder_name="$(basename "$(pwd)")"
  normalized_name="$(echo "$current_folder_name" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/_/g' | sed -E 's/^_+|(_)+$//g')"
  iso_path="/tmp/${normalized_name}.iso"

  echo "============================================================="
  echo " DVD BUILD COMPLETE"
  echo " Structure: $out_dir_abs"
  echo " Preview:   vlc \"dvd://${out_dir_abs}\""
  echo " Generate .iso: genisoimage -dvd-video -o \"$iso_path\" \"$out_dir_abs\""
  echo "============================================================="
}

resolve_menu_background() {
  local out_png="$WORK_DIR/_menu_bg_resolved.png"
  local out_vid="$WORK_DIR/_menu_bg_video.mpg"

  # Case 1: Explicit hex color — generate solid gradient background
  if [[ -n "$MENU_BG" && "$MENU_BG" =~ ^#[0-9a-fA-F]{3,8}$ ]]; then
    local base_color="$MENU_BG"
    echo "  -> Menu background: solid color $base_color"

    # Parse hex to RGB for gradient generation
    local hex="${base_color#\#}"
    # Expand 3-char hex to 6-char
    if [ ${#hex} -eq 3 ]; then
      hex="${hex:0:1}${hex:0:1}${hex:1:1}${hex:1:1}${hex:2:1}${hex:2:1}"
    fi
    local r=$((16#${hex:0:2})) g=$((16#${hex:2:2})) b=$((16#${hex:4:2}))

    # Darken for the top band of the title bar gradient
    local dr=$(( r * 40 / 100 ))
    local dg=$(( g * 40 / 100 ))
    local db=$(( b * 40 / 100 ))
    local menu_w=720 menu_h=576
    [ "$DETECTED_FORMAT" = "ntsc" ] && menu_h=480
    local title_bar_h=80
    [ "$DETECTED_FORMAT" = "ntsc" ] && title_bar_h=65
    local third_h=$((title_bar_h / 3))

    # Build gradient title bar over the solid color
    convert -size "${menu_w}x${menu_h}" xc:"rgb($r,$g,$b)" \
      -fill "rgb($dr,$dg,$db)" -draw "rectangle 0,0 ${menu_w},${third_h}" \
      -fill "rgb($((r*60/100)),$((g*60/100)),$((b*60/100)))" -draw "rectangle 0,${third_h} ${menu_w},$((third_h*2))" \
      -fill "rgb($((r*80/100)),$((g*80/100)),$((b*80/100)))" -draw "rectangle 0,$((third_h*2)) ${menu_w},${title_bar_h}" \
      -fill "rgb($((r*120/100 > 255 ? 255 : r*120/100)),$((g*120/100 > 255 ? 255 : g*120/100)),$((b*120/100 > 255 ? 255 : b*120/100)))" \
        -draw "rectangle 0,${title_bar_h} ${menu_w},$((title_bar_h + 2))" "$out_png"
    MENU_BG_RESOLVED="$out_png"
    return
  fi

  # Case 2: Explicit image file
  if [ -n "$MENU_BG" ] && [ -f "$MENU_BG" ]; then
    local ext="${MENU_BG##*.}"
    ext="$(echo "$ext" | tr '[:upper:]' '[:lower:]')"
    if [[ "$ext" =~ ^(mpg|mpeg|m2v|vob|mkv|mp4|avi|mov|ts)$ ]]; then
      echo "  -> Menu background: video file $MENU_BG"
      # Extract a still from the video at the specified or default time
      local seek_time="$MENU_BG_TIME"
      [ -z "$seek_time" ] && seek_time="0"
      run_logged "$LOG_DIR/_bg_from_video.log" \
        ffmpeg -y -ss "$seek_time" -i "$MENU_BG" -vframes 1 \
                -vf "scale=${WIDTH}:${HEIGHT}:force_original_aspect_ratio=decrease,pad=${WIDTH}:${HEIGHT}:(ow-iw)/2:(oh-ih)/2:black" \
                -pix_fmt yuv420p "$out_png"
      MENU_BG_RESOLVED="$out_png"
    else
      echo "  -> Menu background: image file $MENU_BG"
      run_logged "$LOG_DIR/_bg_from_image.log" \
        convert "$MENU_BG" -resize "${WIDTH}x${HEIGHT}^" -gravity center -extent "${WIDTH}x${HEIGHT}" "$out_png"
      MENU_BG_RESOLVED="$out_png"
    fi
    return
  fi

  # Case 3: Auto-extract still from main movie
  local seek_time="$MENU_BG_TIME"
  if [ -z "$seek_time" ]; then
    # Get duration, pick a random moment between 5% and 40% of the movie
    local duration
    duration="$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$MAIN_MOVIE" 2>/dev/null || echo "3600")"
    # Trim to integer seconds
    duration="$(echo "$duration" | grep -oE '^[0-9]+' || echo "3600")"
    [ -z "$duration" ] && duration=3600
    # Random between 5% and 40%
    local min_sec=$(( duration * 5 / 100 ))
    local max_sec=$(( duration * 40 / 100 ))
    [ "$max_sec" -le "$min_sec" ] && max_sec=$((min_sec + 10))
    local range=$(( max_sec - min_sec ))
    # $RANDOM is 0-32767
    seek_time=$(( min_sec + ( RANDOM * range / 32768 ) ))
    echo "  -> Menu background: auto-still from main movie at ${seek_time}s (random)"
  else
    echo "  -> Menu background: auto-still from main movie at $seek_time"
  fi

  run_logged "$LOG_DIR/_bg_auto_still.log" ffmpeg -y -ss "$seek_time" -i "$MAIN_MOVIE" -vframes 1 -vf "scale=${WIDTH}:${HEIGHT},eq=brightness=-0.15:saturation=0.6" -pix_fmt yuv420p "$out_png"
  MENU_BG_RESOLVED="$out_png"
}

# ---------------------------------------------------------------------------
# HELPER: Build a dynamic menu (Graphics + Video + Spumux logic)
# ---------------------------------------------------------------------------
# Optional 5th+ args: pairs of  "label" "vmgm_command"  used by extras
#   pagination to wire "Next page" / "Prev page" buttons.
#   When extra_vmgm_pairs are provided, this menu lives in the VMGM and
#   those button actions are appended to the label list automatically.
# ---------------------------------------------------------------------------
build_menu() {
  local out_mpg="$1"
  local title_text="$2"
  shift 2
  # Remaining positional args are labels, EXCEPT that if the special sentinel "--vmgm-pairs--" appears, everything after it is   "label" "vmgm_cmd" "label" "vmgm_cmd" ...
  local labels=()
  local vmgm_pairs=()
  local collecting_pairs=false

  for arg in "$@"; do
    if [ "$arg" = "--vmgm-pairs--" ]; then
      collecting_pairs=true
      continue
    fi
    if [ "$collecting_pairs" = true ]; then
      vmgm_pairs+=("$arg")
    else
      labels+=("$arg")
    fi
  done
  local num_pairs=$(( ${#vmgm_pairs[@]} / 2 ))

  local num_items=${#labels[@]}
  local pfx="${out_mpg%.mpg}"

  [ "$num_items" -gt 0 ] || { echo "ERROR: build_menu called with zero labels for $out_mpg" >&2; exit 1; }
  # DVD spec limits to 36 buttons per PGC
  local total_buttons=$(( num_items + num_pairs ))
  [ "$total_buttons" -le 36 ] || { echo "ERROR: Too many buttons ($total_buttons) in menu '$title_text'. Max 36." >&2; exit 1; }

  # Hardcode menu dimensions to standard DVD to avoid scaling mismatches with ffmpeg -target
  local menu_w=720
  local menu_h=576
  if [ "$DETECTED_FORMAT" = "ntsc" ]; then
    menu_h=480
  fi

  # ---- Detect menu type for styling ----
  local is_subtitle_menu=false
  local is_extras_menu=false
  [[ "$title_text" == Subtitles:* ]] && is_subtitle_menu=true
  [[ "$title_text" == "Extras Menu" ]] || [[ "$title_text" == "Extras"*"("*")" ]] && is_extras_menu=true

  # ---- Title configuration ----
  local title_line1="" title_line2=""
  local title_size=42
  local title_bar_h=80

  if [ "$is_subtitle_menu" = true ]; then
    # Two-line title: "Subtitles" / "{Title Name}"
    title_line1="Subtitles"
    title_line2="${title_text#Subtitles: }"
    title_size=30
    title_bar_h=100
  else
    title_line1="$title_text"
    title_line2=""
    # Dynamic title font sizing (shrink for long titles like extras)
    if [ ${#title_text} -gt 30 ]; then title_size=36; fi
    if [ ${#title_text} -gt 45 ]; then title_size=30; fi
    if [ ${#title_text} -gt 60 ]; then title_size=26; fi
    if [ ${#title_text} -gt 80 ]; then title_size=22; fi
  fi
  [ "$title_size" -lt "$MIN_POINT_SIZE" ] && title_size=$MIN_POINT_SIZE
  [ "$DETECTED_FORMAT" = "ntsc" ] && title_bar_h=$((title_bar_h - 15))

  # Calculate title y-positions (vertically centered in title bar)
  local title1_y title2_y
  if [ -n "$title_line2" ]; then
    local line2_size=$((title_size - 4))
    [ "$line2_size" -lt "$MIN_POINT_SIZE" ] && line2_size=$MIN_POINT_SIZE
    local total_title_h=$((title_size + line2_size + 6))
    title1_y=$(( (title_bar_h - total_title_h) / 2 ))
    title2_y=$((title1_y + title_size + 6))
  else
    title1_y=$(( (title_bar_h - title_size) / 2 ))
    title2_y=""
  fi

  local top_margin=$((title_bar_h + 30))

  # ---- Classify buttons into content vs navigation ----
  local nav_indices=()
  local content_count=0
  for i in "${!labels[@]}"; do
    if [[ "${labels[$i]}" == "Main Menu" ]] || [[ "${labels[$i]}" == "Back to Extras" ]]; then
      nav_indices+=("$i")
    else
      content_count=$((content_count + 1))
    fi
  done
  local nav_count=${#nav_indices[@]}

  # ---- Calculate layout ----
  # Reserve space at bottom for navigation buttons
  local nav_zone_y=$((menu_h - 55 * nav_count - 30))
  [ "$nav_count" -eq 0 ] && nav_zone_y=$((menu_h - 40))

  local line_h=$(( (nav_zone_y - top_margin) / content_count ))
  [ "$line_h" -gt 70 ] && line_h=70
  [ "$line_h" -lt $((MIN_POINT_SIZE + 6)) ] && line_h=$((MIN_POINT_SIZE + 6))

  local point_size=$(( line_h / 2 + 10 ))
  [ "$point_size" -gt "$MAX_POINT_SIZE" ] && point_size=$MAX_POINT_SIZE
  [ "$point_size" -lt "$MIN_POINT_SIZE" ] && point_size=$MIN_POINT_SIZE

  # Smaller font for extras menu items (they tend to be long filenames)
  if [ "$is_extras_menu" = true ]; then
    point_size=$(( point_size * 3 / 4 ))
    [ "$point_size" -lt "$MIN_POINT_SIZE" ] && point_size=$MIN_POINT_SIZE
    line_h=$(( point_size * 2 + 8 ))
  fi

  # Navigation button styling
  local nav_point_size=$((point_size - 2))
  [ "$nav_point_size" -lt "$MIN_POINT_SIZE" ] && nav_point_size=$MIN_POINT_SIZE
  local nav_line_h=50
  local nav_left_margin=$((menu_w / 4))  # Indented more for visual distinction

  local left_margin=$(( menu_w / 6 ))
  local right_margin=$(( menu_w / 20 ))

  # ---- Overflow warnings ----
  if [ "$content_count" -gt 0 ] && [ $((top_margin + content_count * line_h)) -gt "$nav_zone_y" ]; then
    echo "WARNING: menu '$title_text' content area may overflow." >&2
  fi
  if [ "$nav_count" -gt 0 ] && [ $((nav_zone_y + nav_count * nav_line_h)) -gt "$menu_h" ]; then
    echo "WARNING: menu '$title_text' navigation area may overflow." >&2
  fi

  echo "  -> Building Menu: $title_text"
  echo "     Target: ${menu_w}x${menu_h} (${DETECTED_FORMAT^^})"
  echo "     Layout: $num_items content + $num_pairs pagination = $total_buttons buttons @ ${point_size}pt (title @ ${title_size}pt)"
  [ "$is_extras_menu" = true ] && echo "     (Extras menu: reduced font)"
  echo "     Buttons:"
  for i in "${!labels[@]}"; do
    local tag=""
    for ni in "${nav_indices[@]}"; do
      [ "$i" = "$ni" ] && tag=" [NAV]" && break
    done
    printf "       %d - %s%s\n" "$i" "${labels[$i]}" "$tag"
  done
  for p in $(seq 0 $((num_pairs - 1))); do
    local pidx=$(( p * 2 ))
    printf "       %d - %s [PAGINATION]\n" "$((num_items + p))" "${vmgm_pairs[$pidx]}"
  done
  echo "+-- Muxing menu stream..."

  # ---- Truncate title lines if needed ----
  local title_max_chars=$(( (menu_w - 2 * left_margin) * 10 / (title_size * 6) ))
  [ "$title_max_chars" -lt 10 ] && title_max_chars=10
  if [ ${#title_line1} -gt "$title_max_chars" ]; then
    title_line1="${title_line1:0:$((title_max_chars - 1))}…"
  fi
  if [ -n "$title_line2" ]; then
    local line2_size=$((title_size - 4))
    [ "$line2_size" -lt "$MIN_POINT_SIZE" ] && line2_size=$MIN_POINT_SIZE
    local line2_max_chars=$(( (menu_w - 2 * left_margin) * 10 / (line2_size * 6) ))
    [ "$line2_max_chars" -lt 10 ] && line2_max_chars=10
    if [ ${#title_line2} -gt "$line2_max_chars" ]; then
      title_line2="${title_line2:0:$((line2_max_chars - 1))}…"
    fi
  fi

  # ---- Build background ----
  if [ -n "$MENU_BG_RESOLVED" ] && [ -f "$MENU_BG_RESOLVED" ]; then
    # Start from the resolved background image
    cp "$MENU_BG_RESOLVED" "${pfx}_bg.png"
    # Darken it slightly so text remains readable, then add title bar overlay
    local third_h=$((title_bar_h / 3))
    run_logged "$LOG_DIR/$(basename "$pfx")_convert_bg0.log" \
      convert "${pfx}_bg.png" \
        -fill "rgba(0,0,0,0.75)" -draw "rectangle 0,0 ${menu_w},${title_bar_h}" \
        -fill "#08081a" -draw "rectangle 0,0 ${menu_w},${third_h}" \
        -fill "#12122a" -draw "rectangle 0,${third_h} ${menu_w},$((third_h * 2))" \
        -fill "#1a1a2e" -draw "rectangle 0,$((third_h * 2)) ${menu_w},${title_bar_h}" \
        -fill "#555577" -draw "rectangle 0,${title_bar_h} ${menu_w},$((title_bar_h + 2))" \
        "${pfx}_bg_tmp.png" && mv "${pfx}_bg_tmp.png" "${pfx}_bg.png"
  else
    # Original gradient-only background
    local third_h=$((title_bar_h / 3))
    run_logged "$LOG_DIR/$(basename "$pfx")_convert_bg0.log" \
      convert -size "${menu_w}x${menu_h}" xc:black \
        -fill "#08081a" -draw "rectangle 0,0 ${menu_w},${third_h}" \
        -fill "#12122a" -draw "rectangle 0,${third_h} ${menu_w},$((third_h * 2))" \
        -fill "#1a1a2e" -draw "rectangle 0,$((third_h * 2)) ${menu_w},${title_bar_h}" \
        -fill "#555577" -draw "rectangle 0,${title_bar_h} ${menu_w},$((title_bar_h + 2))" \
        "${pfx}_bg.png"
  fi

  # Draw title text (CENTER aligned horizontally, positioned in top title bar)
  local title_gravity="center"
  local center_y=$(( menu_h / 2 ))

  run_logged "$LOG_DIR/$(basename "$pfx")_convert_bg0t.log" convert "${pfx}_bg.png" -gravity "$title_gravity" -fill white -font "$FONT" -pointsize "$title_size" -annotate +0+$(( title1_y + title_size / 2 - center_y )) "$title_line1" "${pfx}_bg_tmp.png" && mv "${pfx}_bg_tmp.png" "${pfx}_bg.png"
  # Second title line
  if [ -n "$title_line2" ]; then
    local line2_size=$((title_size - 4))
    [ "$line2_size" -lt "$MIN_POINT_SIZE" ] && line2_size=$MIN_POINT_SIZE
    run_logged "$LOG_DIR/$(basename "$pfx")_convert_bg0b.log" convert "${pfx}_bg.png" -gravity "$title_gravity" -fill "#9999bb" -font "$FONT" -pointsize "$line2_size" -annotate +0+$(( title2_y + line2_size / 2 - center_y )) "$title_line2" "${pfx}_bg_tmp.png" && mv "${pfx}_bg_tmp.png" "${pfx}_bg.png"
  fi
  # Separator line before navigation buttons
  if [ "$nav_count" -gt 0 ]; then
    local nav_sep_y=$((nav_zone_y - 15))
    run_logged "$LOG_DIR/$(basename "$pfx")_convert_bg0c.log" convert "${pfx}_bg.png" -fill "#333355" -draw "rectangle $((left_margin - 10)),${nav_sep_y} $((menu_w - left_margin + 10)),$((nav_sep_y + 1))" "${pfx}_bg_tmp.png" && mv "${pfx}_bg_tmp.png" "${pfx}_bg.png"
  fi

  # ---- Build highlight overlay (transparent, only button text) ----
  run_logged "$LOG_DIR/$(basename "$pfx")_convert_hl0.log" convert -size "${menu_w}x${menu_h}" xc:none "${pfx}_hl.png"
  # ---- Draw all content + nav buttons ----
  local y0_arr=() y1_arr=() x0_arr=() x1_arr=()
  local current_y=$top_margin
  local nav_drawn=0
  local center_y=$(( menu_h / 2 ))
  local center_x=$(( menu_w / 2 ))

  for i in "${!labels[@]}"; do
    local text="${labels[$i]}"
    local is_nav=false
    for ni in "${nav_indices[@]}"; do
      [ "$i" = "$ni" ] && is_nav=true && break
    done

    local this_left this_y this_ps this_color
    if [ "$is_nav" = true ]; then
      # Navigation button: gold color, indented, separate zone
      this_left=$nav_left_margin
      this_y=$((nav_zone_y + nav_drawn * nav_line_h))
      this_ps=$nav_point_size
      this_color="#ffcc44"
      nav_drawn=$((nav_drawn + 1))
    else
      # Content button: white, normal position
      this_left=$left_margin
      this_y=$current_y
      this_ps=$point_size
      this_color="white"
      current_y=$((current_y + line_h))
    fi

    # Truncate text if too long
    local max_chars=$(( (menu_w - this_left - right_margin) * 10 / (this_ps * 6) ))
    [ "$max_chars" -lt 4 ] && max_chars=4
    if [ "${#text}" -gt "$max_chars" ]; then
      text="${text:0:$((max_chars - 1))}…"
    fi

    # Store button bounds for spumux
    y0_arr[$i]=$((this_y - 5))
    y1_arr[$i]=$((this_y + this_ps + 5))
    x0_arr[$i]=$((this_left - 20))
    x1_arr[$i]=$((menu_w - left_margin))

    # Calculate center of button area, then offsets from image center
    local btn_center_x=$(( (this_left + menu_w - left_margin) / 2 ))
    local btn_center_y=$(( this_y + this_ps / 2 ))
    local x_offset=$(( btn_center_x - center_x ))
    local y_offset=$(( btn_center_y - center_y ))

    # Draw on background (CENTER aligned)
    run_logged "$LOG_DIR/$(basename "$pfx")_convert_bg${i}.log" \
      convert "${pfx}_bg.png" \
        -gravity center -fill "$this_color" -font "$FONT" -pointsize "$this_ps" \
        -annotate +${x_offset}+${y_offset} "$text" \
        "${pfx}_bg_tmp.png" && mv "${pfx}_bg_tmp.png" "${pfx}_bg.png"

    # Draw on highlight overlay (red fill + blue stroke for spumux 3-color mask)
    run_logged "$LOG_DIR/$(basename "$pfx")_convert_hl${i}.log" \
      convert "${pfx}_hl.png" +antialias \
        -gravity center -fill red -stroke blue -strokewidth 1 -font "$FONT" -pointsize "$this_ps" \
        -annotate +${x_offset}+${y_offset} "$text" \
        -colors 3 \
        "${pfx}_hl_tmp.png" && mv "${pfx}_hl_tmp.png" "${pfx}_hl.png"
  done

  # ---- Draw pagination buttons (centered at bottom) ----
  if [ "$num_pairs" -gt 0 ]; then
    # Place pagination buttons in a row at the very bottom
    local pag_y=$((menu_h - 40))
    local pag_total_w=$(( num_pairs * 160 ))
    local pag_start_x=$(( (menu_w - pag_total_w) / 2 ))
    local pag_ps=$(( point_size - 2 ))
    [ "$pag_ps" -lt "$MIN_POINT_SIZE" ] && pag_ps=$MIN_POINT_SIZE

    for p in $(seq 0 $((num_pairs - 1))); do
      local pidx=$(( p * 2 ))
      local ptxt="${vmgm_pairs[$pidx]}"
      local pcmd="${vmgm_pairs[$((pidx + 1))]}"
      local btn_global_idx=$((num_items + p))

      local px=$(( pag_start_x + p * 160 ))
      # Center text within its 160px slot
      local ptx=$(( px + 80 ))

      y0_arr[$btn_global_idx]=$((pag_y - 5))
      y1_arr[$btn_global_idx]=$((pag_y + pag_ps + 5))
      x0_arr[$btn_global_idx]=$((px - 10))
      x1_arr[$btn_global_idx]=$((px + 150))

      # Calculate offsets from image center for pagination button
      local pag_btn_center_y=$(( pag_y + pag_ps / 2 ))
      local pag_x_offset=$(( ptx - center_x ))
      local pag_y_offset=$(( pag_btn_center_y - center_y ))

      # Draw on background (cyan-ish for pagination)
      run_logged "$LOG_DIR/$(basename "$pfx")_convert_bg_pag${p}.log" \
        convert "${pfx}_bg.png" \
          -gravity center -fill "#66ccff" -font "$FONT" -pointsize "$pag_ps" \
          -annotate +${pag_x_offset}+${pag_y_offset} "$ptxt" \
          "${pfx}_bg_tmp.png" && mv "${pfx}_bg_tmp.png" "${pfx}_bg.png"

      # Draw on highlight overlay
      run_logged "$LOG_DIR/$(basename "$pfx")_convert_hl_pag${p}.log" \
        convert "${pfx}_hl.png" +antialias \
          -gravity center -fill red -stroke blue -strokewidth 1 -font "$FONT" -pointsize "$pag_ps" \
          -annotate +${pag_x_offset}+${pag_y_offset} "$ptxt" \
          -colors 3 \
          "${pfx}_hl_tmp.png" && mv "${pfx}_hl_tmp.png" "${pfx}_hl.png"
    done
  fi
  # ---- Generate blank menu video ----
  run_logged "$LOG_DIR/$(basename "$pfx")_ffmpeg_blank.log" \
    ffmpeg -y -f lavfi -i "color=c=black:s=${menu_w}x${menu_h}:d=${MENU_SECONDS}:r=${FPS}" \
            -f lavfi -i "anullsrc=r=48000:cl=stereo" \
            -shortest -pix_fmt yuv420p -target "$TARGET" \
            -b:v 6000k -maxrate 9000k -minrate 6000k -bufsize 1835k \
            "${pfx}_blank.mpg"

  # ---- Overlay background onto blank video ----
  run_logged "$LOG_DIR/$(basename "$pfx")_ffmpeg_merge.log" \
    ffmpeg -y -i "${pfx}_blank.mpg" -i "${pfx}_bg.png" \
            -filter_complex "[0:v][1:v]overlay=0:0[v]" -map "[v]" -map 0:a \
            -c:a copy -pix_fmt yuv420p -target "$TARGET" -f dvd \
            -b:v 6000k -maxrate 9000k -minrate 6000k -bufsize 1835k \
            "${pfx}_merged.mpg"

  # ---- Generate spumux XML ----
  {
    echo '<subpictures><stream>'
    # Add end="9999" so buttons don't disappear when the menu video loops
    echo "  <spu start=\"0\" end=\"9999\" force=\"yes\" highlight=\"${pfx}_hl.png\" select=\"${pfx}_hl.png\">"
    for i in "${!labels[@]}"; do
      local up=$(( (i - 1 + num_items) % num_items ))
      local down=$(( (i + 1) % num_items ))
      echo "    <button name=\"b$i\" x0=\"${x0_arr[$i]}\" y0=\"${y0_arr[$i]}\" x1=\"${x1_arr[$i]}\" y1=\"${y1_arr[$i]}\" up=\"b$up\" down=\"b$down\" />"
    done
    for p in $(seq 0 $((num_pairs - 1))); do
      local btn_global_idx=$((num_items + p))
      echo "    <button name=\"b${btn_global_idx}\" x0=\"${x0_arr[$btn_global_idx]}\" y0=\"${y0_arr[$btn_global_idx]}\" x1=\"${x1_arr[$btn_global_idx]}\" y1=\"${y1_arr[$btn_global_idx]}\" up=\"b$(( (btn_global_idx - 1 + total_buttons) % total_buttons ))\" down=\"b$(( (btn_global_idx + 1) % total_buttons ))\" />"
    done
    echo '  </spu>'
    echo '</stream></subpictures>'
  } > "${pfx}_btn.xml"

  # Mux highlights with spumux
  run_logged "$LOG_DIR/$(basename "$pfx")_spumux.log" \
    bash -c "spumux -m dvd '${pfx}_btn.xml' < '${pfx}_merged.mpg' > '$out_mpg'"

  [ -s "$out_mpg" ] || { echo "ERROR: spumux produced an empty/missing menu video: $out_mpg" >&2; exit 1; }

  # Export pagination info for caller to use in dvdauthor XML. We use a sidecar file since bash functions can't return arrays cleanly
  if [ "$num_pairs" -gt 0 ]; then
    {
      echo "NUM_ITEMS=$num_items"
      echo "NUM_PAIRS=$num_pairs"
      for p in $(seq 0 $((num_pairs - 1))); do
        local pidx=$(( p * 2 ))
        echo "PAG_LABEL_${p}=${vmgm_pairs[$pidx]}"
        echo "PAG_CMD_${p}=${vmgm_pairs[$((pidx + 1))]}"
      done
    } > "${pfx}_paginfo.sh"
  else
    : > "${pfx}_paginfo.sh"
  fi
}