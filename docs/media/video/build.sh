#!/usr/bin/env bash
# Builds out/org-nvim-promo.mp4 (1080p30, YouTube-ready). See README.md.
#   docs/media/video/build.sh          everything
#   docs/media/video/build.sh --skip-record   reuse the recorded clips
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../../.." && pwd)"

if [[ "${1:-}" != "--skip-record" ]]; then
  cd "$root"
  for t in "$here"/tapes/*.tape; do
    case $t in */common.tape) ;; *) vhs "${t#"$root"/}" >/dev/null & ;; esac
  done
  wait
fi

cd "$here"
[[ -d node_modules ]] || npm install --silent
./frames.sh
python3 music.py build/music.wav
rm -rf build/render && node render.mjs
mkdir -p out
ffmpeg -v error -y -framerate 30 -i build/render/%05d.jpg -i build/music.wav \
  -af loudnorm=I=-14:TP=-1:LRA=11 -c:v libx264 -preset slow -crf 16 -pix_fmt yuv420p \
  -profile:v high -c:a aac -b:a 320k -ar 48000 -shortest -movflags +faststart out/org-nvim-promo.mp4
ffmpeg -v error -y -ss 4.8 -i out/org-nvim-promo.mp4 -frames:v 1 out/thumbnail.png
echo "out/org-nvim-promo.mp4"
