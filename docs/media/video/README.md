# Promo videos

Two 1080p30 promos for org.nvim, meant for YouTube. Everything in them is
generated from this directory, so they can be rebuilt when the UI changes.

- The main promo (92 s): the core features. Built by `build.sh`, described below.
- The extensions promo (2:32), in `extensions/`: the 20 extensions and the
  core features the first one skips. See [Extensions video](#extensions-video).

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

`base.css` holds the styles both compositions share, and `render.mjs`
renders either one (`PAGE=extensions/composition.html node render.mjs`).

## Extensions video

```sh
docs/media/video/extensions/build.sh                # record, render, encode
docs/media/video/extensions/build.sh --skip-record  # reuse extensions/clips/*.mp4
```

The result is `extensions/out/org-nvim-extensions.mp4`.

| File | What it does |
| --- | --- |
| `extensions/record.sh` | records the 16 extension clips from the README tapes in `docs/media/tapes` at video size, so the video and the GIFs show the same thing. The diagrams tape needs `mmdc` (or `$DEMO_MMDC`) |
| `extensions/scenes.js` | the four chapters and their scenes, with the segment of each clip to play |
| `extensions/frames.sh` | cuts those segments, and 16 more README GIFs for the wall, into frames |
| `extensions/composition.html` | the video: 20 extension toggles lighting up, a title card per chapter, a scene per extension, the wall, stats and the outro |
| `extensions/music.py` | a new arrangement of `music.py`'s instruments for this timeline |

Timeline: 0–8 intro, then four chapters (a 2 s card, then 7 s per
extension): See your work (8), Get things done (38), Where code meets notes
(68), Beyond the editor (105); 128–136 the wall of core features, 136–142
stats, 142–152 outro. `music.py` mirrors these times.

Needs `vhs`, `ffmpeg`, Node, Python 3 with numpy and scipy, Google Chrome
(or `CHROME=/path/to/chrome`), and the BlexMono Nerd Font.
