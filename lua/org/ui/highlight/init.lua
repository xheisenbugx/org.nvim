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
  -- the block open there: from the headline above (or LOOKBACK lines up)
  local start = math.max(top, scan_row - LOOKBACK)
  local before = get(start, scan_row)
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
        block = { name = name, verbatim = E.VERBATIM_BLOCKS[name] == true, row = start + j - 1, line = before[j] }
      end
    end
  end
  local lines = get(scan_row, stop)
  local found = {} ---@type table<string, integer|false>
  local function end_after(name)
    local v = found[name]
    if v ~= nil then
      return v or nil
    end
    v = false
    local from = stop
    while not v and from < math.min(bottom, stop + LOOKBACK) do
      local chunk = get(from, math.min(bottom, from + 256))
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
    found[name] = v
    return v or nil
  end
  return {
    lines = lines,
    row0 = scan_row,
    block = block,
    prev = scan_row > top and get(scan_row - 1, scan_row)[1] or nil,
    closed_after = function(name)
      return end_after(name) ~= nil
    end,
    end_after = end_after,
  }
end

--- The text of buffer `bufnr`, rows `top` to `bottom - 1` (default: all).
---@return org.ui.highlight.Text
local function buffer_text(bufnr, top, bottom)
  return {
    top = top or 0,
    bottom = bottom or vim.api.nvim_buf_line_count(bufnr),
    get = function(s, e)
      return vim.api.nvim_buf_get_lines(bufnr, s, e, false)
    end,
  }
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
---@field get_line fun(row: integer): string? any line of the text drawn, by 0-based row
---@field top integer 0-based first row of the text drawn: 0, or the first line of the body of an org src block drawn as Org (`M.org_body`)
---@field bottom integer 0-based row after its last line
---@field get_lines fun(s: integer, e: integer): string[] the lines of rows [s, e) of the text drawn (kept within `top` and `bottom`)

---@class org.ui.highlight.MarkOpts
---@field hl_group? string a syntax group name (orgTodo, ...)
---@field priority? integer (see `M.PRIO`)
---@field spell? boolean false: not spell checked (like a syntax group without @Spell)
---@field conceal? string

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
  E.marks(w.lines, w.row0, first, last, {
    hide_markers = hide,
    conceal_links = conceal_links and not body,
    reveal = body,
    block = w.block,
    prev = w.prev,
    closed_after = w.closed_after,
  }, rows)

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
  local files = require("org.files")
  local file = files.cached_buffer(bufnr) or parses[bufnr]
  if not file then
    file = files.get_buffer(bufnr)
  end
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
end

return M
