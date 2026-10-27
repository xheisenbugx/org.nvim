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
---@field lines string[] buffer lines from `row0` on
---@field row0 integer 0-based row of lines[1]
---@field block org.ui.emphasis.Block|false the block open before lines[1]
---@field prev? string the line before lines[1] (nil at the top)
---@field closed_after fun(name: string): boolean whether a block's end line follows the lines

-- What the lookbacks and lookaheads of the scans found, per buffer at one
-- changedtick. A redraw scans one window per range of rows drawn (one per
-- closed fold in an overview), so the same lines would be read again for
-- each range otherwise, up to LOOKBACK of them.
local memos = {} ---@type table<integer, { tick: integer, star: table<integer, integer|false>, block: table<integer, org.ui.emphasis.Block|false>, closed: table<string, boolean> }>

local function memo_of(bufnr)
  local tick = vim.api.nvim_buf_get_changedtick(bufnr)
  local m = memos[bufnr]
  if not m or m.tick ~= tick then
    m = { tick = tick, star = {}, block = {}, closed = {} }
    memos[bufnr] = m
  end
  return m
end

--- The 0-based row of the nearest line of stars (`E.star_line`) above row
--- `row` of `bufnr`, `max` lines up at most, or false. Read back in chunks
--- (the headline above is usually near), kept per changedtick.
---@param bufnr integer
---@param row integer
---@param max integer
---@return integer|false
function M.star_above(bufnr, row, max)
  local m = memo_of(bufnr)
  local key = row * 8192 + max
  local v = m.star[key]
  if v ~= nil then
    return v
  end
  v = false
  local stop = math.max(0, row - max)
  local e, size = row, 64
  while e > stop do
    local s = math.max(stop, e - size)
    local chunk = vim.api.nvim_buf_get_lines(bufnr, s, e, false)
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
  m.star[key] = v
  return v
end

--- The block open at the start of row `row` (0-based): from the headline
--- above (or LOOKBACK lines up).
---@return org.ui.emphasis.Block|false
local function block_before(bufnr, row)
  local m = memo_of(bufnr)
  local v = m.block[row]
  if v ~= nil then
    return v
  end
  local h = M.star_above(bufnr, row, LOOKBACK)
  local from = h and h + 1 or math.max(0, row - LOOKBACK)
  local block = false ---@type org.ui.emphasis.Block|false
  for _, line in ipairs(vim.api.nvim_buf_get_lines(bufnr, from, row, false)) do
    local name, begins = E.block_line(line)
    if name then
      if block and not begins and name == block.name then
        block = false
      elseif not block and begins then
        -- (whether it has an end line is found out by `E.kinds`)
        block = { name = name, verbatim = E.VERBATIM_BLOCKS[name] == true }
      end
    end
  end
  m.block[row] = block
  return block
end

--- Whether a line of stars, or the end line of block `name`, follows row
--- `stop` (0-based, excluded) of `bufnr` within LOOKBACK lines (beyond
--- them: taken as closed).
local function closed_from(bufnr, stop, name)
  local m = memo_of(bufnr)
  local key = name .. ":" .. stop
  local known = m.closed[key]
  if known ~= nil then
    return known
  end
  local n = vim.api.nvim_buf_line_count(bufnr)
  local from = stop
  local v ---@type boolean?
  while v == nil and from < math.min(n, stop + LOOKBACK) do
    local chunk = vim.api.nvim_buf_get_lines(bufnr, from, math.min(n, from + 256), false)
    for _, line in ipairs(chunk) do
      if E.star_line(line) then
        v = true
        break
      end
      local nm, begins = E.block_line(line)
      if nm == name and not begins then
        v = true
        break
      end
    end
    from = from + #chunk
  end
  if v == nil then
    v = from < n
  end
  m.closed[key] = v
  return v
end

--- The lines the rows `first` to `last` (0-based) of `bufnr` are drawn
--- from: markup can start on the line above, and a link's text goes on
--- over the lines of its paragraph, so the window covers the paragraphs
--- around the rows (PARAGRAPH lines at most each way); a row drawn alone
--- is drawn as in a scan of the whole buffer.
---@return org.ui.highlight.Window
function M.window(bufnr, first, last)
  local n = vim.api.nvim_buf_line_count(bufnr)
  local separates = E.separates
  local scan_row = math.max(0, first - 2)
  local up = vim.api.nvim_buf_get_lines(bufnr, math.max(0, scan_row - PARAGRAPH), scan_row + 1, false)
  for k = #up, 2, -1 do
    if separates(up[k]) then
      break
    end
    scan_row = scan_row - 1
  end
  local stop = math.min(n, last + 2)
  local down = vim.api.nvim_buf_get_lines(bufnr, stop, math.min(n, stop + PARAGRAPH), false)
  for _, line in ipairs(down) do
    if separates(line) then
      break
    end
    stop = stop + 1
  end
  local lines = vim.api.nvim_buf_get_lines(bufnr, scan_row, stop, false)
  local prev ---@type string?
  if scan_row > 0 then
    -- (the line before the window: in `up` unless the window starts above it)
    local k = scan_row - math.max(0, math.max(0, first - 2) - PARAGRAPH)
    prev = up[k] or vim.api.nvim_buf_get_lines(bufnr, scan_row - 1, scan_row, false)[1]
  end
  return {
    lines = lines,
    row0 = scan_row,
    block = block_before(bufnr, scan_row),
    prev = prev,
    closed_after = function(name)
      return closed_from(bufnr, stop, name)
    end,
  }
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
---@field get_line fun(row: integer): string? any line of the buffer, by 0-based row

---@class org.ui.highlight.MarkOpts
---@field hl_group? string a syntax group name (orgTodo, ...)
---@field priority? integer (see `M.PRIO`)
---@field spell? boolean false: not spell checked (like a syntax group without @Spell)
---@field conceal? string

--- Marks of rows `first` to `last` (0-based) of buffer `bufnr`, added to
--- `rows` (the format of org.ui.decorations `compute`):
--- `{ [row] = { { col, opts, nil, "parser" }, ... } }`.
---@param bufnr integer
---@param first integer
---@param last integer
---@param ui table the buffer's `ui` options
---@param rows table<integer, table[]>
function M.add_marks(bufnr, first, last, ui, rows)
  local w = M.window(bufnr, first, last)
  -- (the rows read: the window, the line above it and the line below it,
  -- which ended it; org.ui.decorations keeps the marks of rows an edit
  -- elsewhere can't change)
  M.last_read = { w.row0 - 1, w.row0 + #w.lines }
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
    conceal_links = conceal_links,
    block = w.block,
    prev = w.prev,
    closed_after = w.closed_after,
    kinds = kinds,
    types = types,
  }, rows)

  local file = M.file_in_use(bufnr) or require("org.files").get_buffer(bufnr)
  parses[bufnr] = file
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
    emit = function(i, col, end_col, o)
      local row = row0 + i - 1
      if row < first or row > last or end_col <= col then
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
          conceal = o.conceal,
          ephemeral = true,
        },
        nil,
        "parser",
      }
    end,
    get_line = function(row)
      return vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1]
    end,
  }
  for _, part in ipairs(M.PARTS) do
    require("org.ui.highlight." .. part).paint(ctx)
  end
end

--- Forget what is kept for `bufnr` (it was wiped out).
function M.detach(bufnr)
  parses[bufnr] = nil
  memos[bufnr] = nil
end

return M
