# HTML Preview Generator
# ---------------------------------------------------------------------------
# Subtitle preview strategy:
#   Bitmap subs (.idx/.sub.idx/.sup) are converted with the SAME bdsup2sub
#   invocation that mux_subs() uses (--no-verbose -o out.xml input), yielding
#   BDN XML + transparent PNGs. Timing + X/Y/Width are parsed from the BDN XML
#   and rendered in the browser as a positioned transparent overlay.
#   Text subs (.srt) are parsed directly and rendered as styled text.
#
# Navigation model (mirrors the authored DVD):
#   Disc start (FPC) -> VMGM Main Menu
#   "Play movie"     -> titleset subtitle menu (if subs) -> title playback
#   Title end        -> post { g1=0; call vmgm menu } -> Main Menu
#   A simulated remote offers Title Menu / Subtitle Menu (root,subtitle entry)
#   / End Title keys.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Config for background preview clips (override via env before sourcing)
# ---------------------------------------------------------------------------
PREVIEW_CACHE_DIR="${PREVIEW_CACHE_DIR:-preview_cache}"
PREVIEW_CLIP_SECONDS="${PREVIEW_CLIP_SECONDS:-15}"     # length of clip
PREVIEW_CLIP_START="${PREVIEW_CLIP_START:-120}"        # seek-in point (skip logos/black)
PREVIEW_CLIP_WIDTH="${PREVIEW_CLIP_WIDTH:-640}"        # preview width

# ---------------------------------------------------------------------------
# HELPER: Make a path HTML-friendly (relative to CWD when possible)
# ---------------------------------------------------------------------------
rel_path() {
  local p="$1"
  case "$p" in
    /*) realpath --relative-to="$PWD" "$p" 2>/dev/null || echo "$p" ;;
    *)  echo "$p" ;;
  esac
}

# ---------------------------------------------------------------------------
# HELPER: Escape text for safe embedding in HTML
# ---------------------------------------------------------------------------
html_escape() {
  local s="$1"
  s="${s//&/&amp;}"; s="${s//</&lt;}"; s="${s//>/&gt;}"; s="${s//\"/&quot;}"
  printf '%s' "$s"
}
# ---------------------------------------------------------------------------
# HELPER: Echo $1 if it is a clean non-negative number, otherwise $2 (or "").
# Every value coming out of ffprobe/grep/env must pass through here before
# it is used in [ ... -eq ] or spliced into an awk program — those sources
# can emit "N/A", empty output, or junk.
# ---------------------------------------------------------------------------
num_or() {
  local v="${1:-}" fb="${2:-}"
  v="${v//[[:space:]]/}"
  if [[ "$v" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    printf '%s' "$v"
  else
    printf '%s' "$fb"
  fi
}
# ---------------------------------------------------------------------------
# HELPER: Convert time formats to seconds (float).
# Handles: "HH:MM:SS.mmm", "HH:MM:SS,mmm", "HH:MM:SS:mmm", "MM:SS.mmm", ints
# ---------------------------------------------------------------------------
convert_time_to_seconds() {
  local tc="$1"
  tc="${tc//[$'\t\r\n ']/}"

  if [[ "$tc" =~ ^([0-9]{1,2}):([0-9]{2}):([0-9]{2})[\.:,]([0-9]{1,3})$ ]]; then
    local h="${BASH_REMATCH[1]}" m="${BASH_REMATCH[2]}" s="${BASH_REMATCH[3]}" ms="${BASH_REMATCH[4]}"
    while [ ${#ms} -lt 3 ]; do ms="${ms}0"; done
    LC_ALL=C awk "BEGIN { printf \"%.3f\", $h * 3600 + $m * 60 + $s + $ms / 1000 }"
    return
  fi
  if [[ "$tc" =~ ^([0-9]{1,2}):([0-9]{2}):([0-9]{2})$ ]]; then
    LC_ALL=C awk "BEGIN { printf \"%.3f\", ${BASH_REMATCH[1]} * 3600 + ${BASH_REMATCH[2]} * 60 + ${BASH_REMATCH[3]} }"
    return
  fi
  if [[ "$tc" =~ ^([0-9]{1,2}):([0-9]{2})[\.:,]([0-9]{1,3})$ ]]; then
    local ms="${BASH_REMATCH[3]}"
    while [ ${#ms} -lt 3 ]; do ms="${ms}0"; done
    LC_ALL=C awk "BEGIN { printf \"%.3f\", ${BASH_REMATCH[1]} * 60 + ${BASH_REMATCH[2]} + $ms / 1000 }"
    return
  fi
  if [[ "$tc" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
    LC_ALL=C awk "BEGIN { printf \"%.3f\", $tc }"
    return
  fi
  echo "0"
}
# ---------------------------------------------------------------------------
# HELPER: First subtitle timestamp (seconds) in a sub file, for aligning the
# preview window. Echoes seconds or fails.
# ---------------------------------------------------------------------------
get_first_sub_time() {
  local sub_file="$1"
  local ext="${sub_file##*.}"
  ext="${ext,,}"                        # case-insensitive extension check
  local tc="" line pts

  case "$ext" in
    srt)
      line=$(grep -m1 -E '[0-9]{2}:[0-9]{2}:[0-9]{2}[,.][0-9]{3}' "$sub_file" 2>/dev/null || true)
      tc=$(printf '%s\n' "$line" | grep -oE '[0-9]{2}:[0-9]{2}:[0-9]{2}[,.][0-9]{3}' | head -1)
      ;;
    sup)
      # Only accept clean numeric timestamps; ffprobe prints "N/A" when a
      # packet has no pts, and "N/A" spliced into awk breaks the arithmetic.
      pts=$(ffprobe -v error -select_streams s -show_entries packet=pts_time \
              -of csv=p=0 "$sub_file" 2>/dev/null \
            | grep -m1 -E '^[0-9]+([.][0-9]+)?$' || true)
      [ -n "$pts" ] && { printf '%s\n' "$pts"; return 0; }
      return 1
      ;;
    *)  # .idx / .sub.idx — "timestamp: 00:01:23:456" lines
      line=$(grep -m1 '^timestamp:' "$sub_file" 2>/dev/null || true)
      tc=$(printf '%s\n' "$line" | grep -oE '[0-9]{2}:[0-9]{2}:[0-9]{2}[:.,][0-9]{1,3}' | head -1)
      ;;
  esac

  [ -n "$tc" ] || return 1
  # convert_time_to_seconds always emits a number, but route it through
  # num_or anyway so a future edit can't reintroduce the bug.
  num_or "$(convert_time_to_seconds "$tc")" ""
}
# ---------------------------------------------------------------------------
# HELPER (fallback only): Locate a subtitle entry file for a video using the
# SAME glob conventions as discover_subs() in subtitles.sh:
#   {base}_*.idx / {base}_*.sub.idx / {base}_*.sup / {base}.*.srt
# including _pal-stripped and spaceless variants. Prefers DEFAULT_HINT, then
# track0, then the first match.
# ---------------------------------------------------------------------------
find_subtitle_for_preview() {
  local video="$1"
  local base_path="${video%.*}"
  local base_clean="${base_path%_pal}"
  base_clean="${base_clean%_PAL}"
  local base_ns="${base_path// /}"
  local base_clean_ns="${base_clean// /}"

  shopt -s nullglob
  local -a cands=(
    "${base_path}"_*.idx "${base_path}"_*.sub.idx "${base_path}"_*.sup "${base_path}".*.srt
  )
  if [ "$base_path" != "$base_clean" ]; then
    cands+=("${base_clean}"_*.idx "${base_clean}"_*.sub.idx "${base_clean}"_*.sup "${base_clean}".*.srt)
  fi
  if [ "$base_path" != "$base_ns" ]; then
    cands+=("${base_ns}"_*.idx "${base_ns}"_*.sub.idx "${base_ns}"_*.sup "${base_ns}".*.srt)
  fi
  if [ "$base_clean" != "$base_clean_ns" ]; then
    cands+=("${base_clean_ns}"_*.idx "${base_clean_ns}"_*.sub.idx "${base_clean_ns}"_*.sup "${base_clean_ns}".*.srt)
  fi
  shopt -u nullglob

  [ ${#cands[@]} -gt 0 ] || return 1

  # Deduplicate while keeping sort order
  local -a uniq=()
  local seen=" " f
  while IFS= read -r f; do
    [[ "$seen" != *" $f "* ]] && { seen+="$f "; uniq+=("$f"); }
  done < <(printf '%s\n' "${cands[@]}" | sort)

  local hint="${DEFAULT_HINT:-}"
  if [ -n "$hint" ]; then
    for f in "${uniq[@]}"; do
      [[ "${f,,}" == *"${hint,,}"* ]] && { echo "$f"; return 0; }
    done
  fi
  for f in "${uniq[@]}"; do
    [[ "$f" == *track0* ]] && { echo "$f"; return 0; }
  done
  echo "${uniq[0]}"
}

# ---------------------------------------------------------------------------
# HELPER: Convert .srt to overlay JSON [{start,end,text}] with times adjusted
# for the preview clip window (clip_start..clip_start+dur), clamped.
# ---------------------------------------------------------------------------
srt_to_json() {
  local srt="$1" json_out="$2" cstart="$3" cdur="$4"

  LC_ALL=C awk -v cstart="$cstart" -v cdur="$cdur" '
    function tc_to_sec(tc,   a) {
      split(tc, a, ":")
      gsub(/,/, ".", a[3])
      return a[1] * 3600 + a[2] * 60 + a[3]
    }
    # esc(): make s safe as a JSON string value. Backslashes and newlines are rebuilt with split() + plain concatenation because gsub() REPLACEMENT strings containing "\\" are ambiguous across awks (gawk collapses "\\\\" to one backslash, mawk passes both through). Concatenation has exactly one meaning everywhere.
    function esc(s,   m, a, i, r, sent) {
      sent = sprintf("%c", 1)             # sentinel char, absent from SRT text
      s = s sent                          # protects a trailing "\" (split()
      m = split(s, a, "\\\\")             # drops trailing empty fields)
      r = ""
      for (i = 1; i <= m; i++)
        r = r (i > 1 ? "\\\\" : "") a[i]  # rejoin: every "\" is now "\\"
      sub(sent "$", "", r)                # drop the sentinel
      gsub(/"/, "\\\"", r)                # " -> \"
      m = split(r, a, "\n")               # real newline -> the two chars \ n
      r = a[1]
      for (i = 2; i <= m; i++)
        r = r "\\n" a[i]
      gsub(/</, "\\u003c", r)             # < -> \u003c (</script> safety)
      return r
    }
    function emit(   as, ae) {
      if (txt == "") return
      as = s - cstart; ae = e - cstart
      if (ae > 0 && as < cdur) {
        if (as < 0) as = 0
        if (ae > cdur) ae = cdur
        printf "%s\n    {\"start\": %.3f, \"end\": %.3f, \"text\": \"%s\"}", (n > 0 ? "," : ""), as, ae, esc(txt)
        n++
      }
    }
    BEGIN { print "["; n = 0; has = 0; intext = 0 }
    { sub(/\r$/, "") }
    /^[[:space:]]*[0-9][0-9]:[0-9][0-9]:[0-9][0-9][,.][0-9][0-9][0-9][[:space:]]*-->/ {
      if (has) emit()
      match($0, /[0-9][0-9]:[0-9][0-9]:[0-9][0-9][,.][0-9][0-9][0-9]/)
      st = substr($0, RSTART, RLENGTH)
      rest = substr($0, RSTART + RLENGTH)
      en = ""
      if (match(rest, /[0-9][0-9]:[0-9][0-9]:[0-9][0-9][,.][0-9][0-9][0-9]/))
        en = substr(rest, RSTART, RLENGTH)
      if (en != "") { s = tc_to_sec(st); e = tc_to_sec(en); txt = ""; has = 1; intext = 1 }
      next
    }
    /^[[:space:]]*$/ { if (has) emit(); has = 0; intext = 0; next }
    { if (intext) txt = txt (txt == "" ? "" : "\n") $0 }
    END { if (has) emit(); print (n > 0 ? "\n  " : "") "]" }
  ' "$srt" > "$json_out" 2>/dev/null || true

  [ -s "$json_out" ] && grep -q '"start"' "$json_out"
}
# ---------------------------------------------------------------------------
# HELPER: Extract subtitle frames + timing as overlay JSON for one sub file.
#   - .srt            -> text entries
#   - .idx/.sub.idx/.sup -> bdsup2sub (same invocation as mux_subs) -> BDN XML
#     + transparent PNGs; entries carry image path + x/y/width percentages so
#     the browser positions the bitmap exactly like the DVD subpicture.
# Echoes the JSON path on success.
# ---------------------------------------------------------------------------
extract_subtitle_frames() {
  local sub_file="$1" sub_dir="$2" clip_start="$3" clip_dur="$4" ts_idx="$5"

  mkdir -p "$sub_dir"
  local json_file="$sub_dir/subs.json"
  local ext="${sub_file##*.}"

  # --- SRT: pure text, no bdsup2sub needed ---
  if [ "$ext" = "srt" ]; then
    srt_to_json "$sub_file" "$json_file" "$clip_start" "$clip_dur"
    [ -s "$json_file" ] && grep -q '"start"' "$json_file" && { echo "$json_file"; return 0; }
    return 1
  fi

  # --- Bitmap subs: bdsup2sub ---
  if [ -z "${BDSUP2SUB_CMD[@]+x}" ]; then
    echo "    bdsup2sub not available; cannot extract bitmap subtitles for preview" >&2
    return 1
  fi

  # Stage into clean paths (idx + companion sub must share a basename),
  # exactly like mux_subs does.
  local bdsup_in="" data=""
  if [ "$ext" = "sup" ]; then
    cp -f "$sub_file" "$sub_dir/stage.sup"
    bdsup_in="$sub_dir/stage.sup"
  else
    if [[ "$sub_file" == *.sub.idx ]]; then
      [ -f "${sub_file%.sub.idx}.sub" ] && data="${sub_file%.sub.idx}.sub"
      [ -f "${sub_file%.sub.idx}.sub.sub" ] && data="${sub_file%.sub.idx}.sub.sub"
    else
      [ -f "${sub_file%.idx}.sub" ] && data="${sub_file%.idx}.sub"
      [ -f "${sub_file%.idx}.sub.sub" ] && data="${sub_file%.idx}.sub.sub"
    fi
    if [ -z "$data" ]; then
      echo "    no companion .sub file found for $(basename "$sub_file")" >&2
      return 1
    fi
    cp -f "$sub_file" "$sub_dir/stage.idx"
    cp -f "$data" "$sub_dir/stage.sub"
    bdsup_in="$sub_dir/stage.idx"
  fi

  local bdn_xml="$sub_dir/ts${ts_idx}_bdn.xml"
  local bd_log="$sub_dir/bdsup2sub.log"
  rm -f "$bdn_xml"
  rm -f "$sub_dir"/ts${ts_idx}_bdn*.png

  if [[ "${BDSUP2SUB_CMD[*]}" == *"bdsup2sub++"* ]]; then
    env QT_QPA_PLATFORM=offscreen "${BDSUP2SUB_CMD[@]}" --no-verbose -o "$bdn_xml" "$bdsup_in" > "$bd_log" 2>&1
  else
    "${BDSUP2SUB_CMD[@]}" --no-verbose -o "$bdn_xml" "$bdsup_in" > "$bd_log" 2>&1
  fi

  [ -s "$bdn_xml" ] || { echo "    bdsup2sub produced no XML for $(basename "$sub_file")" >&2; return 1; }

  shopt -s nullglob
  local pngs=( "$sub_dir"/ts${ts_idx}_bdn*.png )
  shopt -u nullglob
  [ ${#pngs[@]} -gt 0 ] || { echo "    bdsup2sub produced no PNG frames" >&2; return 1; }

  # Source resolution for placement percentages (same detection as mux_subs)
  local src_w="$WIDTH" src_h="$HEIGHT" res_str
  res_str=$(grep -i -m1 -E '(resolution|size):' "$bd_log" | grep -o '[0-9]\+x[0-9]\+' || true)
  if [ -n "$res_str" ]; then
    src_w="${res_str%x*}"; src_h="${res_str#*x}"
  fi

  local img_dir
  img_dir=$(rel_path "$sub_dir")

  # BDN XML -> overlay JSON (InTC/OutTC timing, Graphic X/Y/Width placement)
  LC_ALL=C awk -v dir="$img_dir" -v fps="$FPS" -v sw="$src_w" -v sh="$src_h" \
      -v cstart="$clip_start" -v cdur="$clip_dur" '
    function tc_to_sec(tc,   t, hh, mm, ss, ff, ms) {
      split(tc, t, ":")
      hh = t[1]; mm = t[2]; ss = t[3]; ff = t[4]
      if (ff == "") ff = 0
      if (fps + 0 == 25) ms = ff * 40
      else if (fps + 0 == 24 || fps + 0 == 23.976) ms = ff * 42
      else ms = ff * 33
      return hh * 3600 + mm * 60 + ss + ms / 1000
    }
    BEGIN { print "["; n = 0 }
    { sub(/\r$/, "") }
    /<[Ee]vent / {
      start = ""; end = ""
      if (match($0, /[Ii]nTC="[^"]*"/))  start = substr($0, RSTART + 6, RLENGTH - 7)
      if (match($0, /[Oo]utTC="[^"]*"/)) end   = substr($0, RSTART + 7, RLENGTH - 8)
    }
    /<[Gg]raphic[ >]/ {
      x = 0; y = 0; w = 0
      if (match($0, /[Xx]="[0-9]+"/))     x = substr($0, RSTART + 3, RLENGTH - 4) + 0
      if (match($0, /[Yy]="[0-9]+"/))     y = substr($0, RSTART + 3, RLENGTH - 4) + 0
      if (match($0, /[Ww]idth="[0-9]+"/)) w = substr($0, RSTART + 7, RLENGTH - 8) + 0
      line = $0
      sub(/.*<[Gg]raphic[^>]*>/, "", line)
      sub(/<\/[Gg]raphic>.*/, "", line)
      gsub(/^[ \t]+|[ \t]+$/, "", line)
      img = line
      if (start != "" && end != "" && img != "") {
        s = tc_to_sec(start) - cstart
        e = tc_to_sec(end) - cstart
        if (e > 0 && s < cdur) {
          if (s < 0) s = 0
          if (e > cdur) e = cdur
          gsub(/\\/, "\\\\", img)
          gsub(/"/, "\\\"", img)
          xp = (sw > 0) ? x * 100 / sw : 0
          yp = (sh > 0) ? y * 100 / sh : 0
          wp = (w > 0 && sw > 0) ? w * 100 / sw : 0
          printf "%s\n    {\"start\": %.3f, \"end\": %.3f, \"image\": \"%s\", \"x\": %.2f, \"y\": %.2f, \"w\": %.2f}", \
                 (n > 0 ? "," : ""), s, e, dir "/" img, xp, yp, wp
          n++
        }
      }
    }
    END { print (n > 0 ? "\n  " : "") "]" }
  ' "$bdn_xml" > "$json_file"
  if grep -q '"start"' "$json_file" 2>/dev/null; then
    echo "$json_file"
    return 0
  fi
  rm -f "$json_file"
  return 1
}
# ---------------------------------------------------------------------------
# HELPER: Validate (and repair) a subtitle overlay JSON file. Returns 0 when
# $1 is usable. Repairs the comma-decimal corruption ("start": 0,000) a
# non-C-locale awk produces, then validates with jq; unrecoverable files are
# deleted so the caller regenerates them.
# Safe to sed: an unescaped "start": / "end": ... sequence cannot occur
# inside a JSON string value (awk escapes every quote in text).
# ---------------------------------------------------------------------------
subs_json_ensure() {
  local f="$1"
  [ -s "$f" ] || return 1
  grep -q '"start"' "$f" 2>/dev/null || return 1

  if grep -qE '"(start|end|x|y|w)": -?[0-9]+,' "$f"; then
    echo "  -> Repairing locale-corrupted subtitle data in $(basename "$f")" >&2
    sed -i -E 's/("(start|end|x|y|w)": -?[0-9]+),([0-9]+)/\1.\3/g' "$f"
  fi
  # TODO: uncomment...
#  # Repair the doubled-backslash newline joiner ("\\n" -> "\n" in text values). Caveat: also rewrites a genuine literal backslash-before-n in subtitle text, which effectively never occurs.
#  if grep -q '\\\\n' "$f"; then
#    echo "  -> Repairing doubled newline escapes in $(basename "$f")" >&2
#    sed -i 's/\\\\n/\\n/g' "$f"
#  fi
  if command -v jq >/dev/null 2>&1; then
    if ! jq -e . "$f" >/dev/null 2>&1; then
      echo "  -> Warning: $(basename "$f") is not valid JSON; regenerating" >&2
      rm -f "$f"
      return 1
    fi
  fi
  return 0
}
# ---------------------------------------------------------------------------
# HELPER: Encode a file's contents as a JSON string literal — pure bash.
# Covers everything the awk generators emit (backslash, quote, newline, CR,
# TAB). Always succeeds; emits "[]" for missing/empty/unreadable input.
# ---------------------------------------------------------------------------
json_string_encode_file() {
  local f="$1" s
  if [ ! -s "$f" ]; then printf '"[]"'; return 0; fi
  s=$(<"$f") || { printf '"[]"'; return 0; }
  s="${s//\\/\\\\}"     # backslash first!
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/\\r}"
  s="${s//$'\t'/\\t}"
  printf '"%s"' "$s"
}
# ---------------------------------------------------------------------------
# HELPER: Generate (and cache) a muted H.264 proxy clip + poster frame +
# subtitle overlay JSON. Subtitles are NOT burned in; they are overlaid live
# in the browser.
# Echoes "clip_path|sub_json_path|poster_path" (fields may be empty).
# ---------------------------------------------------------------------------
generate_preview_clip() {
  local src="$1" ts_idx="$2" has_subs="${3:-0}" sub_file="${4:-}"

  mkdir -p "$PREVIEW_CACHE_DIR"
  local out="$PREVIEW_CACHE_DIR/ts${ts_idx}_preview.mp4"
  local start_file="$PREVIEW_CACHE_DIR/ts${ts_idx}_preview.start"
  local poster="$PREVIEW_CACHE_DIR/ts${ts_idx}_poster.jpg"
  local sub_dir="$PREVIEW_CACHE_DIR/ts${ts_idx}_subs"
  local sub_json=""

  # Sanitize inputs before they reach [ -eq ] / awk
  has_subs=$(num_or "$has_subs" 0)

  # Resolve the subtitle file to preview (the DEFAULT track, passed in from
  # the analysis phase; fallback to the discover_subs-style glob if absent).
  if [ "$has_subs" -eq 1 ]; then
    if [ -z "$sub_file" ] || [ ! -f "$sub_file" ]; then
      sub_file=$(find_subtitle_for_preview "$src" 2>/dev/null || true)
    fi
    [ -f "$sub_file" ] || sub_file=""   # a stale glob result is no good either
  fi

  if ! command -v ffmpeg >/dev/null 2>&1; then
    echo "  -> Note: ffmpeg not found; no video preview for ts${ts_idx}." >&2
    echo "||"
    return 1
  fi

  # Source duration. ffprobe may print "N/A" or nothing; num_or turns all of that into a plain 0. The '|| true' keeps a hard ffprobe failure from aborting the whole build under 'set -e'.
  local dur
  dur=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$src" 2>/dev/null || true)
  dur=$(num_or "${dur%.*}" 0)

  local start
  start=$(num_or "$PREVIEW_CLIP_START" 120)

  if [ "$dur" -gt 0 ] && [ "$start" -ge "$dur" ]; then
    start=$(( dur / 4 ))
  fi

  # If subtitles exist but start after our window, slide the window to them.
  # Every value entering the awk programs is validated first — a stray "N/A"
  # or empty string used to leave $move empty, which then blew up
  # [ "$move" -eq 1 ] with "integer expression expected".
  if [ "$has_subs" -eq 1 ] && [ -n "$sub_file" ]; then
    local first_sub
    first_sub=$(get_first_sub_time "$sub_file" 2>/dev/null || true)
    first_sub=$(num_or "$first_sub" "")
    if [ -n "$first_sub" ]; then
      local move
      move=$(num_or "$(LC_ALL=C awk "BEGIN { print ($first_sub >= $start + $PREVIEW_CLIP_SECONDS) ? 1 : 0 }" 2>/dev/null || true)" 0)
      if [ "$move" -eq 1 ]; then
        local newstart
        newstart=$(num_or "$(LC_ALL=C awk "BEGIN { printf \"%d\", ($first_sub > 2 ? $first_sub - 2 : 0) }" 2>/dev/null || true)" "$start")
        if [ "$dur" -eq 0 ] || [ "$newstart" -lt "$dur" ]; then
          echo "  -> Aligning ts${ts_idx} preview window with first subtitle (~${newstart}s)" >&2
          start="$newstart"
        fi
      fi
    fi
  fi

  local scale_filter="scale=${PREVIEW_CLIP_WIDTH}:-2"

  # Generate/validate clip. A .start sidecar guards the cache: if the window
  # moved (e.g. subtitle alignment changed), the clip and overlay regenerate.
  local need_clip=1
  if [ -s "$out" ] && [ -s "$start_file" ] && [ "$(cat "$start_file" 2>/dev/null)" = "$start" ]; then
    need_clip=0
  fi
  if [ "$need_clip" -eq 1 ]; then
    echo "  -> Generating ${PREVIEW_CLIP_SECONDS}s preview clip for ts${ts_idx} (from ${start}s)..." >&2
    rm -f "$out" "$sub_dir/subs.json"
    ffmpeg -y -ss "$start" -i "$src" -t "$PREVIEW_CLIP_SECONDS" \
      -vf "$scale_filter" -an \
      -c:v libx264 -preset veryfast -crf 28 -movflags +faststart \
      "$out" >/dev/null 2>&1
    echo "$start" > "$start_file"
    [ -s "$out" ] || echo "  -> Warning: clip generation failed for $(basename "$src")" >&2
  fi

  # Poster frame
  if [ ! -s "$poster" ]; then
    local poster_start=$(( start + PREVIEW_CLIP_SECONDS / 2 ))
    [ "$dur" -gt 0 ] && [ "$poster_start" -ge "$dur" ] && poster_start="$start"
    ffmpeg -y -ss "$poster_start" -i "$src" -vframes 1 \
      -vf "$scale_filter" "$poster" >/dev/null 2>&1
  fi

  # Subtitle overlay extraction
  if [ "$has_subs" -eq 1 ]; then
    if [ -n "$sub_file" ] && [ -f "$sub_file" ]; then
      if subs_json_ensure "$sub_dir/subs.json"; then
        sub_json="$sub_dir/subs.json"
      else
        echo "  -> Extracting subtitle overlay for ts${ts_idx} from $(basename "$sub_file")..." >&2
        sub_json=$(extract_subtitle_frames "$sub_file" "$sub_dir" "$start" "$PREVIEW_CLIP_SECONDS" "$ts_idx" || true)
        if [ -n "$sub_json" ] && [ -s "$sub_json" ] && subs_json_ensure "$sub_json"; then
          local cnt
          cnt=$(num_or "$(grep -c '"start"' "$sub_json" 2>/dev/null || true)" 0)
          echo "  -> ts${ts_idx}: ${cnt} subtitle(s) fall inside the preview window" >&2
        else
          echo "  -> Warning: subtitle extraction produced invalid data for ts${ts_idx}; preview plays without subs" >&2
          sub_json=""
        fi
      fi
    else
      echo "  -> Warning: no subtitle file could be located for ts${ts_idx}; preview plays without subs" >&2
    fi
  fi

  local clip_out="" poster_out=""
  [ -s "$out" ] && clip_out="$out"
  [ -s "$poster" ] && poster_out="$poster"
  echo "${clip_out}|${sub_json}|${poster_out}"
}
# ---------------------------------------------------------------------------
# HELPER: Compute the title font size for a given text length.
# Mirrors build_menu().
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
# HELPER: Compute button point size + line height for a menu with N buttons.
# Mirrors build_menu() layout math. Echoes "point_size line_height".
# ---------------------------------------------------------------------------
compute_menu_layout() {
  local num_items="$1"
  local menu_h=576 top_margin=120
  if [ "$DETECTED_FORMAT" = "ntsc" ]; then menu_h=480; top_margin=100; fi
  local line_h=$(( (menu_h - top_margin - 60) / num_items ))
  [ "$line_h" -gt 70 ] && line_h=70
  [ "$line_h" -lt $((MIN_POINT_SIZE + 6)) ] && line_h=$((MIN_POINT_SIZE + 6))
  local point_size=$(( line_h / 2 + 10 ))
  [ "$point_size" -gt "$MAX_POINT_SIZE" ] && point_size=$MAX_POINT_SIZE
  [ "$point_size" -lt "$MIN_POINT_SIZE" ] && point_size=$MIN_POINT_SIZE
  echo "$point_size $line_h"
}

# ---------------------------------------------------------------------------
# HELPER: Generate the complete HTML DVD preview
# ---------------------------------------------------------------------------
generate_html_preview() {
  local html_file="dvd_preview.html"

  # Layout constants mirroring build_menu()
  local menu_w=720 menu_h=576 top_margin=120
  if [ "$DETECTED_FORMAT" = "ntsc" ]; then menu_h=480; top_margin=100; fi
  local left_margin=$((menu_w / 6))
  local title_bar_h=$((top_margin - 15))
  local title_bar_pct=$(( title_bar_h * 100 / menu_h ))
  local top_margin_pct=$(( top_margin * 100 / menu_h ))
  local left_margin_pct=$(( left_margin * 100 / menu_w ))

  local has_extras=0
  [ ${#ANALYSIS_TITLES[@]} -gt 1 ] && has_extras=1

  # Menu button typography (mirrors build_menu point sizes)
  local n_main_btns=1
  [ "$has_extras" -eq 1 ] && n_main_btns=2
  local main_pt main_lh main_gap
  read -r main_pt main_lh <<< "$(compute_menu_layout "$n_main_btns")"
  main_gap=$(( main_lh - main_pt - 10 )); [ "$main_gap" -lt 4 ] && main_gap=4

  local extras_pt=28 extras_lh=44 extras_gap=6
  if [ "$has_extras" -eq 1 ]; then
    read -r extras_pt extras_lh <<< "$(compute_menu_layout "$(( ${#ANALYSIS_TITLES[@]} ))")"
    extras_gap=$(( extras_lh - extras_pt - 10 )); [ "$extras_gap" -lt 4 ] && extras_gap=4
  fi

  # ---- Generate preview assets (clips, posters, subtitle overlays) ----
  declare -a CLIP_PLAIN SUB_JSON POSTER_PATH

  echo "" >&2
  echo "  Generating preview assets..." >&2

  for i in "${!ANALYSIS_TITLES[@]}"; do
    local ts_idx=$((i + 1))
    local video="${ALL_VIDEOS[$i]}"
    local has_subs=$(num_or "${ANALYSIS_HAS_SUBS[$i]:-0}" 0)

    local sub_file=""

    # Use the subtitle file list discovered during analysis (default track)
    if [ "$has_subs" -eq 1 ]; then
      local default_idx=$(( ${ANALYSIS_DEFAULTS[$i]:-62} - 64 ))
      if [ "$default_idx" -ge 0 ] && [ -n "${ANALYSIS_SUB_FILES[$i]:-}" ]; then
        local saved_ifs="$IFS"
        IFS='|' read -ra sub_files <<< "${ANALYSIS_SUB_FILES[$i]}"
        IFS="$saved_ifs"
        sub_file="${sub_files[$default_idx]:-}"
      fi
    fi

    local info
    info=$(generate_preview_clip "$video" "$ts_idx" "$has_subs" "$sub_file")
    CLIP_PLAIN[$i]="${info%%|*}"
    local rest="${info#*|}"
    SUB_JSON[$i]="${rest%%|*}"
    POSTER_PATH[$i]="${rest##*|}"
  done

  local sub_count=0
  for i in "${!ANALYSIS_TITLES[@]}"; do
    [ -n "${SUB_JSON[$i]:-}" ] && [ -s "${SUB_JSON[$i]}" ] && sub_count=$((sub_count + 1))
  done

  local main_title_html sub_menu_title_html
  main_title_html=$(html_escape "${ANALYSIS_TITLES[0]}")

  # ---- HTML head + CSS ----
  cat <<HTMLEOF > "$html_file"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>DVD Preview</title>
<style>
  * { box-sizing: border-box; margin: 0; padding: 0; }
  body { background:#0a0a0a; color:#d4d4d4; font-family:'Segoe UI',Arial,sans-serif; display:flex; flex-direction:column; align-items:center; min-height:100vh; padding:20px; }
  h1 { color:#fff; font-size:1.4em; margin-bottom:4px; }
  .meta { color:#888; margin-bottom:18px; font-size:.85em; }

  .dvd-frame { width:100%; max-width:720px; aspect-ratio:4/3; background:#000; border:2px solid #2a2a2a; border-radius:4px; position:relative; overflow:hidden; box-shadow:0 0 30px rgba(0,0,0,.6); }
  .screen { position:absolute; inset:0; display:none; }
  .screen.active { display:block; }

  /* Menus — mirror build_menu(): black bg, navy title bar, gray separator */
  .menu-screen .title-bar { position:absolute; top:0; left:0; right:0; height:${title_bar_pct}%; background:#1a1a2e; display:flex; align-items:center; padding-left:${left_margin_pct}%; padding-right:${left_margin_pct}%; z-index:2; }
  .menu-screen .separator { position:absolute; top:${title_bar_pct}%; left:0; right:0; height:3px; background:#555555; z-index:2; }
  .menu-screen .title-text { color:#fff; font-weight:bold; white-space:nowrap; overflow:hidden; text-overflow:ellipsis; width:100%; }
  .menu-screen .button-area { position:absolute; top:${top_margin_pct}%; left:${left_margin_pct}%; right:${left_margin_pct}%; bottom:4%; z-index:2; display:flex; flex-direction:column; }

  .btn { background:none; border:none; color:#fff; text-align:left; cursor:pointer; padding:4px 10px; width:100%; font-family:inherit; line-height:1.25; transition:color .1s; text-shadow:0 1px 3px rgba(0,0,0,.9); }
  .btn:hover, .btn.active { color:#ff3333; }
  .btn::before { content:"\\25B6  "; opacity:0; color:#ff3333; }
  .btn.active::before, .btn:hover::before { opacity:1; }
  .btn.is-default::after { content:" \\00b7 default"; color:#8a8a8a; font-size:.65em; font-style:italic; }

  /* Movie screens: clean video, object-fit fill = anamorphic 4:3 like a TV */
  .movie-screen .video-container { position:absolute; inset:0; background:#000; }
  .movie-screen .video-container video,
  .movie-screen .video-container img { width:100%; height:100%; object-fit:fill; display:block; }

  /* Subtitle overlay: transparent bitmap PNGs / styled text */
  .sub-layer { position:absolute; inset:0; z-index:1; pointer-events:none; overflow:hidden; }
  .sub-bitmap { position:absolute; opacity:0; transition:opacity .1s; max-width:92%; }
  .sub-bitmap.visible { opacity:1; }
  .sub-text { position:absolute; left:8%; right:8%; bottom:8%; text-align:center; color:#ffe14d; font-size:20px; line-height:1.3; white-space:pre-line; text-shadow:0 0 3px #000,1px 1px 2px #000,-1px -1px 2px #000; opacity:0; transition:opacity .1s; font-family:Arial,sans-serif; }
  .sub-text.visible { opacity:1; }

  .sub-badge { position:absolute; top:8px; right:10px; z-index:3; background:rgba(0,0,0,.65); color:#ffd700; font-size:11px; letter-spacing:1px; padding:3px 8px; border-radius:3px; border:1px solid rgba(255,215,0,.3); display:none; }
  .sub-badge.visible { display:block; }

  .osd { position:absolute; left:12px; bottom:12px; z-index:3; background:rgba(0,0,0,.65); color:#fff; font-size:13px; padding:6px 12px; border-radius:3px; opacity:0; transition:opacity .5s; pointer-events:none; }
  .osd.visible { opacity:1; }

  /* Simulated remote + VM status */
  .remote-panel { margin-top:16px; display:flex; gap:14px; align-items:center; flex-wrap:wrap; justify-content:center; }
  .remote { display:flex; gap:8px; }
  .remote button { background:#222; color:#ddd; border:1px solid #444; padding:8px 14px; border-radius:4px; cursor:pointer; font-size:.85em; }
  .remote button:hover { background:#333; border-color:#666; color:#fff; }
  .vm-status { font-family:ui-monospace,Consolas,monospace; font-size:.78em; color:#7fbf7f; min-width:280px; }
  .vm-status.flash { color:#ffd166; }
  .hint { color:#666; font-size:.78em; }
  .proxy-note { max-width:720px; margin-top:12px; font-size:.75em; color:#555; text-align:center; line-height:1.5; }
</style>
</head>
<body>
  <h1>DVD Preview</h1>
  <div class="meta">
    Format: ${DETECTED_FORMAT^^} ${WIDTH}&times;${HEIGHT} @ ${FPS}fps &middot;
    Titles: ${#ANALYSIS_TITLES[@]} &middot;
    Generated: $(date '+%Y-%m-%d %H:%M')
  </div>

  <div class="dvd-frame">
HTMLEOF

  # ================================================================
  # VMGM Main Menu (PGC 1, entry="title")
  # ================================================================
  local main_title_size
  main_title_size=$(compute_title_size "${ANALYSIS_TITLES[0]}")

  # "Play movie" -> titleset 1 menu if it has subs, else straight to title (mirrors VMGM_TARGETS: "jump titleset 1 menu" vs "jump titleset 1 title 1")
  local play_target="ts1_movie"
  [ "$(num_or "${ANALYSIS_HAS_SUBS[0]:-0}" 0)" -eq 1 ] && play_target="ts1_menu"

  cat <<HTMLEOF >> "$html_file"
    <div id="vmgm" class="screen menu-screen active">
      <div class="title-bar">
        <span class="title-text" style="font-size:${main_title_size}px;">${main_title_html}</span>
      </div>
      <div class="separator"></div>
      <div class="button-area" style="font-size:${main_pt}px; gap:${main_gap}px;">
        <button class="btn" data-target="${play_target}">Play movie</button>
HTMLEOF

  if [ "$has_extras" -eq 1 ]; then
    echo '        <button class="btn" data-target="vmgm_extras">Extras Menu</button>' >> "$html_file"
  fi

  echo '      </div>' >> "$html_file"
  echo '    </div>' >> "$html_file"

  # ================================================================
  # VMGM Extras Menu (PGC 2)
  # ================================================================
  if [ "$has_extras" -eq 1 ]; then
    cat <<HTMLEOF >> "$html_file"
    <div id="vmgm_extras" class="screen menu-screen">
      <div class="title-bar">
        <span class="title-text" style="font-size:42px;">Extras Menu</span>
      </div>
      <div class="separator"></div>
      <div class="button-area" style="font-size:${extras_pt}px; gap:${extras_gap}px;">
HTMLEOF

    for i in "${!ANALYSIS_TITLES[@]}"; do
      local ts_idx=$((i + 1))
      if [ "$ts_idx" -gt 1 ]; then
        local extra_target="ts${ts_idx}_movie"
        [ "${ANALYSIS_HAS_SUBS[$i]}" -eq 1 ] && extra_target="ts${ts_idx}_menu"
        local extra_label_html
        extra_label_html=$(html_escape "${ANALYSIS_TITLES[$i]}")
        echo "        <button class='btn' data-target='${extra_target}'>${extra_label_html}</button>" >> "$html_file"
      fi
    done

    echo '        <button class="btn" data-target="vmgm">Main Menu</button>' >> "$html_file"
    echo '      </div>' >> "$html_file"
    echo '    </div>' >> "$html_file"
  fi

  # ================================================================
  # Per-titleset screens
  # ================================================================
  for i in "${!ANALYSIS_TITLES[@]}"; do
    ts_idx=$((i + 1))
    local title="${ANALYSIS_TITLES[$i]}"
    local has_subs="${ANALYSIS_HAS_SUBS[$i]}"
    local subs_str="${ANALYSIS_SUBS_STR[$i]}"
    local default_idx=$(( ${ANALYSIS_DEFAULTS[$i]} - 64 ))
    local clip="${CLIP_PLAIN[$i]:-}"
    local sub_json="${SUB_JSON[$i]:-}"
    local poster="${POSTER_PATH[$i]:-}"
    local title_html
    title_html=$(html_escape "$title")

    # ---- Titleset Subtitle Menu (entry="root,subtitle") ----
    if [ "$has_subs" -eq 1 ]; then
      local sub_menu_title="Subtitles: $title"
      [ "$ts_idx" -eq 1 ] && sub_menu_title="Movie Subtitles"
      local sub_title_size
      sub_title_size=$(compute_title_size "$sub_menu_title")
      local sub_menu_title_html
      sub_menu_title_html=$(html_escape "$sub_menu_title")

      local saved_ifs="$IFS"
      IFS='|' read -ra subs <<< "$subs_str"
      IFS="$saved_ifs"

      local n_btns=$(( ${#subs[@]} + 2 ))
      [ "$ts_idx" -gt 1 ] && n_btns=$(( n_btns + 1 ))
      local sub_pt sub_lh sub_gap
      read -r sub_pt sub_lh <<< "$(compute_menu_layout "$n_btns")"
      sub_gap=$(( sub_lh - sub_pt - 10 )); [ "$sub_gap" -lt 4 ] && sub_gap=4

      cat <<HTMLEOF >> "$html_file"
    <div id='ts${ts_idx}_menu' class='screen menu-screen'>
      <div class="title-bar">
        <span class="title-text" style="font-size:${sub_title_size}px;">${sub_menu_title_html}</span>
      </div>
      <div class="separator"></div>
      <div class="button-area" style="font-size:${sub_pt}px; gap:${sub_gap}px;">
HTMLEOF

      for j in "${!subs[@]}"; do
        local sub_label="${subs[$j]}"
        local sub_label_html
        sub_label_html=$(html_escape "$sub_label")
        local btn_class="btn"
        [ "$j" -eq "$default_idx" ] && btn_class="btn is-default"
        echo "        <button class='${btn_class}' data-target='ts${ts_idx}_movie' data-subs='on' data-sub-label='${sub_label_html}'>${sub_label_html}</button>" >> "$html_file"
      done

      echo "        <button class='btn' data-target='ts${ts_idx}_movie' data-subs='off'>No subtitles</button>" >> "$html_file"

      if [ "$ts_idx" -gt 1 ] && [ "$has_extras" -eq 1 ]; then
        echo "        <button class='btn' data-target='vmgm_extras'>Back to Extras</button>" >> "$html_file"
      fi

      echo "        <button class='btn' data-target='vmgm'>Main Menu</button>" >> "$html_file"
      echo '      </div>' >> "$html_file"
      echo '    </div>' >> "$html_file"
    fi

    # ---- Titleset Playback (title 1) ----
    cat <<HTMLEOF >> "$html_file"
    <div id='ts${ts_idx}_movie' class='screen movie-screen' data-title='${title_html}'>
      <div class="video-container">
HTMLEOF

    if [ -n "$clip" ]; then
      local clip_html poster_html
      clip_html=$(rel_path "$clip")
      poster_html=$(rel_path "$poster")
      echo "        <video id='video_${ts_idx}' muted playsinline preload='auto'" >> "$html_file"
      [ -n "$poster" ] && echo "          poster='${poster_html}'" >> "$html_file"
      echo "          style='width:100%;height:100%;object-fit:fill;'>" >> "$html_file"
      echo "          <source src='${clip_html}' type='video/mp4'>" >> "$html_file"
      echo "        </video>" >> "$html_file"
    elif [ -n "$poster" ]; then
      local poster_html
      poster_html=$(rel_path "$poster")
      echo "        <img src='${poster_html}' alt=''>" >> "$html_file"
    else
      echo "        <div style='display:flex;align-items:center;justify-content:center;height:100%;color:#666;font-size:.8em;'>No preview available</div>" >> "$html_file"
    fi

    cat <<HTMLEOF >> "$html_file"
      </div>
      <div class="sub-layer">
        <img id="subimg_${ts_idx}" class="sub-bitmap" alt="">
        <div id="subtext_${ts_idx}" class="sub-text"></div>
      </div>
      <div class="sub-badge" id="badge_${ts_idx}">SUB</div>
      <div class="osd" id="osd_${ts_idx}"></div>
    </div>
HTMLEOF

  done

  # ================================================================
  # Close frame, remote control, notes
  # ================================================================
  cat <<HTMLEOF >> "$html_file"
  </div>

  <div class="remote-panel">
    <div class="remote">
      <button onclick="pressTitleMenu()" title="jump vmgm menu entry title">&#9194; Title Menu</button>
      <button onclick="pressSubtitleMenu()" title="titleset menu (entry=root,subtitle)">&#128172; Subtitle Menu</button>
      <button onclick="pressEndTitle()" title="simulate title end &lt;post&gt; call vmgm menu">&#9197; End Title</button>
    </div>
    <div class="vm-status" id="vm_status"></div>
  </div>
  <div class="hint">Menus: Arrow keys + Enter &middot; M = Title Menu &middot; S = Subtitle Menu</div>

  <div class="proxy-note">
    Clips are ${PREVIEW_CLIP_SECONDS}s H.264 proxies; menus are static mock-ups of the authored MPEG stills.<br>
    Subtitles render as live transparent overlays extracted via bdsup2sub/SRT parsing (${sub_count}/${#ANALYSIS_TITLES[@]} titles; default track shown).<br>
    None of this affects the actual DVD-Video encode.
  </div>
HTMLEOF

  # ================================================================
  # JavaScript: subtitle data + DVD VM navigation simulation
  # ================================================================
  {
    echo '<script>'
    echo '  // Subtitle overlay data per titleset (bitmap PNGs and/or SRT text). Decoded per-title inside try/catch: one corrupt file must never abort the whole script (a top-level throw leaves every let below in its temporal dead zone: ReferenceErrors).'
    echo '  const subtitleData = {};'
    echo '  function loadSubs(key, raw) {'
    echo '    try { subtitleData[key] = JSON.parse(raw); }'
    echo '    catch (e) {'
    echo '      console.warn("subtitle overlay data for " + key + " failed to parse: " + e.message);'
    echo '      subtitleData[key] = [];'
    echo '    }'
    echo '  }'
    for i in "${!ANALYSIS_TITLES[@]}"; do
      ts_idx=$((i + 1))
      if [ -n "${SUB_JSON[$i]:-}" ] && [ -s "${SUB_JSON[$i]}" ]; then
        local encoded
        # jq: read the whole file as one raw string (-R -s) and print it as a JSON string literal; -a keeps the payload pure ASCII (defuses U+2028/2029, which are legal JSON but hostile in JS string literals).
        encoded=$(jq -aRs . "${SUB_JSON[$i]}" 2>/dev/null || true)
        # Fallback if jq is missing or rejects the file
        [ -n "$encoded" ] || encoded=$(json_string_encode_file "${SUB_JSON[$i]}")
        encoded="${encoded:-\"[]\"}"
        # HTML safety: a literal "</script>" inside subtitle text would terminate this <script> block early — no raw '<' may survive.
        encoded="${encoded//</\\u003c}"
        printf '  loadSubs("ts%d", %s);\n' "$ts_idx" "$encoded"
      fi
    done
    cat <<'JSEOF'

  // ---- VM state ----
  let activeScreenId = "vmgm";
  let currentButtons = [];
  let selectedIndex = 0;
  let currentTs = 0;          // titleset currently playing (0 = in a menu)
  let subsEnabled = false;
  let subLabel = "";
  let osdTimer = null;
  let statusTimer = null;

  function tsHasSubData(ts) {
    return (subtitleData["ts" + ts] || []).length > 0;
  }

  function showScreen(id, opts) {
    document.querySelectorAll("video").forEach(v => v.pause());
    document.querySelectorAll(".screen").forEach(s => s.classList.remove("active"));

    const target = document.getElementById(id);
    if (!target) return;
    target.classList.add("active");
    activeScreenId = id;

    const m = id.match(/^ts(\d+)_movie$/);
    currentTs = m ? parseInt(m[1], 10) : 0;

    if (m) {
      // Entering title playback: subtitle state is whatever the menu chose
      if (opts && opts.subs === "on") { subsEnabled = true; subLabel = opts.subLabel || "Subtitles"; }
      else if (opts && opts.subs === "off") { subsEnabled = false; subLabel = ""; }
      else { subsEnabled = false; subLabel = ""; }

      const v = document.getElementById("video_" + currentTs);
      if (v) { try { v.currentTime = 0; } catch (e) {} v.play().catch(() => {}); }
      updateBadge(currentTs);
      showOsd(target);
    }

    currentButtons = Array.from(target.querySelectorAll(".btn"));
    selectedIndex = 0;
    updateButtonStates();
    updateStatus();
  }

  function updateButtonStates() {
    currentButtons.forEach((b, i) => {
      if (i === selectedIndex) b.classList.add("active");
      else b.classList.remove("active");
    });
  }

  function activateButton(btn) {
    if (!btn) return;
    const target = btn.getAttribute("data-target");
    if (!target) return;
    showScreen(target, {
      subs: btn.getAttribute("data-subs"),
      subLabel: btn.getAttribute("data-sub-label")
    });
  }

  // ---- Subtitle overlay rendering ----
  function renderSubs(ts, t) {
    const img = document.getElementById("subimg_" + ts);
    const txt = document.getElementById("subtext_" + ts);
    if (img) img.classList.remove("visible");
    if (txt) txt.classList.remove("visible");

    const subs = subtitleData["ts" + ts] || [];
    if (!subsEnabled || subs.length === 0) return;

    const sub = subs.find(s => t >= s.start && t <= s.end);
    if (!sub) return;

    if (sub.image && img) {
      img.src = sub.image;
      img.style.left = (sub.x || 0) + "%";
      img.style.top = (sub.y || 0) + "%";
      img.style.width = (sub.w > 0 ? sub.w + "%" : "auto");
      img.classList.add("visible");
    } else if (sub.text && txt) {
      txt.textContent = sub.text;
      txt.classList.add("visible");
    }
  }

  function updateBadge(ts) {
    const b = document.getElementById("badge_" + ts);
    if (!b) return;
    if (subsEnabled) {
      b.textContent = "SUB: " + (subLabel || "on") + (tsHasSubData(ts) ? "" : " (no preview data)");
      b.classList.add("visible");
    } else {
      b.classList.remove("visible");
    }
  }

  function showOsd(screenEl) {
    const osd = screenEl.querySelector(".osd");
    if (!osd) return;
    const title = screenEl.getAttribute("data-title") || "Title";
    osd.textContent = "Now Playing: " + title + (subsEnabled ? "  \u00b7  SUB: " + subLabel : "");
    osd.classList.add("visible");
    clearTimeout(osdTimer);
    osdTimer = setTimeout(() => osd.classList.remove("visible"), 4000);
  }

  // ---- Simulated remote keys ----
  function pressTitleMenu() { showScreen("vmgm"); }

  function pressSubtitleMenu() {
    if (currentTs > 0 && document.getElementById("ts" + currentTs + "_menu")) {
      showScreen("ts" + currentTs + "_menu");
    } else {
      flashStatus(currentTs > 0 ? "titleset has no subtitle menu" : "no titleset active");
    }
  }

  function pressEndTitle() {
    if (currentTs > 0) {
      const v = document.getElementById("video_" + currentTs);
      if (v && v.duration) {
        v.currentTime = Math.max(0, v.duration - 0.05); // 'ended' fires -> post command
        return;
      }
    }
    flashStatus("not playing a title");
  }

  // ---- VM status line ----
  function updateStatus() {
    const el = document.getElementById("vm_status");
    if (!el) return;
    let txt = "";
    if (activeScreenId === "vmgm") txt = "VMGM menu 1 (entry=title) \u2014 Main Menu";
    else if (activeScreenId === "vmgm_extras") txt = "VMGM menu 2 \u2014 Extras Menu";
    else {
      const m = activeScreenId.match(/^ts(\d+)_menu$/);
      if (m) txt = "Titleset " + m[1] + " menu (entry=root,subtitle)";
      else {
        const t = activeScreenId.match(/^ts(\d+)_movie$/);
        if (t) txt = "Titleset " + t[1] + " title 1 \u2014 playing" +
          (subsEnabled ? " [sub: " + subLabel + "]" : " [sub: off]");
      }
    }
    el.textContent = txt;
  }

  function flashStatus(msg) {
    const el = document.getElementById("vm_status");
    if (!el) return;
    el.textContent = "\u00bb " + msg;
    el.classList.add("flash");
    clearTimeout(statusTimer);
    statusTimer = setTimeout(() => { el.classList.remove("flash"); updateStatus(); }, 2200);
  }

  // ---- Attach video listeners: subtitle ticks + title-end post command ----
  document.querySelectorAll(".movie-screen video").forEach(v => {
    const ts = v.id.replace(/^video_/, "");
    v.addEventListener("timeupdate", () => {
      if (String(currentTs) === ts) renderSubs(ts, v.currentTime);
    });
    v.addEventListener("ended", () => {
      if (String(currentTs) === ts) {
        showScreen("vmgm"); // titleset <post> { g1 = 0; call vmgm menu; }
        flashStatus("title ended \u2014 post: call vmgm menu");
      }
    });
  });

  // ---- Keyboard = remote ----
  document.addEventListener("keydown", (e) => {
    const k = e.key.toLowerCase();
    if (e.key === "Escape" || k === "m") { e.preventDefault(); pressTitleMenu(); return; }
    if (k === "s") { e.preventDefault(); pressSubtitleMenu(); return; }
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
      activateButton(currentButtons[selectedIndex]);
    }
  });

  // ---- Mouse = remote ----
  document.querySelectorAll(".btn").forEach(b => {
    b.addEventListener("click", () => activateButton(b));
  });

  // ---- Disc start (FPC -> vmgm menu entry title) ----
  showScreen("vmgm");
JSEOF
    echo '</script>'
  } >> "$html_file"

  echo '</body>' >> "$html_file"
  echo '</html>' >> "$html_file"

  echo "============================================================="
  echo " 🌐 HTML Preview generated at file://$(pwd)/$html_file"
  echo "    ${#ANALYSIS_TITLES[@]} titles · ${DETECTED_FORMAT^^} ${WIDTH}x${HEIGHT}"
  echo "    Clips: ${PREVIEW_CLIP_SECONDS}s @ ${PREVIEW_CLIP_WIDTH}px"
  echo "    Subtitle overlays: ${sub_count}/${#ANALYSIS_TITLES[@]}"
  echo "============================================================="
}