-- Screen snapshots: what an org buffer looks like on screen, text and
-- highlight groups, compared with tests/fixtures/screen/*.txt. They catch
-- rendering bugs text-based specs miss (#118 stars drawn as bold markup,
-- #119 folded headlines losing their faces, #121 highlighting stopping
-- after a long line). ORG_UPDATE_SNAPSHOTS=1 rewrites the golden files;
-- see tests/screen.lua.
local Screen = require("tests.screen")

local screen

--- A child Neovim of `width` x `height` with org set up with `setup`.
local function new(setup, width, height, now)
  screen = Screen.new({ width = width or 60, height = height or 12, setup = setup, now = now })
  return screen
end

local HEADLINES = {
  "* TODO [#A] Level one :work:",
  "Body text of level one.",
  "** NEXT [#B] Level two :home:errand:",
  "*** DONE [#C] Level three",
  "**** Level four with [#A] priority :deep:",
  "***** TODO Level five",
  "* COMMENT A commented headline",
}

describe("screen snapshot", function()
  after_each(function()
    if screen then
      screen:close()
      screen = nil
    end
  end)

  it("headline levels 1-5 with TODO keywords, priorities and tags", function()
    new({ todo_keywords = { "TODO", "NEXT", "|", "DONE" } })
    screen:org(HEADLINES)
    screen:expect("headlines")
  end)

  -- #118: the stars of a level 3+ headline aren't bold markup
  local EMPHASIS = {
    "* *bold* one",
    "** *bold* two",
    "*** *bold* three",
    "**** /italic/ and *bold* four",
    "***** _under_ =verbatim= ~code~ +strike+ five",
    "Body with *bold*, /italic/ and =verbatim=.",
  }

  it("emphasis next to headline stars", function()
    new()
    screen:org(EMPHASIS)
    screen:expect("emphasis_stars")
  end)

  it("emphasis next to headline stars with hide_emphasis_markers", function()
    new({ ui = { hide_emphasis_markers = true } })
    screen:org(EMPHASIS)
    screen:expect("emphasis_stars_hidden")
  end)

  it("emphasis next to headline bullets with hide_emphasis_markers", function()
    new({ ui = { hide_emphasis_markers = true, bullets = { "◉", "○", "✸", "✿" } } })
    screen:org(EMPHASIS)
    screen:expect("emphasis_bullets_hidden")
  end)

  -- #119: a closed fold keeps the faces of its headline
  it("folded headlines keep their keyword, priority and tag faces", function()
    new({ todo_keywords = { "TODO", "NEXT", "|", "DONE" } })
    screen:org({
      "* TODO [#A] Folded task with [[https://orgmode.org][a link]] :work:",
      "Hidden body.",
      "** DONE Hidden child",
      "* NEXT *Bold* folded :home:",
      "Hidden body.",
      "* Open headline without body",
    })
    screen:cmd("normal! zM")
    screen:expect("folded_headlines")
  end)

  -- #121: highlighting goes on after a line of thousands of characters
  it("highlights after a 2000-character line", function()
    new(nil, 60, 10)
    local prose = string.rep("I would like the board to be set to a certain color. *ok* ", 40):sub(1, 2000)
    screen:org({
      "* TODO Long lines :tag:",
      "",
      prose,
      "",
      "- " .. prose .. ":: term",
      "",
      "** Prompt *bold* [[https://orgmode.org][link]]",
      "SCHEDULED: <2026-10-02 Fri>",
    })
    screen:expect("long_line")
  end)

  -- markup that ends past a 'synmaxcol' lowered after the syntax was set
  -- up isn't drawn, and doesn't go on over the lines below
  it("follows a lowered 'synmaxcol'", function()
    new(nil, 60, 8)
    screen:org({
      string.rep("word ", 20):sub(1, 96) .. " *starts here and* ends after",
      "plain text",
      "* Next *bold*",
    })
    screen:cmd("setlocal synmaxcol=110")
    screen:expect("synmaxcol_lowered")
  end)

  it("conceals link brackets and targets", function()
    new()
    screen:org({
      "* Links",
      "A [[https://orgmode.org][described link]] in text.",
      "A bare [[https://neovim.io]] link.",
      "A plain https://example.com/path link.",
      "A [[file:notes.org::*Heading][file link]] and <<target>>.",
      "A footnote[fn:1] and a radio <<<radio>>> target.",
    })
    screen:expect("links")
  end)

  it("lists and checkboxes", function()
    new()
    screen:org({
      "* Tasks [1/3] [33%]",
      "- [ ] open item",
      "- [X] done item",
      "- [-] partial item",
      "  1. ordered child",
      "  2) other child",
      "+ term :: description",
      "* Fancy",
      "- [ ] icon",
      "- [X] icon",
    })
    screen:expect("lists")
  end)

  it("checkbox icons", function()
    new({ ui = { checkboxes = { "☐", "◐", "☑" } } })
    screen:org({
      "- [ ] open item",
      "- [X] done item",
      "- [-] partial item",
    })
    screen:expect("checkbox_icons")
  end)

  it("tables", function()
    new()
    screen:org({
      "#+NAME: scores",
      "| Name  | Score |",
      "|-------+-------|",
      "| Alice |    10 |",
      "| *Bob* |     7 |",
      "#+TBLFM: $2=$2+1",
    })
    screen:expect("table")
  end)

  it("source blocks", function()
    new()
    screen:org({
      "#+TITLE: Blocks",
      "#+begin_src lua :results output",
      'local x = "string" -- comment',
      "print(x)",
      "#+end_src",
      "#+begin_quote",
      "A *quote*.",
      "#+end_quote",
      ": fixed width",
      "# a comment",
    })
    screen:expect("blocks")
  end)

  it("timestamps, planning and clocks", function()
    new()
    screen:org({
      "* TODO Planned",
      "DEADLINE: <2026-10-09 Fri> SCHEDULED: <2026-10-02 Fri 10:00 +1w>",
      ":LOGBOOK:",
      "CLOCK: [2026-10-01 Thu 09:00]--[2026-10-01 Thu 10:30] =>  1:30",
      ":END:",
      "Active <2026-10-02 Fri>, inactive [2026-10-01 Thu],",
      "range <2026-10-02 Fri>--<2026-10-04 Sun>.",
      "* DONE Closed",
      "CLOSED: [2026-10-01 Thu 18:00]",
    })
    screen:expect("timestamps")
  end)

  it("drawers folded when the file opens", function()
    -- Emacs leaves drawers open with showeverything, the default
    new({ startup_folded = "showall" })
    screen:org({
      "* Headline",
      ":PROPERTIES:",
      ":ID: 1234",
      ":CUSTOM: value",
      ":END:",
      ":LOGBOOK:",
      "- Note taken on [2026-10-01 Thu 09:00]",
      ":END:",
      "Body after the drawers.",
    })
    screen:expect("drawers_folded")
  end)

  it("VISIBILITY: all leaves drawers open under nohidedrawers", function()
    new()
    screen:org({
      "#+STARTUP: overview nohidedrawers",
      "* Headline",
      ":PROPERTIES:",
      ":VISIBILITY: all",
      ":END:",
      ":LOGBOOK:",
      "- Note taken on [2026-10-01 Thu 09:00]",
      ":END:",
      "Body after the drawers.",
      "* Folded",
      "Hidden body.",
    })
    screen:expect("visibility_all_drawers_open")
  end)

  it("a day agenda", function()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    local file = dir .. "/agenda.org"
    vim.fn.writefile({
      "* TODO [#A] Call Alice :work:",
      "SCHEDULED: <2026-10-02 Fri 09:00>",
      "* NEXT Write report",
      "DEADLINE: <2026-10-02 Fri>",
      "* DONE Morning run :health:",
      "SCHEDULED: <2026-10-02 Fri 07:00>",
      "* Meeting",
      "<2026-10-02 Fri 14:00-15:00>",
      "* TODO Overdue thing",
      "SCHEDULED: <2026-09-30 Wed>",
    }, file)
    new({
      todo_keywords = { "TODO", "NEXT", "|", "DONE" },
      agenda_files = { file },
      org_directory = dir,
      agenda = { window = "only" },
    }, 70, 20, { year = 2026, month = 10, day = 2, hour = 10, min = 0 })
    screen:lua([[require("org.agenda").open_agenda({ span = "day" })]])
    screen:expect("agenda_day")
    vim.fn.delete(dir, "rf")
  end)

  it("a picker wider than its rows for its title and footer", function()
    -- the export dispatcher's # (insert template) picker: short rows, a
    -- longer title and footer that used to be cut off at the rows' width
    new(nil, 60, 14)
    screen:org({ "#+TITLE: Hello", "", "* A" })
    screen:input(" oe")
    screen:request("nvim_eval", "1")
    screen:input("#")
    screen:request("nvim_eval", "1")
    screen:expect("choose_title_footer")
    screen:input("<Esc>")
  end)

  it("fails with a diff when the screen differs, and on a missing golden file", function()
    local dir, update = Screen.dir, vim.env.ORG_UPDATE_SNAPSHOTS
    Screen.dir = vim.fn.tempname()
    vim.env.ORG_UPDATE_SNAPSHOTS = nil
    local ok_run, err = pcall(function()
      new(nil, 30, 3)
      screen:org({ "* TODO Task" })
      local missing_ok, missing = pcall(screen.expect, screen, "golden")
      ok(not missing_ok and missing:match("no golden file"), missing)
      vim.fn.mkdir(Screen.dir, "p")
      vim.fn.writefile({ "screen 30x3", "|* DONE Task|" }, Screen.dir .. "/golden.txt")
      local diff_ok, diff = pcall(screen.expect, screen, "golden")
      ok(not diff_ok and diff:match("differs") and diff:match("\n%-|%* DONE Task|"), diff)
      ok(diff:match("\n%+|{1:%* }{2:TODO}{1: Task}|"), diff)
    end)
    vim.fn.delete(Screen.dir, "rf")
    Screen.dir, vim.env.ORG_UPDATE_SNAPSHOTS = dir, update
    assert(ok_run, err)
  end)
end)
