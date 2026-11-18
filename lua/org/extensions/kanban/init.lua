---@mod org.extensions.kanban Kanban board of TODO states
---
--- A board with one column per TODO keyword (or group of keywords) and a
--- card per headline. Moving a card changes the headline's TODO state as
--- `C-c C-t` does (through org.api), so logging, CLOSED, blocking and
--- repeaters behave the same. Built on `org.api` only (`:h org-api`).
---
--- ```lua
--- require("org").setup({ extensions = { kanban = {
---   columns = { "TODO", { "NEXT", "WAITING", name = "Doing", wip = 3 }, "DONE" },
--- } } })
--- ```

local api = require("org.api")
local views = require("org.extensions.views_util")

local M = {}

local MOD = "org.extensions.kanban"
local ns = vim.api.nvim_create_namespace("org_kanban")
local sel_ns = vim.api.nvim_create_namespace("org_kanban_selection")
local augroup = vim.api.nvim_create_augroup("OrgKanban", { clear = true })

--- See :h org-extensions-stability (scripts/extension_report.lua measures it).
M.stability = "stable"

M.defaults = {
  --- Columns, left to right: a keyword, or a table of keywords with an
  --- optional `name` and `wip` limit: `{ "NEXT", "WAITING", name = "Doing" }`.
  --- A card moved into a column gets the column's first keyword that its
  --- file knows (see `choose_keyword`). Empty: one column per TODO keyword,
  --- in the order they are defined.
  ---@type (string|table)[]
  columns = {},
  --- Moving a card into a column of several keywords asks which one
  --- (vim.ui.select) instead of taking the first.
  choose_keyword = false,
  --- WIP limits by column name or keyword: `{ NEXT = 3 }`. The header shows
  --- `count/limit`, in the error colour when over it.
  ---@type table<string, integer>
  wip = {},
  --- Show the columns of DONE keywords.
  show_done = true,
  --- Cards come from: "agenda" (the agenda files), "buffer" (the current
  --- buffer), "subtree" (the subtree at the cursor), or a file, glob or
  --- list of them.
  source = "agenda",
  --- Only headlines matching this org-ql query (sexp or plain syntax).
  ---@type string|nil
  query = nil,
  --- Only headlines with this tag (inherited tags count).
  ---@type string|nil
  tag = nil,
  --- Card order in a column: "priority" (then deadline), "deadline",
  --- "scheduled" or "file".
  sort = "priority",
  --- Window: "float", "tab", "split", "vsplit" or "current".
  layout = "float",
  --- Size of the float: fractions of the editor, or columns / lines.
  width = 0.94,
  height = 0.88,
  --- Column width limits; columns share the window width between them.
  min_column_width = 22,
  max_column_width = 44,
  --- Lines of a card's title before it is cut.
  title_lines = 2,
  --- What cards show.
  card = { priority = true, tags = true, deadline = true, scheduled = false, effort = true, category = false },
  --- Save the file after moving a card; nil follows `agenda.save_after_edit`.
  ---@type boolean|nil
  save = nil,
  --- Keys in the board.
  keys = {
    prev_state = "h",
    next_state = "l",
    down = "j",
    up = "k",
    prev_column = "H",
    next_column = "L",
    move_down = "J",
    move_up = "K",
    jump = "<CR>",
    refresh = "r",
    filter = "/",
    quit = { "<Esc>", "q" },
  },
}

M.actions = {
  kanban_open = { MOD, "open", desc = "Kanban board of the agenda files (or the `source` option)" },
  kanban_buffer = { MOD, "open_buffer", desc = "Kanban board of the current buffer" },
  kanban_subtree = { MOD, "open_subtree", desc = "Kanban board of the subtree at the cursor" },
}

M.commands = {
  kanban = {
    MOD,
    "command",
    desc = "Kanban board: :Org kanban [agenda|buffer|subtree|<file>] [filter]",
    complete = function(arglead, cmdline)
      return require(MOD).complete(arglead, cmdline)
    end,
  },
}

M.mappings = { global = { kanban_open = "<prefix>Vk" } }
M.groups = { { "V", "views" } }

--- The open board, or nil.
---@type table|nil
M.state = nil

local function opts()
  return require("org.extensions").opts("kanban") or M.defaults
end

function M.setup()
  views.highlights(augroup, {
    OrgKanbanTitle = { link = "Title" },
    OrgKanbanHint = { link = "Comment" },
    OrgKanbanBorder = { link = "FloatBorder" },
    OrgKanbanSelected = { link = "Special" },
    -- no colours of its own: the text keeps the window background
    OrgKanbanCardTitle = {},
    OrgKanbanDoneTitle = { link = "Comment" },
    OrgKanbanCount = { link = "Comment" },
    OrgKanbanWipExceeded = { link = "DiagnosticError" },
    OrgKanbanOverdue = { link = "DiagnosticError" },
    OrgKanbanDueSoon = { link = "DiagnosticWarn" },
    OrgKanbanDue = { link = "Comment" },
    OrgKanbanScheduled = { link = "Comment" },
    OrgKanbanEffort = { link = "Comment" },
    OrgKanbanCategory = { link = "Comment" },
    OrgKanbanEmpty = { link = "NonText" },
  })
end

function M.teardown()
  M.close()
  vim.api.nvim_clear_autocmds({ group = augroup })
end

function M.health(h)
  h.ok("kanban: :Org kanban")
end

---------------------------------------------------------------------------
-- Columns and cards
---------------------------------------------------------------------------

---@class org.kanban.Keywords
---@field all string[] the keywords, in the order they are defined
---@field is table<string, true> the keywords
---@field done table<string, true> the done keywords

--- The TODO keywords of `api.todo_keywords()` as lookups.
---@param kws org.api.TodoKeywords
---@return org.kanban.Keywords
local function keyword_set(kws)
  local set = { all = kws.all, is = {}, done = {} }
  for _, k in ipairs(kws.all) do
    set.is[k] = true
  end
  for _, k in ipairs(kws.done) do
    set.done[k] = true
  end
  return set
end
M._keyword_set = keyword_set

--- The columns of the board: `{ name, keywords, set, wip, done }`.
---@param o table options
---@param global org.kanban.Keywords the keywords of the `todo_keywords` option
---@param sets org.kanban.Keywords[] the keywords of the board's files
---@return table[]
function M.columns(o, global, sets)
  local spec = o.columns
  if not spec or #spec == 0 then
    spec = {}
    local seen = {}
    local function add(set)
      for _, name in ipairs(set.all) do
        if not seen[name] then
          seen[name] = true
          spec[#spec + 1] = name
        end
      end
    end
    add(global)
    for _, set in ipairs(sets) do
      add(set)
    end
  end
  local cols = {}
  for _, c in ipairs(spec) do
    local kws = type(c) == "table" and vim.list_slice(c, 1) or { c }
    if #kws > 0 then
      local name = type(c) == "table" and c.name or kws[1]
      local set, done = {}, true
      for _, k in ipairs(kws) do
        set[k] = true
        local is_done = global.done[k] == true
        for _, s in ipairs(sets) do
          if s.is[k] then
            is_done = s.done[k] == true
            break
          end
        end
        done = done and is_done
      end
      local wip = type(c) == "table" and c.wip or (o.wip or {})[name] or (o.wip or {})[kws[1]]
      if o.show_done ~= false or not done then
        cols[#cols + 1] = { name = name, keywords = kws, set = set, wip = tonumber(wip), done = done, cards = {} }
      end
    end
  end
  return cols
end

--- Days before a deadline its warning starts: the `-Nd` cookie's
--- (org-get-wdays: a month is 30.4 days, a year 365.25), else 14.
---@param dl org.api.Date
---@return integer
local function warning_days(dl)
  local w = dl.warning
  if not w then
    return 14
  end
  local mult = { h = 1 / 24, d = 1, w = 7, m = 30.4, y = 365.25 }
  return math.floor(w.value * (mult[w.unit] or 1))
end

--- `H:MM` for a number of minutes.
---@param minutes number
---@return string
local function format_duration(minutes)
  local neg = minutes < 0
  minutes = math.abs(math.floor(minutes + 0.5))
  local s = string.format("%d:%02d", math.floor(minutes / 60), minutes % 60)
  return neg and "-" .. s or s
end

---@param h org.api.Headline
---@param today integer
---@param keywords org.kanban.Keywords|nil the TODO keywords of its file
local function card_of(h, today, keywords)
  local dl, sc = h.deadline, h.scheduled
  return {
    h = h,
    ref = views.handle_ref(h),
    title = h.plain_title,
    todo = h.todo,
    priority = h.priority,
    tags = h.tags,
    done = h.done,
    deadline = dl and (dl.days - today) or nil,
    warning = dl and warning_days(dl) or nil,
    scheduled = sc and (sc.days - today) or nil,
    effort = h.effort,
    category = h.category,
    prio_value = h.priority_value,
    -- the TODO keywords of the card's file (#+TODO lines)
    keywords = keywords,
  }
end

local function sort_cards(cards, how)
  if how == "file" then
    return
  end
  local function by_date(a, b, key)
    local x, y = a[key], b[key]
    if x ~= y then
      if x == nil then
        return false
      elseif y == nil then
        return true
      end
      return x < y
    end
    return nil
  end
  table.sort(cards, function(a, b)
    if how == "priority" and a.prio_value ~= b.prio_value then
      return a.prio_value > b.prio_value
    end
    local r = by_date(a, b, how == "scheduled" and "scheduled" or "deadline")
    if r ~= nil then
      return r
    end
    return a.order < b.order
  end)
end

--- The fields of the headline handles (`:h org-api-headlines`) the cards
--- show or are sorted by, beside the ones a handle always has.
---@param o table options
---@return string[]
function M.fields(o)
  local card, sort = o.card or {}, o.sort
  local fields = {}
  local function want(name, yes)
    if yes then
      fields[#fields + 1] = name
    end
  end
  want("deadline", card.deadline ~= false or sort == "priority" or sort == "deadline")
  want("scheduled", card.scheduled or sort == "scheduled")
  want("effort", card.effort ~= false)
  want("category", card.category)
  want("priority_value", sort == "priority")
  return fields
end

--- Build the board data: columns with their cards. Remembers in `st` the
--- files shown (`file_set`, `key`) for the redraw watch.
---@param st table board state
---@return table[] columns, string|nil err
function M.build(st)
  local o = st.opts
  local sf = views.source_files(st.src)
  st.file_set, st.key = sf.file_set, sf.key
  local sets, by_file = {}, {}
  for _, where in ipairs(sf.files) do
    local kws = api.todo_keywords(where)
    if kws then
      sets[#sets + 1] = keyword_set(kws)
      by_file[where] = sets[#sets]
    end
  end
  local cols = M.columns(o, keyword_set(assert(api.todo_keywords())), sets)
  local by_kw, kws = {}, {}
  for _, c in ipairs(cols) do
    for _, k in ipairs(c.keywords) do
      if not by_kw[k] then
        by_kw[k] = c
        kws[#kws + 1] = k
      end
    end
  end
  local hs, err = views.collect(st.src, {
    query = o.query,
    filter = st.filter,
    tag = st.tag,
    todo = kws,
    fields = M.fields(o),
  })
  local today = api.today().days
  for i, h in ipairs(hs) do
    local card = card_of(h, today, by_file[h.file or h.bufnr])
    card.order = i
    local c = by_kw[h.todo]
    c.cards[#c.cards + 1] = card
  end
  for _, c in ipairs(cols) do
    sort_cards(c.cards, o.sort)
  end
  return cols, err
end

---------------------------------------------------------------------------
-- Rendering
---------------------------------------------------------------------------

local B = { tl = "╭", tr = "╮", bl = "╰", br = "╯", h = "─", v = "│", rule = "━" }

--- `ch` repeated over `cells` display cells. Box-drawing characters are
--- two cells wide with 'ambiwidth' "double"; a cell they can't fill is a
--- space.
local function fill(ch, cells)
  local cw = math.max(1, views.width(ch))
  local n = math.max(0, math.floor(cells / cw))
  return string.rep(ch, n) .. string.rep(" ", math.max(0, cells - n * cw))
end
M._fill = fill

--- A border row `w` cells wide: `l`, `h` repeated, `r`.
local function edge(l, h, r, w)
  return l .. fill(h, w - views.width(l) - views.width(r)) .. r
end

--- Wrap `s` into at most `n` lines of `width` cells; the last is cut.
local function wrap(s, width, n)
  local words = vim.split(vim.trim(s), "%s+", { trimempty = true })
  local out, cur, i = {}, "", 1
  while i <= #words do
    local cand = cur == "" and words[i] or (cur .. " " .. words[i])
    if cur == "" or views.width(cand) <= width then
      cur, i = cand, i + 1
    elseif #out == n - 1 then
      break
    else
      out[#out + 1], cur = cur, ""
    end
  end
  if i <= #words then
    cur = cur .. " " .. table.concat(words, " ", i)
  end
  out[#out + 1] = cur
  for k, l in ipairs(out) do
    out[k] = views.truncate(l, width)
  end
  return out
end
M._wrap = wrap

--- Rows of a card: each row a list of segments exactly `w` cells wide.
--- The first and last segment of each row are the border.
local function card_rows(card, w, o)
  local border = "OrgKanbanBorder"
  local inner = w - 2 * views.width(B.v) - 2
  local rows = {}
  local function row(segs)
    local used = 0
    for _, s in ipairs(segs) do
      used = used + views.width(s[1])
    end
    local line = { { B.v .. " ", border } }
    vim.list_extend(line, segs)
    line[#line + 1] = { string.rep(" ", math.max(0, inner - used)) .. " " .. B.v, border }
    rows[#rows + 1] = line
  end
  rows[1] = { { edge(B.tl, B.h, B.tr, w), border } }
  local prefix = ""
  local show_prio = o.card.priority ~= false and card.priority
  if show_prio then
    prefix = "[#" .. card.priority .. "] "
  end
  local title_hl = card.done and "OrgKanbanDoneTitle" or "OrgKanbanCardTitle"
  local lines = wrap(prefix .. card.title, inner, math.max(1, o.title_lines or 2))
  for i, l in ipairs(lines) do
    if i == 1 and show_prio and l:sub(1, #prefix) == prefix then
      row({ { prefix, views.priority_group(card.priority) }, { l:sub(#prefix + 1), title_hl } })
    else
      row({ { l, title_hl } })
    end
  end
  -- meta: deadline, scheduled, effort
  local meta, mw = {}, 0
  local function add(text, hl)
    if mw > 0 then
      text = "  " .. text
    end
    local tw = views.width(text)
    if mw + tw <= inner then
      meta[#meta + 1] = { text, hl }
      mw = mw + tw
    end
  end
  if o.card.deadline ~= false and card.deadline and not card.done then
    local d = card.deadline
    local hl = d < 0 and "OrgKanbanOverdue" or (d <= (card.warning or 14) and "OrgKanbanDueSoon" or "OrgKanbanDue")
    add("◆ " .. views.relative_days(d), hl)
  end
  if o.card.scheduled and card.scheduled and not card.done then
    add("▸ " .. views.relative_days(card.scheduled), "OrgKanbanScheduled")
  end
  if o.card.effort ~= false and card.effort then
    add("◷ " .. format_duration(card.effort), "OrgKanbanEffort")
  end
  if #meta > 0 then
    row(meta)
  end
  local tagsegs, tw = {}, 0
  if o.card.tags ~= false and #card.tags > 0 then
    local text = views.truncate(":" .. table.concat(card.tags, ":") .. ":", inner)
    tagsegs[1] = { text, "OrgTags" }
    tw = views.width(text)
  end
  if o.card.category and card.category then
    local cat = card.category
    if tw + views.width(cat) + 1 <= inner then
      tagsegs[#tagsegs + 1] = { string.rep(" ", inner - tw - views.width(cat)) .. cat, "OrgKanbanCategory" }
    end
  end
  if #tagsegs > 0 then
    row(tagsegs)
  end
  rows[#rows + 1] = { { edge(B.bl, B.h, B.br, w), border } }
  return rows
end

local function header_rows(col, w)
  local segs, used = { { " " } }, 1
  local label = col.name
  -- the face of the keyword per the `todo_keywords` option
  local hl = views.todo_group(col.keywords[1])
  segs[#segs + 1] = { views.truncate(label, math.max(1, w - 8)), hl }
  used = used + views.width(segs[#segs][1])
  local n = #col.cards
  local count = col.wip and string.format("%d/%d", n, col.wip) or tostring(n)
  local over = col.wip and n > col.wip
  local ctext = "  " .. count .. (over and " !" or "")
  segs[#segs + 1] = { ctext, over and "OrgKanbanWipExceeded" or "OrgKanbanCount" }
  used = used + views.width(ctext)
  segs[#segs + 1] = { string.rep(" ", math.max(0, w - used)) }
  return { segs, { { fill(B.rule, w), over and "OrgKanbanWipExceeded" or hl } } }
end

--- Column width for `n` columns in `avail` cells.
function M.column_width(n, avail, o)
  local gap = 1
  local w = math.floor((avail - gap * (n - 1)) / math.max(1, n))
  -- a card needs its borders and a few cells of text
  return math.max(8, o.min_column_width or 22, math.min(o.max_column_width or 44, w))
end

local function hint(o)
  local k = o.keys or {}
  local function key(name)
    return require("org.extensions.views_util").key_hint(k, name)
  end
  local parts = {}
  for _, p in ipairs({
    { "prev_state", "next_state", "move" },
    { "down", "up", "cards" },
    { "move_down", "move_up", "reorder" },
    { "prev_column", "next_column", "columns" },
    { "jump", nil, "open" },
    { "filter", nil, "filter" },
    { "refresh", nil, "refresh" },
    { "quit", nil, "quit" },
  }) do
    local a, b = key(p[1]), p[2] and key(p[2])
    if a then
      parts[#parts + 1] = (b and (a .. "/" .. b) or a) .. " " .. p[3]
    end
  end
  return table.concat(parts, "  ")
end

local HEADER_LINES = 2 -- title, blank

--- Keep the selection inside the board.
local function clamp_selection(st)
  local cols = st.cols or {}
  st.sel.col = math.max(1, math.min(st.sel.col, math.max(1, #cols)))
  local sc = cols[st.sel.col]
  st.sel.row = sc and math.max(math.min(st.sel.row, #sc.cards), #sc.cards > 0 and 1 or 0) or 0
end

--- The rectangle of the selected card, or nil.
local function selected_rect(st)
  for _, r in ipairs(st.rects or {}) do
    if r.col == st.sel.col and r.row == st.sel.row then
      return r
    end
  end
end

--- Highlight the border of the selected card (its own namespace, so
--- moving the selection redraws nothing else).
local function paint_selection(st)
  if not vim.api.nvim_buf_is_valid(st.buf) then
    return
  end
  vim.api.nvim_buf_clear_namespace(st.buf, sel_ns, 0, -1)
  local r = selected_rect(st)
  if not r then
    return
  end
  local function mark(lnum, s, e)
    pcall(vim.api.nvim_buf_set_extmark, st.buf, sel_ns, lnum - 1, s, {
      end_col = e,
      hl_group = "OrgKanbanSelected",
      priority = 200,
    })
  end
  for k, sp in ipairs(r.spans) do
    local lnum, s, e = sp[1], sp[2], sp[3]
    if k == 1 or k == #r.spans then
      mark(lnum, s, e)
    else
      mark(lnum, s, s + #B.v)
      mark(lnum, e - #B.v, e)
    end
  end
end

--- Draw the board from `st.cols` (built by `build`).
---@param st table
function M.draw(st)
  if not vim.api.nvim_buf_is_valid(st.buf) then
    return
  end
  local o = st.opts
  local cols, err = st.cols or {}, st.err
  local win = st.win and vim.api.nvim_win_is_valid(st.win) and st.win or nil
  local avail = (win and vim.api.nvim_win_get_width(win) or vim.o.columns) - 2
  local w = M.column_width(#cols, avail, o)
  st.col_width = w
  clamp_selection(st)

  local cv = views.Canvas.new()
  cv:add({ { " Kanban", "OrgKanbanTitle" }, { "  " .. views.source_label(st.src), "OrgKanbanHint" } })
  local filters = {}
  if o.query then
    filters[#filters + 1] = "query " .. o.query
  end
  if st.tag and st.tag ~= "" then
    filters[#filters + 1] = "tag " .. st.tag
  end
  if st.filter and st.filter ~= "" then
    filters[#filters + 1] = "filter " .. st.filter
  end
  if #filters > 0 then
    cv:put("  · " .. table.concat(filters, " · "), "OrgKanbanHint")
  end
  if err then
    cv:put("  " .. err, "DiagnosticError")
  end
  cv:add({ { " " .. hint(o), "OrgKanbanHint" } })

  -- each column as rows of segments; `owner[ci][i]` is the card rect a
  -- row belongs to
  local col_rows, owner = {}, {}
  local rects = {}
  local height = 0
  for ci, col in ipairs(cols) do
    local rows = header_rows(col, w)
    owner[ci] = {}
    for ri, card in ipairs(col.cards) do
      local top = #rows + 1
      vim.list_extend(rows, card_rows(card, w, o))
      local rect = { col = ci, row = ri, top = top, bottom = #rows, card = card, spans = {} }
      rects[#rects + 1] = rect
      for i = top, #rows do
        owner[ci][i] = rect
      end
    end
    if #col.cards == 0 then
      rows[#rows + 1] = { { views.center("·", w), "OrgKanbanEmpty" } }
    end
    col_rows[ci] = rows
    height = math.max(height, #rows)
  end
  local base = HEADER_LINES
  for i = 1, height do
    local lnum = cv:line()
    cv:put(" ")
    for ci = 1, #cols do
      if ci > 1 then
        cv:put(" ")
      end
      local r = col_rows[ci][i]
      if r then
        local l = cv.lines[lnum]
        local b0 = l.bytes
        for _, s in ipairs(r) do
          cv:put(s[1], s[2])
        end
        local rect = owner[ci][i]
        if rect then
          rect.spans[#rect.spans + 1] = { lnum, b0, l.bytes }
        end
      elseif ci < #cols then
        cv:put(string.rep(" ", w))
      end
    end
  end
  if #cols == 0 then
    cv:add({ { " No TODO keywords to show", "OrgKanbanEmpty" } })
  end
  for _, r in ipairs(rects) do
    r.top = r.top + base
    r.bottom = r.bottom + base
    r.left = 2 + (r.col - 1) * (w + 1)
    r.right = r.left + w - 1
  end
  st.rects = rects
  st.lines = cv:strings()
  vim.api.nvim_buf_clear_namespace(st.buf, sel_ns, 0, -1)
  cv:draw(st.buf, ns)
  paint_selection(st)
  M.place_cursor(st)
end

--- Build and draw the board.
---@param st table
function M.render(st)
  if not vim.api.nvim_buf_is_valid(st.buf) then
    return
  end
  st.cols, st.err = M.build(st)
  M.draw(st)
end

--- Put the cursor on the selected card (or the column's header).
function M.place_cursor(st)
  if not (st.win and vim.api.nvim_win_is_valid(st.win)) then
    return
  end
  local r = selected_rect(st)
  local lnum, vcol
  if r then
    lnum, vcol = r.top + 1, r.left + 2
  else
    lnum, vcol = HEADER_LINES + 1, 2 + (st.sel.col - 1) * ((st.col_width or 0) + 1) + 1
  end
  lnum = math.min(lnum, vim.api.nvim_buf_line_count(st.buf))
  local col = vim.fn.virtcol2col(st.win, lnum, vcol)
  st.placing = true
  pcall(vim.api.nvim_win_set_cursor, st.win, { lnum, math.max(0, col - 1) })
  st.placing = false
end

---------------------------------------------------------------------------
-- Commands in the board
---------------------------------------------------------------------------

local function current()
  local st = M.state
  if st and vim.api.nvim_buf_is_valid(st.buf) then
    return st
  end
end

--- The selected card, or nil.
function M.selected()
  local st = current()
  if not st or not st.cols then
    return nil
  end
  local col = st.cols[st.sel.col]
  return col and col.cards[st.sel.row] or nil
end

--- Whether two references are in the same file (or buffer).
local function same_file(a, b)
  if a.filename and b.filename then
    return views.same_file(a.filename, b.filename)
  end
  return a.filename == b.filename and a.bufnr == b.bufnr
end

local function same_ref(a, b)
  return a.lnum == b.lnum and same_file(a, b)
end

--- Select the card whose headline is at `ref` (file and line), if shown.
local function reselect(st, ref)
  for ci, col in ipairs(st.cols or {}) do
    for ri, card in ipairs(col.cards) do
      if same_ref(card.ref, ref) then
        st.sel = { col = ci, row = ri }
        return true
      end
    end
  end
  return false
end

--- Rebuild and redraw, keeping the selected card selected. With `lazy`
--- (the redraw watch), nothing happens while the board's files are
--- unchanged.
---@param lazy? boolean
function M.refresh(lazy)
  local st = current()
  if not st then
    return
  end
  if lazy == true and st.key and st.key == views.source_files(st.src).key then
    return
  end
  local card = M.selected()
  st.cols, st.err = M.build(st)
  if card then
    reselect(st, card.ref)
  end
  M.draw(st)
end

--- Move the selection by `dr` cards and `dc` columns.
function M.move(dr, dc)
  local st = current()
  if not st or not st.cols or #st.cols == 0 then
    return
  end
  if dc ~= 0 then
    local r = selected_rect(st)
    local line = r and r.top or 0
    st.sel.col = math.max(1, math.min(#st.cols, st.sel.col + dc))
    -- the card of the new column nearest the old line
    local best, dist = 0, math.huge
    for _, x in ipairs(st.rects) do
      if x.col == st.sel.col and math.abs(x.top - line) < dist then
        best, dist = x.row, math.abs(x.top - line)
      end
    end
    st.sel.row = best
  else
    local n = #st.cols[st.sel.col].cards
    st.sel.row = n == 0 and 0 or math.max(1, math.min(n, st.sel.row + dr))
  end
  paint_selection(st)
  M.place_cursor(st)
end

--- The keywords of column `col` that a card's file knows.
local function usable_keywords(col, card)
  local out = {}
  for _, k in ipairs(col.keywords) do
    if not card.keywords or card.keywords.is[k] then
      out[#out + 1] = k
    end
  end
  return out
end

--- Report what an org.api change returned instead of the handle: a change
--- that org refused or the user cancelled has said why already.
---@param err string|nil
local function report(err)
  if err then
    views.warn("kanban: " .. err)
  end
end

--- Move the selected card to the previous (`dir` = -1) or next column:
--- its headline gets the first keyword of that column that its file
--- knows (columns without one are skipped); with `choose_keyword` and
--- several, the user picks one.
function M.move_card(dir)
  local st = current()
  local card = M.selected()
  if not st or not card then
    return
  end
  local ci, kws = st.sel.col + dir, nil
  while st.cols[ci] do
    kws = usable_keywords(st.cols[ci], card)
    if #kws > 0 then
      break
    end
    ci = ci + dir
  end
  local to = st.cols[ci]
  if not to or not kws then
    return
  end
  local kw = kws[1]
  local co, main = coroutine.running()
  if st.opts.choose_keyword and #kws > 1 and co and not main then
    kw = views.select(kws, { prompt = "State: " })
    if not kw or not current() then
      return
    end
  end
  -- as C-c C-t: a note the logging wants is asked for
  local ok, err = card.h:set_todo(kw, { interactive = true, save = views.save_after_edit(st.opts.save) })
  if not ok then
    report(err)
  end
  if current() == st then
    st.cols, st.err = M.build(st)
    if not reselect(st, card.ref) then
      -- the card left the board (or moved under the new state's sort)
      st.sel.col = math.max(1, math.min(#st.cols, ci))
    end
    M.draw(st)
  end
end

--- Move the selected card before the previous (`dir` = -1) or after the
--- next card of its column in the file: its subtree moves past the other
--- one's. Only for siblings (the same parent heading), with sort = "file".
function M.move_order(dir)
  local st = current()
  local card = M.selected()
  if not st or not card then
    return
  end
  if st.opts.sort ~= "file" then
    views.warn("kanban: cards are sorted by " .. tostring(st.opts.sort) .. '; reorder them with sort = "file"')
    return
  end
  local other = st.cols[st.sel.col].cards[st.sel.row + dir]
  if not other then
    return
  end
  -- siblings share a parent heading (or both are at the top of one file)
  local pa, pb = card.h:parent(), other.h:parent()
  local siblings
  if pa or pb then
    siblings = pa ~= nil and pb ~= nil and same_ref(views.handle_ref(pa), views.handle_ref(pb))
  else
    siblings = same_file(card.ref, other.ref)
  end
  if not siblings then
    views.warn("kanban: only cards under the same heading can be reordered")
    return
  end
  local save = views.save_after_edit(st.opts.save)
  local ok, err
  if dir > 0 then
    ok, err = card.h:move_after(other.h, { save = save })
  else
    ok, err = card.h:move_before(other.h, { save = save })
  end
  if not ok then
    report(err)
    return
  end
  if current() == st then
    st.cols, st.err = M.build(st)
    -- the handle followed the subtree
    reselect(st, views.handle_ref(card.h))
    M.draw(st)
  end
end

function M.jump()
  local st = current()
  local card = M.selected()
  if st and card then
    views.jump(card.ref, st.how)
    M.state = vim.api.nvim_buf_is_valid(st.buf) and st or nil
  end
end

--- Ask for a filter: an org-ql sexp `(…)` or a tags match (`work-home`);
--- empty clears it.
function M.ask_filter()
  local st = current()
  if not st then
    return
  end
  local input = views.input({ prompt = "Filter (tags match or (ql query)): ", default = st.filter or "" })
  if input == nil or current() ~= st then
    return
  end
  local _, err = views.compile_filter(input)
  if err then
    views.error(err)
    return
  end
  local card = M.selected()
  st.filter = vim.trim(input) ~= "" and vim.trim(input) or nil
  st.sel = { col = st.sel.col, row = 1 }
  st.cols, st.err = M.build(st)
  -- keep the selected card when the filter lets it through
  if card then
    reselect(st, card.ref)
  end
  M.draw(st)
end

function M.close()
  local st = M.state
  M.state = nil
  if not st then
    return
  end
  pcall(vim.api.nvim_del_augroup_by_id, st.watch)
  if vim.api.nvim_buf_is_valid(st.buf) then
    local win = st.how.win
    if win and vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == st.buf then
      views.close(st.how)
    end
    if vim.api.nvim_buf_is_valid(st.buf) then
      pcall(vim.api.nvim_buf_delete, st.buf, { force = true })
    end
  end
end

local function on_cursor(st)
  if st.placing or not st.rects then
    return
  end
  local pos = vim.api.nvim_win_get_cursor(0)
  local vcol = vim.fn.virtcol(".")
  for _, r in ipairs(st.rects) do
    if pos[1] >= r.top and pos[1] <= r.bottom and vcol >= r.left and vcol <= r.right then
      if r.col ~= st.sel.col or r.row ~= st.sel.row then
        st.sel = { col = r.col, row = r.row }
        paint_selection(st)
      end
      return
    end
  end
end

---------------------------------------------------------------------------
-- Opening
---------------------------------------------------------------------------

--- Open the board.
---@param o? { source?: any, filter?: string, tag?: string, query?: string }
function M.open(o)
  o = type(o) == "table" and o or {}
  local eopts = vim.deepcopy(opts())
  if o.query then
    eopts.query = o.query
  end
  local src, err = views.resolve_source(o.source or eopts.source)
  if not src then
    views.error("kanban: " .. err)
    return
  end
  M.close()
  local buf = views.scratch("org://kanban", "orgkanban")
  local st = {
    buf = buf,
    src = src,
    opts = eopts,
    filter = o.filter,
    tag = o.tag or eopts.tag,
    sel = { col = 1, row = 1 },
  }
  M.state = st
  st.win, st.how = views.open(buf, eopts.layout, { width = eopts.width, height = eopts.height, title = "Kanban" })
  vim.wo[st.win].cursorline = false
  views.map(buf, eopts.keys, {
    prev_state = function()
      M.move_card(-1)
    end,
    next_state = function()
      M.move_card(1)
    end,
    down = function()
      M.move(1, 0)
    end,
    up = function()
      M.move(-1, 0)
    end,
    move_down = function()
      M.move_order(1)
    end,
    move_up = function()
      M.move_order(-1)
    end,
    prev_column = function()
      M.move(0, -1)
    end,
    next_column = function()
      M.move(0, 1)
    end,
    jump = M.jump,
    refresh = function()
      M.refresh()
    end,
    filter = M.ask_filter,
    quit = M.close,
  }, "kanban")
  st.watch = views.watch("OrgKanbanWatch", function()
    if current() == st then
      M.refresh(true)
    end
  end, { buf = buf, relevant = views.relevant(st) })
  vim.api.nvim_create_autocmd("CursorMoved", {
    group = st.watch,
    buffer = buf,
    callback = function()
      on_cursor(st)
    end,
  })
  vim.api.nvim_create_autocmd({ "WinResized", "VimResized" }, {
    group = st.watch,
    callback = function(ev)
      if current() ~= st then
        return
      end
      if ev.event == "WinResized" and not vim.tbl_contains(vim.v.event.windows or {}, st.win) then
        return
      end
      if ev.event == "VimResized" then
        views.relayout(st.how)
      end
      pcall(M.draw, st)
    end,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = st.watch,
    buffer = buf,
    callback = function()
      if M.state == st then
        M.state = nil
      end
      vim.schedule(function()
        pcall(vim.api.nvim_del_augroup_by_id, st.watch)
      end)
    end,
  })
  M.render(st)
  return st
end

function M.open_buffer()
  return M.open({ source = "buffer" })
end

function M.open_subtree()
  return M.open({ source = "subtree" })
end

--- Parse `:Org kanban` arguments: an optional source word, then a filter.
---@param args string
---@return table
function M.parse_args(args)
  args = vim.trim(args or "")
  local first, rest = args:match("^(%S+)%s*(.*)$")
  local o = {}
  if first == "agenda" or first == "buffer" or first == "subtree" then
    o.source, args = first, rest
  elseif first and views.is_path(first) then
    o.source, args = views.expand(first), rest
  end
  if args ~= "" then
    o.filter = args
  end
  return o
end

--- Completion of `:Org kanban`: a source, then tags for the filter.
function M.complete(arglead, cmdline)
  local words = vim.split(cmdline, "%s+", { trimempty = false })
  -- "Org kanban <arglead>": the first argument
  if #words <= 3 then
    return vim.list_extend(views.complete_sources(arglead), views.complete_tags())
  end
  return views.complete_tags()
end

--- `:Org kanban [agenda|buffer|subtree|<file>] [filter]`.
function M.command(args)
  local o = M.parse_args(args)
  if o.filter then
    local _, err = views.compile_filter(o.filter)
    if err then
      views.error(err)
      return
    end
  end
  return M.open(o)
end

return M
