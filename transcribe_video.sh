#!/usr/bin/env bash
set -euo pipefail

IMAGE="localhost/whisperx"
INPUT_FILE="${1:-}"
INPUT_DIR="${2:-}"

if [[ -z "${INPUT_FILE}" || -z "${INPUT_DIR}" ]]; then
  echo "Usage: $0 /path/to/input_file /path/to/input_dir"
  exit 1
fi

# Resolve to absolute paths (helps with volume mounting)
INPUT_FILE="$(realpath "$INPUT_FILE")"
INPUT_DIR="$(realpath "$INPUT_DIR")"

# Ensure INPUT_DIR is the directory that contains INPUT_FILE (optional but avoids confusion)
if [[ "$(dirname "$INPUT_FILE")" != "$INPUT_DIR" ]]; then
  echo "Note: INPUT_DIR does not match dirname(INPUT_FILE)."
  echo "We will still mount INPUT_DIR and pass INPUT_FILE basename into the container."
fi

BASENAME="$(basename "$INPUT_FILE")"

# TODO make all these params configurable, especially language
podman run --rm -v "${PWD}:/data:Z" "$IMAGE" "/data/${BASENAME}" --language en --model small --device cpu --compute_type int8 --output_format srt --output_dir "/data/${INPUT_DIR##*/}"
