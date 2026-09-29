#!/usr/bin/env bash
# Turns the recorded clips and the README GIFs into the JPEG frame
# sequences that composition.html plays. Run from the repository root.
set -euo pipefail
cd "$(dirname "$0")"
rm -rf build/frames && mkdir -p build/frames
for c in clips/*.mp4; do
  n=$(basename "$c" .mp4); mkdir -p build/frames/$n
  ffmpeg -v error -i "$c" -vf fps=30 -q:v 2 build/frames/$n/%04d.jpg &
done
# the wall of README GIFs: 8 seconds of each, from 35% in
for g in roam ql super-agenda present images latex lists links timers footnotes countdown speed-keys menus table-tools refile sparse; do
  d=$(ffprobe -v error -show_entries format=duration -of csv=p=0 ../$g.gif)
  ss=$(python3 -c "print(round(min($d*0.35, max($d-8, 0)), 2))")
  mkdir -p build/frames/wall-$g
  ffmpeg -v error -ss "$ss" -t 8 -i ../$g.gif -vf "fps=15,scale=640:-1:flags=lanczos" -q:v 3 build/frames/wall-$g/%04d.jpg &
done
wait
for d in build/frames/*; do printf '"%s":%s,' "$(basename "$d")" "$(ls "$d" | wc -l | tr -d ' ')"; done |
  sed 's/^/window.FRAMES={/; s/,$/};\n/' > build/frames.js
