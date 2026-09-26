# README media

The GIFs and screenshots in the main README are recorded with
[VHS](https://github.com/charmbracelet/vhs), so they can be re-recorded
whenever the UI changes.

- `tapes/*.tape`: one script per demo. `common.tape` holds the shared
  size, font and theme.
- `demo/init.lua`: the config the tapes start Neovim with. It copies
  `demo/*.org` into `$ORG_DEMO_DIR` (a directory under `/tmp`) and turns
  `{{N}}` into the date N days from today, so the agenda always has
  something to show.

## Re-recording

You need `vhs` (`brew install vhs`) and the
[BlexMono Nerd Font](https://www.nerdfonts.com/font-downloads). From the
repository root:

```sh
make media                          # every tape, in parallel
vhs docs/media/tapes/agenda.tape    # a single one
```

To try the demo setup by hand:

```sh
export ORG_DEMO_DIR=/tmp/org-nvim-demo
nvim -u docs/media/demo/init.lua $ORG_DEMO_DIR/notes.org
```
