# Promo video

A 92-second 1080p30 promo for org.nvim, meant for YouTube. Everything in it
is generated from this directory, so it can be rebuilt when the UI changes.

```sh
docs/media/video/build.sh                # record, render, encode
docs/media/video/build.sh --skip-record  # reuse clips/*.mp4
```

The result is `out/org-nvim-promo.mp4` plus `out/thumbnail.png`.

## How it's made

| File | What it does |
| --- | --- |
| `tapes/*.tape` | VHS scripts for the seven feature clips (1440x810, drawn 1:1 in the video), using `../demo/init.lua` like the README GIFs |
| `frames.sh` | turns `clips/*.mp4` and 16 README GIFs (the video wall) into JPEG frames under `build/frames/` |
| `composition.html` | the whole video as one page: `window.seek(t)` sets every element for time `t`. Open it in Chrome with `?t=12.5` to look at a moment |
| `render.mjs` | drives headless Chrome through every frame (`node render.mjs --stills 3,12` for PNG stills) |
| `music.py` | synthesises the soundtrack (120 BPM, hits on the scene cuts), so there's no licensing to worry about |
| `build.sh` | runs the steps above and encodes with ffmpeg, normalised to -14 LUFS for YouTube |

Timeline (one bar = 2 s at 120 BPM; `music.py` mirrors these times):

| Time | Scene |
| --- | --- |
| 0–6 | a typed `* TODO` headline, then the logo and wordmark |
| 6–10 | Pure Lua · Zero dependencies · Emacs-compatible · Built for Neovim |
| 10–68 | seven features: outlines, agenda, capture, tables, Babel, clocking, export |
| 68–76 | a wall of the README GIFs: "…and a whole lot more" |
| 76–82 | parity, tests, lines of Lua, dependencies |
| 82–92 | install snippet and GitHub link |

To change a feature scene, edit its tape and the `FEATURES` table in
`composition.html`. If you change scene times, update the constants at the
top of `music.py` too.

Needs `vhs`, `ffmpeg`, Node, Python 3 with numpy and scipy, Google Chrome
(or `CHROME=/path/to/chrome`), and the BlexMono Nerd Font.
