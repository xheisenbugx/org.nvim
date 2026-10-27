-- Spell checking with ui.highlighter = "parser" against the syntax engine:
-- for every example and Emacs fixture file, the words `]s` stops on (with
-- a dictionary of one word, every word it checks) are the same under both
-- engines, but on the lines below, where the parser follows what Emacs's
-- flyspell checks (org-mode-flyspell-verify: org-element's elements and
-- objects) and the syntax engine doesn't.

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h")

-- A comment block's body: flyspell checks it, the syntax engine's orgBlock
-- has no @Spell.
local COMMENT_BLOCK = "a comment block's body"
-- A link over two lines: not checked (Emacs removes flyspell's overlays
-- from links), the syntax engine only finds links on one line.
local LINK = "a link over two lines"
-- Verbatim where org-element finds it (left to right, none starting in
-- another), which ends elsewhere in the syntax engine.
local VERBATIM = "verbatim as org-element finds it"
-- Emphasis in a list item's tag: the tag isn't checked by flyspell, the
-- syntax engine's emphasis groups have @Spell.
local TAG = "emphasis in a list item's tag"
-- Lines the syntax engine draws differently from Emacs (the faces specs):
-- tags with extra colons, a priority cookie in a paragraph, keywords
-- glued to text, invalid footnotes and targets, multi-line macros and inline
-- src blocks, unterminated blocks and links, ...
local FACES = "drawn as Emacs draws it, not as the syntax engine does"

local KNOWN = {
  ["examples/02-markup.org"] = { [403] = COMMENT_BLOCK },
  ["examples/09-agenda.org"] = { [893] = FACES },
  ["examples/13-links.org"] = { [94] = LINK, [95] = LINK },
  ["examples/16-spreadsheet.org"] = { [833] = VERBATIM, [834] = VERBATIM },
  ["examples/18-dynamic-blocks.org"] = { [703] = VERBATIM },
  ["examples/19-export.org"] = { [887] = COMMENT_BLOCK },
  ["examples/21-images-latex.org"] = { [760] = VERBATIM },
  ["examples/22-extras.org"] = { [213] = LINK, [214] = LINK, [891] = FACES },
  ["examples/tutorial.org"] = { [207] = COMMENT_BLOCK },
  ["tests/fixtures/emacs/faces/block.org"] = { [43] = FACES, [76] = COMMENT_BLOCK, [145] = FACES, [146] = FACES },
  ["tests/fixtures/emacs/faces/date.org"] = { [26] = FACES, [27] = FACES, [71] = FACES },
  ["tests/fixtures/emacs/faces/headline.org"] = {
    [28] = FACES,
    [48] = FACES,
    [50] = FACES,
    [55] = FACES,
    [94] = FACES,
    [96] = FACES,
  },
  -- (bare src_LANG, over a line break, and in the body of a src or export
  -- block, where the syntax engine finds no inline src block)
  ["tests/fixtures/emacs/faces/inlinesrc.org"] = {
    [24] = FACES,
    [25] = FACES,
    [26] = FACES,
    [47] = FACES,
    [51] = FACES,
  },
  ["tests/fixtures/emacs/faces/list.org"] = { [32] = TAG, [65] = COMMENT_BLOCK },
  ["tests/fixtures/emacs/faces/meta.org"] = {
    [47] = FACES,
    [59] = FACES,
    [61] = FACES,
    [62] = FACES,
    [70] = FACES,
    [87] = COMMENT_BLOCK,
    [88] = COMMENT_BLOCK,
    [111] = FACES,
  },
  ["tests/fixtures/emacs/faces/object.org"] = {
    [42] = FACES,
    [47] = FACES,
    [54] = FACES,
    [64] = COMMENT_BLOCK,
    [68] = FACES,
    [75] = FACES,
    [76] = FACES,
    [92] = FACES,
    [94] = FACES,
    [95] = FACES,
    [116] = FACES,
    [119] = FACES,
    [121] = FACES,
    [124] = FACES,
    [135] = COMMENT_BLOCK,
  },
  ["tests/fixtures/emacs/faces/table.org"] = {
    [63] = FACES,
    [65] = FACES,
    [68] = FACES,
    [69] = FACES,
    [71] = FACES,
    [72] = FACES,
    [73] = FACES,
    [74] = FACES,
    [76] = FACES,
    [77] = FACES,
    [78] = FACES,
    [79] = FACES,
    [81] = FACES,
    [82] = FACES,
    [107] = FACES,
  },
  ["tests/fixtures/emacs/fontify/cases.org"] = {
    -- ("*a =b* c=": org-element finds the bold first, and no verbatim
    -- after it; the parser highlighter only skips verbatim that opens in
    -- verbatim, and leaves "c" out like the faces)
    [16] = "verbatim opening in bold",
    [30] = VERBATIM,
    [63] = TAG,
    [64] = TAG,
    [66] = TAG,
    [143] = COMMENT_BLOCK,
    [183] = FACES,
    [184] = FACES,
    [186] = FACES,
    [187] = FACES,
    [189] = LINK,
    [190] = LINK,
    [191] = LINK,
    [192] = LINK,
    [246] = FACES,
    [247] = FACES,
    [266] = FACES,
    [276] = FACES,
    [281] = FACES,
    [283] = FACES,
    [284] = FACES,
  },
}

-- Captions are spell checked, as by flyspell (the syntax engine's
-- orgKeywordValue has no @Spell), but not their links and timestamps.
local function caption(line)
  return line:find("^[ \t]*#%+[cC][aA][pP][tT][iI][oO][nN]") ~= nil
end

local spell_dir = vim.fn.tempname()
vim.fn.mkdir(spell_dir .. "/spell", "p")
vim.fn.writefile({ "zzzzq" }, spell_dir .. "/words")
vim.cmd("silent mkspell! " .. spell_dir .. "/spell/zz " .. spell_dir .. "/words")
vim.opt.runtimepath:append(spell_dir)

--- The words `]s` stops on in `lines` drawn by `engine`: "line:col" -> word.
local function words(lines, engine)
  local ui = require("org.config").opts.ui
  local saved = ui.highlighter
  ui.highlighter = engine
  local got = {}
  local ok, err = pcall(function()
    local buf = org_buffer(lines, { 1, 0 })
    vim.wo.spell = true
    vim.wo.foldenable = false
    vim.bo[buf].spelllang = "zz"
    vim.bo[buf].spellcapcheck = ""
    vim.bo[buf].spelloptions = ""
    local wrapscan = vim.o.wrapscan
    vim.o.wrapscan = false
    local function add()
      local p = vim.api.nvim_win_get_cursor(0)
      local key = p[1] .. ":" .. p[2]
      if got[key] then
        return false
      end
      got[key] = vim.fn.spellbadword()[1]
      return true
    end
    if vim.fn.spellbadword()[1] ~= "" then
      add()
    end
    while pcall(vim.cmd, "silent normal! ]s") and add() do
    end
    vim.o.wrapscan = wrapscan
  end)
  ui.highlighter = saved
  assert(ok, err)
  return got
end

--- The lines where the engines check other words: "line: word (engine)".
local function differences(lines, known)
  local s, p = words(lines, "syntax"), words(lines, "parser")
  local out = {}
  local function add(k, w, who)
    local l = tonumber(k:match("^(%d+)"))
    if not (known or {})[l] and not caption(lines[l]) then
      out[#out + 1] = { l, string.format("%d: %s (%s only) | %s", l, w, who, lines[l]) }
    end
  end
  for k, w in pairs(s) do
    if not p[k] then
      add(k, w, "syntax")
    end
  end
  for k, w in pairs(p) do
    if not s[k] then
      add(k, w, "parser")
    end
  end
  table.sort(out, function(a, b)
    return a[1] < b[1] or (a[1] == b[1] and a[2] < b[2])
  end)
  return vim.tbl_map(function(d)
    return d[2]
  end, out)
end

describe("parser highlighter spelling against the syntax engine", function()
  local files = vim.fn.globpath(root .. "/examples", "*.org", false, true)
  vim.list_extend(files, vim.fn.globpath(root .. "/tests/fixtures/emacs", "**/*.org", false, true))
  table.sort(files)
  for _, f in ipairs(files) do
    -- (KNOWN's keys use "/", Windows paths "\\")
    local name = f:sub(#root + 2):gsub("\\", "/")
    it(name, function()
      local diffs = differences(vim.fn.readfile(f), KNOWN[name])
      eq("", table.concat(diffs, "\n", 1, math.min(#diffs, 25)))
    end)
  end
end)

describe("parser highlighter spelling", function()
  with_config({ ui = { highlighter = "parser" } })

  --- The words checked on line 1 of `lines` (in order).
  local function checked(lines)
    local got = words(lines, "parser")
    local out = {}
    for k, w in pairs(got) do
      local l, c = k:match("^(%d+):(%d+)$")
      if tonumber(l) == 1 then
        out[#out + 1] = { tonumber(c), w }
      end
    end
    table.sort(out, function(a, b)
      return a[1] < b[1]
    end)
    return table.concat(
      vim.tbl_map(function(x)
        return x[2]
      end, out),
      " "
    )
  end

  it("]s skips what the screen leaves out (the marks of the decoration provider)", function()
    eq("see and", checked({ "see =verbatim= and ~code~ [[https://x.org]]" }))
  end)

  it("checks verbatim's text after its closing marker opened another", function()
    -- (font-lock draws ", the rest" in verbatim too)
    eq("a the rest", checked({ 'a =x = "y"=, the rest', "=z=" }))
  end)

  it("checks emphasis in table rows, not the rest of them", function()
    eq("bold", checked({ "| *bold* | plain | =v= |" }))
  end)

  it("checks the objects of a comment but its links", function()
    eq("see fn and", checked({ "# see [fn:1] and [[https://x.org]]" }))
  end)

  it("checks captions but their links and timestamps", function()
    eq("A table at", checked({ "#+CAPTION: A table at [2026-01-01 Thu] [[https://x.org]]" }))
  end)

  it("leaves keywords and block lines out, also in quote blocks", function()
    eq("", checked({ "#+NAME: some name" }))
    eq("", checked({ "#+end_quote" }))
    eq("", checked({ "#+1x: digits first" }))
    local buf_words = words({ "#+begin_quote", "#+keyword: in the quote", "text", "#+end_quote" }, "parser")
    eq({ ["3:0"] = "text" }, buf_words)
  end)

  it("checks lines that aren't keywords to org-element", function()
    eq("key without colon", checked({ "#+key without colon" }))
    eq("a tab", checked({ "#\ta tab" }))
  end)
end)
