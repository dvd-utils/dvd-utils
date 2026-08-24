#!/usr/bin/env bash

# Subtitle discovery and muxing logic

# ---------------------------------------------------------------------------
# HELPER: Discover subtitles for a given Title
# This performs only analysis: just filesystem globs & string parsing.
# No bdsup2sub/spumux/ffmpeg calls happen here yet, so this is safe to run during the pre-flight analysis pass before the user has confirmed anything.
# ---------------------------------------------------------------------------
discover_subs() {
  local in_mpg="$1"
  local ts_idx="$2"
  local tag="${3:-[TS$ts_idx]}"
  local pretty_name="$(prettify_filename "$in_mpg")"

  CURRENT_SUB_LABELS=()
  CURRENT_HAS_SUBS=0
  CURRENT_MUXED_MPG="$in_mpg"
  CURRENT_DEFAULT_SUBP=62
  CURRENT_INPUT_FILES=()
  CURRENT_DATA_FILES=()

  local base_path="${in_mpg%.mpg}"
  local base_clean="${base_path%_pal}"
  base_clean="${base_clean%_PAL}"

  # Create spaceless variants to handle subtitles that omit spaces from the movie name
  local base_path_no_space="${base_path// /}"
  local base_clean_no_space="${base_clean// /}"

  shopt -s nullglob
  # TODO why not just gobble up all sub/idx/srt files? `local all_sub_files=( *.idx *.sub *.srt )`
  #      Normalize the video's base name once, then loop through all_sub_files, normalize each one, and check if it starts with the normalized video name:
  # normalize_str() {
  #   local s="$1"
  #   s="${s%_pal}"          # remove format suffix
  #   s="${s%_PAL}"
  #   s="${s%.sub.idx}"      # remove extensions
  #   s="${s%.idx}"
  #   s="${s%.sup}"
  #   s="${s%.srt}"
  #   s="${s,,}"             # lowercase
  #   s="${s//[^a-z0-9]/}"   # strip all non-alphanumerics (spaces, underscores, dashes, dots)
  #   echo "$s"
  # }
  # local norm_video="$(normalize_str "$(basename "$in_mpg" .mpg)")"
  # local raw_sub_files=()
  # for f in "${all_sub_files[@]}"; do
  #   local norm_sub="$(normalize_str "$(basename "$f")")"
  #   if [[ "$norm_sub" == "$norm_video"* ]]; then
  #     raw_sub_files+=("$f")
  #   fi
  # done
  # This completely eliminates the need for separate spaceless globs, handles _pal vs _PAL automatically, and makes the suffix extraction much easier because you can just compare the normalized strings to find exactly where the video name ends and the language suffix begins. Just an idea.
  local raw_sub_files=(
    "${base_path}_"*.srt
    "${base_path}_"*.idx
    "${base_path}_"*.sub.idx
    "${base_path}_"*.sup
    "${base_path}."*.srt
  )
  # Conditionally add the exact .srt match to avoid bypassing nullglob
  [ -f "${base_path}.srt" ] && raw_sub_files+=( "${base_path}.srt" )
  if [ "$base_path" != "$base_clean" ]; then
    raw_sub_files+=(
      "${base_clean}_"*.srt
      "${base_clean}_"*.idx
      "${base_clean}_"*.sub.idx
      "${base_clean}_"*.sup
      "${base_clean}."*.srt
    )
    [ -f "${base_clean}.srt" ] && raw_sub_files+=( "${base_clean}.srt" )
  fi
  # Add spaceless variants if they differ from the originals
  if [ "$base_path" != "$base_path_no_space" ]; then
    raw_sub_files+=(
      "${base_path_no_space}_"*.srt
      "${base_path_no_space}_"*.idx
      "${base_path_no_space}_"*.sub.idx
      "${base_path_no_space}_"*.sup
      "${base_path_no_space}."*.srt
    )
    [ -f "${base_path_no_space}.srt" ] && raw_sub_files+=( "${base_path_no_space}.srt" )
  fi
  if [ "$base_clean" != "$base_clean_no_space" ]; then
    raw_sub_files+=(
      "${base_clean_no_space}_"*.srt
      "${base_clean_no_space}_"*.idx
      "${base_clean_no_space}_"*.sub.idx
      "${base_clean_no_space}_"*.sup
      "${base_clean_no_space}."*.srt
    )
    [ -f "${base_clean_no_space}.srt" ] && raw_sub_files+=( "${base_clean_no_space}.srt" )
  fi
  shopt -u nullglob
  if [ ${#raw_sub_files[@]} -eq 0 ]; then
    echo ""
    echo "${tag} ${pretty_name}"
    echo "  (No subtitles found)"
    return 0
  fi
  # Deduplicate discovered files
  local input_files=()
  local seen_files=" "
  for f in "${raw_sub_files[@]}"; do
    if [[ "$seen_files" != *" $f "* ]]; then
      seen_files+="$f "
      input_files+=("$f")
    fi
  done
  # DVD-Video allows 32 subpicture streams.
  if [ ${#input_files[@]} -gt 32 ]; then
    echo "ERROR: $(basename "$in_mpg") has ${#input_files[@]} subtitle files; max 32 streams allowed." >&2
    exit 1
  fi

  # Verify companion .sub files exist (NOTE: subtitle files may be suffixed by standard .sub/.idx and .sub.sub/.sub.idx.)
  local input_files_clean=()
  local data_files=()
  for f in "${input_files[@]}"; do
    if [[ "$f" == *.sup ]]; then
      # .sup is self-contained
      input_files_clean+=("$f")
      data_files+=("$f")
      continue
    fi
    if [[ "$f" == *.srt ]]; then
      # .srt is a self-contained text subtitle. No companion file needed.
      [ -s "$f" ] || { echo "ERROR: subtitle file is empty: $f" >&2; exit 1; }
      input_files_clean+=("$f")
      data_files+=("$f")
      continue
    fi
    local sub=""
    # Clean VobSub companion logic to correctly handle all extension permutations
    if [[ "$f" == *.sub.idx ]]; then
      if [ -f "${f%.sub.idx}.sub" ]; then
        sub="${f%.sub.idx}.sub"
      # Standard double extension: file.sub.idx -> file.sub.sub
      elif [ -f "${f%.sub.idx}.sub.sub" ]; then
        sub="${f%.sub.idx}.sub.sub"
      fi
    elif [[ "$f" == *.idx ]]; then
      if [ -f "${f%.idx}.sub" ]; then sub="${f%.idx}.sub"
      elif [ -f "${f%.idx}.sub.sub" ]; then
        sub="${f%.idx}.sub.sub"
      fi
    fi

    if [ -z "$sub" ] || [ ! -f "$sub" ]; then
      echo "ERROR: missing companion .sub file for index '$f'" >&2
      echo "       Expected either '${f%.idx}.sub' or '${f%.sub.idx}.sub.sub'" >&2
      exit 1
    fi

    [ -s "$f" ] || { echo "ERROR: subtitle index file is empty: $f" >&2; exit 1; }
    [ -s "$sub" ] || { echo "ERROR: subtitle data file is empty: $sub" >&2; exit 1; }

    input_files_clean+=("$f")
    data_files+=("$sub")
  done

  # Reassign checked input files
  input_files=("${input_files_clean[@]}")

  CURRENT_HAS_SUBS=1
  CURRENT_MUXED_MPG="$WORK_DIR/ts${ts_idx}_muxed.mpg"

  local default_index=-1
  local track0_index=-1
  local seen_labels=""

  local video_stem="$(basename "$base_path")"
  local video_stem_clean="$(basename "$base_clean")"
  local video_stem_no_space="${video_stem// /}"
  local video_stem_clean_no_space="${video_stem_clean// /}"

  for i in "${!input_files[@]}"; do
    local f="${input_files[$i]}"
    local fname="$(basename "$f")"
    local raw_lang=""
    local is_track0=0
    if [[ "$fname" == *.srt ]]; then
      # .srt uses a DOT-separated language suffix: "Movie Name.lang.srt" (as opposed to the underscore-separated suffix used by .idx/.sub.idx/.sup)
      local srt_stem="${fname%.srt}"
      local srt_stem_no_space="${srt_stem// /}"
      if [[ "$srt_stem" == "${video_stem}."* ]]; then
        raw_lang="${srt_stem#"${video_stem}."}"
      elif [[ "$srt_stem" == "${video_stem_clean}."* ]]; then
        raw_lang="${srt_stem#"${video_stem_clean}."}"
      elif [[ "$srt_stem_no_space" == "${video_stem_no_space}."* ]]; then
        raw_lang="${srt_stem_no_space#"${video_stem_no_space}."}"
      elif [[ "$srt_stem_no_space" == "${video_stem_clean_no_space}."* ]]; then
        raw_lang="${srt_stem_no_space#"${video_stem_clean_no_space}."}"
      else
        # Fall back to whatever trails the final dot, e.g. "Movie Name.en.srt" -> "en"
        raw_lang="${srt_stem##*.}"
      fi
    else
      # Strip extension (.sub.idx, .idx, or .sup) cleanly to isolate track suffix
      local stem=""

      if [[ "$fname" == *.sub.idx ]]; then
        stem="${fname%.sub.idx}"
      elif [[ "$fname" == *.sup ]]; then
        stem="${fname%.sup}"
      else
        stem="${fname%.idx}"
      fi

      # Extract suffix after video prefix
      local suffix="$stem"
      local stem_no_space="${stem// /}"

      if [[ "$suffix" == "${video_stem}_"* ]]; then
        suffix="${suffix#"${video_stem}_"}"
      elif [[ "$suffix" == "${video_stem_clean}_"* ]]; then
        suffix="${suffix#"${video_stem_clean}_"}"
      elif [[ "$stem_no_space" == "${video_stem_no_space}_"* ]]; then
        suffix="${stem_no_space#"${video_stem_no_space}_"}"
      elif [[ "$stem_no_space" == "${video_stem_clean_no_space}_"* ]]; then
        suffix="${stem_no_space#"${video_stem_clean_no_space}_"}"
      else
        suffix="${suffix#"${video_stem}"}"
        suffix="${suffix#"${video_stem_clean}"}"
        suffix="${suffix#"${video_stem_no_space}"}"
        suffix="${suffix#"${video_stem_clean_no_space}"}"
        suffix="${suffix#_}"
      fi

      # Strip trailing _exp
      suffix="${suffix%_exp}"
      suffix="${suffix%.exp}"
      suffix="${suffix%-exp}"

      # Check for track0 / track{n}
      if [[ "$suffix" =~ ^track0(_|-|$) ]]; then
        is_track0=1
        suffix="${suffix#track0}"
        suffix="${suffix#_}"
        suffix="${suffix#-}"
      elif [[ "$suffix" =~ ^track[0-9]+(_|-|$) ]]; then
        local trk="${BASH_REMATCH[0]}"
        suffix="${suffix#"$trk"}"
        suffix="${suffix#_}"
        suffix="${suffix#-}"
      fi
      raw_lang="$suffix"
    fi
    [ -n "$raw_lang" ] || raw_lang="Language $((i+1))"
    normalize_language "$raw_lang"
    local label_name="$NORM_LANG_LABEL"
    local lang_code="$NORM_LANG_CODE"

    if [[ " $seen_labels " == *" $label_name "* ]]; then
      label_name="${label_name} ($((i+1)))"
    fi
    seen_labels+=" $label_name "
    CURRENT_SUB_LABELS+=("$label_name")

    # Priority 1: Check configured DEFAULT_HINT (e.g. Dutch/nl)
    local matches_hint=0
    if [ -n "${DEFAULT_HINT:-}" ]; then
      local hint_lower="${DEFAULT_HINT,,}"
      if [[ "${raw_lang,,}" == *"$hint_lower"* ]] || \
         [[ "${lang_code,,}" == *"$hint_lower"* ]] || \
         [[ "${label_name,,}" == *"$hint_lower"* ]]; then
        matches_hint=1
      fi
    fi

    if [ "$matches_hint" -eq 1 ] && [ "$default_index" -eq -1 ]; then
      default_index=$i
    fi

    if [ "$is_track0" -eq 1 ] && [ "$track0_index" -eq -1 ]; then
      track0_index=$i
    fi
  done

  if [ "$default_index" -eq -1 ]; then
    if [ "$track0_index" -ne -1 ]; then default_index=$track0_index
    else
      default_index=0
    fi
  fi

  CURRENT_DEFAULT_SUBP=$((64 + default_index))
  CURRENT_INPUT_FILES=("${input_files[@]}")
  CURRENT_DATA_FILES=("${data_files[@]}")
  echo ""
  echo "${tag} ${pretty_name}"

  if [ "$CURRENT_HAS_SUBS" -eq 1 ]; then
    echo "  Found ${#CURRENT_SUB_LABELS[@]} subtitle track(s):"
    for i in "${!CURRENT_SUB_LABELS[@]}"; do
      printf "    %d. %s\n" "$((i+1))" "${CURRENT_SUB_LABELS[$i]}"
    done
    printf "  Default: %s\n" "${CURRENT_SUB_LABELS[$default_index]}"
  else
    echo "  No subtitles found."
  fi
}

# ---------------------------------------------------------------------------
# HELPER: Mux Subtitles for a given Title
# This runs bdsup2sub, spumux.
# Must be called after [discover_subs] for the same (in_mpg, ts_idx), since
# it relies on CURRENT_HAS_SUBS / CURRENT_INPUT_FILES / CURRENT_DATA_FILES.
# ---------------------------------------------------------------------------
mux_subs() {
  local in_mpg="$1"
  local ts_idx="$2"

  if [ "$CURRENT_HAS_SUBS" -ne 1 ]; then
    CURRENT_MUXED_MPG="$in_mpg"
    return 0
  fi

  local input_files=("${CURRENT_INPUT_FILES[@]}")
  local data_files=("${CURRENT_DATA_FILES[@]}")

  local current_vid="$in_mpg"
  for i in "${!input_files[@]}"; do
    local f="${input_files[$i]}"
    local data_file="${data_files[$i]}"
    local pfx="$WORK_DIR/ts${ts_idx}_sub_${i}"
    local stage_base="$WORK_DIR/ts${ts_idx}_sub_${i}_input"
    local label="${CURRENT_SUB_LABELS[$i]}"
    echo "  -> Muxing Subtitle $((i+1))/${#input_files[@]}: $label"
    # .srt is plain text and has no bitmap frames to render via bdsup2sub; spumux can burn text subtitles directly via its <textsub> element, so we skip straight to building a textsub XML and hand it to spumux.
    if [[ "$f" == *.srt ]]; then
      local stage_srt="${stage_base}.srt"
      cp "$f" "$stage_srt"
      cat > "${pfx}.xml" <<EOF
<subpictures>
  <stream>
    <textsub filename="${stage_srt}" characterset="UTF-8" movie-fps="${FPS}" movie-width="${WIDTH}" movie-height="${HEIGHT}" />
  </stream>
</subpictures>
EOF
      echo "     Muxing text subtitle into video..."
      local next_vid="$WORK_DIR/ts${ts_idx}_mux_${i}.mpg"
      run_logged "$LOG_DIR/ts${ts_idx}_spumux_${i}.log" \
          bash -c 'spumux -s "$1" "$2" < "$3" > "$4"' \
          _ "$i" "${pfx}.xml" "$current_vid" "$next_vid"
      [ -s "$next_vid" ] || { echo "ERROR: spumux produced an empty output muxing subtitle track $i into $(basename "$in_mpg")." >&2; exit 1; }
      current_vid="$next_vid"
      continue
    fi
    local bdsup_in=""
    # Stage files into clean paths for bdsup2sub. Preserve exact companion basename matching so the internal .idx reference resolves properly.
    if [[ "$f" == *.sup ]]; then
      cp "$f" "${stage_base}.sup"
      bdsup_in="${stage_base}.sup"
    else
      cp "$f" "${stage_base}.idx"
      if [[ "$data_file" == *.sub.sub ]]; then
        cp "$data_file" "${stage_base}.sub.sub"
        # Create a symlink/copy so bdsup2sub can find it regardless of whether it expects .sub or .sub.sub
        cp "$data_file" "${stage_base}.sub"
      else
        cp "$data_file" "${stage_base}.sub"
      fi
      bdsup_in="${stage_base}.idx"
    fi

    # Conditionally execute depending on whether we resolved the Qt C++ fork or the Java version
    # Utilizing array expansion for BDSUP2SUB_CMD to safely preserve path/arguments
    echo "     Converting to images..."
    if [[ "${BDSUP2SUB_CMD[*]}" == *"bdsup2sub++"* ]]; then
      run_logged "$LOG_DIR/ts${ts_idx}_bdsup2sub_${i}.log" env QT_QPA_PLATFORM=offscreen "${BDSUP2SUB_CMD[@]}" --no-verbose -o "${pfx}_bdn.xml" "$bdsup_in"
    else
      run_logged "$LOG_DIR/ts${ts_idx}_bdsup2sub_${i}.log" "${BDSUP2SUB_CMD[@]}" --no-verbose -o "${pfx}_bdn.xml" "$bdsup_in"
    fi
    # Verify that bdsup2sub successfully generated the images
    shopt -s nullglob
    local pngs=( "${pfx}_bdn"*.png )
    shopt -u nullglob
    if [ ${#pngs[@]} -eq 0 ]; then
      echo "ERROR: bdsup2sub produced no .png frames for $f (subtitle file may be malformed)." >&2
      exit 1
    fi
    # Determine source resolution to scale subtitles to fit DVD frame
    local src_w=0 src_h=0
    local log_file="$LOG_DIR/ts${ts_idx}_bdsup2sub_${i}.log"
    local res_str=$(grep -i -m 1 -E '(resolution|size):' "$log_file" | grep -o '[0-9]\+x[0-9]\+' || true)
    if [ -n "$res_str" ]; then
      src_w="${res_str%x*}"
      src_h="${res_str#*x}"
    fi

    local scale_w=1.0 scale_h=1.0
    if [ "$src_w" -gt 0 ] && [ "$src_h" -gt 0 ]; then
      scale_w=$(awk "BEGIN {print $WIDTH / $src_w}")
      scale_h=$(awk "BEGIN {print $HEIGHT / $src_h}")
    fi

    local w_pct=$(awk "BEGIN {printf \"%.6f\", $scale_w * 100}")
    local h_pct=$(awk "BEGIN {printf \"%.6f\", $scale_h * 100}")

    # Scale PNGs to fit DVD resolution and quantize PNGs to 4 colors to satisfy spumux's DVD subtitle requirements # TODO is this quantization really necessary?
    for png in "${pngs[@]}"; do
      convert "$png" -alpha on -resize "${w_pct}x${h_pct}!" -colors 4 +dither PNG8:"${png}.tmp" && mv "${png}.tmp" "$png"
    done

    # When bdsup2sub++ exports XML subtitles, its root tag is <BDN>:
    #   <BDN Version="0.28" defaultSubtitleStreamName="...">
    # However, spumux is designed specifically for DVD authoring and expects a <subpictures> root tag:
    #   <subpictures>
    #     <stream>
    #       <spu start="..." end="..." image="...">
    # Convert BDN XML -> DVDAuthor spumux XML format, applying scale factors to X/Y
    #
    # Pass $WORK_DIR to awk and use case-insensitive regex for bdn.xml tags
    # Extract X and Y coordinates from <Graphic> tag so spumux places the cropped PNG correctly
    # Convert HH:MM:SS:FF to HH:MM:SS.mmm to bypass spumux's frame parsing bug
    awk -v workdir="$WORK_DIR" -v fps="$FPS" -v scale_w="$scale_w" -v scale_h="$scale_h" '
      function tc_to_ms(tc,   t, hh, mm, ss, ff, ms) {
        split(tc, t, ":");
        hh = t[1]; mm = t[2]; ss = t[3]; ff = t[4];
        if (fps == 25) ms = ff * 40;
        else ms = ff * 33;
        return sprintf("%02d:%02d:%02d.%03d", hh, mm, ss, ms);
      }
      BEGIN { print "<subpictures>\n  <stream>" }
      /<[Ee]vent / {
        for (i = 1; i <= NF; i++) {
          if ($i ~ /^[Ii]nTC=/)  { split($i, a, "\""); start = a[2] }
          if ($i ~ /^[Oo]utTC=/) { split($i, b, "\""); end = b[2] }
        }
      }
      /<[Gg]raphic[ >]/ {
        x=0; y=0
        if (match($0, /[Xx]="[0-9]+"/)) { x = substr($0, RSTART+3, RLENGTH-4) }
        if (match($0, /[Yy]="[0-9]+"/)) { y = substr($0, RSTART+3, RLENGTH-4) }

        sub(/.*<[Gg]raphic[^>]*>/, "", $0); sub(/<\/[Gg]raphic>.*/, "", $0)
        gsub(/^[ \t\r\n]+|[ \t\r\n]+$/, "", $0)

        if (start != "" && end != "" && $0 != "") {
          x = int(x * scale_w)
          y = int(y * scale_h)
          print "    <spu start=\"" tc_to_ms(start) "\" end=\"" tc_to_ms(end) "\" image=\"" workdir "/" $0 "\" xoffset=\"" x "\" yoffset=\"" y "\" />"
        }
      }
      END { print "  </stream>\n</subpictures>" }
    ' "${pfx}_bdn.xml" > "${pfx}.xml"
    echo "     Muxing into video..."
    local next_vid="$WORK_DIR/ts${ts_idx}_mux_${i}.mpg"
    # Mux directly using the generated DVDAuthor-formatted XML
    run_logged "$LOG_DIR/ts${ts_idx}_spumux_${i}.log" \
      bash -c 'spumux -s "$1" "$2" < "$3" > "$4"' \
      _ "$i" "${pfx}.xml" "$current_vid" "$next_vid"

    [ -s "$next_vid" ] || { echo "ERROR: spumux produced an empty output muxing subtitle track $i into $(basename "$in_mpg")." >&2; exit 1; }
    current_vid="$next_vid"
  done
  cp "$current_vid" "$CURRENT_MUXED_MPG"
}
