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

local M = {}

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
  -- the block open there: from the headline above (or LOOKBACK lines up)
  local start = math.max(0, scan_row - LOOKBACK)
  local before = vim.api.nvim_buf_get_lines(bufnr, start, scan_row, false)
  local h = 0
  for k = #before, 1, -1 do
    if E.star_line(before[k]) then
      h = k
      break
    end
  end
  local block = false ---@type org.ui.emphasis.Block|false
  for j = h + 1, #before do
    local name, begins = E.block_line(before[j])
    if name then
      if block and not begins and name == block.name then
        block = false
      elseif not block and begins then
        -- (whether it has an end line is found out by `E.kinds`)
        block = { name = name, verbatim = E.VERBATIM_BLOCKS[name] == true }
      end
    end
  end
  local lines = vim.api.nvim_buf_get_lines(bufnr, scan_row, stop, false)
  local function closed_after(name)
    local from = stop
    while from < math.min(n, stop + LOOKBACK) do
      local chunk = vim.api.nvim_buf_get_lines(bufnr, from, math.min(n, from + 256), false)
      for _, line in ipairs(chunk) do
        if E.star_line(line) then
          return true
        end
        local nm, begins = E.block_line(line)
        if nm == name and not begins then
          return true
        end
      end
      from = from + #chunk
    end
    -- (beyond LOOKBACK lines: taken as closed)
    return from < n
  end
  return {
    lines = lines,
    row0 = scan_row,
    block = block,
    prev = scan_row > 0 and vim.api.nvim_buf_get_lines(bufnr, scan_row - 1, scan_row, false)[1] or nil,
    closed_after = closed_after,
  }
end

--- The last parse of each buffer seen (its #+TODO keywords and other
--- settings, which drawing needs without parsing on every redraw).
local parses = {} ---@type table<integer, org.File>

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
  local b = vim.b[bufnr]
  local hide = ui.hide_emphasis_markers and true or false
  if b.org_hide_emphasis_markers ~= nil then
    hide = b.org_hide_emphasis_markers and true or false
  end
  local conceal_links = ui.conceal_links ~= false
  if b.org_link_descriptive ~= nil then
    conceal_links = b.org_link_descriptive and true or false
  end
  E.marks(w.lines, w.row0, first, last, {
    hide_markers = hide,
    conceal_links = conceal_links,
    block = w.block,
    prev = w.prev,
    closed_after = w.closed_after,
  }, rows)

  local files = require("org.files")
  local file = files.cached_buffer(bufnr) or parses[bufnr]
  if not file then
    file = files.get_buffer(bufnr)
  end
  parses[bufnr] = file
  local kinds, roles = E.kinds(w.lines, w.block, w.closed_after)
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
end

return M
