---@mod org.ui.src_highlight Tree-sitter highlighting of src block bodies
---
--- org-src-fontify-natively with tree-sitter: when the language of a
--- `#+begin_src <lang>` block has a tree-sitter parser and a highlights
--- query, its body is drawn with the query's captures (`@keyword.lua`,
--- `@string.c`, ...) as Neovim draws a buffer of that language, instead of
--- the language's Vim syntax included into the org syntax (see
--- `ui.src_highlight_engine`).
---
--- A decoration provider draws the rows windows draw, nothing else: a row
--- is placed in its block when it is first drawn after a change (found by
--- going up to the nearest block delimiter or headline), and a block is
--- parsed only when its text is not one parsed before. Moving around and
--- editing outside a block don't parse it again. Blocks of up to
--- `inject_max` lines are parsed with their injected languages; a longer
--- one is parsed again from its previous tree after an edit in it.

local M = {}

local ns = vim.api.nvim_create_namespace("org.src_highlight")

local attached = {} ---@type table<integer, boolean>

--- Captures that don't name a highlight.
local SKIP = { spell = true, nospell = true, conceal = true }

-- Tree-sitter language per Vim syntax name (false: none), for the
-- 'runtimepath' it was looked up with (a parser added to it is found).
local ts_of_syntax = {} ---@type table<string, string|false>
local ts_rtp ---@type string?

---@return "auto"|"treesitter"|"syntax"|false
local function engine()
  local ui = require("org.config").opts.ui or {}
  if ui.src_highlight == false then
    return false
  end
  local e = ui.src_highlight_engine
  if e == "treesitter" or e == "syntax" then
    return e
  end
  return "auto"
end
M.engine = engine

--- The tree-sitter language of src blocks whose Vim syntax is `syn` (see
--- `org.syntax.syntax_of`), when Neovim has a parser and a highlights query
--- for it.
---@param syn string
---@return string?
function M.ts_lang_of_syntax(syn)
  local rtp = vim.o.runtimepath
  if ts_rtp ~= rtp then
    ts_rtp, ts_of_syntax = rtp, {}
  end
  local v = ts_of_syntax[syn]
  if v == nil then
    v = false
    if syn ~= "" and syn ~= "org" and syn:match("^[%w_]+$") then
      local okl, l = pcall(vim.treesitter.language.get_lang, syn)
      local lang = okl and l or syn
      local oka, added = pcall(vim.treesitter.language.add, lang)
      if oka and added then
        local okq, query = pcall(vim.treesitter.query.get, lang, "highlights")
        if okq and query then
          v = lang
        end
      end
    end
    ts_of_syntax[syn] = v
  end
  return v or nil
end

--- The tree-sitter language src blocks of `lang` are highlighted with, or
--- nil when they aren't (no parser or query, or `src_highlight_engine` is
--- "syntax").
---@param lang string
---@return string?
function M.ts_lang(lang)
  local e = engine()
  if not e or e == "syntax" then
    return nil
  end
  return M.ts_lang_of_syntax(require("org.syntax").syntax_of(lang))
end

-- Line kinds -------------------------------------------------------------

local function is_headline(line)
  return line:byte(1) == 42 and line:find("^%*+%s") ~= nil
end

--- For a `#+begin_` line: the kind ("src", "quote", ...) and the language.
local function begin_of(line)
  local kind = line:match("^%s*#%+[bB][eE][gG][iI][nN]_(%S+)")
  if not kind then
    return nil
  end
  kind = kind:lower()
  local lang = (kind == "src" or kind == "export") and line:match("^%s*#%+%S+%s+(%S+)") or nil
  return kind, lang
end

--- The kind of a `#+end_` line ("src", ...).
local function end_of(line)
  local kind = line:match("^%s*#%+[eE][nN][dD]_(%S*)")
  return kind and kind:lower()
end

-- Parsed blocks ------------------------------------------------------------

---@class org.SrcHlTree
---@field root TSNode
---@field query vim.treesitter.Query
---@field lang string

---@class org.SrcHlEntry
---@field lang string tree-sitter language
---@field source string
---@field lines string[]
---@field trees org.SrcHlTree[]|false|nil nil = not parsed yet, false = failed
---@field tree TSTree? the tree of `lang` when parsed without injections (an edit parses from it)
---@field parser vim.treesitter.LanguageTree? (keeps the injected trees)
---@field rows table<integer, table[]> 0-based row in the block -> marks
---@field used integer changedtick it was last used at
---@field base? org.SrcHlEntry the same block before an edit, parsed (see `parse_from`)

--- Per buffer: parsed block texts by "lang\0text", how many and their size.
local entries = {} ---@type table<integer, { map: table<string, org.SrcHlEntry>, n: integer, bytes: integer }>

-- Texts kept per buffer, beyond those drawn at the current changedtick:
-- the blocks scrolled past, and the texts of a block before its last edits.
local MAX_ENTRIES, MAX_BYTES = 64, 4 * 1024 * 1024

--- Drop the least recently used texts not used at `tick` until `e` holds
--- at most MAX_ENTRIES of them and MAX_BYTES.
local function evict(e, tick)
  if e.n < MAX_ENTRIES and e.bytes < MAX_BYTES then
    return
  end
  local old = {}
  for k, v in pairs(e.map) do
    if v.used ~= tick then
      old[#old + 1] = { k, v }
    end
  end
  table.sort(old, function(x, y)
    return x[2].used < y[2].used
  end)
  for _, kv in ipairs(old) do
    if e.n < MAX_ENTRIES and e.bytes < MAX_BYTES then
      break
    end
    e.map[kv[1]] = nil
    e.n, e.bytes = e.n - 1, e.bytes - #kv[2].source
  end
end

local function entry_for(buf, tick, lang, lines)
  local e = entries[buf]
  if not e then
    e = { map = {}, n = 0, bytes = 0 }
    entries[buf] = e
  end
  local source = table.concat(lines, "\n")
  local key = lang .. "\0" .. source
  local entry = e.map[key]
  if not entry then
    evict(e, tick)
    entry = { lang = lang, source = source, lines = lines, rows = {}, used = tick }
    e.map[key] = entry
    e.n, e.bytes = e.n + 1, e.bytes + #source
  end
  entry.used = tick
  return entry
end

--- How many block texts were parsed (for tests), and how many of those
--- parses reused the tree of the block's text before an edit.
M.parses, M.incremental = 0, 0

--- Byte offset and { row, col } of the start of line `k` (1-based) of
--- `lines` joined by newlines; past the last line, the end of the text.
local function pos(lines, k)
  local n = #lines
  local byte = 0
  for i = 1, math.min(k, n + 1) - 1 do
    byte = byte + #lines[i] + 1
  end
  if k > n then
    return byte - 1, n - 1, #lines[n]
  end
  return byte, k - 1, 0
end

--- The tree of `entry`'s text, parsed from the tree of `base` (the same
--- block's text before an edit) like Neovim parses a buffer again after a
--- change: only what the edit touched is parsed again. nil when Neovim's
--- parser objects aren't there or the parse fails.
local function parse_from(entry, base)
  local create = vim._create_ts_parser
  if type(create) ~= "function" or not (base and base.tree) then
    return nil
  end
  local old, new = base.lines, entry.lines
  -- the lines that changed: old[a..bo] became new[a..bn]
  local a = 1
  while a <= #old and a <= #new and old[a] == new[a] do
    a = a + 1
  end
  local bo, bn = #old, #new
  while bo >= a and bn >= a and old[bo] == new[bn] do
    bo, bn = bo - 1, bn - 1
  end
  -- (the text before the change is the same in both: a line added at the
  -- end starts at the end of the old text, one removed at the end of the new)
  local sb, sr, sc = pos(a > #new and new or old, a)
  local ob, orow, ocol = pos(old, bo + 1)
  local nb, nrow, ncol = pos(new, bn + 1)
  local ok, tree = pcall(function()
    local t = base.tree:copy()
    -- (Neovim 0.12 returns the edited tree, 0.11 edits it in place)
    t = t:edit(sb, ob, nb, sr, sc, orow, ocol, nrow, ncol) or t
    local parser = create(entry.lang)
    return (parser:parse(t, entry.source, true))
  end)
  return ok and tree or nil
end

-- Blocks up to this many lines get their injected languages too (the
-- inline markup of markdown, Vim script in a vim.cmd() string, ...): those
-- are parsed again whole after each edit; longer blocks of a language with
-- injections are parsed again from their tree, without them.
M.inject_max = 1000

local has_injections = {} ---@type table<string, boolean>
local function injects(lang)
  local v = has_injections[lang]
  if v == nil then
    local ok, q = pcall(vim.treesitter.query.get, lang, "injections")
    v = ok and q ~= nil
    has_injections[lang] = v
  end
  return v
end

local function highlights_query(lang)
  local ok, q = pcall(vim.treesitter.query.get, lang, "highlights")
  return ok and q or nil
end

local function parse(entry)
  M.parses = M.parses + 1
  local query = highlights_query(entry.lang)
  if not query then
    entry.trees = false
    return
  end
  if #entry.lines <= M.inject_max and injects(entry.lang) then
    local ok, parser = pcall(vim.treesitter.get_string_parser, entry.source, entry.lang)
    if ok and parser and pcall(parser.parse, parser, true) then
      local trees = {}
      -- (the block's language first, then the injected ones: like
      -- Neovim's highlighter, a later tree wins over an earlier one)
      parser:for_each_tree(function(tree, ltree)
        local lang = ltree:lang()
        local q = lang == entry.lang and query or highlights_query(lang)
        if q then
          trees[#trees + 1] = { root = tree:root(), query = q, lang = lang }
        end
      end)
      entry.trees, entry.parser, entry.base = trees, parser, nil
      return
    end
  end
  local tree = parse_from(entry, entry.base)
  entry.base = nil
  if tree then
    M.incremental = M.incremental + 1
  else
    local ok, parser = pcall(vim.treesitter.get_string_parser, entry.source, entry.lang)
    local okp, trees = pcall(function()
      return ok and parser:parse()
    end)
    tree = okp and trees and trees[1]
  end
  if not tree then
    entry.trees = false
    return
  end
  entry.tree, entry.trees = tree, { { root = tree:root(), query = query, lang = entry.lang } }
end

local EMPTY = {}
-- (rows whose captures are found at once: one query run for a screenful)
local CHUNK = 64

local hl_ids = {} ---@type table<string, integer>
local function hl_id(name)
  local id = hl_ids[name]
  if not id then
    id = vim.api.nvim_get_hl_id_by_name(name)
    hl_ids[name] = id
  end
  return id
end

local PRIORITY = (vim.hl or vim.highlight).priorities.treesitter

--- The marks of row `rel` (0-based, in the block): { start_col, end_col,
--- hl_id, priority }, in the order Neovim's highlighter sets them (a later
--- capture wins over an earlier one of the same priority).
local function row_marks(entry, rel)
  local marks = entry.rows[rel]
  if marks then
    return marks
  end
  if entry.trees == nil then
    parse(entry)
  end
  local trees = entry.trees
  if not trees then
    return EMPTY
  end
  local lines = entry.lines
  local first, last = rel, math.min(rel + CHUNK, #lines) - 1
  for r = first, last do
    entry.rows[r] = entry.rows[r] or {}
  end
  for _, t in ipairs(trees) do
    local query, lang = t.query, t.lang
    local captures = query.captures
    -- (a query error leaves the rows with what was found before it)
    pcall(function()
      for id, node, metadata in query:iter_captures(t.root, entry.source, first, last + 1) do
        local name = captures[id]
        if name and name:byte(1) ~= 95 and not SKIP[name] then
          local m = metadata and metadata[id]
          local sr, sc, er, ec
          if m and m.range then
            local range = vim.treesitter.get_range(node, entry.source, m)
            sr, sc, er, ec = range[1], range[2], range[4], range[5]
          else
            sr, sc, er, ec = node:range()
          end
          local pri = tonumber(metadata and metadata.priority or (m and m.priority)) or PRIORITY
          local group = hl_id("@" .. name .. "." .. lang)
          for r = math.max(sr, first), math.min(er, last) do
            local s = r == sr and sc or 0
            local e = r == er and ec or #(lines[r + 1] or "")
            if e > s and not entry.rows[r].done then
              local row = entry.rows[r]
              row[#row + 1] = { s, e, group, pri }
            end
          end
        end
      end
    end)
  end
  for r = first, last do
    entry.rows[r].done = true
  end
  return entry.rows[rel]
end

-- Rows -> blocks -------------------------------------------------------------

---@class org.SrcHlBlock
---@field first integer first body row (0-based)
---@field last integer last body row
---@field entry org.SrcHlEntry

--- Per buffer, at one changedtick: each row looked at -> its block, or
--- false when it is no body row of a tree-sitter block; blocks by begin row.
---@class org.SrcHlState
---@field tick integer
---@field rows table<integer, org.SrcHlBlock|false>
---@field blocks table<integer, org.SrcHlBlock|false>
---@field prev? table<integer, org.SrcHlBlock|false> the blocks at the tick before

local state = {} ---@type table<integer, org.SrcHlState>

--- The state of `buf` at its current changedtick.
---@return org.SrcHlState
local function state_of(buf)
  local tick = vim.api.nvim_buf_get_changedtick(buf)
  local st = state[buf]
  if not st or st.tick ~= tick then
    st = { tick = tick, rows = {}, blocks = {}, prev = st and st.blocks }
    state[buf] = st
  end
  return st
end

--- The block that begins at row `open` (a `#+begin_<kind> <lang>` line):
--- its body runs to the matching `#+end_<kind>` line, or to the next
--- headline or the end of the buffer (a block always ends at a headline).
local function block_at(buf, st, open, kind, lang, n)
  local blk = st.blocks[open]
  if blk ~= nil then
    return blk
  end
  local tslang = M.ts_lang(lang)
  if not tslang then
    st.blocks[open] = false
    return false
  end
  local body = {}
  local row = open + 1
  local size = 64
  local close = n
  while row < n do
    local chunk = vim.api.nvim_buf_get_lines(buf, row, math.min(n, row + size), false)
    local done = false
    for i, line in ipairs(chunk) do
      if is_headline(line) or end_of(line) == kind then
        close = row + i - 1
        done = true
        break
      end
      body[#body + 1] = line
    end
    if done then
      break
    end
    row = row + #chunk
    size = math.min(size * 4, 4096)
  end
  if close <= open + 1 then
    st.blocks[open] = false
    return false
  end
  local entry = entry_for(buf, st.tick, tslang, body)
  if entry.trees == nil and st.prev then
    -- (the block at this row when it was last drawn: the text it had
    -- before this edit, parsed again from its tree)
    local before = st.prev[open]
    if before and before.entry.lang == tslang and before.entry.tree then
      entry.base = before.entry
    end
  end
  blk = { first = open + 1, last = close - 1, entry = entry }
  st.blocks[open] = blk
  for r = blk.first, blk.last do
    st.rows[r] = blk
  end
  return blk
end

--- The tree-sitter block whose body holds `row`, or false.
---@return org.SrcHlBlock|false
local function classify(buf, st, row)
  local v = st.rows[row]
  if v ~= nil then
    return v
  end
  local n = vim.api.nvim_buf_line_count(buf)
  if row > 0 and st.rows[row - 1] ~= nil then
    -- (a block marks all its body rows when it is found: a row after a
    -- known one is in none, unless that one begins a block)
    local prev = vim.api.nvim_buf_get_lines(buf, row - 1, row, false)[1] or ""
    local kind, lang = begin_of(prev)
    local blk = lang and block_at(buf, st, row - 1, kind, lang, n)
    if blk then
      return blk
    end
    st.rows[row] = false
    return false
  end
  -- Up to the nearest headline, block begin or src/export block end.
  local result = false ---@type org.SrcHlBlock|false
  local stop = -1
  local hi = row + 1
  local size = 32
  while hi > 0 do
    local lo = math.max(0, hi - size)
    local chunk = vim.api.nvim_buf_get_lines(buf, lo, hi, false)
    local found = false
    for i = #chunk, 1, -1 do
      local r = lo + i - 1
      local line = chunk[i]
      local b = line:byte(line:find("%S") or 1)
      if b == 35 or b == 42 then
        if is_headline(line) then
          stop, found = r, true
        else
          local kind, lang = begin_of(line)
          if kind then
            stop, found = r, true
            if lang then
              local blk = block_at(buf, st, r, kind, lang, n)
              if blk and blk.first <= row and blk.last >= row then
                result = blk
              end
            end
          else
            local e = end_of(line)
            if e == "src" or e == "export" then
              stop, found = r, true
            end
          end
        end
      end
      if not found and r < row and st.rows[r] ~= nil then
        -- (known: in a block it would have been found going up from row)
        stop, found = r, true
        result = false
      end
      if found then
        break
      end
    end
    if found then
      break
    end
    hi = lo
    size = math.min(size * 4, 4096)
  end
  if not result then
    for r = stop + 1, row do
      if st.rows[r] == nil then
        st.rows[r] = false
      end
    end
  end
  return result
end

-- Drawing -------------------------------------------------------------------

--- Whether `buf` may have a tree-sitter block: a language seen in it (by
--- the org syntax) has one.
local function active(buf)
  local e = engine()
  if not e or e == "syntax" then
    return false
  end
  local syntax = require("org.syntax")
  for lang in pairs(syntax.languages_seen(buf) or EMPTY) do
    if M.ts_lang_of_syntax(syntax.syntax_of(lang)) then
      return true
    end
  end
  return false
end

local current ---@type org.SrcHlState?

vim.api.nvim_set_decoration_provider(ns, {
  on_win = function(_, _, buf)
    if not attached[buf] or not active(buf) then
      current = nil
      return false
    end
    current = state_of(buf)
  end,
  on_line = function(_, _, buf, row)
    local st = current
    if not st then
      return
    end
    local blk = classify(buf, st, row)
    if not blk then
      return
    end
    for _, m in ipairs(row_marks(blk.entry, row - blk.first)) do
      pcall(vim.api.nvim_buf_set_extmark, buf, ns, row, m[1], {
        end_row = row,
        end_col = m[2],
        hl_group = m[3],
        priority = m[4],
        ephemeral = true,
      })
    end
  end,
})

--- The highlights tree-sitter gives row `row` (0-based) of `buf`, as the
--- decoration provider draws them: { { start_col, end_col, group_name } }.
--- For tests and `:Inspect`-like tools.
---@return { [1]: integer, [2]: integer, [3]: string }[]
function M.highlights_at(buf, row)
  buf = buf == 0 and vim.api.nvim_get_current_buf() or buf
  local st = state_of(buf)
  local out = {}
  if not active(buf) then
    return out
  end
  local blk = classify(buf, st, row)
  if blk then
    for _, m in ipairs(row_marks(blk.entry, row - blk.first)) do
      out[#out + 1] = { m[1], m[2], vim.fn.synIDattr(m[3], "name") }
    end
  end
  return out
end

local function forget(buf)
  state[buf] = nil
  entries[buf] = nil
end

--- Draw the src blocks of `buf` with tree-sitter (from `org.buffer.attach`).
function M.attach(buf)
  attached[buf] = true
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = vim.api.nvim_create_augroup("org.src_highlight." .. buf, { clear = true }),
    buffer = buf,
    callback = function()
      attached[buf] = nil
      forget(buf)
    end,
  })
end

--- Stop drawing them (the filetype changed).
function M.detach(buf)
  attached[buf] = nil
  forget(buf)
  pcall(vim.api.nvim_del_augroup_by_name, "org.src_highlight." .. buf)
end

--- Forget what was parsed and which languages have a parser.
function M.refresh(buf)
  forget(buf)
  ts_rtp = nil
end

return M
