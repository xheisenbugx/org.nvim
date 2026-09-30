---@mod org.extensions.kanban Kanban board of TODO states
---
--- A board with one column per TODO keyword (or group of keywords) and a
--- card per headline. Moving a card changes the headline's TODO state with
--- the regular `org.todo` code, so logging, CLOSED, blocking and repeaters
--- behave as with `C-c C-t`.
---
--- ```lua
--- require("org").setup({ extensions = { kanban = {
---   columns = { "TODO", { "NEXT", "WAITING", name = "Doing", wip = 3 }, "DONE" },
--- } } })
--- ```

local views = require("org.extensions.views_util")
local date = require("org.date")
local utils = require("org.utils")

local M = {}

local MOD = "org.extensions.kanban"
local ns = vim.api.nvim_create_namespace("org_kanban")
local sel_ns = vim.api.nvim_create_namespace("org_kanban_selection")
local augroup = vim.api.nvim_create_augroup("OrgKanban", { clear = true })

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
    quit = "<Esc>",
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

--- The columns of the board: `{ name, keywords, set, wip, done }`.
---@param o table options
---@param files org.File[]
---@return table[]
function M.columns(o, files)
  local global = require("org.todo_keywords").global()
  local spec = o.columns
  if not spec or #spec == 0 then
    spec = {}
    local seen = {}
    local function add(cfg)
      for _, kw in ipairs(cfg.keywords) do
        if not seen[kw.name] then
          seen[kw.name] = true
          spec[#spec + 1] = kw.name
        end
      end
    end
    add(global)
    for _, f in ipairs(files) do
      add(f.settings.todo)
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
        local is_done = global:is_done(k)
        for _, f in ipairs(files) do
          if f.settings.todo:is_keyword(k) then
            is_done = f.settings.todo:is_done(k)
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

local function card_of(hl, today)
  local dl, sc = hl.planning.deadline, hl.planning.scheduled
  return {
    ref = views.ref(hl),
    title = views.title(hl),
    todo = hl.todo,
    priority = hl.priority,
    tags = hl.tags,
    done = hl:is_done(),
    deadline = dl and (dl:days() - today) or nil,
    warning = dl and date.warning_days(dl) or nil,
    scheduled = sc and (sc:days() - today) or nil,
    effort = views.effort(hl),
    category = hl:get_category(),
    prio_value = require("org.agenda.items").priority_value(hl),
    -- the TODO keywords of the card's file (#+TODO lines)
    todo_cfg = hl.file.settings.todo,
    -- siblings share a parent (the file for top-level headlines)
    parent = hl.parent or hl.file,
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

--- Build the board data: columns with their cards. Remembers in `st` the
--- files shown (`file_set`, `key`) for the redraw watch.
---@param st table board state
---@return table[] columns, string|nil err
function M.build(st)
  local o = st.opts
  local files = views.files(st.src)
  st.file_set = views.file_set(files)
  st.key = views.files_key(files)
  local cols = M.columns(o, files)
  local by_kw = {}
  for _, c in ipairs(cols) do
    for _, k in ipairs(c.keywords) do
      by_kw[k] = by_kw[k] or c
    end
  end
  local hls, err = views.collect(st.src, {
    files = files,
    query = o.query,
    filter = st.filter,
    tag = st.tag,
    pred = function(hl)
      return hl.todo ~= nil and by_kw[hl.todo] ~= nil
    end,
  })
  local today = date.today_days()
  for i, hl in ipairs(hls) do
    local card = card_of(hl, today)
    card.order = i
    local c = by_kw[hl.todo]
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

--- Wrap `s` into at most `n` lines of `width` cells; the last is cut.
local function wrap(s, width, n)
  local words = vim.split(vim.trim(s), "%s+", { trimempty = true })
  local out, cur, i = {}, "", 1
  while i <= #words do
    local cand = cur == "" and words[i] or (cur .. " " .. words[i])
    if cur == "" or utils.width(cand) <= width then
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
    out[k] = utils.truncate(l, width)
  end
  return out
end
M._wrap = wrap

--- Rows of a card: each row a list of segments exactly `w` cells wide.
--- The first and last segment of each row are the border.
local function card_rows(card, w, o)
  local border = "OrgKanbanBorder"
  local inner = w - 4
  local rows = {}
  local function row(segs)
    local used = 0
    for _, s in ipairs(segs) do
      used = used + utils.width(s[1])
    end
    local line = { { B.v .. " ", border } }
    vim.list_extend(line, segs)
    line[#line + 1] = { string.rep(" ", math.max(0, inner - used)) .. " " .. B.v, border }
    rows[#rows + 1] = line
  end
  rows[1] = { { B.tl .. string.rep(B.h, w - 2) .. B.tr, border } }
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
    local tw = utils.width(text)
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
    add("◷ " .. date.format_duration(card.effort), "OrgKanbanEffort")
  end
  if #meta > 0 then
    row(meta)
  end
  local tagsegs, tw = {}, 0
  if o.card.tags ~= false and #card.tags > 0 then
    local text = utils.truncate(":" .. table.concat(card.tags, ":") .. ":", inner)
    tagsegs[1] = { text, "OrgTags" }
    tw = utils.width(text)
  end
  if o.card.category and card.category then
    local cat = card.category
    if tw + utils.width(cat) + 1 <= inner then
      tagsegs[#tagsegs + 1] = { string.rep(" ", inner - tw - utils.width(cat)) .. cat, "OrgKanbanCategory" }
    end
  end
  if #tagsegs > 0 then
    row(tagsegs)
  end
  rows[#rows + 1] = { { B.bl .. string.rep(B.h, w - 2) .. B.br, border } }
  return rows
end

local function header_rows(col, w)
  local todo_cfg = require("org.todo_keywords").global()
  local segs, used = { { " " } }, 1
  local label = col.name
  local hl = views.todo_group(col.keywords[1], todo_cfg)
  segs[#segs + 1] = { utils.truncate(label, math.max(1, w - 8)), hl }
  used = used + utils.width(segs[#segs][1])
  local n = #col.cards
  local count = col.wip and string.format("%d/%d", n, col.wip) or tostring(n)
  local over = col.wip and n > col.wip
  local ctext = "  " .. count .. (over and " !" or "")
  segs[#segs + 1] = { ctext, over and "OrgKanbanWipExceeded" or "OrgKanbanCount" }
  used = used + utils.width(ctext)
  segs[#segs + 1] = { string.rep(" ", math.max(0, w - used)) }
  return { segs, { { string.rep(B.rule, w), over and "OrgKanbanWipExceeded" or hl } } }
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
    local v = k[name]
    return type(v) == "table" and v[1] or v
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

local function same_ref(a, b)
  if a.lnum ~= b.lnum then
    return false
  end
  if a.filename and b.filename then
    return views.same_file(a.filename, b.filename)
  end
  return a.filename == b.filename and a.bufnr == b.bufnr
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
  if lazy == true and st.key and st.key == views.files_key(views.files(st.src)) then
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
    if not card.todo_cfg or card.todo_cfg:is_keyword(k) then
      out[#out + 1] = k
    end
  end
  return out
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
  if not to then
    return
  end
  local kw = kws[1]
  local co, main = coroutine.running()
  if st.opts.choose_keyword and #kws > 1 and co and not main then
    kw = utils.select(kws, { prompt = "State: " })
    if not kw or not current() then
      return
    end
  end
  local target = views.target(card.ref)
  if not target then
    return
  end
  local res = require("org.todo").change_state(target, kw)
  if res then
    views.after_edit(target.bufnr, st.opts.save)
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
    utils.warn('kanban: cards are sorted by ' .. tostring(st.opts.sort) .. '; reorder them with sort = "file"')
    return
  end
  local other = st.cols[st.sel.col].cards[st.sel.row + dir]
  if not other then
    return
  end
  if card.parent ~= other.parent then
    utils.warn("kanban: only cards under the same heading can be reordered")
    return
  end
  local a, b = views.target(card.ref), views.target(other.ref)
  if not a or not b or a.bufnr ~= b.bufnr then
    return
  end
  local file = require("org.files").get_buffer(a.bufnr)
  local ha, hb = file:headline_at(a.lnum), file:headline_at(b.lnum)
  if not ha or not hb or ha.line ~= a.lnum or hb.line ~= b.lnum then
    return
  end
  local buf = a.bufnr
  local text = vim.api.nvim_buf_get_lines(buf, ha.line - 1, ha.end_line, false)
  local new_line
  if dir > 0 and hb.line > ha.end_line then
    vim.api.nvim_buf_set_lines(buf, hb.end_line, hb.end_line, false, text)
    vim.api.nvim_buf_set_lines(buf, ha.line - 1, ha.end_line, false, {})
    new_line = hb.end_line - #text + 1
  elseif dir < 0 and hb.end_line < ha.line then
    vim.api.nvim_buf_set_lines(buf, ha.line - 1, ha.end_line, false, {})
    vim.api.nvim_buf_set_lines(buf, hb.line - 1, hb.line - 1, false, text)
    new_line = hb.line
  else
    return
  end
  views.after_edit(buf, st.opts.save)
  if current() == st then
    st.cols, st.err = M.build(st)
    local ref = vim.deepcopy(card.ref)
    ref.lnum = new_line
    reselect(st, ref)
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
  local input = utils.input({ prompt = "Filter (tags match or (ql query)): ", default = st.filter or "" })
  if input == nil or current() ~= st then
    return
  end
  local _, err = views.compile_filter(input)
  if err then
    utils.error(err)
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
    utils.error("kanban: " .. err)
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
    o.source, args = utils.expand(first), rest
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
      utils.error(err)
      return
    end
  end
  return M.open(o)
end

return M
