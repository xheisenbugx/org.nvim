# README media

The GIFs and screenshots in the main README are recorded with
[VHS](https://github.com/charmbracelet/vhs), so they can be re-recorded
whenever the UI changes.

- `tapes/*.tape`: one script per demo. `common.tape` holds the shared
  size, font and theme.
- `demo/init.lua`: the config the tapes start Neovim with. It copies
  `demo/*.org` into `$ORG_DEMO_DIR` (a directory under `/tmp`) and turns
  `{{N}}` into the date N days from today, so the agenda always has
  something to show. It also defines `:Cap` and `:Do`, which show the key
  caption in the corner, and `:Do` presses keys that VHS can't send
  (`<S-Right>`, `<M-Up>`…). The tapes type them hidden, after `<C-g>`.
- `demo/roam.lua`: `init.lua` with the org-roam extension on, for
  `roam.tape`; it copies `demo/roam/*.org` into `$ORG_DEMO_DIR/roam`.

## Re-recording

You need `vhs` (`brew install vhs`) and the
[BlexMono Nerd Font](https://www.nerdfonts.com/font-downloads). From the
repository root:

```sh
make media                          # every tape, in parallel
vhs docs/media/tapes/agenda.tape    # a single one
```

Some tapes set extras in the environment (see the top of
`demo/init.lua`): `DEMO_SNACKS=1` uses snacks.nvim's picker and notifier
(from `$SNACKS_PATH`, else the lazy.nvim directory), `DEMO_SPEED=1` turns
on speed keys, and `DEMO_NOTIFY=1` adds `demo/reminders.org`, whose
entries `{{now+1}}` put a minute from now, for the reminders demo.

`demo/present.lua` is `init.lua` with the `present` extension turned on,
for `present.tape`.

`demo/quickadd.lua` is `init.lua` with the `quickadd` extension turned on,
for `quickadd.tape`; it copies `demo/quickadd/*.org` into `$ORG_DEMO_DIR`.

`demo/review.lua` is `init.lua` with the `review` extension on, for
`review.tape`; it copies `demo/review/*.org` into `$ORG_DEMO_DIR` and adds
them to the agenda files.

`demo/pomodoro.lua` is `init.lua` with the `pomodoro` extension turned on and 9-second pomodoros and 6-second breaks, for `pomodoro.tape`.

`demo/drill.lua` is `init.lua` with the `drill` extension turned on, for
`drill.tape`; it copies `demo/drill/*.org` (the flashcards) into
`$ORG_DEMO_DIR`.

`merge.tape` records a shell session: `demo/merge-setup.sh` builds a git
repository in `/tmp/org-demo-merge-repo` (a `main` branch and two branches
that changed `tasks.org`), and `demo/merge.lua` is `init.lua` with the
`merge` extension on. It needs `git`.

`demo/ics.lua` is `init.lua` with the `ics` extension subscribed to
`demo/ics-*.ics` (their `{{N}}` become the date N days from today, as
YYYYMMDD), for `ics.tape`.

`tapes/cli.tape` records a shell session with `bin/org` on `$PATH` and
`demo/cli.lua` as its config (`$ORG_NVIM_CONFIG`); that file copies
`work.org`, `life.org` and `inbox.org` into `$ORG_DEMO_DIR` on its first
run. It needs `jq`.

`demo/diagrams.lua` is `init.lua` with the `diagrams` extension on (and
render on save), for `diagrams.tape`. It needs mermaid-cli: `mmdc` on
`$PATH`, or its path in `DEMO_MMDC`, and `DEMO_MMDC_PUPPETEER` can name a
puppeteer config file, e.g. `{"executablePath": "/Applications/Google
Chrome.app/Contents/MacOS/Google Chrome"}` for an `mmdc` installed with
`PUPPETEER_SKIP_DOWNLOAD=1 npm install @mermaid-js/mermaid-cli`.

`demo/code.lua` (for `code.tape`) turns on the `code` extension and makes
a small git repository in `$ORG_DEMO_DIR/app` (branch `feature/login`),
so it needs `git`. `demo/literate.lua` (for `literate.tape`) turns on the
`literate` extension for `$ORG_DEMO_DIR/nvim/init.org`, which tangles to
`lua/config.lua` next to it.

To try the demo setup by hand:

```sh
export ORG_DEMO_DIR=/tmp/org-nvim-demo
nvim -u docs/media/demo/init.lua $ORG_DEMO_DIR/notes.org
```

## Images (kitty)

`images.gif` and `latex.gif` show images drawn with the Kitty graphics
protocol, which VHS's terminal can't display. `kitty/record.py` records
them in a real kitty window instead: it drives Neovim through kitty's
remote control, captures the window with `screencapture` and builds the
GIF with ffmpeg (and gifsicle when installed). macOS only; it needs kitty,
ffmpeg, swiftc, Neovim 0.13+ and Screen Recording permission for the
terminal that runs it. LaTeX needs `latex` + `dvipng` or `tectonic`.

```sh
python3 docs/media/kitty/record.py          # both
python3 docs/media/kitty/record.py latex    # one
```
