#!/usr/bin/env bash
# Turns each clip's segment (from scenes.js) and the wall GIFs into the JPEG
# frames composition.html plays.
set -euo pipefail
cd "$(dirname "$0")"
rm -rf build/frames && mkdir -p build/frames
node -e 'global.window = {}; const s = require("./scenes.js");
  for (const c of s.CHAPTERS) for (const f of c.features) console.log(f.clip, f.from, f.to);' |
while read -r clip from to; do
  mkdir -p build/frames/$clip
  ffmpeg -v error -ss "$from" -to "$to" -i clips/$clip.mp4 -vf fps=30 -q:v 2 build/frames/$clip/%04d.jpg &
done
for g in $(node -e 'global.window = {}; console.log(require("./scenes.js").WALL.join(" "))'); do
  d=$(ffprobe -v error -show_entries format=duration -of csv=p=0 ../../$g.gif)
  ss=$(python3 -c "print(round(min($d*0.35, max($d-8, 0)), 2))")
  mkdir -p build/frames/wall-$g
  ffmpeg -v error -ss "$ss" -t 8 -i ../../$g.gif -vf "fps=15,scale=640:-1:flags=lanczos" -q:v 3 build/frames/wall-$g/%04d.jpg &
done
wait
for d in build/frames/*; do printf '"%s":%s,' "$(basename "$d")" "$(ls "$d" | wc -l | tr -d ' ')"; done |
  sed 's/^/window.FRAMES={/; s/,$/};\n/' > build/frames.js
