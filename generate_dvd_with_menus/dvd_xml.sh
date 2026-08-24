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