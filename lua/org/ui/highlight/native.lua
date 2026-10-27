---@mod org.ui.highlight.native LaTeX drawn by Vim's tex syntax
---
--- Part of org.ui.highlight.block: `ui.highlight_latex_and_related`
--- "native" with the parser highlighter. A port of what
--- org-do-latex-and-related does then (org-src-font-lock-fontify-block
--- "latex"): the text of each fragment, environment, entity or
--- sub/superscript is fontified in a buffer of its own in latex-mode, and
--- the faces found there are copied onto it. Here that buffer is a hidden
--- scratch buffer with Vim's tex syntax (`syntax/tex.vim`, as typed: no
--- concealing, no error groups), and the groups its bytes get are drawn
--- over the text as marks of those groups (texMathZoneX, texStatement,
--- ...).
---
--- Fragments are frequent, so the groups of a text are kept (per text, per
--- line of it), and only the lines drawn are asked for. The scratch buffer
--- can't be given a text while the screen is drawn (Neovim's textlock):
--- a text first met then is fontified right after the redraw, which then
--- draws the buffer again; an edit has its row's fragments fontified
--- before the redraw (TextChanged, TextChangedI, TextChangedP), so typing
--- in a fragment doesn't flash it uncoloured.

-- Not compiled by the JIT, like org.ui.highlight (see the comment there).
if jit then
  jit.off(true, true)
end

local M = {}

local api = vim.api

---@alias org.ui.highlight.native.Span { [1]: integer, [2]: integer, [3]: string } bytes [col, end_col) (0-based) of a line, and their group

--- Texts kept before the cache starts again.
local MAX = 2048

--- Text -> 0-based line of it -> its spans.
local cache = {} ---@type table<string, table<integer, org.ui.highlight.native.Span[]>>
local size = 0

local scratch ---@type integer?
--- The text the scratch buffer holds.
local loaded ---@type string?

--- Whether Vim's tex syntax is on the 'runtimepath' (per 'runtimepath').
local available ---@type boolean?
local available_rtp ---@type string?

--- Texts to fontify after the redraw (text -> first and last line), and
--- the buffers to draw again then.
local pending = {} ---@type table<string, { [1]: integer, [2]: integer }>
local pending_bufs = {} ---@type table<integer, boolean>
local scheduled = false

--- Whether Vim's tex syntax can be loaded.
---@return boolean
function M.available()
  local rtp = vim.o.runtimepath
  if available == nil or rtp ~= available_rtp then
    available_rtp = rtp
    available = #api.nvim_get_runtime_file("syntax/tex.vim", false) > 0
      or #api.nvim_get_runtime_file("syntax/tex.lua", false) > 0
  end
  return available
end

--- Groups not drawn: tex.vim's errors (`_` and `^` outside math are
--- texOnlyMath, in Error); latex-mode draws no error there.
---@param name string
---@return boolean
local function skipped(name)
  return name == "" or name == "texOnlyMath" or name:find("Error") ~= nil
end

--- The scratch buffer, with the tex syntax loaded (once).
---@return integer
local ready = false
local function buffer()
  if not (scratch and api.nvim_buf_is_valid(scratch)) then
    scratch, loaded, ready = api.nvim_create_buf(false, true), nil, false
    vim.bo[scratch].undolevels = -1
  end
  local buf = scratch --[[@as integer]]
  if ready then
    return buf
  end
  api.nvim_buf_call(buf, function()
    -- as typed (Emacs shows the text as is): no concealing, and no error
    -- groups for what plain TeX forbids outside math
    local saved = { tex_conceal = vim.g.tex_conceal, tex_no_error = vim.g.tex_no_error }
    vim.g.tex_conceal = ""
    vim.g.tex_no_error = 1
    vim.b.current_syntax = nil
    pcall(api.nvim_command, "syntax clear")
    pcall(api.nvim_command, "runtime! syntax/tex.vim syntax/tex.lua")
    -- (a text is drawn from its start: a line far into an environment
    -- still knows it is in it)
    pcall(api.nvim_command, "syntax sync fromstart")
    vim.g.tex_conceal = saved.tex_conceal
    vim.g.tex_no_error = saved.tex_no_error
  end)
  ready = true
  return buf
end

--- The groups of lines [r0, r1] (0-based) of `text` not known yet, from the
--- scratch buffer, which holds it.
---@param lines string[]
---@param entry table<integer, org.ui.highlight.native.Span[]>
local function fill(lines, entry, r0, r1)
  api.nvim_buf_call(assert(scratch), function()
    local synID, attr = vim.fn.synID, vim.fn.synIDattr
    for r = r0, math.min(r1, #lines - 1) do
      if not entry[r] then
        local spans = {} ---@type org.ui.highlight.native.Span[]
        local line = lines[r + 1]
        local cur, from = "", 0
        for c = 1, #line + 1 do
          local name = c <= #line and attr(synID(r + 1, c, 1), "name") or ""
          if name ~= cur then
            if not skipped(cur) then
              spans[#spans + 1] = { from, c - 1, cur }
            end
            cur, from = name, c - 1
          end
        end
        entry[r] = spans
      end
    end
  end)
end

--- Load `text` in the scratch buffer; false while the screen is drawn.
---@param text string
---@return string[]|false
local function load(text)
  -- (a buffer may not be made while the screen is drawn either)
  local ok, buf = pcall(buffer)
  if not ok then
    return false
  end
  local lines = vim.split(text, "\n", { plain = true })
  if loaded ~= text then
    if not pcall(api.nvim_buf_set_lines, buf, 0, -1, false, lines) then
      return false
    end
    loaded = text
  end
  return lines
end

local function flush()
  scheduled = false
  local texts, bufs = pending, pending_bufs
  pending, pending_bufs = {}, {}
  for text, rr in pairs(texts) do
    local entry = cache[text]
    local lines = entry and load(text)
    if lines and entry then
      fill(lines, entry, rr[1], rr[2])
    end
  end
  for buf in pairs(bufs) do
    if api.nvim_buf_is_valid(buf) then
      require("org.ui.decorations").render(buf, true)
    end
  end
end

--- The tex groups of lines [r0, r1] (0-based) of `text`, a fragment drawn
--- in `bufnr`: line -> spans, missing the lines not fontified yet (they
--- are after the redraw, which `bufnr` gets again).
---@param bufnr integer
---@param text string
---@param r0 integer
---@param r1 integer
---@return table<integer, org.ui.highlight.native.Span[]>
function M.spans(bufnr, text, r0, r1)
  local entry = cache[text]
  if not entry then
    if size >= MAX then
      cache, size = {}, 0
    end
    entry = {}
    cache[text] = entry
    size = size + 1
  end
  local missing = false
  for r = r0, r1 do
    if not entry[r] then
      missing = true
      break
    end
  end
  if not missing then
    return entry
  end
  local lines = load(text)
  if lines then
    fill(lines, entry, r0, r1)
    return entry
  end
  local rr = pending[text]
  pending[text] = rr and { math.min(rr[1], r0), math.max(rr[2], r1) } or { r0, r1 }
  pending_bufs[bufnr] = true
  if not scheduled then
    scheduled = true
    vim.schedule(flush)
  end
  return entry
end

local watched = {} ---@type table<integer, boolean>

--- Fontify the fragments of the cursor row of `bufnr` when its text
--- changes, before the redraw that shows the change.
---@param bufnr integer
function M.watch(bufnr)
  if watched[bufnr] then
    return
  end
  watched[bufnr] = true
  local ok = pcall(api.nvim_create_autocmd, { "TextChanged", "TextChangedI", "TextChangedP" }, {
    group = api.nvim_create_augroup("org.ui.highlight.native." .. bufnr, { clear = true }),
    buffer = bufnr,
    callback = function(ev)
      local win = api.nvim_get_current_win()
      if api.nvim_win_get_buf(win) ~= ev.buf then
        return
      end
      local row = api.nvim_win_get_cursor(win)[1] - 1
      pcall(require("org.ui.decorations").line_marks, ev.buf, row)
    end,
  })
  if not ok then
    watched[bufnr] = nil
  end
end

--- Forget what was fontified (tests).
function M._reset()
  cache, size, loaded, available = {}, 0, nil, nil
end

return M
