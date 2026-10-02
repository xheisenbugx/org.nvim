-- ob-lilypond, checked against Emacs Org 9.8.10 (`emacs --batch`) with the
-- same fake lilypond (not installed), which logs its arguments and input
-- and makes OUT.pdf and OUT.midi, and a fake viewer. Arrange mode was run
-- in Emacs with a stub LilyPond-mode for the comment syntax.
local config = require("org.config")
local h = require("tests.helpers.babel_ob")

local FAKE_LILYPOND = [[
log="$(dirname "$0")/lily.log"
echo "lilypond $*" >> "$log"
for a in "$@"; do case $a in --output=*) out=${a#--output=};; esac; last=$a; done
cat "$last" >> "$log"
echo "---" >> "$log"
: > "$out.pdf"
: > "$out.midi"
: > "$out.mid"]]
-- the MIDI file played: .mid on Windows, like Emacs (system-type windows-nt)
local MIDI = vim.fn.has("win32") == 1 and ".mid" or ".midi"

local PAPER = {
  "#(if (ly:get-option 'use-paper-size-for-page)",
  "            (begin (ly:set-option 'use-paper-size-for-page #f)",
  "                   (ly:set-option 'tall-page-formats 'png)))",
  "\\paper {",
  "  indent=0\\mm",
  '  tagline=""',
  "  oddFooterMarkup=##f",
  "  oddHeaderMarkup=##f",
  "  bookTitleMarkup=##f",
  "  scoreTitleMarkup=##f",
  "}",
}

describe("babel ob-lilypond", function()
  local lily, viewer, dir
  before_each(function()
    config.opts.babel.confirm_evaluate = false
    dir = h.tmpdir()
    lily = h.fake(dir, "lilypond", FAKE_LILYPOND)
    viewer = h.fake(dir, "viewer", 'echo "viewer $*" >> "$(dirname "$0")/lily.log"')
    h.set_lang("lilypond", { commands = { lily, viewer, viewer } })
  end)
  after_each(h.restore)

  it("expands $variables (org-babel-expand-body:lilypond)", function()
    -- Emacs 9.8.10
    eq(
      "% pro\n\\relative { c4 d e }",
      h.expand({
        '#+begin_src lilypond :file music.png :var n="c4" :prologue "% pro"',
        "\\relative { $n d e }",
        "#+end_src",
      })
    )
  end)

  it("engraves a block to its :file in basic mode", function()
    local out = h.run({
      '#+begin_src lilypond :file m.pdf :cmdline "-dx "',
      "{ c }",
      "#+end_src",
      "",
      '#+begin_src lilypond :file music.png :var n="c4" :prologue "% pro"',
      "\\relative { $n d e }",
      "#+end_src",
    }, dir)
    eq({ "#+RESULTS:", "[[file:m.pdf]]" }, vim.list_slice(out, 5, 6))
    local log = vim.fn.readfile(dir .. "/lily.log")
    -- Emacs 9.8.10: the generic expansion is engraved (no $n substitution)
    local flags = "^lilypond %-dbackend=eps %-dno%-gs%-load%-fonts %-dinclude%-eps%-fonts "
    ok(log[1]:match(flags .. "%-%-pdf %-%-output=m %-dx %S+$"))
    eq("                   (ly:set-option 'tall-page-formats 'pdf)))", log[4])
    eq("{ c }---", log[13])
    ok(log[14]:match(flags .. "%-%-png %-%-output=music %S+$"))
    eq(vim.list_extend(vim.deepcopy(PAPER), { "% pro", "\\relative { $n d e }---" }), vim.list_slice(log, 15, 27))
  end)

  it("tangles, engraves and opens the results in arrange mode", function()
    local lp = require("org.babel.lang.lilypond")
    h.set_lang("lilypond", { gen_png = true })
    eq(true, lp.toggle_arrange_mode())
    eq(
      { tangle = "yes", noweb = "yes", results = "silent", cache = "yes", comments = "yes" },
      config.opts.babel.languages.lilypond.default_header_args
    )
    local buf = org_buffer({
      "* Score",
      '#+begin_src lilypond :var n="c4"',
      "\\relative { $n d e }",
      "#+end_src",
      "",
      "#+begin_src lilypond",
      "\\layout { }",
      "#+end_src",
    }, { 3, 0 })
    vim.api.nvim_buf_set_name(buf, dir .. "/score.org")
    require("org.babel").execute_block({ sync = true, skip_confirm = true })
    -- Emacs 9.8.10
    eq({
      "% [[file:score.org::*Score][Score:1]]",
      "\\relative { c4 d e }",
      "% Score:1 ends here",
      "",
      "% [[file:score.org::*Score][Score:2]]",
      "\\layout { }",
      "% Score:2 ends here",
    }, vim.fn.readfile(dir .. "/score.ly"))
    -- the viewers run asynchronously: slow under parallel spec jobs
    vim.wait(10000, function()
      return #vim.fn.readfile(dir .. "/lily.log") >= 11
    end)
    local log = vim.fn.readfile(dir .. "/lily.log")
    eq("lilypond --png --output=" .. dir .. "/score " .. dir .. "/score.ly", log[1])
    -- the viewer and the player run at the same time
    local shown = vim.list_slice(log, 10, 11)
    table.sort(shown)
    eq({ "viewer " .. dir .. "/score" .. MIDI, "viewer " .. dir .. "/score.pdf" }, shown)
    eq(false, lp.toggle_arrange_mode())
    eq({ results = "file", exports = "results" }, config.opts.babel.languages.lilypond.default_header_args)
  end)

  it("toggles its options", function()
    local lp = require("org.babel.lang.lilypond")
    local o = config.opts.babel.languages.lilypond
    eq(true, lp.toggle_png_generation())
    eq(true, o.gen_png)
    eq(false, lp.toggle_png_generation())
    eq(true, lp.toggle_html_generation())
    eq(true, lp.toggle_pdf_generation())
    eq(false, lp.toggle_midi_play())
    eq(false, lp.toggle_pdf_display())
    eq(false, o.play_midi_post_tangle)
  end)

  it("finds the line of a compilation error", function()
    eq(3, require("org.babel.lang.lilypond").parse_line_num("/x/score.ly:3:5: error: syntax error\n  c d"))
  end)
end)
