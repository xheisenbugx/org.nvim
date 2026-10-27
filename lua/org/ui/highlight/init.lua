---@mod org.ui.highlight The parser highlighter
---
--- With `ui.highlighter = "parser"`, org buffers are drawn by the
--- decoration provider (org.ui.decorations) from a scan of the rows on
--- screen instead of by `:syntax` regions: this module computes the marks
--- of those rows. org.syntax then defines only the regions that include the
--- Vim syntax of src block languages (for languages without a tree-sitter
--- parser, see org.ui.src_highlight).
---
--- The marks come from parts, one per area, each a module of this
--- directory with `paint(ctx)` (see `org.ui.highlight.Ctx`): headlines,
--- lists, dates and planning, keywords / drawers / comments, tables,
--- blocks and LaTeX, links and other objects; emphasis and the hidden parts
--- of links are org.ui.emphasis. Each is a port of what Emacs Org draws
--- (org-set-font-lock-defaults), compared with Emacs byte by byte by
--- tests/spec/emacs_faces_*_spec.lua (tests/helpers/faces.lua).
---
--- Parts draw with the syntax group names (orgHeadlineLevel1, orgTodo,
--- ...: org.highlights links them to the Org* groups), so a colorscheme or
--- config that sets either keeps working. Where marks overlap, the one of
--- higher priority wins each attribute it sets (Emacs prepends faces the
--- same way): the line of an element (`M.PRIO.element`) under its parts
--- (`M.PRIO.part`) under the objects in it (`M.PRIO.object`) under
--- emphasis (101 and up).
---
--- The body of an org src block (`M.org_body`) is drawn by the same parts
--- as a text of its own, the way Emacs fontifies it in an Org buffer that
--- holds only the body (org-src-font-lock-fontify-block): its lines as
--- typed (",* x" is no headline), nothing hidden, over the block's orgBlock.

-- The parts (and this module) are not compiled by the JIT: they ran 3 to 6
-- times faster interpreted (the marks of a screen of 10,000 headlines in
-- 0.2 instead of 1.2 ms, at every keystroke). Their loops are short (the
-- lines of a screen, the cookies of a line) and make closures, which the
-- JIT can't compile, so most traces aborted, and the time a screen took
-- went from one run to the next with what was compiled before it.
-- org.ui.emphasis, whose scans run over whole long lines, is compiled.
if jit then
  jit.off(true, true)
end

local M = {}

--- The rows (0-based, first and last) the last `add_marks` read.
---@type { [1]: integer, [2]: integer }?
M.last_read = nil

local E = require("org.ui.emphasis")

--- The parts, in the order they paint (the order doesn't decide which
--- mark wins: the priority does).
M.PARTS = { "headline", "list", "date", "meta", "table", "block", "object" }

M.PRIO = {
  --- a whole element: a headline line, a table row, a block's body
  element = 80,
  --- what an element holds: a TODO keyword, tags, a table formula
  part = 90,
  --- an object: a link, a timestamp, a footnote
  object = 95,
}

--- Whether buffer `bufnr` is drawn by this highlighter (`ui.highlighter`).
---@param bufnr? integer
---@return boolean
function M.active(bufnr)
  return E.active(bufnr)
end

--- How far back the scan looks for the headline above (the blocks open
--- there), and ahead for the end line of a block.
local LOOKBACK = 3000
--- How far the scan goes on over a paragraph around the rows drawn.
local PARAGRAPH = 50

---@class org.ui.highlight.Window
---@field lines string[] lines of the text from `row0` on
---@field row0 integer 0-based row of lines[1]
---@field block org.ui.emphasis.Block|false the block open before lines[1]
---@field prev? string the line before lines[1] (nil at the top)
---@field closed_after fun(name: string): boolean whether a block's end line follows the lines
---@field end_after fun(name: string): integer? the row of the first line after the lines that ends a block `name` (its end line or a line of stars; LOOKBACK lines on at most, then the row the search stopped at), nil when none does

---@class org.ui.highlight.Text
---@field top integer 0-based row of the text's first line
---@field bottom integer 0-based row after its last line
---@field get fun(s: integer, e: integer): string[] the lines of rows [s, e) (within [top, bottom))
---@field memo org.ui.highlight.Memo what its lookbacks and lookaheads found

---@class org.ui.highlight.Memo
---@field tick? integer
---@field star table<integer, integer|false>
---@field block table<integer, org.ui.emphasis.Block|false>
---@field ends table<string, integer|false>

-- What the lookbacks and lookaheads of the scans of a buffer found, at one
-- changedtick. A redraw scans one window per range of rows drawn (one per
-- closed fold in an overview), so the same lines would be read again for
-- each range otherwise, up to LOOKBACK of them.
local memos = {} ---@type table<integer, org.ui.highlight.Memo>

---@return org.ui.highlight.Memo
local function new_memo(tick)
  return { tick = tick, star = {}, block = {}, ends = {} }
end

local function memo_of(bufnr)
  local tick = vim.api.nvim_buf_get_changedtick(bufnr)
  local m = memos[bufnr]
  if not m or m.tick ~= tick then
    m = new_memo(tick)
    memos[bufnr] = m
  end
  return m
end

--- The 0-based row of the nearest line of stars (`E.star_line`) above row
--- `row` of `text`, `max` lines up at most (and within it), or false. Read
--- back in chunks (the headline above is usually near).
---@param text org.ui.highlight.Text
---@param row integer
---@param max integer
---@return integer|false
local function star_above(text, row, max)
  local key = row * 8192 + max
  local v = text.memo.star[key]
  if v ~= nil then
    return v
  end
  v = false
  local stop = math.max(text.top, row - max)
  local e, size = row, 64
  while e > stop do
    local s = math.max(stop, e - size)
    local chunk = text.get(s, e)
    for k = #chunk, 1, -1 do
      if E.star_line(chunk[k]) then
        v = s + k - 1
        break
      end
    end
    if v then
      break
    end
    e, size = s, math.min(2 * size, 1024)
  end
  text.memo.star[key] = v
  return v
end

--- The block open at the start of row `row` (0-based) of `text`: from the
--- headline above (or LOOKBACK lines up).
---@param text org.ui.highlight.Text
---@return org.ui.emphasis.Block|false
local function block_before(text, row)
  local v = text.memo.block[row]
  if v ~= nil then
    return v
  end
  local h = star_above(text, row, LOOKBACK)
  local from = h and h + 1 or math.max(text.top, row - LOOKBACK)
  local block = false ---@type org.ui.emphasis.Block|false
  for j, line in ipairs(text.get(from, row)) do
    local name, begins = E.block_line(line)
    if name then
      if block and not begins and name == block.name then
        block = false
      elseif not block and begins then
        -- (whether it has an end line is found out by `E.kinds`)
        block = { name = name, verbatim = E.VERBATIM_BLOCKS[name] == true, row = from + j - 1, line = line }
      end
    end
  end
  text.memo.block[row] = block
  return block
end

--- The row of the first line from row `stop` (0-based) of `text` on that
--- ends a block `name` (its end line or a line of stars; LOOKBACK lines on
--- at most, then the row the search stopped at), nil when none does.
---@param text org.ui.highlight.Text
---@return integer?
local function end_from(text, stop, name)
  local key = name .. ":" .. stop
  local v = text.memo.ends[key]
  if v ~= nil then
    return v or nil
  end
  v = false
  local bottom = text.bottom
  local from = stop
  while not v and from < math.min(bottom, stop + LOOKBACK) do
    local chunk = text.get(from, math.min(bottom, from + 256))
    for k, line in ipairs(chunk) do
      local nm, begins = E.block_line(line)
      if E.star_line(line) or (nm == name and not begins) then
        v = from + k - 1
        break
      end
    end
    from = from + #chunk
  end
  -- (beyond LOOKBACK lines: taken as closed there)
  if not v and from < bottom then
    v = from
  end
  text.memo.ends[key] = v
  return v or nil
end

--- The lines rows `first` to `last` (0-based) of `text` are drawn from
--- (see `M.window`).
---@param text org.ui.highlight.Text
---@return org.ui.highlight.Window
local function window_of(text, first, last)
  local top, bottom, get = text.top, text.bottom, text.get
  local separates = E.separates
  local scan_row = math.max(top, first - 2)
  local up = get(math.max(top, scan_row - PARAGRAPH), scan_row + 1)
  for k = #up, 2, -1 do
    if separates(up[k]) then
      break
    end
    scan_row = scan_row - 1
  end
  local stop = math.min(bottom, last + 2)
  local down = get(stop, math.min(bottom, stop + PARAGRAPH))
  for _, line in ipairs(down) do
    if separates(line) then
      break
    end
    stop = stop + 1
  end
  local lines = get(scan_row, stop)
  local prev ---@type string?
  if scan_row > top then
    -- (the line before the window: in `up` unless the window starts above it)
    local k = scan_row - math.max(top, math.max(top, first - 2) - PARAGRAPH)
    prev = up[k] or get(scan_row - 1, scan_row)[1]
  end
  local function end_after(name)
    return end_from(text, stop, name)
  end
  return {
    lines = lines,
    row0 = scan_row,
    block = block_before(text, scan_row),
    prev = prev,
    closed_after = function(name)
      return end_after(name) ~= nil
    end,
    end_after = end_after,
  }
end

--- The text of buffer `bufnr`, rows `top` to `bottom - 1` (default: all;
--- what the lookbacks of the whole buffer find is kept per changedtick).
---@return org.ui.highlight.Text
local function buffer_text(bufnr, top, bottom)
  return {
    top = top or 0,
    bottom = bottom or vim.api.nvim_buf_line_count(bufnr),
    get = function(s, e)
      return vim.api.nvim_buf_get_lines(bufnr, s, e, false)
    end,
    memo = top and new_memo() or memo_of(bufnr),
  }
end

--- The 0-based row of the nearest line of stars above row `row` of `bufnr`,
--- `max` lines up at most, or false (kept per changedtick).
---@param bufnr integer
---@param row integer
---@param max integer
---@return integer|false
function M.star_above(bufnr, row, max)
  return star_above(buffer_text(bufnr), row, max)
end

--- The lines the rows `first` to `last` (0-based) of `bufnr` are drawn
--- from: markup can start on the line above, and a link's text goes on
--- over the lines of its paragraph, so the window covers the paragraphs
--- around the rows (PARAGRAPH lines at most each way); a row drawn alone
--- is drawn as in a scan of the whole buffer.
---@return org.ui.highlight.Window
function M.window(bufnr, first, last)
  return window_of(buffer_text(bufnr), first, last)
end

--- The last parse of each buffer seen (its #+TODO keywords and other
--- settings, which drawing needs without parsing on every redraw).
local parses = {} ---@type table<integer, org.File>

--- The parse the marks of `bufnr` are drawn with: that of its current text
--- when one is cached, else the last one seen (nil before the first).
---@param bufnr integer
---@return org.File?
function M.file_in_use(bufnr)
  return require("org.files").cached_buffer(bufnr) or parses[bufnr]
end

---@class org.ui.highlight.Ctx
---@field bufnr integer
---@field ui table the buffer's `ui` options (org.ui.decorations `ui_options`)
---@field file org.File the buffer's parse (its settings: `file.settings.todo`, ...), possibly of an earlier text
---@field lines string[] the lines scanned (see `M.window`)
---@field row0 integer 0-based row of lines[1]
---@field first integer 0-based first row drawn
---@field last integer 0-based last row drawn
---@field kinds org.ui.emphasis.Kind[] what each line holds (org.ui.emphasis `kinds`)
---@field roles table<integer, org.ui.emphasis.Role> the block each line is in, and its role there
---@field prev? string the line before lines[1]
---@field link_types? table<string, boolean> org.ui.emphasis `link_types()`
---@field links? { [1]: integer, [2]: integer, [3]: string }[] the links of `lines` (org.ui.emphasis `_links`), when known
---@field emit fun(i: integer, col: integer, end_col: integer, opts: org.ui.highlight.MarkOpts) mark bytes [col, end_col) (0-based) of lines[i]
---@field get_line fun(row: integer): string? any line of the text drawn, by 0-based row
---@field top integer 0-based first row of the text drawn: 0, or the first line of the body of an org src block drawn as Org (`M.org_body`)
---@field bottom integer 0-based row after its last line
---@field get_lines fun(s: integer, e: integer): string[] the lines of rows [s, e) of the text drawn (kept within `top` and `bottom`)
---@field star_above fun(row: integer, max: integer): integer|false the row of the nearest line of stars above `row` in the text drawn, `max` lines up at most

---@class org.ui.highlight.MarkOpts
---@field hl_group? string a syntax group name (orgTodo, ...)
---@field priority? integer (see `M.PRIO`)
---@field spell? boolean false: not spell checked (like a syntax group without @Spell)
---@field conceal? string
---@field link? boolean (org.ui.highlight.object) a link: left out of spell checking on comment lines too

--- Whether the body of the block that `line` begins is drawn as Org text
--- (org-src-font-lock-fontify-block with org-mode, `:h org-highlighter`):
--- a src, export or example block whose language (the word after
--- `#+begin_NAME`, case-sensitive, through `src_lang_modes`) is "org", while
--- src blocks are drawn natively (`ui.src_highlight`).
---@param line string a `#+begin_` line
---@return boolean
function M.org_body(line)
  local name, lang = line:match("^[ \t]*#%+[bB][eE][gG][iI][nN]_(%a+)[ \t]+([^ \t]+)")
  if not name then
    return false
  end
  name = name:lower()
  if name ~= "src" and name ~= "export" and name ~= "example" then
    return false
  end
  local ui = require("org.config").opts.ui or {}
  if ui.src_highlight == false then
    return false
  end
  return require("org.syntax").syntax_of(lang) == "org"
end

--- A file with no settings and no radio targets, for the body of an org
--- src block (its own buffer to Emacs; it has no headlines, a line of stars
--- ends the block).
local BODY_FILE = { settings = {}, lines = {} }

--- Marks of rows `first` to `last` of `text` (in buffer `bufnr`), added to
--- `rows` (see `M.add_marks`); `body`: the text is the body of an org src
--- block, drawn as Org with nothing hidden (Emacs copies only the faces
--- of the Org buffer it fontifies the body in).
---@param text org.ui.highlight.Text
---@param file org.File
---@param body boolean
---@return org.ui.highlight.Window, org.ui.emphasis.Kind[], table<integer, org.ui.emphasis.Role>
local function paint(bufnr, text, first, last, ui, rows, file, body)
  local w = window_of(text, first, last)
  local b = vim.b[bufnr]
  local hide = ui.hide_emphasis_markers and true or false
  if b.org_hide_emphasis_markers ~= nil then
    hide = b.org_hide_emphasis_markers and true or false
  end
  local conceal_links = ui.conceal_links ~= false
  if b.org_link_descriptive ~= nil then
    conceal_links = b.org_link_descriptive and true or false
  end
  local kinds, roles = E.kinds(w.lines, w.block, w.closed_after)
  local types = E.link_types()
  local found = E.marks(w.lines, w.row0, first, last, {
    hide_markers = hide,
    conceal_links = conceal_links and not body,
    reveal = body,
    block = w.block,
    prev = w.prev,
    closed_after = w.closed_after,
    kinds = kinds,
    types = types,
  }, rows)
  -- (the rows read: the window, the line above it and the line below it,
  -- which ended it; org.ui.decorations keeps the marks of rows an edit
  -- elsewhere can't change)
  local read = M.last_read
  local r0, r1 = w.row0 - 1, w.row0 + #w.lines
  M.last_read = read and { math.min(read[1], r0), math.max(read[2], r1) } or { r0, r1 }
  local row0 = w.row0
  ---@type org.ui.highlight.Ctx
  local ctx = {
    bufnr = bufnr,
    ui = ui,
    file = file,
    lines = w.lines,
    row0 = row0,
    first = first,
    last = last,
    kinds = kinds,
    roles = roles,
    prev = w.prev,
    link_types = types,
    links = found,
    top = text.top,
    bottom = text.bottom,
    emit = function(i, col, end_col, o)
      local row = row0 + i - 1
      if row < first or row > last or end_col <= col then
        return
      end
      if body and not o.hl_group then
        return
      end
      local t = rows[row]
      if not t then
        t = {}
        rows[row] = t
      end
      t[#t + 1] = {
        col,
        {
          end_col = end_col,
          hl_group = o.hl_group,
          priority = o.priority,
          spell = o.spell,
          conceal = (not body) and o.conceal or nil,
          ephemeral = true,
        },
        nil,
        "parser",
      }
    end,
    get_line = function(row)
      if row < text.top or row >= text.bottom then
        return nil
      end
      return text.get(row, row + 1)[1]
    end,
    get_lines = function(s, e)
      s, e = math.max(s, text.top), math.min(e, text.bottom)
      if e <= s then
        return {}
      end
      return text.get(s, e)
    end,
    star_above = function(row, max)
      return star_above(text, row, max)
    end,
  }
  for _, part in ipairs(M.PARTS) do
    require("org.ui.highlight." .. part).paint(ctx)
  end
  return w, kinds, roles
end

--- The row after the body of `block`, found from line `i` of the window
--- `w` on: its end line or a line of stars (see `Window.end_after`).
---@param w org.ui.highlight.Window
---@param roles table<integer, org.ui.emphasis.Role>
---@param block org.ui.emphasis.Block
---@return integer
local function body_bottom(w, roles, block, i)
  local lines = w.lines
  for j = i, #lines do
    local r = roles[j]
    if not r or r.block ~= block or r.role ~= "body" then
      return w.row0 + j - 1
    end
  end
  -- (an open block is closed below the lines: `E.kinds` asked)
  return w.end_after(block.name) or w.row0 + #lines
end

--- Marks of rows `first` to `last` (0-based) of buffer `bufnr`, added to
--- `rows` (the format of org.ui.decorations `compute`):
--- `{ [row] = { { col, opts, nil, "parser" }, ... } }`.
---
--- The body of an org src block (`M.org_body`) is drawn as its own text:
--- the rows of it drawn are scanned like those of a buffer that holds only
--- the body (the window around them, within the body), on top of the
--- block's orgBlock.
---@param bufnr integer
---@param first integer
---@param last integer
---@param ui table the buffer's `ui` options
---@param rows table<integer, table[]>
function M.add_marks(bufnr, first, last, ui, rows)
  M.last_read = nil
  local file = M.file_in_use(bufnr) or require("org.files").get_buffer(bufnr)
  parses[bufnr] = file
  local w, _, roles = paint(bufnr, buffer_text(bufnr), first, last, ui, rows, file, false)

  -- the bodies of org src blocks among the rows drawn
  local lines, row0 = w.lines, w.row0
  local i = math.max(1, first - row0 + 1)
  local to = math.min(#lines, last - row0 + 1)
  while i <= to do
    local r = roles[i]
    local block = r and r.role == "body" and r.block.verbatim and r.block
    local top, begin ---@type integer?, string?
    if block then
      -- its begin line: in the lines, or above them (the window's block)
      for j = i - 1, 1, -1 do
        local rj = roles[j]
        if not rj or rj.block ~= block then
          break
        end
        if rj.role == "begin" then
          begin, top = lines[j], row0 + j
          break
        end
      end
      if not begin and block == w.block and block.row then
        begin, top = block.line, block.row + 1
      end
    end
    if block and top and begin and M.org_body(begin) then
      local bottom = body_bottom(w, roles, block, i)
      local text = buffer_text(bufnr, top, bottom)
      paint(bufnr, text, math.max(first, top), math.min(last, bottom - 1), ui, rows, BODY_FILE, true)
      i = bottom - row0 + 1
    elseif block then
      -- (the rest of a block that isn't Org)
      while i <= to and roles[i] and roles[i].block == block do
        i = i + 1
      end
    else
      i = i + 1
    end
  end
end

--- Forget what is kept for `bufnr` (it was wiped out).
function M.detach(bufnr)
  parses[bufnr] = nil
  memos[bufnr] = nil
end

return M
