#!/usr/bin/env bash

# Shared utility functions for DVD Builder

run_logged() {
  local log="$1"; shift
  if ! "$@" >"$log" 2>&1; then
    echo "=============================================================" >&2
    echo " ERROR: Command failed!" >&2
    echo " Command: $*" >&2
    echo "-------------------------------------------------------------" >&2
    echo " Last 20 lines of $log:" >&2
    tail -n 20 "$log" >&2
    echo "=============================================================" >&2
    return 1
  fi
}
normalize_str() {
  local s="$1"
  s="${s%_pal}"; s="${s%_PAL}"
  s="${s%.sub.idx}"; s="${s%.idx}"; s="${s%.sup}"
  s="${s,,}"             # lowercase
  s="${s//[^a-z0-9]/}"   # strip all non-alphanumerics (spaces, underscores, dashes)
  echo "$s"
}
prettify_filename() {
  local file="$1"
  local base="$(basename "$file" .mpg)"
  base="${base%_pal}"
  base="${base%_PAL}"
  local words=(${base//_/ })
  echo "${words[@]^}"
}
normalize_language() {
  local raw="$1"
  local lang_lower="${raw,,}"
  lang_lower="${lang_lower//-/_}"
  lang_lower="${lang_lower// /_}"

  case "$lang_lower" in
    nl|nld|dut|dutch) NORM_LANG_CODE="nl"; NORM_LANG_LABEL="Dutch" ;;
    en|eng|english) NORM_LANG_CODE="en"; NORM_LANG_LABEL="English" ;;
    eng_sdh|en_sdh) NORM_LANG_CODE="en"; NORM_LANG_LABEL="English (SDH)" ;;
    spa_latin_american|spa_latin_america|spa_la|es_la|spanish_latin_american|spanish_latin_america) NORM_LANG_CODE="es"; NORM_LANG_LABEL="Spanish (Latin American)" ;;
    spa|es|esl|spanish) NORM_LANG_CODE="es"; NORM_LANG_LABEL="Spanish" ;;
    fra|fre|fr|french) NORM_LANG_CODE="fr"; NORM_LANG_LABEL="French" ;;
    ger|deu|de|german) NORM_LANG_CODE="de"; NORM_LANG_LABEL="German" ;;
    *)
      NORM_LANG_CODE="${lang_lower%%_*}"
      NORM_LANG_CODE="${NORM_LANG_CODE%%-*}"
      local clean_label="${raw//_/ }"
      clean_label="${clean_label//-/ }"
      if [[ "$lang_lower" == *sdh* ]]; then
        clean_label="$(echo "$clean_label" | sed -E 's/[sS][dD][hH]//g' | xargs)"
        clean_label="${clean_label} (SDH)"
      fi
      local words=($clean_label)
      NORM_LANG_LABEL="${words[@]^}" ;;
  esac
}