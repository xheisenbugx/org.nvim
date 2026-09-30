#!/usr/bin/env bash
# Builds out/org-nvim-extensions.mp4, the extension promo. See ../README.md.
#   docs/media/video/extensions/build.sh               everything
#   docs/media/video/extensions/build.sh --skip-record reuse clips/*.mp4
# The diagrams clip needs mmdc; set DEMO_MMDC (and DEMO_MMDC_PUPPETEER) if it
# isn't on $PATH, as for docs/media/tapes/diagrams.tape.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"

[[ "${1:-}" == "--skip-record" ]] || "$here/record.sh"
cd "$here"
[[ -d ../node_modules ]] || (cd .. && npm install --silent)
./frames.sh
python3 music.py build/music.wav
rm -rf build/render && PAGE="$here/composition.html" node ../render.mjs
mkdir -p out
ffmpeg -v error -y -framerate 30 -i build/render/%05d.jpg -i build/music.wav \
  -af loudnorm=I=-14:TP=-1:LRA=11 -c:v libx264 -preset slow -crf 16 -pix_fmt yuv420p \
  -profile:v high -c:a aac -b:a 320k -ar 48000 -shortest -movflags +faststart out/org-nvim-extensions.mp4
ffmpeg -v error -y -ss 5.2 -i out/org-nvim-extensions.mp4 -frames:v 1 out/thumbnail.png
echo "out/org-nvim-extensions.mp4"
