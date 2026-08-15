#!/usr/bin/env bash
set -euo pipefail
DIR="whisperx-container"
FILE="${DIR}/Containerfile"

echo "====================="
echo "Installing whisperx"
echo " in directory ${pwd}/${FILE}"
echo "====================="
mkdir -p "$DIR"

cat > "$FILE" <<'EOF'
FROM python:3.12-slim
RUN apt-get update && apt-get install -y --no-install-recommends ffmpeg git && rm -rf /var/lib/apt/lists/*
RUN pip install --no-cache-dir -U pip &&  pip install --no-cache-dir whisperx
WORKDIR /data
ENTRYPOINT ["whisperx"]
EOF

cd "$DIR"
echo "====================="
echo "Building container..."
echo "====================="
podman build -t localhost/whisperx .
