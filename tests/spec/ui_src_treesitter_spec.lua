-- Tree-sitter highlighting of src block bodies (org.ui.src_highlight,
-- ui.src_highlight_engine), org-src-fontify-natively with tree-sitter.

local ts = require("org.ui.src_highlight")

-- the parsers bundled with Neovim (lib/nvim/parser: c, lua, vim, ...),
-- which the minimal runtimepath leaves out
local parser_dir = vim.fs.normalize(vim.env.VIMRUNTIME .. "/../../../lib/nvim")

--- Lowercase syntax group names at line l, column c (1-based).
local function groups(l, c)
  return table.concat(
    vim.tbl_map(function(id)
      return vim.fn.synIDattr(id, "name"):lower()
    end, vim.fn.synstack(l, c)),
    " "
  )
end

--- The tree-sitter groups of line l (1-based) as "col-col:@group" strings.
local function hls(l)
  local out = {}
  for _, h in ipairs(ts.highlights_at(0, l - 1)) do
    out[#out + 1] = ("%d-%d:%s"):format(h[1], h[2], h[3])
  end
  return out
end

--- The tree-sitter group covering column c (0-based) of line l, the last
--- one set winning like for Neovim's highlighter.
local function group_at(l, c)
  local g
  for _, h in ipairs(ts.highlights_at(0, l - 1)) do
    if h[1] <= c and c < h[2] then
      g = h[3]
    end
  end
  return g
end

local function has_parser(lang)
  local ok, res = pcall(vim.treesitter.language.add, lang)
  return ok and res and true or false
end

local saved_rtp, saved_ui

local function set_ui(opts)
  local ui = require("org.config").opts.ui
  for k, v in pairs(opts) do
    ui[k] = v
  end
end

describe("tree-sitter src blocks", function()
  before_each(function()
    saved_rtp = vim.o.runtimepath
    if vim.uv.fs_stat(parser_dir .. "/parser") then
      vim.opt.runtimepath:append(parser_dir)
    end
    local ui = require("org.config").opts.ui
    saved_ui = { ui.src_highlight, ui.src_highlight_engine }
  end)
  after_each(function()
    local ui = require("org.config").opts.ui
    ui.src_highlight, ui.src_highlight_engine = saved_ui[1], saved_ui[2]
    vim.o.runtimepath = saved_rtp
  end)

  it("finds the bundled lua parser", function()
    -- (the specs below need it: every Neovim release bundles it)
    ok(has_parser("lua"), "no lua parser under " .. parser_dir)
    eq("lua", ts.ts_lang("lua"))
    eq("vim", ts.ts_lang("vim"))
    eq("c", ts.ts_lang("c"))
  end)

  it("highlights a lua block with @capture.lua groups", function()
    org_buffer({ "* H", "#+begin_src lua :results output", 'local x = "s" -- c', "print(x)", "#+end_src" })
    eq("@keyword.lua", group_at(3, 0))
    eq("@string.lua", group_at(3, 11))
    eq("@comment.lua", group_at(3, 15))
    eq("@function.builtin.lua", group_at(4, 0))
    -- the delimiter lines and the headline get none
    eq({}, hls(1))
    eq({}, hls(2))
    eq({}, hls(5))
  end)

  it("doesn't include the lua syntax: the body is a plain region", function()
    org_buffer({ "* H", "#+begin_src lua", "local x = 1", "#+end_src" })
    eq("orgsrcblock_lua", groups(3, 1))
    eq("orgsrcblock_lua orgblockdelimiter", groups(2, 1))
  end)

  it("follows the aliases and src_lang_modes of a language", function()
    org_buffer({ "#+begin_src viml", "let g:x = 1", "#+end_src", "#+BEGIN_SRC C", "int x;", "#+END_SRC" })
    eq("@keyword.vim", group_at(2, 0))
    -- (C is c through src_lang_modes' default `C = "c"`, or no language)
    if ts.ts_lang("C") then
      eq("@type.builtin.c", group_at(5, 0))
    end
  end)

  it("highlights each row of a capture over several lines", function()
    org_buffer({ "#+begin_src lua", "local s = [[", "two", "]]", "#+end_src" })
    eq("@string.lua", group_at(2, 10))
    eq({ "0-3:@string.lua" }, hls(3))
    eq({ "0-2:@string.lua" }, hls(4))
  end)

  it("ends a block at a headline and at the end of the buffer", function()
    org_buffer({ "#+begin_src lua", "local a", "* Headline", "#+begin_src lua", "return 1" })
    eq("@keyword.lua", group_at(2, 0))
    eq({}, hls(3))
    eq("@keyword.return.lua", group_at(5, 0))
  end)

  it("indented blocks and blocks with an empty body", function()
    org_buffer({ "- item", "  #+begin_src lua", "  local a", "  #+end_src", "#+begin_src lua", "#+end_src", "text" })
    eq("@keyword.lua", group_at(3, 2))
    eq({}, hls(5))
    eq({}, hls(6))
    eq({}, hls(7))
  end)

  it("finds the same blocks whatever row is drawn first", function()
    local lines = {
      "* H",
      "#+begin_src lua",
      "local a",
      "#+end_src",
      "text",
      "#+begin_quote",
      "#+begin_src lua",
      "return 1",
      "#+end_src",
      "#+end_quote",
      "#+begin_example",
      "local not_code",
      "#+end_example",
      "#+begin_src lua",
      "#+end_quote",
      "local b",
      "#+end_src",
      "local after",
    }
    org_buffer(lines)
    local forward = {}
    for l = 1, #lines do
      forward[l] = table.concat(hls(l), " ")
    end
    for _, order in ipairs({ { 18, 1 }, { 16, 1 }, { 12, 1 } }) do
      -- (a fresh state: the next edit's changedtick)
      vim.api.nvim_buf_set_lines(0, 0, 1, false, { "* H" })
      for l = order[1], #lines do
        eq(forward[l], table.concat(hls(l), " "), "line " .. l)
      end
      for l = order[2], #lines do
        eq(forward[l], table.concat(hls(l), " "), "line " .. l)
      end
    end
    eq("@keyword.lua", group_at(3, 0))
    eq("@keyword.return.lua", group_at(8, 0))
    eq("", forward[12])
    -- a stray end line of another kind stays in the block
    eq("@keyword.lua", group_at(16, 0))
    eq("", forward[18])
  end)

  it("highlights again after an edit in the block, not after one elsewhere", function()
    local buf = org_buffer({ "* H", "text", "#+begin_src lua", "local x = 1", "#+end_src" })
    eq("@keyword.lua", group_at(4, 0))
    local parses = ts.parses
    vim.api.nvim_buf_set_lines(buf, 1, 2, false, { "other text" })
    eq("@keyword.lua", group_at(4, 0))
    eq(parses, ts.parses)
    vim.api.nvim_buf_set_lines(buf, 3, 4, false, { "return x" })
    eq("@keyword.return.lua", group_at(4, 0))
    eq(parses + 1, ts.parses)
    -- a line added above the block moves it: its text is the same
    vim.api.nvim_buf_set_lines(buf, 0, 0, false, { "* Top" })
    eq("@keyword.return.lua", group_at(5, 0))
    eq(parses + 1, ts.parses)
  end)

  it("parses an edited block from its tree to the same highlights as from scratch", function()
    local buf = org_buffer({
      "* H",
      "#+begin_src lua",
      "local a = 1",
      "local s = [[",
      "text",
      "]]",
      "return a",
      "#+end_src",
    })
    local function all()
      local out = {}
      for l = 1, vim.api.nvim_buf_line_count(buf) do
        out[l] = table.concat(hls(l), " ")
      end
      return out
    end
    all()
    local edits = {
      { 2, 2, { "local first = true" } }, -- a line added at the start
      { 4, 4, { "-- a comment", "local b = 'x'" } }, -- lines added in the middle
      { 4, 5, {} }, -- a line removed
      { 3, 4, { "local a = [[" } }, -- a string opened: the rest changes
      { 3, 4, { "local a = 2" } }, -- and closed again
      { 7, 7, { "if a then end" } }, -- before the last line
      { 8, 9, {} }, -- the last body line removed
      { 7, 7, { "print(1)", "print(2)" } }, -- lines added at the end
    }
    for i, e in ipairs(edits) do
      local incremental = ts.incremental
      vim.api.nvim_buf_set_lines(buf, e[1], e[2], false, e[3])
      local got = all()
      eq(incremental + 1, ts.incremental, "edit " .. i .. " parsed from the tree")
      ts.refresh(buf)
      eq(all(), got, "edit " .. i)
    end
  end)

  it("highlights a block whose language was typed after the buffer was opened", function()
    local buf = org_buffer({ "* H", "#+begin_src", "local x = 1", "#+end_src" })
    eq({}, hls(3))
    vim.api.nvim_buf_set_lines(buf, 1, 2, false, { "#+begin_src lua" })
    eq("@keyword.lua", group_at(3, 0))
  end)

  it("keeps the Vim syntax for a language without a parser", function()
    if has_parser("fstab") then
      return -- (a fstab parser installed: nothing to check)
    end
    org_buffer({ "#+begin_src fstab", "UUID=1234 / ext4 defaults 0 1", "#+end_src" })
    eq(nil, ts.ts_lang("fstab"))
    eq({}, hls(2))
    ok(groups(2, 1):find("^orgsrcblock_fstab fs"), groups(2, 1))
  end)

  it('src_highlight_engine = "syntax" includes the Vim syntax for every language', function()
    set_ui({ src_highlight_engine = "syntax" })
    org_buffer({ "#+begin_src lua", "local x = 1", "#+end_src" })
    eq(nil, ts.ts_lang("lua"))
    eq({}, hls(2))
    ok(groups(2, 1):find("^orgsrcblock_lua lua"), groups(2, 1))
  end)

  it('src_highlight_engine = "treesitter" leaves a language without a parser plain', function()
    if has_parser("fstab") then
      return
    end
    set_ui({ src_highlight_engine = "treesitter" })
    org_buffer({
      "#+begin_src fstab",
      "UUID=1234 / ext4 defaults 0 1",
      "#+end_src",
      "#+begin_src lua",
      "local x",
      "#+end_src",
    })
    eq("orgblock", groups(2, 1))
    eq("@keyword.lua", group_at(5, 0))
  end)

  it("src_highlight = false turns both off", function()
    set_ui({ src_highlight = false })
    org_buffer({ "#+begin_src lua", "local x = 1", "#+end_src" })
    eq({}, hls(2))
    eq("orgblock", groups(2, 1))
  end)

  it("draws the highlights as extmarks in the window", function()
    org_buffer({ "#+begin_src lua", "local x = 1", "#+end_src" })
    local ns = vim.api.nvim_create_namespace("org.src_highlight")
    local seen = {}
    -- (ephemeral marks: catch them as they are set while drawing)
    local set = vim.api.nvim_buf_set_extmark
    vim.api.nvim_buf_set_extmark = function(b, n, r, c, o)
      if n == ns then
        seen[#seen + 1] = ("%d:%d-%d:%s"):format(r, c, o.end_col, vim.fn.synIDattr(o.hl_group, "name"))
      end
      return set(b, n, r, c, o)
    end
    local okd, err = pcall(vim.cmd, "redraw!")
    vim.api.nvim_buf_set_extmark = set
    ok(okd, err)
    ok(vim.tbl_contains(seen, "1:0-5:@keyword.lua"), vim.inspect(seen))
  end)
end)
