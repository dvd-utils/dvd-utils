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
    aa|afar) NORM_LANG_CODE="aa"; NORM_LANG_LABEL="Afar" ;;
    ar|ara|arabic) NORM_LANG_CODE="ar"; NORM_LANG_LABEL="Arabic" ;;
    hy|hye|arm|armenian) NORM_LANG_CODE="hy"; NORM_LANG_LABEL="Armenian" ;;
    eu|baq|eus|basque) NORM_LANG_CODE="eu"; NORM_LANG_LABEL="Basque" ;;
    bn|ben|bengali) NORM_LANG_CODE="bn"; NORM_LANG_LABEL="Bengali" ;;
    bs|bos|bosnian) NORM_LANG_CODE="bs"; NORM_LANG_LABEL="Bosnian" ;;
    bg|bul|bulgarian) NORM_LANG_CODE="bg"; NORM_LANG_LABEL="Bulgarian" ;;
    my|mya|bur|burmese) NORM_LANG_CODE="my"; NORM_LANG_LABEL="Burmese" ;;
    ca|cat|catalan) NORM_LANG_CODE="ca"; NORM_LANG_LABEL="Catalan" ;;
    zh|chi|zho|chinese) NORM_LANG_CODE="zh"; NORM_LANG_LABEL="Chinese" ;;
    chs|zh_cn|chi_sim|chinese_simplified|chinese_\(simplified\)) NORM_LANG_CODE="zh"; NORM_LANG_LABEL="Chinese (Simplified)" ;;
    cht|zh_tw|chi_tra|chinese_traditional|chinese_\(traditional\)) NORM_LANG_CODE="zh"; NORM_LANG_LABEL="Chinese (Traditional)" ;;
    hr|hrv|croatian) NORM_LANG_CODE="hr"; NORM_LANG_LABEL="Croatian" ;;
    cs|ces|cze|czech) NORM_LANG_CODE="cs"; NORM_LANG_LABEL="Czech" ;;
    da|dan|danish) NORM_LANG_CODE="da"; NORM_LANG_LABEL="Danish" ;;
    nl|nld|dut|dutch) NORM_LANG_CODE="nl"; NORM_LANG_LABEL="Dutch" ;;
    en|eng|english) NORM_LANG_CODE="en"; NORM_LANG_LABEL="English" ;;
    eng_sdh|en_sdh|english_sdh) NORM_LANG_CODE="en"; NORM_LANG_LABEL="English (SDH)" ;;
    eng_cc|en_cc|english_cc|english_closed_captions) NORM_LANG_CODE="en"; NORM_LANG_LABEL="English (CC)" ;;
    et|est|estonian) NORM_LANG_CODE="et"; NORM_LANG_LABEL="Estonian" ;;
    fi|fin|finnish) NORM_LANG_CODE="fi"; NORM_LANG_LABEL="Finnish" ;;
    fr|fra|fre|french) NORM_LANG_CODE="fr"; NORM_LANG_LABEL="French" ;;
    fr_ca|fra_ca|fre_ca|french_canadian|french_\(canada\)) NORM_LANG_CODE="fr"; NORM_LANG_LABEL="French (Canada)" ;;
    gl|glg|galician) NORM_LANG_CODE="gl"; NORM_LANG_LABEL="Galician" ;;
    ka|geo|kat|georgian) NORM_LANG_CODE="ka"; NORM_LANG_LABEL="Georgian" ;;
    de|deu|ger|german) NORM_LANG_CODE="de"; NORM_LANG_LABEL="German" ;;
    el|ell|gre|greek) NORM_LANG_CODE="el"; NORM_LANG_LABEL="Greek" ;;
    gu|guj|gujarati) NORM_LANG_CODE="gu"; NORM_LANG_LABEL="Gujarati" ;;
    he|heb|hebrew) NORM_LANG_CODE="he"; NORM_LANG_LABEL="Hebrew" ;;
    hi|hin|hindi) NORM_LANG_CODE="hi"; NORM_LANG_LABEL="Hindi" ;;
    hu|hun|hungarian) NORM_LANG_CODE="hu"; NORM_LANG_LABEL="Hungarian" ;;
    is|isl|ice|icelandic) NORM_LANG_CODE="is"; NORM_LANG_LABEL="Icelandic" ;;
    id|ind|indonesian) NORM_LANG_CODE="id"; NORM_LANG_LABEL="Indonesian" ;;
    it|ita|italian) NORM_LANG_CODE="it"; NORM_LANG_LABEL="Italian" ;;
    ja|jpn|japanese) NORM_LANG_CODE="ja"; NORM_LANG_LABEL="Japanese" ;;
    kn|kan|kannada) NORM_LANG_CODE="kn"; NORM_LANG_LABEL="Kannada" ;;
    kk|kaz|kazakh) NORM_LANG_CODE="kk"; NORM_LANG_LABEL="Kazakh" ;;
    km|khm|cambodian|khmer) NORM_LANG_CODE="km"; NORM_LANG_LABEL="Khmer" ;;
    ko|kor|korean) NORM_LANG_CODE="ko"; NORM_LANG_LABEL="Korean" ;;
    ku|kur|kurdish) NORM_LANG_CODE="ku"; NORM_LANG_LABEL="Kurdish" ;;
    lo|lao|laothian) NORM_LANG_CODE="lo"; NORM_LANG_LABEL="Lao" ;;
    lv|lav|latvian) NORM_LANG_CODE="lv"; NORM_LANG_LABEL="Latvian" ;;
    lt|lit|lithuanian) NORM_LANG_CODE="lt"; NORM_LANG_LABEL="Lithuanian" ;;
    mk|mac|mkd|macedonian) NORM_LANG_CODE="mk"; NORM_LANG_LABEL="Macedonian" ;;
    ms|msa|may|malay) NORM_LANG_CODE="ms"; NORM_LANG_LABEL="Malay" ;;
    ml|mal|malayalam) NORM_LANG_CODE="ml"; NORM_LANG_LABEL="Malayalam" ;;
    mt|mlt|maltese) NORM_LANG_CODE="mt"; NORM_LANG_LABEL="Maltese" ;;
    mr|mar|marathi) NORM_LANG_CODE="mr"; NORM_LANG_LABEL="Marathi" ;;
    mn|mon|mongolian) NORM_LANG_CODE="mn"; NORM_LANG_LABEL="Mongolian" ;;
    ne|nep|nepali) NORM_LANG_CODE="ne"; NORM_LANG_LABEL="Nepali" ;;
    no|nor|nob|norwegian) NORM_LANG_CODE="no"; NORM_LANG_LABEL="Norwegian" ;;
    nn|nno|norwegian_nynorsk) NORM_LANG_CODE="nn"; NORM_LANG_LABEL="Norwegian (Nynorsk)" ;;
    or|ori|odia|oriya) NORM_LANG_CODE="or"; NORM_LANG_LABEL="Odia" ;;
    fa|fas|per|persian|farsi) NORM_LANG_CODE="fa"; NORM_LANG_LABEL="Persian" ;;
    pl|pol|polish) NORM_LANG_CODE="pl"; NORM_LANG_LABEL="Polish" ;;
    pt|por|portuguese) NORM_LANG_CODE="pt"; NORM_LANG_LABEL="Portuguese" ;;
    pt_br|pob|ptb|portuguese_brazilian|portuguese_brazil) NORM_LANG_CODE="pt"; NORM_LANG_LABEL="Portuguese (Brazil)" ;;
    pt_pt|por_pt|portuguese_european) NORM_LANG_CODE="pt"; NORM_LANG_LABEL="Portuguese (Portugal)" ;;
    pa|pan|panjabi|punjabi) NORM_LANG_CODE="pa"; NORM_LANG_LABEL="Punjabi" ;;
    ro|ron|rum|romanian) NORM_LANG_CODE="ro"; NORM_LANG_LABEL="Romanian" ;;
    ru|rus|russian) NORM_LANG_CODE="ru"; NORM_LANG_LABEL="Russian" ;;
    sr|srp|serbian) NORM_LANG_CODE="sr"; NORM_LANG_LABEL="Serbian" ;;
    zh_cn|zh_hans|serbian_latin) NORM_LANG_CODE="sr"; NORM_LANG_LABEL="Serbian (Latin)" ;;
    sk|slk|slo|slovak) NORM_LANG_CODE="sk"; NORM_LANG_LABEL="Slovak" ;;
    sl|slv|slovenian) NORM_LANG_CODE="sl"; NORM_LANG_LABEL="Slovenian" ;;
    es|spa|esl|spanish) NORM_LANG_CODE="es"; NORM_LANG_LABEL="Spanish" ;;
    spa_latin_american|spa_latin_america|spa_la|es_la|spanish_latin_american|spanish_latin_america|es_419) NORM_LANG_CODE="es"; NORM_LANG_LABEL="Spanish (Latin America)" ;;
    es_mx|spa_mx|spanish_mexican) NORM_LANG_CODE="es"; NORM_LANG_LABEL="Spanish (Mexico)" ;;
    sw|swa|swahili) NORM_LANG_CODE="sw"; NORM_LANG_LABEL="Swahili" ;;
    sv|swe|swedish) NORM_LANG_CODE="sv"; NORM_LANG_LABEL="Swedish" ;;
    ta|tam|tamil) NORM_LANG_CODE="ta"; NORM_LANG_LABEL="Tamil" ;;
    te|tel|telugu) NORM_LANG_CODE="te"; NORM_LANG_LABEL="Telugu" ;;
    th|tha|thai) NORM_LANG_CODE="th"; NORM_LANG_LABEL="Thai" ;;
    tr|tur|turkish) NORM_LANG_CODE="tr"; NORM_LANG_LABEL="Turkish" ;;
    uk|ukr|ukrainian) NORM_LANG_CODE="uk"; NORM_LANG_LABEL="Ukrainian" ;;
    ur|urd|urdu) NORM_LANG_CODE="ur"; NORM_LANG_LABEL="Urdu" ;;
    uz|uzb|uzbek) NORM_LANG_CODE="uz"; NORM_LANG_LABEL="Uzbek" ;;
    vi|vie|vietnamese) NORM_LANG_CODE="vi"; NORM_LANG_LABEL="Vietnamese" ;;
    cy|cym|wel|welsh) NORM_LANG_CODE="cy"; NORM_LANG_LABEL="Welsh" ;;
    yue|zh_hk|cantonese) NORM_LANG_CODE="yue"; NORM_LANG_LABEL="Yue (Cantonese)" ;;
    zu|zul|zulu) NORM_LANG_CODE="zu"; NORM_LANG_LABEL="Zulu" ;;
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
