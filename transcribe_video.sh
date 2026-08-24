#!/usr/bin/env bash
set -euo pipefail

# See ./install_transcription_service.sh to install this
IMAGE="localhost/whisperx"
LANGUAGE="en"

# Parse optional arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    --language)
      LANGUAGE="$2"
      shift 2
      ;;
    *)
      if [[ -z "${INPUT_FILE:-}" ]]; then
        INPUT_FILE="$1"
      elif [[ -z "${INPUT_DIR:-}" ]]; then
        INPUT_DIR="$1"
      fi
      shift
      ;;
  esac
done

if [[ -z "${INPUT_FILE:-}" ]]; then
  echo "Usage: $0 [--language CODE] /path/to/input_file [/path/to/input_dir]"
  echo ""
  echo "Options:"
  echo "  --language CODE  Language code (default: en)"
  echo "                  Examples: en, fr, de, es, it, pt, ja, zh, ko, ru, ar, hi"
  echo ""
  echo "Arguments:"
  echo "  input_file       Path to input audio/video file (required)"
  echo "  input_dir        Directory to mount (default: input_file's parent folder)"
  exit 1
fi

# Resolve to absolute paths (helps with volume mounting)
INPUT_FILE="$(realpath "$INPUT_FILE")"

# Default INPUT_DIR to parent directory of INPUT_FILE if not provided
INPUT_DIR="${INPUT_DIR:-$(dirname "$INPUT_FILE")}"
INPUT_DIR="$(realpath "$INPUT_DIR")"

# INPUT_DIR MUST contain INPUT_FILE for the container to access it
if [[ "$(dirname "$INPUT_FILE")" != "$INPUT_DIR" ]]; then
  echo "Error: INPUT_DIR must be the parent directory of INPUT_FILE."
  echo "  INPUT_FILE: $INPUT_FILE"
  echo "  INPUT_DIR:  $INPUT_DIR"
  exit 1
fi

BASENAME="$(basename "$INPUT_FILE")"

# TODO make remaining params configurable (model, device, compute_type, output_format)
podman run --rm -v "${INPUT_DIR}:/data:Z" "$IMAGE" "/data/${BASENAME}" --language "$LANGUAGE" --model small --device cpu --compute_type int8 --output_format srt --output_dir "/data"
