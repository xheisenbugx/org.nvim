---@mod org.extensions.drill Spaced repetition, like Emacs org-drill
---
--- Enable with `extensions = { drill = {} }` (see `:h org-extensions-drill`).
---
--- ```lua
--- require("org.extensions.drill").start("agenda")   -- a session over the agenda files
--- ```

local card_mod = require("org.extensions.drill.card")
local sm2 = require("org.extensions.drill.sm2")
local schedule = require("org.extensions.drill.schedule")
local utils = require("org.utils")

local M = {}

M.card = card_mod
M.sm2 = sm2
M.schedule = schedule
M.cloze = require("org.extensions.drill.cloze")

M.defaults = {
  --- Tag of drill cards (org-drill-question-tag).
  tag = "drill",
  --- Cards a session looks at when `:Org drill` gets no argument
  --- (org-drill-scope): "file", "tree", "agenda", "directory", "tag:NAME"
  --- (agenda files, cards also tagged NAME) or a list of files and globs.
  scope = "file",
  --- At most this many cards per session; 0 for no limit
  --- (org-drill-maximum-items-per-session).
  maximum_items_per_session = 30,
  --- Minutes after which the session ends once the current card is done;
  --- 0 for no limit (org-drill-maximum-duration).
  maximum_duration = 20,
  --- Answers of this quality or lower fail (org-drill-failure-quality).
  failure_quality = 2,
  --- Scheduling algorithm (org-drill-spaced-repetition-algorithm): "sm5"
  --- (org-drill's default), "sm2" or "simple8".
  algorithm = "sm5",
  --- How fast intervals grow with SM-5 and Simple8 (org-drill-learn-fraction).
  learn_fraction = 0.5,
  --- First SM-5 interval in days (org-drill-sm5-initial-interval).
  sm5_initial_interval = 4.0,
  --- Where SM-5's matrix of optimal factors is kept between sessions
  --- (org-drill-sm5-optimal-factor-matrix, saved with `persist` in Emacs).
  sm5_matrix_file = vim.fn.stdpath("data") .. "/org/drill-sm5.json",
  --- A card failed more than this many times is tagged :leech:
  --- (org-drill-leech-failure-threshold); false for never.
  leech_failure_threshold = 15,
  --- Leech cards: "skip" (left out of sessions), "warn" (asked, marked as
  --- a leech) or false (asked like the others) (org-drill-leech-method).
  leech_method = "skip",
  --- Weighted cloze types (hide1_firstmore, show1_lastmore,
  --- show1_firstless) do the less favoured thing every Nth time; false
  --- makes them act like hide1cloze / show1cloze (org-drill-cloze-text-weight).
  cloze_text_weight = 4,
  --- Cram mode asks cards not reviewed in this many hours (org-drill-cram-hours).
  cram_hours = 12,
  --- Cards with a longer last interval (days) are "old" rather than "young"
  --- when a session is put in order (org-drill-days-before-old).
  days_before_old = 10,
  --- A card is overdue when it is late by more than (factor - 1) times its
  --- last interval (org-drill-overdue-interval-factor).
  overdue_interval_factor = 1.2,
  --- Failed cards come back at the end of the session until passed
  --- (as in org-drill).
  repeat_failed = true,
  --- Shuffle each group of cards (failed, overdue, young, old and new).
  shuffle = true,
  --- Write the files changed by a session when it ends
  --- (org-drill-save-buffers-after-drill-sessions-p).
  save_buffers = true,
  --- Size of the session window.
  width = 72,
  height = 20,
  border = "rounded",
  --- Keys in the session window. Grades are the keys 0-5.
  keys = {
    reveal = { "<Space>", "<CR>" },
    skip = "s",
    edit = "e",
    quit = { "<Esc>", "q" },
  },
}

--- Random 1..m, replaceable in tests.
M.random = function(m)
  return math.random(m)
end

local function opts()
  return require("org.extensions").opts("drill") or M.defaults
end

local GRADES = {
  [0] = "wrong, and the answer is unfamiliar",
  [1] = "wrong, but upon seeing the answer it felt familiar",
  [2] = "wrong, but upon seeing the answer it seemed easy",
  [3] = "correct, but it took a lot of effort",
  [4] = "correct, after some hesitation",
  [5] = "correct, and it was easy",
}
M.GRADES = GRADES

---------------------------------------------------------------------------
-- Collecting cards
---------------------------------------------------------------------------

local function has_tag(list, tag)
  for _, t in ipairs(list or {}) do
    if t == tag then
      return true
    end
  end
  return false
end

local function current_file()
  local buf = vim.api.nvim_get_current_buf()
  -- from the session window: the buffer it was started from
  local s = M.session
  if vim.bo[buf].filetype == "org_drill" and s and s.origin_win and vim.api.nvim_win_is_valid(s.origin_win) then
    buf = vim.api.nvim_win_get_buf(s.origin_win)
  end
  return require("org.files").get_buffer(buf)
end

--- Files and an optional headline range and extra tag for a scope.
---@param scope any
---@return org.File[] files, { from: integer, to: integer }|nil range, string|nil tag
function M.scope_files(scope)
  local files = require("org.files")
  scope = scope == nil and opts().scope or scope
  if type(scope) == "string" then
    scope = vim.trim(scope)
  end
  if scope == "" or scope == nil then
    scope = "file"
  end
  if scope == "file" then
    return { current_file() }
  elseif scope == "tree" then
    local f = current_file()
    local hl = f:headline_at(vim.api.nvim_win_get_cursor(0)[1])
    if not hl then
      return { f }
    end
    return { f }, { from = hl.line, to = hl.end_line }
  elseif scope == "agenda" then
    return files.agenda_files()
  elseif scope == "directory" then
    local name = vim.api.nvim_buf_get_name(0)
    local dir = name ~= "" and vim.fs.dirname(name) or vim.fn.getcwd()
    local out = {}
    for _, p in ipairs(utils.glob_org_files({ dir .. "/*.org" })) do
      out[#out + 1] = files.get(p)
    end
    return out
  elseif type(scope) == "string" and scope:match("^tag:") then
    return files.agenda_files(), nil, scope:sub(5)
  end
  local out = {}
  for _, p in ipairs(utils.glob_org_files(type(scope) == "table" and scope or vim.split(scope, "%s+"))) do
    out[#out + 1] = files.get(p)
  end
  return out
end

--- Every drill card of a scope, due or not.
---@param scope any see `scope_files`
---@return { file: org.File, hl: org.Headline, card: org.drill.Card }[]
function M.cards(scope)
  local tag = opts().tag
  local fs, range, extra = M.scope_files(scope)
  local out = {}
  for _, f in ipairs(fs) do
    for _, hl in ipairs(f.headlines) do
      if
        has_tag(hl.tags, tag)
        and (not range or (hl.line >= range.from and hl.line <= range.to))
        and (not extra or has_tag(hl:get_tags(), extra))
        and not hl.commented
        and not hl:is_archived()
      then
        out[#out + 1] = { file = f, hl = hl, card = card_mod.read(f, hl) }
      end
    end
  end
  return out
end

local function shuffle(list)
  for i = #list, 2, -1 do
    local j = M.random(i)
    list[i], list[j] = list[j], list[i]
  end
end

--- Seconds since the card was last reviewed (nil: never).
local function seconds_since_review(card)
  local d = card.last_reviewed
  if not d then
    return nil
  end
  local t = os.time({ year = d.year, month = d.month, day = d.day, hour = d.hour or 0, min = d.min or 0, sec = 0 })
  return M.now_seconds() - t
end

--- org-drill-entry-status: where a card goes in a session, or nil when it
--- is not asked. One of "failed" (failed last time), "new" (never
--- scheduled), "overdue", "young" (a last interval of `days_before_old`
--- days or less) and "old". With `cram`, every card not reviewed in the
--- last `cram_hours` hours is asked (org-drill-cram).
---@param card org.drill.Card
---@param today integer day number
---@param cram? boolean
---@return string|nil status, integer days overdue
function M.status(card, today, cram)
  local o = opts()
  if card.unknown or card_mod.is_empty(card) then
    return nil, 0
  end
  local due
  if cram then
    local secs = seconds_since_review(card)
    if secs and secs < (tonumber(o.cram_hours) or 12) * 3600 then
      return nil, 0
    end
    due = 0
  else
    if card.leech and o.leech_method == "skip" then
      return nil, 0
    end
    due = card.scheduled and (today - card.scheduled:days()) or 0
    if due < 0 then
      return nil, due
    end
  end
  local fq = tonumber(o.failure_quality) or 2
  if (card.last_quality or 9999) <= fq then
    return "failed", due
  elseif not card.scheduled then
    return "new", due
  end
  local last = card.interval or 1
  local factor = tonumber(o.overdue_interval_factor) or 1.2
  if due > 1 and (due + last + 1.0) / last > factor then
    return "overdue", due
  elseif (card.interval or 9999) <= (tonumber(o.days_before_old) or 10) then
    return "young", due
  end
  return "old", due
end

--- The cards a session asks, in org-drill's order: cards failed last time,
--- overdue cards (the most overdue first), young cards, then old and new
--- cards mixed; up to `maximum_items_per_session` (not in cram mode).
--- Every group is shuffled with `shuffle`; without it old cards come
--- before new ones.
---@param scope any
---@param today integer day number
---@param cram? boolean
function M.due_cards(scope, today, cram)
  local o = opts()
  local groups = { failed = {}, overdue = {}, young = {}, old = {}, new = {} }
  local unknown = {}
  for _, c in ipairs(M.cards(scope)) do
    local status, due = M.status(c.card, today, cram)
    if status then
      c.status, c.due = status, due
      table.insert(groups[status], c)
    elseif c.card.unknown then
      unknown[#unknown + 1] = c.card.unknown
    end
  end
  if #unknown > 0 then
    utils.warn(string.format("Drill: %d card(s) of unknown type skipped (%s)", #unknown, table.concat(unknown, ", ")))
  end
  if o.shuffle then
    for _, g in pairs(groups) do
      shuffle(g)
    end
  end
  -- org-drill-order-overdue-entries: shuffled, then by days overdue
  -- (a stable sort, so equal ones stay shuffled)
  local overdue = groups.overdue
  for i, c in ipairs(overdue) do
    c.order = i
  end
  table.sort(overdue, function(a, b)
    if a.due ~= b.due then
      return a.due > b.due
    end
    return a.order < b.order
  end)
  local pool = vim.list_extend(vim.list_extend({}, groups.old), groups.new)
  if o.shuffle then
    shuffle(pool)
  end
  local out = {}
  for _, g in ipairs({ groups.failed, overdue, groups.young, pool }) do
    vim.list_extend(out, g)
  end
  local max = tonumber(o.maximum_items_per_session) or 0
  if max > 0 and not cram then
    for i = #out, max + 1, -1 do
      out[i] = nil
    end
  end
  return out
end

---------------------------------------------------------------------------
-- Session
---------------------------------------------------------------------------

local ns = vim.api.nvim_create_namespace("org_drill")
local mark_ns = vim.api.nvim_create_namespace("org_drill_cards")

--- The running (or last) session.
---@type table|nil
M.session = nil

local function define_highlights()
  local links = {
    OrgDrillTitle = "Title",
    OrgDrillHidden = "Search",
    OrgDrillCloze = "DiffAdd",
    OrgDrillSide = "Identifier",
    OrgDrillHeading = "Identifier",
    OrgDrillRule = "Comment",
    OrgDrillHint = "Comment",
    OrgDrillHeader = "Comment",
    OrgDrillPass = "DiagnosticOk",
    OrgDrillFail = "DiagnosticError",
  }
  for name, link in pairs(links) do
    vim.api.nvim_set_hl(0, name, { link = link, default = true })
  end
end

-- position of a card's headline, following edits
local function card_line(entry)
  if entry.bufnr and entry.mark and vim.api.nvim_buf_is_valid(entry.bufnr) then
    local pos = vim.api.nvim_buf_get_extmark_by_id(entry.bufnr, mark_ns, entry.mark, {})
    if pos[1] then
      return entry.bufnr, pos[1] + 1
    end
  end
end

-- re-read the card at its current position
local function reload(entry)
  local bufnr, lnum = card_line(entry)
  if not bufnr then
    return nil
  end
  local file = require("org.files").get_buffer(bufnr)
  local hl = file:headline_at(lnum)
  if not hl or hl.line ~= lnum then
    return nil
  end
  return card_mod.read(file, hl), bufnr, lnum
end

local function format_time(seconds)
  seconds = math.max(0, math.floor(seconds))
  return string.format("%d:%02d", math.floor(seconds / 60), seconds % 60)
end

local function close_window(s)
  if s.win and vim.api.nvim_win_is_valid(s.win) then
    vim.api.nvim_win_close(s.win, true)
  end
  s.win = nil
  if s.buf and vim.api.nvim_buf_is_valid(s.buf) then
    vim.api.nvim_buf_delete(s.buf, { force = true })
  end
  s.buf = nil
end

local function footer(s)
  local quit = require("org.extensions.views_util").key_hint(
    opts().keys or {},
    "quit",
    { grade = { "0", "1", "2", "3", "4", "5" } }
  ) or "<Esc>"
  if s.finished then
    return { quit .. " close" }
  end
  if not s.revealed then
    return { "<Space> show answer   s skip   e edit   " .. quit .. " quit" }
  end
  return {
    "0-2 failed   3 hard   4 good   5 easy",
    "s skip   e edit   " .. quit .. " quit",
  }
end

local function set_lines(s, lines, hls)
  local buf = s.buf
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for _, h in ipairs(hls) do
    pcall(vim.api.nvim_buf_set_extmark, buf, ns, h[1], h[2], { end_col = h[3], hl_group = h[4] })
  end
end

-- the window fits the text, up to `height` lines
local function resize(s, nlines)
  if not (s.win and vim.api.nvim_win_is_valid(s.win)) then
    return
  end
  local o = opts()
  local width = math.min(o.width or 72, vim.o.columns - 4)
  local height = math.max(6, math.min(nlines, o.height or 20, vim.o.lines - 4))
  vim.api.nvim_win_set_config(s.win, {
    relative = "editor",
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height) / 2) - 1,
    col = math.floor((vim.o.columns - width) / 2),
  })
end

local function title_text(s)
  local name = s.cram and "Drill (cram)" or "Drill"
  if s.finished then
    return " " .. name .. ": session finished "
  end
  return string.format(" %s %d/%d ", name, s.index, #s.queue)
end

local function render(s)
  if not (s.buf and vim.api.nvim_buf_is_valid(s.buf)) then
    return
  end
  local lines, hls = {}, {}
  local function push(text, group)
    lines[#lines + 1] = text
    if group and text ~= "" then
      hls[#hls + 1] = { #lines - 1, 0, #text, group }
    end
  end
  if s.finished then
    for _, l in ipairs(M.summary_lines(s)) do
      push(l[1], l[2])
    end
  else
    local entry = s.queue[s.index]
    local c = entry.card
    local info = { c.type }
    if c.new then
      info[#info + 1] = "new"
    elseif c.data.total_repeats > 0 then
      info[#info + 1] = string.format("seen %d×, ease %.2f", c.data.total_repeats, c.data.ease or sm2.DEFAULT_EASE)
    end
    if c.leech then
      info[#info + 1] = "leech"
    end
    if entry.again then
      info[#info + 1] = "again"
    end
    if s.cram then
      info[#info + 1] = "cram"
    end
    push(table.concat(info, " · ") .. "   " .. vim.fn.fnamemodify(c.path or "[buffer]", ":t"), "OrgDrillHeader")
    push("")
    local r = card_mod.render(c, entry.choice, s.revealed)
    local base = #lines
    vim.list_extend(lines, r.lines)
    for _, h in ipairs(r.hls) do
      hls[#hls + 1] = { h[1] + base, h[2], h[3], h[4] }
    end
  end
  push("")
  for _, f in ipairs(footer(s)) do
    push(f, "OrgDrillHint")
  end
  -- pad the text by one column
  for i, l in ipairs(lines) do
    lines[i] = " " .. l
  end
  for _, h in ipairs(hls) do
    h[2], h[3] = h[2] + 1, h[3] + 1
  end
  set_lines(s, lines, hls)
  resize(s, #lines)
  if s.win and vim.api.nvim_win_is_valid(s.win) then
    pcall(vim.api.nvim_win_set_config, s.win, { title = title_text(s), title_pos = "center" })
    pcall(vim.api.nvim_win_set_cursor, s.win, { 1, 0 })
  end
end

local function map_keys(s)
  local o = opts()
  local buf = s.buf
  local function map(lhs, fn)
    for _, k in ipairs(type(lhs) == "table" and lhs or { lhs }) do
      if k and k ~= "" then
        vim.keymap.set("n", k, fn, { buffer = buf, nowait = true, silent = true })
      end
    end
  end
  local keys = o.keys or {}
  local views = require("org.extensions.views_util")
  local grades = { grade = { "0", "1", "2", "3", "4", "5" } }
  map(views.lhs(keys, "reveal", grades), function()
    M.reveal()
  end)
  map(views.lhs(keys, "skip", grades), function()
    M.skip()
  end)
  map(views.lhs(keys, "edit", grades), function()
    M.edit()
  end)
  map(views.lhs(keys, "quit", grades), function()
    M.quit()
  end)
  for q = 0, 5 do
    map(tostring(q), function()
      M.grade(q)
    end)
  end
end

local function open_window(s)
  define_highlights()
  local o = opts()
  s.buf = vim.api.nvim_create_buf(false, true)
  vim.bo[s.buf].bufhidden = "wipe"
  vim.bo[s.buf].filetype = "org_drill"
  vim.bo[s.buf].syntax = "org"
  pcall(vim.api.nvim_buf_set_name, s.buf, "org-drill")
  s.origin_win = vim.api.nvim_get_current_win()
  local width = math.min(o.width or 72, vim.o.columns - 4)
  local height = math.min(10, vim.o.lines - 4)
  s.win = vim.api.nvim_open_win(s.buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height) / 2) - 1,
    col = math.floor((vim.o.columns - width) / 2),
    style = "minimal",
    border = o.border or "rounded",
    title = title_text(s),
    title_pos = "center",
    zindex = 60,
  })
  vim.wo[s.win].wrap = true
  vim.wo[s.win].linebreak = true
  -- wrapped lines keep the text's one-column padding
  vim.wo[s.win].breakindent = true
  vim.wo[s.win].cursorline = false
  map_keys(s)
  vim.api.nvim_create_autocmd("WinClosed", {
    pattern = tostring(s.win),
    once = true,
    callback = function()
      if M.session == s and not s.finished and not s.closing then
        -- closed from outside: the session can be resumed
        s.win = nil
        s.paused = true
      end
    end,
  })
end

local function now_seconds()
  return os.time()
end
M.now_seconds = now_seconds

--- Save the buffers the session changed.
local function save(s)
  if not opts().save_buffers then
    return
  end
  for bufnr in pairs(s.buffers) do
    if vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_get_name(bufnr) ~= "" then
      utils.save_buffer_or_warn(bufnr)
    end
  end
end

local function clear_marks(s)
  for bufnr in pairs(s.buffers) do
    if vim.api.nvim_buf_is_valid(bufnr) then
      vim.api.nvim_buf_clear_namespace(bufnr, mark_ns, 0, -1)
    end
  end
end

local function finish(s)
  s.finished = true
  s.ended = M.now_seconds()
  save(s)
  clear_marks(s)
  render(s)
end

local function time_up(s)
  local max = tonumber(opts().maximum_duration) or 0
  return not s.cram and max > 0 and (M.now_seconds() - s.started) >= max * 60
end

-- show the next card, refreshing it from its buffer; cards that are gone
-- are dropped
local function advance(s)
  s.revealed = false
  while true do
    s.index = s.index + 1
    if s.index > 1 and s.index <= #s.queue and time_up(s) then
      -- time is up: no more new cards, but the failed ones are still
      -- asked until they pass (org-drill-entries-pending-p)
      for i = #s.queue, s.index, -1 do
        table.remove(s.queue, i)
      end
      s.cut = true
    end
    if s.index > #s.queue then
      if #s.again > 0 then
        for _, e in ipairs(s.again) do
          s.queue[#s.queue + 1] = e
        end
        s.again = {}
      else
        s.index = #s.queue
        finish(s)
        return
      end
    end
    local entry = s.queue[s.index]
    local c = reload(entry)
    if c then
      entry.card = c
      entry.choice = card_mod.choose(c, M.random, opts().cloze_text_weight or nil)
      render(s)
      return
    end
  end
end

--- Start a session over the due cards of `scope` (see `scope_files`);
--- with `cram`, over the cards not reviewed in the last `cram_hours`
--- hours, and nothing is rescheduled (org-drill-cram).
---@param scope? any
---@param cram? boolean
---@return table|nil session
function M.start(scope, cram)
  if M.session and not M.session.finished then
    close_window(M.session)
    clear_marks(M.session)
  end
  local date = require("org.date")
  local today = date.today():days()
  local entries = M.due_cards(scope, today, cram)
  if #entries == 0 then
    utils.notify(cram and "No drill cards to cram" or "No drill cards are due")
    return nil
  end
  local s = { queue = {}, again = {}, index = 0, buffers = {}, results = {}, started = M.now_seconds(), cram = cram }
  s.stats = { reviewed = 0, passed = 0, failed = 0, skipped = 0, qualities = {}, new = 0 }
  for q = 0, 5 do
    s.stats.qualities[q] = 0
  end
  for _, e in ipairs(entries) do
    local bufnr = e.file.bufnr
    if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
      bufnr = e.file.filename and utils.load_buffer(e.file.filename)
    end
    if bufnr then
      local mark = vim.api.nvim_buf_set_extmark(bufnr, mark_ns, e.hl.line - 1, 0, {})
      s.buffers[bufnr] = true
      s.queue[#s.queue + 1] = { bufnr = bufnr, mark = mark, card = e.card, new = e.card.new }
    end
  end
  M.session = s
  open_window(s)
  advance(s)
  return s
end

--- Show the answer of the current card.
function M.reveal()
  local s = M.session
  if not s or s.finished then
    return
  end
  s.revealed = true
  render(s)
end

---------------------------------------------------------------------------
-- Writing the result
---------------------------------------------------------------------------

--- SM-5's matrix of optimal factors, read once from `sm5_matrix_file`.
local matrix_cache

---@return table
function M.sm5_matrix()
  if not matrix_cache then
    local f = opts().sm5_matrix_file
    -- lint: allow expand: the sm5_matrix_file option
    local m = f and f ~= "" and utils.read_json(vim.fn.expand(f)) or nil
    matrix_cache = type(m) == "table" and m or {}
  end
  return matrix_cache
end

local function save_matrix(m)
  matrix_cache = m
  local f = opts().sm5_matrix_file
  if not f or f == "" then
    return
  end
  -- lint: allow expand: the sm5_matrix_file option
  f = vim.fn.expand(f)
  pcall(vim.fn.mkdir, vim.fn.fnamemodify(f, ":h"), "p")
  local ok, err = pcall(utils.write_json, f, m)
  if not ok then
    utils.warn("Drill: could not save " .. f .. ": " .. tostring(err))
  end
end

--- Forget the cached SM-5 matrix (it is read again from its file).
function M.reset_matrix()
  matrix_cache = nil
end

-- indentation for a new planning line or property drawer: the existing
-- planning line or drawer's, else the entry text's when it is indented
-- (as in the cards of most org-drill decks), else `body_indent`
local function meta_indent(file, hl)
  if hl.planning_line then
    return file.lines[hl.planning_line]:match("^(%s*)")
  elseif hl.properties_range then
    return file.lines[hl.properties_range[1]]:match("^(%s*)")
  end
  local indent = require("org.edit").body_indent(hl.level)
  if indent ~= "" then
    return indent
  end
  local stop = hl.children and hl.children[1] and hl.children[1].line - 1 or hl.end_line
  for l = hl.line + 1, stop do
    local line = file.lines[l] or ""
    if line:match("%S") then
      local w = line:match("^(%s*)")
      return #w <= hl.level + 1 and w or ""
    end
  end
  return ""
end

-- The closed folds starting in lines [from, to], per window showing
-- `bufnr` (the outermost ones: what can be seen of the entry).
local function closed_folds(bufnr, from, to)
  local out = {}
  for _, win in ipairs(vim.fn.win_findbuf(bufnr)) do
    local list = {}
    pcall(vim.api.nvim_win_call, win, function()
      local l = from
      while l <= to do
        local c = vim.fn.foldclosed(l)
        if c ~= -1 then
          if c >= from then
            list[#list + 1] = c
          end
          l = math.max(l, vim.fn.foldclosedend(l)) + 1
        else
          l = l + 1
        end
      end
    end)
    out[win] = list
  end
  return out
end

-- Close the folds again after the entry at `hl_line` changed: `folds`
-- from `closed_folds`, `map` turns an old line into its new one; the new
-- drawer at `drawer` (when the entry is open) is closed too, as org shows
-- drawers.
local function restore_folds(folds, map, hl_line, drawer)
  for win, list in pairs(folds) do
    if vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_call, win, function()
        for i = #list, 1, -1 do
          local l = map(list[i])
          if l and vim.fn.foldclosed(l) ~= l then
            vim.cmd(string.format("silent! %dfoldclose", l))
          end
        end
        if drawer and vim.fn.foldclosed(hl_line) == -1 and vim.fn.foldclosed(drawer) == -1 then
          vim.cmd(string.format("silent! %dfoldclose", drawer))
        end
      end)
    end
  end
end

--- Replace the planning line and property drawer of the headline at
--- `lnum` in one change: SCHEDULED set to `scheduled` (false removes it),
--- properties `set` ({ name, value } pairs, in order) and `remove`d.
---@param bufnr integer
---@param lnum integer
---@param scheduled table|false|nil org.date; nil keeps it
---@param set { [1]: string, [2]: string }[]
---@param remove? string[]
function M.write_meta(bufnr, lnum, scheduled, set, remove)
  local files = require("org.files")
  local edit = require("org.edit")
  local date = require("org.date")
  local file = files.get_buffer(bufnr)
  local hl = file:headline_at(lnum)
  if not hl or hl.line ~= lnum then
    return false
  end
  local indent = meta_indent(file, hl)
  local out = {}
  -- the planning line
  local planning = {}
  for k, v in pairs(hl.planning or {}) do
    planning[k] = date.Date.new(v)
    if v.range_end then
      planning[k].range_end = date.Date.new(v.range_end)
    end
  end
  if scheduled ~= nil then
    planning.scheduled = scheduled or nil
  end
  local pline = edit.build_planning(planning, indent)
  if hl.planning_line and pline then
    -- keep the text as written when SCHEDULED doesn't change
    pline = scheduled == nil and file.lines[hl.planning_line] or pline
  end
  out[#out + 1] = pline
  -- the property drawer
  local props, order = {}, {}
  local dindent = indent
  if hl.properties_range then
    local s, e = hl.properties_range[1], hl.properties_range[2]
    dindent = file.lines[s]:match("^(%s*)")
    for i = s + 1, e - 1 do
      local key = require("org.parser").parse_property_line(file.lines[i])
      local k = key and key:upper() or ("\0" .. i)
      if props[k] then
        -- a repeated property: its later lines are kept as they are
        k = "\0" .. i
      end
      order[#order + 1] = k
      props[k] = { line = file.lines[i] }
    end
  end
  for _, name in ipairs(remove or {}) do
    props[name:upper()] = nil
  end
  for _, p in ipairs(set) do
    local k = p[1]:upper()
    if not props[k] then
      order[#order + 1] = k
    end
    props[k] = { line = edit.property_line(dindent, p[1], p[2]) }
  end
  local drawer = {}
  for _, k in ipairs(order) do
    if props[k] then
      drawer[#drawer + 1] = props[k].line
      props[k] = nil
    end
  end
  if #drawer > 0 then
    out[#out + 1] = dindent .. ":PROPERTIES:"
    vim.list_extend(out, drawer)
    out[#out + 1] = dindent .. ":END:"
  end
  -- replace the lines between the headline and the end of its drawer,
  -- keeping the folds of the windows that show the entry (Neovim opens
  -- the folds of an entry whose lines change)
  local last = edit.meta_end(hl)
  local old = vim.api.nvim_buf_get_lines(bufnr, hl.line, last, false)
  if not vim.deep_equal(old, out) then
    local folds = closed_folds(bufnr, hl.line, hl.end_line)
    -- an entry whose text is hidden (the content view conceals it)
    local fold = require("org.fold")
    local ok, hidden = pcall(fold.is_concealed, bufnr, hl.line + 1)
    vim.api.nvim_buf_set_lines(bufnr, hl.line, last, false, out)
    if ok and hidden and #out > 0 then
      pcall(fold.conceal, bufnr, hl.line + 1, hl.line + #out)
    end
    local delta = #out - (last - hl.line)
    local drawer = #drawer > 0 and hl.line + (pline and 1 or 0) + 1 or nil
    restore_folds(folds, function(l)
      if l <= hl.line then
        return l
      elseif l > last then
        return l + delta
      end
      return nil -- the old planning line or drawer: replaced
    end, hl.line, drawer)
  end
  return true
end

--- Write the result of an answer of `quality` to the card at (bufnr,
--- lnum), like org-drill-reschedule: the DRILL_* properties, the SCHEDULED
--- date of the next review (removed after a failure: the card is due at
--- once) and, after too many failures, the :leech: tag.
---@param bufnr integer
---@param lnum integer
---@param card org.drill.Card
---@param quality integer
---@return org.drill.ItemData data, boolean failed, integer days_ahead
function M.reschedule(bufnr, lnum, card, quality)
  local date = require("org.date")
  local o = opts()
  local algorithm = schedule.ALGORITHMS[o.algorithm] and o.algorithm or "sm5"
  local matrix = algorithm == "sm5" and M.sm5_matrix() or nil
  local sopts = {
    failure_quality = tonumber(o.failure_quality) or 2,
    learn_fraction = tonumber(o.learn_fraction) or 0.5,
    sm5_initial_interval = tonumber(o.sm5_initial_interval) or 4.0,
  }
  local weight = card.weight
  local data, days, failed, new_matrix, unschedule =
    schedule.answer(algorithm, card.data, quality, matrix, sopts, weight)
  local scheduled = false
  if not unschedule then
    scheduled = date.today():add(days, "d")
  end
  local now = date.now()
  local reviewed = date.Date.new({
    year = now.year,
    month = now.month,
    day = now.day,
    hour = now.hour,
    min = now.min,
    active = false,
  })
  M.write_meta(bufnr, lnum, scheduled, {
    { "DRILL_LAST_INTERVAL", sm2.float_string(data.last_interval, 4) },
    { "DRILL_REPEATS_SINCE_FAIL", tostring(data.repeats) },
    { "DRILL_TOTAL_REPEATS", tostring(data.total_repeats) },
    { "DRILL_FAILURE_COUNT", tostring(data.failures) },
    { "DRILL_AVERAGE_QUALITY", sm2.float_string(data.meanq, 3) },
    { "DRILL_EASE", sm2.float_string(data.ease, 3) },
    { "DRILL_LAST_QUALITY", tostring(quality) },
    { "DRILL_LAST_REVIEWED", reviewed:to_string() },
  }, { "LEARN_DATA" })
  if algorithm == "sm5" and new_matrix then
    save_matrix(new_matrix)
  end
  -- org-drill-reschedule: more failures than the threshold make a leech
  local threshold = tonumber(o.leech_failure_threshold)
  if failed and threshold and (card.data.failures or 0) + 1 > threshold and not card.leech then
    local hl = require("org.files").get_buffer(bufnr):headline_at(lnum)
    if hl and hl.line == lnum then
      local tags = vim.deepcopy(hl.tags or {})
      if not vim.tbl_contains(tags, "leech") then
        tags[#tags + 1] = "leech"
        require("org.edit").update_headline(bufnr, lnum, { tags = tags })
      end
    end
  end
  return data, failed, days
end

--- Grade the current card 0-5 (org-drill's answer qualities) and go on.
--- In cram mode nothing is written.
---@param quality integer
function M.grade(quality)
  local s = M.session
  if not s or s.finished then
    return
  end
  if not s.revealed then
    -- a grade key first shows the answer
    M.reveal()
    return
  end
  local entry = s.queue[s.index]
  local c, bufnr, lnum = reload(entry)
  if c then
    local data, failed, days
    if s.cram then
      failed = quality <= (tonumber(opts().failure_quality) or 2)
      data, days = c.data, nil
    else
      data, failed, days = M.reschedule(bufnr, lnum, c, quality)
    end
    s.stats.reviewed = s.stats.reviewed + 1
    s.graded = s.graded or {}
    s.graded[entry.bufnr .. ":" .. entry.mark] = true
    s.stats.qualities[quality] = s.stats.qualities[quality] + 1
    if entry.new and not entry.again then
      s.stats.new = s.stats.new + 1
    end
    if failed then
      s.stats.failed = s.stats.failed + 1
      if opts().repeat_failed then
        -- org-drill shuffles the cards to ask again, then adds this one
        if opts().shuffle then
          shuffle(s.again)
        end
        s.again[#s.again + 1] = { bufnr = entry.bufnr, mark = entry.mark, card = c, again = true }
      end
    else
      s.stats.passed = s.stats.passed + 1
    end
    s.results[#s.results + 1] = { title = c.title, quality = quality, days = days, failed = failed, ease = data.ease }
  end
  advance(s)
end

--- Leave the current card for later.
function M.skip()
  local s = M.session
  if not s or s.finished then
    return
  end
  s.stats.skipped = s.stats.skipped + 1
  advance(s)
end

--- End the session: its summary replaces the card, or, when it is over,
--- the window closes.
function M.quit()
  local s = M.session
  if not s then
    return
  end
  if s.finished then
    s.closing = true
    close_window(s)
    return
  end
  s.quit_at = s.index
  finish(s)
end

--- Stop at the current card to edit it; `:Org drill_resume` goes on.
function M.edit()
  local s = M.session
  if not s or s.finished then
    return
  end
  local entry = s.queue[s.index]
  local bufnr, lnum = card_line(entry)
  s.paused = true
  s.closing = true
  close_window(s)
  s.closing = false
  if not bufnr then
    return
  end
  local win = vim.fn.bufwinid(bufnr)
  if win ~= -1 then
    vim.api.nvim_set_current_win(win)
  elseif s.origin_win and vim.api.nvim_win_is_valid(s.origin_win) then
    vim.api.nvim_set_current_win(s.origin_win)
    vim.api.nvim_set_current_buf(bufnr)
  else
    vim.api.nvim_set_current_buf(bufnr)
  end
  vim.api.nvim_win_set_cursor(0, { lnum, 0 })
  pcall(vim.cmd, "normal! zv")
  utils.notify("Drill paused; :Org drill_resume goes on")
end

--- Go on with a session paused by `edit` or a closed window
--- (org-drill-resume).
function M.resume()
  local s = M.session
  if not s or s.finished or not s.paused then
    utils.notify("No drill session to resume")
    return
  end
  s.paused = false
  open_window(s)
  -- the card may have been edited: read it again
  s.index = s.index - 1
  advance(s)
end

--- Lines of the summary: { text, highlight group }.
---@param s table session
---@return { [1]: string, [2]: string|nil }[]
function M.summary_lines(s)
  local st = s.stats
  local out = {}
  local function add(text, group)
    out[#out + 1] = { text, group }
  end
  local elapsed = (s.ended or M.now_seconds()) - s.started
  local cards = 0
  for _ in pairs(s.graded or {}) do
    cards = cards + 1
  end
  local answers = st.reviewed ~= cards and string.format(", %d answers", st.reviewed) or ""
  add(string.format("Reviewed   %d card%s%s in %s", cards, cards == 1 and "" or "s", answers, format_time(elapsed)))
  add(string.format("Passed     %d", st.passed), st.passed > 0 and "OrgDrillPass" or nil)
  add(string.format("Failed     %d", st.failed), st.failed > 0 and "OrgDrillFail" or nil)
  if st.new > 0 then
    add(string.format("New        %d", st.new))
  end
  if st.skipped > 0 then
    add(string.format("Skipped    %d", st.skipped))
  end
  if st.reviewed > 0 then
    local sum = 0
    for q = 0, 5 do
      sum = sum + q * st.qualities[q]
    end
    add(string.format("Average    %.2f", sum / st.reviewed))
    local parts = {}
    for q = 0, 5 do
      parts[#parts + 1] = string.format("%d:%d", q, st.qualities[q])
    end
    add("Grades     " .. table.concat(parts, "  "))
  end
  local left = 0
  if s.quit_at then
    left = #s.queue - s.quit_at + 1 + #s.again
  end
  if left > 0 then
    add(string.format("Still due  %d", left))
  end
  if #s.results > 0 then
    add("")
    add("Next reviews", "OrgDrillSide")
    local seen = {}
    for i = #s.results, 1, -1 do
      local r = s.results[i]
      if not seen[r.title] then
        seen[r.title] = true
        local when = r.days == nil and "not rescheduled (cram)"
          or r.days == 0 and "today"
          or r.days == 1 and "tomorrow"
          or string.format("in %d days", r.days)
        add(string.format("  %-40s %s", vim.fn.strcharpart(r.title, 0, 40), when))
      end
    end
  end
  return out
end

---------------------------------------------------------------------------
-- Commands
---------------------------------------------------------------------------

--- `:Org drill [scope]`: file, tree, agenda, directory, tag:NAME or files.
---@param args? string
function M.command(args)
  local scope = args and vim.trim(args) or ""
  return M.start(scope ~= "" and scope or nil)
end

--- A session over the subtree at the cursor (org-drill-tree).
function M.tree()
  return M.start("tree")
end

--- `:Org drill_cram [scope]`: a cram session (org-drill-cram): every card
--- not reviewed in the last `cram_hours` hours, nothing rescheduled.
---@param args? string
function M.cram(args)
  local scope = type(args) == "string" and vim.trim(args) or ""
  return M.start(scope ~= "" and scope or nil, true)
end

--- Completion of the scope argument: the named scopes, `tag:` with the
--- tags of the agenda files, and org files.
---@param arglead string
---@return string[]
function M.complete_scope(arglead)
  local out = { "file", "tree", "agenda", "directory" }
  if arglead:match("^tag:") then
    local ok, tags = pcall(function()
      local seen, list = {}, {}
      for _, f in ipairs(require("org.files").agenda_files()) do
        for _, hl in ipairs(f.headlines) do
          for _, t in ipairs(hl.tags or {}) do
            if not seen[t] then
              seen[t] = true
              list[#list + 1] = "tag:" .. t
            end
          end
        end
      end
      table.sort(list)
      return list
    end)
    return ok and tags or {}
  end
  out[#out + 1] = "tag:"
  if arglead:find("/", 1, true) or arglead:match("^[~.]") then
    for _, p in ipairs(require("org.utils").complete_path(arglead, "file")) do
      if p:match("%.org$") or p:match("/$") then
        out[#out + 1] = p
      end
    end
  end
  return out
end

--- Count the cards of a scope (`:Org drill_stats`): all, due (reviewed
--- before), new and recently failed ones.
---@param args? string
function M.stats(args)
  local scope = args and vim.trim(args) or ""
  local today = require("org.date").today():days()
  local total, due, new, failing = 0, 0, 0, 0
  for _, c in ipairs(M.cards(scope ~= "" and scope or nil)) do
    total = total + 1
    if c.card.new then
      new = new + 1
    elseif card_mod.is_due(c.card, today) then
      due = due + 1
    end
    if (c.card.data.failures or 0) > 0 and (c.card.data.repeats or 0) <= 1 then
      failing = failing + 1
    end
  end
  local msg = string.format("Drill: %d cards, %d due, %d new, %d recently failed", total, due, new, failing)
  utils.notify(msg)
  return { total = total, due = due, new = new, failing = failing }
end

---------------------------------------------------------------------------
-- Extension
---------------------------------------------------------------------------

M.actions = {
  drill = { "org.extensions.drill", "command", desc = "Drill: review due flashcards", global = true },
  drill_tree = { "org.extensions.drill", "tree", desc = "Drill: review the cards of this subtree" },
  drill_resume = { "org.extensions.drill", "resume", desc = "Drill: resume a paused session", global = true },
  drill_stats = { "org.extensions.drill", "stats", desc = "Drill: count due and new cards", global = true },
  drill_cram = { "org.extensions.drill", "cram", desc = "Drill: cram the cards not reviewed lately", global = true },
}

local function complete_scope(arglead)
  return M.complete_scope(arglead)
end

M.commands = {
  drill = {
    "org.extensions.drill",
    "command",
    desc = "Review flashcards: :Org drill [file|tree|agenda|directory|tag:NAME|files]",
    complete = complete_scope,
  },
  drill_cram = {
    "org.extensions.drill",
    "cram",
    desc = "Cram flashcards: :Org drill_cram [file|tree|agenda|directory|tag:NAME|files]",
    complete = complete_scope,
  },
  drill_stats = {
    "org.extensions.drill",
    "stats",
    desc = "Count drill cards: :Org drill_stats [file|tree|agenda|directory|tag:NAME|files]",
    complete = complete_scope,
  },
}

M.mappings = {
  global = { drill = "<prefix>D" },
}

function M.setup()
  define_highlights()
  M.reset_matrix()
end

function M.teardown()
  local s = M.session
  if s then
    s.closing = true
    close_window(s)
    clear_marks(s)
  end
  M.session = nil
end

function M.health(h, o)
  h.info("drill: cards are headlines tagged :" .. tostring(o.tag) .. ":")
  if not schedule.ALGORITHMS[o.algorithm] then
    h.warn('drill: algorithm should be "sm5", "sm2" or "simple8" (using "sm5")')
  end
  local scope = o.scope
  if type(scope) == "string" and not vim.tbl_contains({ "file", "tree", "agenda", "directory" }, scope) then
    if not scope:match("^tag:") and #utils.glob_org_files(vim.split(scope, "%s+")) == 0 then
      h.warn("drill: scope " .. scope .. " matches no org files")
    end
  end
end

return M
