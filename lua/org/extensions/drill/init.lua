---@mod org.extensions.drill Spaced repetition, like Emacs org-drill
---
--- Enable with `extensions = { drill = {} }` (see `:h org-extensions-drill`).
---
--- ```lua
--- require("org.extensions.drill").start("agenda")   -- a session over the agenda files
--- ```

local card_mod = require("org.extensions.drill.card")
local sm2 = require("org.extensions.drill.sm2")
local utils = require("org.utils")

local M = {}

M.card = card_mod
M.sm2 = sm2
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
  --- Failed cards come back at the end of the session until passed
  --- (as in org-drill).
  repeat_failed = true,
  --- Present cards in random order; new cards come after the due ones.
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
    quit = { "q", "<Esc>" },
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
  return require("org.files").get_buffer(vim.api.nvim_get_current_buf())
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

--- The cards a session asks: due cards (most overdue first, or shuffled),
--- then new cards, up to `maximum_items_per_session`.
---@param scope any
---@param today integer day number
function M.due_cards(scope, today)
  local o = opts()
  local due, new = {}, {}
  for _, c in ipairs(M.cards(scope)) do
    if not card_mod.is_empty(c.card) and card_mod.is_due(c.card, today) then
      if c.card.new then
        new[#new + 1] = c
      else
        due[#due + 1] = c
      end
    end
  end
  if o.shuffle then
    shuffle(due)
    shuffle(new)
  else
    table.sort(due, function(a, b)
      local da = a.card.scheduled and a.card.scheduled:days() or today
      local db = b.card.scheduled and b.card.scheduled:days() or today
      return da < db
    end)
  end
  local out = vim.list_extend(due, new)
  local max = tonumber(o.maximum_items_per_session) or 0
  if max > 0 then
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
  if s.finished then
    return { "q close" }
  end
  if not s.revealed then
    return { "<Space> show answer   s skip   e edit   q quit" }
  end
  return {
    "0-2 failed   3 hard   4 good   5 easy",
    "s skip   e edit   q quit",
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
  if s.finished then
    return " Drill: session finished "
  end
  return string.format(" Drill %d/%d ", s.index, #s.queue)
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
    if entry.again then
      info[#info + 1] = "again"
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
  map(keys.reveal, function()
    M.reveal()
  end)
  map(keys.skip, function()
    M.skip()
  end)
  map(keys.edit, function()
    M.edit()
  end)
  map(keys.quit, function()
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
  return max > 0 and (M.now_seconds() - s.started) >= max * 60
end

-- show the next card, refreshing it from its buffer; cards that are gone
-- are dropped
local function advance(s)
  s.revealed = false
  while true do
    s.index = s.index + 1
    if s.index > #s.queue then
      if #s.again > 0 and not time_up(s) then
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
    if s.index > 1 and time_up(s) then
      s.index = s.index - 1
      finish(s)
      return
    end
    local entry = s.queue[s.index]
    local c = reload(entry)
    if c then
      entry.card = c
      entry.choice = card_mod.choose(c, M.random)
      render(s)
      return
    end
  end
end

--- Start a session over the due cards of `scope` (see `scope_files`).
---@param scope? any
---@return table|nil session
function M.start(scope)
  if M.session and not M.session.finished then
    close_window(M.session)
    clear_marks(M.session)
  end
  local date = require("org.date")
  local today = date.today():days()
  local entries = M.due_cards(scope, today)
  if #entries == 0 then
    utils.notify("No drill cards are due")
    return nil
  end
  local s = { queue = {}, again = {}, index = 0, buffers = {}, results = {}, started = M.now_seconds() }
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

--- Write the result of an answer of `quality` to the card at (bufnr,
--- lnum): the DRILL_* properties and the SCHEDULED date of the next
--- review (org-drill-smart-reschedule).
---@param bufnr integer
---@param lnum integer
---@param card org.drill.Card
---@param quality integer
---@return org.drill.ItemData data, boolean failed, integer days_ahead
function M.reschedule(bufnr, lnum, card, quality)
  local date = require("org.date")
  local edit = require("org.edit")
  local files = require("org.files")
  local data, failed = sm2.next(card.data, quality, opts().failure_quality)
  local days = sm2.days_ahead(data.last_interval)
  local today = date.today()
  edit.set_planning(bufnr, lnum, "scheduled", today:add(days, "d"))
  local now = date.now()
  local reviewed = date.Date.new({
    year = now.year,
    month = now.month,
    day = now.day,
    hour = now.hour,
    min = now.min,
    active = false,
  })
  local props = {
    { "DRILL_LAST_INTERVAL", sm2.float_string(data.last_interval, 4) },
    { "DRILL_REPEATS_SINCE_FAIL", tostring(data.repeats) },
    { "DRILL_TOTAL_REPEATS", tostring(data.total_repeats) },
    { "DRILL_FAILURE_COUNT", tostring(data.failures) },
    { "DRILL_AVERAGE_QUALITY", sm2.float_string(data.meanq, 3) },
    { "DRILL_EASE", sm2.float_string(data.ease, 3) },
    { "DRILL_LAST_QUALITY", tostring(quality) },
    { "DRILL_LAST_REVIEWED", reviewed:to_string() },
  }
  for _, p in ipairs(props) do
    local hl = files.get_buffer(bufnr):headline_at(lnum)
    edit.set_property(bufnr, hl.line, p[1], p[2])
  end
  return data, failed, days
end

--- Grade the current card 0-5 (org-drill's answer qualities) and go on.
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
    local data, failed, days = M.reschedule(bufnr, lnum, c, quality)
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
        local when = r.days == 0 and "today" or r.days == 1 and "tomorrow" or string.format("in %d days", r.days)
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
}

M.commands = {
  drill = {
    "org.extensions.drill",
    "command",
    desc = "Review flashcards: :Org drill [file|tree|agenda|directory|tag:NAME|files]",
  },
  drill_stats = {
    "org.extensions.drill",
    "stats",
    desc = "Count drill cards: :Org drill_stats [file|tree|agenda|directory|tag:NAME|files]",
  },
}

M.mappings = {
  global = { drill = "<prefix>D" },
}

function M.setup()
  define_highlights()
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
  local scope = o.scope
  if type(scope) == "string" and not vim.tbl_contains({ "file", "tree", "agenda", "directory" }, scope) then
    if not scope:match("^tag:") and #utils.glob_org_files(vim.split(scope, "%s+")) == 0 then
      h.warn("drill: scope " .. scope .. " matches no org files")
    end
  end
end

return M
