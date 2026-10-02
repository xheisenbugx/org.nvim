---@mod org.extensions.review Guided weekly review (GTD)
---
--- Enable with `extensions = { review = {} }` (see `:h org-extensions-review`).
---
--- `:Org review` opens a float that steps through the review: empty the
--- inbox, stuck projects, waiting-for, overdue, the next two weeks,
--- someday/maybe, the time clocked last week and a few reflection
--- questions. The progress is saved after every change, so a review can be
--- left and resumed; finishing writes a review entry into a log date tree.

local date = require("org.date")
local steps_mod = require("org.extensions.review.steps")
local utils = require("org.utils")

local M = {}

M.steps = steps_mod

M.defaults = {
  --- Steps in order: builtin names ("inbox", "stuck", "waiting",
  --- "overdue", "upcoming", "someday", "clock", "reflect"), `{ "name",
  --- title = ..., ... }` to override a builtin, custom step tables
  --- (`{ name, title, description, items = function(ctx) }`) or functions
  --- (the `items` of a custom step).
  steps = { "inbox", "stuck", "waiting", "overdue", "upcoming", "someday", "clock", "reflect" },
  --- Inbox file(s) for the "inbox" step; nil = `default_notes_file`.
  inbox = nil,
  --- TODO keywords of the "waiting" step.
  waiting_keywords = { "WAITING" },
  --- Tags and TODO keywords of the "someday" step.
  someday = { tags = { "someday", "maybe" }, keywords = { "SOMEDAY", "MAYBE" } },
  --- Days shown by the "upcoming" step, from today.
  upcoming_days = 14,
  --- Days summed by the "clock" step, and how many entries it lists.
  clock_days = 7,
  clock_top = 10,
  --- Questions of the "reflect" step.
  questions = {
    "What went well this week?",
    "What could have gone better?",
    "What will I focus on next week?",
  },
  --- The review log: a file with a date tree the finished review is
  --- written to (nil = "review.org" in `org_directory`), and the tree type
  --- ("day", "week" or "month").
  log_file = nil,
  log_tree_type = "week",
  --- Heading of the logged review.
  log_heading = "Weekly review",
  --- A capture template key: finishing captures with it instead, the
  --- summary as its initial text (%i), so it can be edited first.
  capture_template = nil,
  --- Open the log at the new entry after finishing.
  open_log = true,
  --- Ask before `delete` removes an entry.
  confirm_delete = true,
  --- Where an unfinished review is kept.
  state_file = vim.fn.stdpath("data") .. "/org/review.json",
  --- Size of the float (clamped to the screen).
  width = 96,
  height = 30,
  border = "rounded",
  --- Keys in the review window (a list or false for none).
  keys = {
    next = { "n", "]]" },
    prev = { "p", "[[" },
    open = "<CR>",
    refile = "r",
    schedule = "s",
    deadline = "S",
    todo = "t",
    delete = "d",
    skip = "x",
    note = "i",
    refresh = "R",
    finish = "F",
    quit = { "<Esc>", "q" },
  },
}

local ns = vim.api.nvim_create_namespace("org_review")
-- marks on the headlines of the listed entries, in their buffers
local item_ns = vim.api.nvim_create_namespace("org_review_items")

--- The open review: { steps, index, buf, win, items (line -> item), state }
---@type table|nil
M.session = nil

local function opts()
  return require("org.extensions").opts("review") or M.defaults
end

local function define_highlights()
  local links = {
    OrgReviewTitle = "Title",
    OrgReviewDone = "DiagnosticOk",
    OrgReviewPending = "NonText",
    OrgReviewCurrent = "WarningMsg",
    OrgReviewDescription = "Comment",
    OrgReviewInfo = "Special",
    OrgReviewFile = "Directory",
    OrgReviewSkipped = "Comment",
    OrgReviewKey = "Special",
    OrgReviewQuestion = "Question",
  }
  for group, link in pairs(links) do
    vim.api.nvim_set_hl(0, group, { link = link, default = true })
  end
end

---------------------------------------------------------------------------
-- State
---------------------------------------------------------------------------

local function state_file()
  local f = opts().state_file
  -- lint: allow expand: the state_file option
  return f and f ~= "" and vim.fn.expand(f) or nil
end

local function new_state()
  return {
    started = date.now():to_string({ brackets = false }),
    step = 1,
    notes = {},
    skipped = {},
    stats = { refiled = 0, scheduled = 0, todo = 0, deleted = 0, skipped = 0 },
    counts = {},
  }
end

--- The saved state of an unfinished review (nil when there is none).
function M.load_state()
  local f = state_file()
  local s = f and utils.read_json(f)
  if type(s) ~= "table" or not s.started then
    return nil
  end
  s.notes = type(s.notes) == "table" and s.notes or {}
  s.skipped = type(s.skipped) == "table" and s.skipped or {}
  s.stats = vim.tbl_extend("keep", type(s.stats) == "table" and s.stats or {}, new_state().stats)
  s.counts = type(s.counts) == "table" and s.counts or {}
  return s
end

local function save_state()
  local s = M.session
  local f = state_file()
  if not (s and f) then
    return
  end
  s.state.step = s.steps[s.index] and s.steps[s.index].name or s.index
  vim.fn.mkdir(vim.fn.fnamemodify(f, ":h"), "p")
  pcall(utils.write_json, f, s.state)
end

--- Forget an unfinished review.
function M.clear_state()
  local f = state_file()
  if f then
    vim.fn.delete(f)
  end
end

---------------------------------------------------------------------------
-- Collecting
---------------------------------------------------------------------------

local function context()
  return {
    opts = opts(),
    today = date.today(),
    now = date.now(),
    files = require("org.files").agenda_files(),
    state = M.session and M.session.state or new_state(),
  }
end

-- the identity of an entry in the saved state (what was skipped): its ID,
-- else its file and outline path
local function item_key(it)
  local hl = it.hl
  if hl and hl.properties and hl.properties.ID then
    return "id:" .. hl.properties.ID
  end
  local title = hl and hl.title or it.text or ""
  local olp = hl and hl.outline_path and hl:outline_path() or {}
  if #olp > 0 then
    title = table.concat(olp, "/") .. "/" .. title
  end
  return (it.path or "") .. "::" .. title
end
M.item_key = item_key

-- Remember where an item's headline is: a mark in its buffer when the
-- file is loaded, and what identifies it (ID, level, outline path).
local function track(it, bufs)
  local hl = it.hl
  it.id = hl.properties and hl.properties.ID or nil
  it.level = hl.level
  local b = it.path and bufs[vim.fs.normalize(it.path)]
  if b and it.lnum and it.lnum <= vim.api.nvim_buf_line_count(b) then
    it.bufnr = b
    it.mark = vim.api.nvim_buf_set_extmark(b, item_ns, it.lnum - 1, 0, {})
  end
end

local function clear_marks()
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(b) then
      pcall(vim.api.nvim_buf_clear_namespace, b, item_ns, 0, -1)
    end
  end
end

local function loaded_buffers()
  local out = {}
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(b) then
      local name = vim.api.nvim_buf_get_name(b)
      if name ~= "" then
        out[vim.fs.normalize(name)] = b
      end
    end
  end
  return out
end

--- Items and extra lines of a step.
---@return table[] items, string[] lines
function M.collect(step, ctx)
  ctx = ctx or context()
  local items, lines = {}, {}
  if step.lines then
    local ok, l = pcall(step.lines, ctx)
    lines = ok and l or { "Error: " .. tostring(l) }
  end
  if step.items then
    local ok, list = pcall(step.items, ctx)
    if ok then
      items = list or {}
    else
      items = { { text = "Error: " .. tostring(list) } }
    end
  end
  return items, lines
end

-- The items of a builtin step are kept while the agenda files are the same
-- (the files module hands out the same parsed file until it changes) and
-- the minute is: a refresh after a skip, or going back to a step, does not
-- collect them again. Custom steps are collected every time.
local function collect_cached(s, step)
  local builtin = steps_mod.builtin[step.name]
  if not (builtin and step.items == builtin.items and step.lines == builtin.lines) then
    return M.collect(step)
  end
  local ctx = context()
  local minute = ctx.now:minutes()
  local key_files = ctx.files
  if step.name == "inbox" then
    key_files = vim.list_extend({}, ctx.files)
    for _, p in ipairs(steps_mod.inbox_paths(ctx.opts)) do
      key_files[#key_files + 1] = require("org.files").get(p) or false
    end
  end
  local c = s.cache and s.cache[step.name]
  if c and c.minute == minute and c.opts == ctx.opts and #c.files == #key_files then
    local same = true
    for i, f in ipairs(key_files) do
      if c.files[i] ~= f then
        same = false
        break
      end
    end
    if same then
      return c.items, c.lines
    end
  end
  local items, lines = M.collect(step, ctx)
  s.cache = s.cache or {}
  s.cache[step.name] = { files = key_files, minute = minute, opts = ctx.opts, items = items, lines = lines }
  return items, lines
end

---------------------------------------------------------------------------
-- Rendering
---------------------------------------------------------------------------

local function current()
  local s = M.session
  return s and s.steps[s.index]
end

local function progress(s)
  local parts = {}
  for i = 1, #s.steps do
    parts[#parts + 1] = i < s.index and "●" or (i == s.index and "◉" or "○")
  end
  return table.concat(parts, " ")
end

local function key_hint(name)
  local k = (opts().keys or {})[name]
  if type(k) == "table" then
    k = k[1]
  end
  return k or nil
end

-- key hints of the footer, the less useful ones dropped when too wide
local function footer(step, width)
  local hints = {}
  local function add(name, what, prio)
    local k = key_hint(name)
    if k then
      hints[#hints + 1] = { k .. " " .. what, prio }
    end
  end
  if step.reflect then
    add("open", "answer", 1)
  else
    add("open", "open", 3)
    add("refile", "refile", 1)
    add("schedule", "schedule", 1)
    add("todo", "todo", 2)
    add("delete", "delete", 2)
    add("skip", "skip", 2)
  end
  add("prev", "back", 3)
  add("next", "next", 1)
  add("finish", "finish", 1)
  add("quit", "quit", 2)
  local function text()
    return " "
      .. table.concat(
        vim.tbl_map(function(h)
          return h[1]
        end, hints),
        "  "
      )
      .. " "
  end
  for prio = 3, 2, -1 do
    for i = #hints, 1, -1 do
      if width and vim.fn.strdisplaywidth(text()) > width - 2 and hints[i][2] == prio then
        table.remove(hints, i)
      end
    end
  end
  return text()
end

local function item_text(it, state, width)
  if it.text then
    return "  " .. it.text, {}
  end
  local hl = it.hl
  local hls = {}
  local parts = { "  " }
  local col = 2
  local function push(text, group)
    if text == nil or text == "" then
      return
    end
    parts[#parts + 1] = text
    if group then
      hls[#hls + 1] = { col, col + #text, group }
    end
    col = col + #text
  end
  local skipped = next(state.skipped) ~= nil and state.skipped[item_key(it)]
  push(skipped and "· " or "▸ ", skipped and "OrgReviewSkipped" or "OrgReviewInfo")
  if hl.todo then
    push(hl.todo, hl:is_done() and "OrgDone" or "OrgTodo")
    push(" ")
  end
  if hl.priority then
    push("[#" .. hl.priority .. "] ", "OrgReviewInfo")
  end
  push(hl:plain_title(), skipped and "OrgReviewSkipped" or nil)
  if #hl.tags > 0 then
    push("  :" .. table.concat(hl.tags, ":") .. ":", "OrgReviewDescription")
  end
  if it.info then
    push("  " .. it.info, "OrgReviewInfo")
  end
  if skipped then
    push("  (skipped)", "OrgReviewSkipped")
  end
  local file = vim.fs.basename(it.path or "")
  -- the file name at the right edge when it fits
  local used = vim.api.nvim_strwidth(table.concat(parts))
  local pad = width and (width - 1 - used - vim.api.nvim_strwidth(file)) or 0
  push(string.rep(" ", math.max(2, pad)))
  push(file, "OrgReviewFile")
  return table.concat(parts), hls
end

--- Redraw the review window for the current step.
function M.render()
  local s = M.session
  if not (s and s.buf and vim.api.nvim_buf_is_valid(s.buf)) then
    return
  end
  local step = current()
  local lines, marks = {}, {}
  local function add(text, group, from, to)
    lines[#lines + 1] = text
    if group then
      marks[#marks + 1] = { #lines - 1, from or 0, to or #text, group }
    end
  end
  local prog = progress(s)
  add(" " .. prog .. "   " .. string.format("Step %d of %d · %s", s.index, #s.steps, step.title or step.name))
  -- progress dots: done / current / pending
  local col = 1
  for i = 1, #s.steps do
    local group = i < s.index and "OrgReviewDone" or (i == s.index and "OrgReviewCurrent" or "OrgReviewPending")
    marks[#marks + 1] = { 0, col, col + 3, group }
    col = col + 4
  end
  marks[#marks + 1] = { 0, #prog + 4, #lines[1], "OrgReviewTitle" }
  if step.description then
    add(" " .. step.description, "OrgReviewDescription")
  end
  add("")
  s.items = {}
  if step.reflect then
    for i, q in ipairs(opts().questions or {}) do
      add("  " .. q, "OrgReviewQuestion")
      s.items[#lines] = { question = i }
      local answer = s.state.notes[tostring(i)]
      if answer and answer ~= "" then
        for _, l in ipairs(vim.split(answer, "\n", { plain = true })) do
          add("    " .. l)
          s.items[#lines] = { question = i }
        end
      else
        add("    (<CR> to answer)", "OrgReviewDescription")
        s.items[#lines] = { question = i }
      end
      add("")
    end
    add("  " .. (key_hint("finish") or "") .. " finishes the review and writes it to the log", "OrgReviewDescription")
  else
    local items, extra = collect_cached(s, step)
    s.state.counts[step.name] = #items
    clear_marks()
    local bufs = loaded_buffers()
    for _, it in ipairs(items) do
      if it.hl and it.path then
        pcall(track, it, bufs)
      end
    end
    for _, l in ipairs(extra) do
      add("  " .. l, "OrgReviewInfo")
    end
    if #extra > 0 then
      add("")
    end
    if #items == 0 then
      add("  Nothing here. " .. (key_hint("next") or "n") .. " goes to the next step.", "OrgReviewDone")
    end
    for _, it in ipairs(items) do
      local width = s.win and vim.api.nvim_win_is_valid(s.win) and vim.api.nvim_win_get_width(s.win) or nil
      local text, hls = item_text(it, s.state, width)
      add(text)
      s.items[#lines] = it
      for _, h in ipairs(hls) do
        marks[#marks + 1] = { #lines - 1, h[1], h[2], h[3] }
      end
    end
  end
  vim.bo[s.buf].modifiable = true
  vim.api.nvim_buf_set_lines(s.buf, 0, -1, false, lines)
  vim.bo[s.buf].modifiable = false
  vim.bo[s.buf].modified = false
  vim.api.nvim_buf_clear_namespace(s.buf, ns, 0, -1)
  for _, m in ipairs(marks) do
    pcall(vim.api.nvim_buf_set_extmark, s.buf, ns, m[1], m[2], { end_col = m[3], hl_group = m[4] })
  end
  if s.win and vim.api.nvim_win_is_valid(s.win) then
    pcall(vim.api.nvim_win_set_config, s.win, {
      title = string.format(" Weekly review %d/%d ", s.index, #s.steps),
      title_pos = "center",
      footer = footer(step, vim.api.nvim_win_get_width(s.win)),
      footer_pos = "center",
    })
    -- the cursor on the first item (or where it was, when still valid)
    local row = s.cursor_row
    if not (row and s.items[row]) then
      row = nil
      for l = 1, #lines do
        if s.items[l] then
          row = l
          break
        end
      end
    end
    pcall(vim.api.nvim_win_set_cursor, s.win, { row or 1, 0 })
  end
  s.cursor_row = nil
  save_state()
end

---------------------------------------------------------------------------
-- Window
---------------------------------------------------------------------------

local function close_window()
  local s = M.session
  if not s then
    return
  end
  clear_marks()
  if s.win and vim.api.nvim_win_is_valid(s.win) then
    pcall(vim.api.nvim_win_close, s.win, true)
  end
  if s.buf and vim.api.nvim_buf_is_valid(s.buf) then
    pcall(vim.api.nvim_buf_delete, s.buf, { force = true })
  end
  s.win, s.buf = nil, nil
end

local function map_keys(buf)
  local keys = opts().keys or {}
  local fns = {
    next = M.next,
    prev = M.prev,
    open = M.open,
    refile = function()
      M.act("refile")
    end,
    schedule = function()
      M.act("schedule")
    end,
    deadline = function()
      M.act("deadline")
    end,
    todo = function()
      M.act("todo")
    end,
    delete = function()
      M.act("delete")
    end,
    skip = function()
      M.act("skip")
    end,
    note = M.note,
    refresh = M.refresh,
    finish = M.finish,
    quit = M.quit,
  }
  -- a key the current step binds (`step.keys`) is the step's
  local step_lhs = vim.tbl_keys((current() or {}).keys or {})
  for name, fn in pairs(fns) do
    if keys[name] then
      for _, k in ipairs(require("org.extensions.views_util").lhs(keys, name, { step = step_lhs })) do
        vim.keymap.set("n", k, function()
          utils.run(fn)
        end, { buffer = buf, nowait = true, desc = "org review: " .. name })
      end
    end
  end
end

-- keys of the current step (`step.keys`), removed when the step changes
local function map_step_keys()
  local s = M.session
  for _, lhs in ipairs(s.step_keys or {}) do
    pcall(vim.keymap.del, "n", lhs, { buffer = s.buf })
  end
  s.step_keys = {}
  -- give back the review keys the previous step's keys covered
  map_keys(s.buf)
  local step = current()
  for lhs, fn in pairs(step.keys or {}) do
    s.step_keys[#s.step_keys + 1] = lhs
    vim.keymap.set("n", lhs, function()
      utils.run(function()
        fn(M.item_at_cursor(), M.session)
        M.render()
      end)
    end, { buffer = s.buf, nowait = true, desc = "org review: " .. (step.title or step.name) })
  end
end

local function open_window()
  local s = M.session
  local o = opts()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "org_review"
  pcall(vim.api.nvim_buf_set_name, buf, "Weekly review")
  local width = math.max(20, math.min(tonumber(o.width) or 96, vim.o.columns - 4))
  local height = math.max(5, math.min(tonumber(o.height) or 30, vim.o.lines - 6))
  s.origin_win = vim.api.nvim_get_current_win()
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height) / 2) - 1,
    col = math.floor((vim.o.columns - width) / 2),
    border = o.border or "rounded",
    style = "minimal",
    title = " Weekly review ",
    title_pos = "center",
  })
  vim.wo[win].cursorline = true
  vim.wo[win].wrap = false
  s.buf, s.win = buf, win
  map_keys(buf)
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = buf,
    once = true,
    callback = function()
      if M.session and M.session.buf == buf then
        M.session.buf, M.session.win = nil, nil
      end
    end,
  })
end

local function show()
  local s = M.session
  if not (s.win and vim.api.nvim_win_is_valid(s.win)) then
    open_window()
  else
    vim.api.nvim_set_current_win(s.win)
  end
  map_step_keys()
  M.render()
end

---------------------------------------------------------------------------
-- Commands
---------------------------------------------------------------------------

local function find_step(steps, what)
  if what == nil or what == "" then
    return nil
  end
  local n = tonumber(what)
  if n then
    return (n >= 1 and n <= #steps) and math.floor(n) or nil
  end
  for i, st in ipairs(steps) do
    if st.name == what then
      return i
    end
  end
  return nil
end

--- Collect the step's entries again and redraw (key `R`).
function M.refresh()
  if M.session then
    M.session.cache = nil
    M.render()
  end
end

--- Start the weekly review, or resume an unfinished one.
---@param args? string "restart", a step name or number
function M.start(args)
  args = vim.trim(type(args) == "string" and args or "")
  define_highlights()
  local steps, errors = steps_mod.resolve(opts().steps)
  for _, e in ipairs(errors) do
    utils.warn(e)
  end
  if #steps == 0 then
    utils.warn("No review steps")
    return
  end
  if M.session and args == "" then
    show()
    return
  end
  local state = args ~= "restart" and M.load_state() or nil
  local resumed = state ~= nil
  state = state or new_state()
  local index = find_step(steps, state.step) or 1
  if args ~= "" and args ~= "restart" then
    index = find_step(steps, args)
    if not index then
      utils.warn("Unknown review step: " .. args)
      return
    end
  end
  close_window()
  M.session = { steps = steps, index = index, state = state }
  if resumed then
    utils.notify("Resuming the weekly review started " .. state.started)
  end
  show()
  return M.session
end

--- `:Org review [restart|step]`.
M.command = M.start

--- Start over, dropping an unfinished review.
function M.restart()
  return M.start("restart")
end

local function require_session()
  if not M.session then
    utils.warn("No weekly review running (:Org review)")
    return false
  end
  return true
end

--- Go to step `i` (clamped).
function M.goto_step(i)
  if not require_session() then
    return
  end
  local s = M.session
  s.index = math.max(1, math.min(#s.steps, i))
  if s.buf and vim.api.nvim_buf_is_valid(s.buf) then
    map_step_keys()
    M.render()
  else
    save_state()
  end
end

function M.next()
  if not require_session() then
    return
  end
  if M.session.index >= #M.session.steps then
    utils.notify("Last step: " .. (key_hint("finish") or "F") .. " finishes the review")
    return
  end
  M.goto_step(M.session.index + 1)
end

function M.prev()
  if require_session() then
    M.goto_step(M.session.index - 1)
  end
end

--- Close the window; the review is kept and `:Org review` resumes it.
function M.quit()
  if not M.session then
    return
  end
  save_state()
  close_window()
  M.session = nil
  utils.notify("Weekly review paused: :Org review resumes it")
end

--- The item under the cursor of the review window.
function M.item_at_cursor()
  local s = M.session
  if not (s and s.win and vim.api.nvim_win_is_valid(s.win)) then
    return nil
  end
  local row = vim.api.nvim_win_get_cursor(s.win)[1]
  return s.items and s.items[row], row
end

-- the headline of an item, from its (loaded) buffer: where its mark is,
-- else by ID, else at its line, else the one entry with its title, level
-- and outline path. Two such entries and no other clue: nil (acting on the
-- wrong one would be worse).
local function resolve(it)
  if not (it and it.hl and it.path) then
    return nil
  end
  local bufnr = utils.load_buffer(it.path)
  local file = require("org.files").get_buffer(bufnr)
  local title, level = it.hl.title, it.level or it.hl.level
  local function same(h)
    return h and h.title == title and h.level == level
  end
  local function olp_of(h)
    return table.concat(h:outline_path(), "/")
  end
  if it.mark and it.bufnr == bufnr then
    local ok, pos = pcall(vim.api.nvim_buf_get_extmark_by_id, bufnr, item_ns, it.mark, {})
    local hl = ok and pos[1] and file:headline_on(pos[1] + 1)
    if same(hl) then
      return bufnr, hl
    end
  end
  if it.id then
    local hl = file:find_by_id(it.id)
    if hl then
      return bufnr, hl
    end
  end
  if it.olp == nil then
    it.olp = it.hl.outline_path and olp_of(it.hl) or false
  end
  local at = file:headline_on(it.lnum or 0)
  if same(at) and (not it.olp or olp_of(at) == it.olp) then
    return bufnr, at
  end
  local found = {}
  for _, h in ipairs(file.headlines) do
    if same(h) and (not it.olp or olp_of(h) == it.olp) then
      found[#found + 1] = h
    end
  end
  if #found == 1 then
    return bufnr, found[1]
  elseif #found > 1 then
    utils.warn("Several entries are called " .. it.hl.title .. ": refresh the review (R) and try again")
    return nil
  end
  utils.warn("Entry is gone: " .. it.hl.title)
  return nil
end

local function save(bufnr)
  return utils.save_buffer_or_warn(bufnr)
end

local function pick_date(prompt, it)
  local cal = require("org.calendar")
  local d = cal.pick({ prompt = prompt, default = date.today() })
  if not d or d.remove then
    return nil
  end
  return d
end

--- Act on the item at the cursor: "refile", "schedule", "deadline",
--- "todo", "delete", "skip" or "open".
---@param what string
---@param it? table the item (default: at the cursor)
function M.act(what, it)
  if not require_session() then
    return
  end
  local row
  if not it then
    it, row = M.item_at_cursor()
  end
  if what == "open" then
    return M.open(it)
  end
  if not (it and it.hl) then
    return
  end
  local s = M.session
  local stats = s.state.stats
  if what == "skip" then
    local key = item_key(it)
    if not s.state.skipped[key] then
      s.state.skipped[key] = true
      stats.skipped = stats.skipped + 1
    end
    s.cursor_row = row and row + 1
    M.render()
    return true
  end
  local bufnr, hl = resolve(it)
  if not bufnr then
    M.render()
    return
  end
  local target = { bufnr = bufnr, lnum = hl.line }
  local done = false
  if what == "refile" then
    local refile = require("org.refile")
    local dest = refile.pick_target({ prompt = "Refile " .. hl:plain_title() .. " to" })
    if dest then
      local ok, err = pcall(refile.move, { bufnr = bufnr, lnum = hl.line, save_destination = true }, dest)
      if ok then
        save(bufnr)
        if dest.filename then
          local dbuf = utils.find_buffer(dest.filename)
          if dbuf then
            save(dbuf)
          end
        end
        stats.refiled = stats.refiled + 1
        done = true
      else
        utils.warn(tostring(err))
      end
    end
  elseif what == "schedule" or what == "deadline" then
    local d = pick_date(what == "schedule" and "Schedule" or "Deadline", it)
    if d then
      local edit = require("org.edit")
      edit.set_planning(bufnr, hl.line, what == "schedule" and "scheduled" or "deadline", d)
      edit.refresh(bufnr, hl.line)
      save(bufnr)
      stats.scheduled = stats.scheduled + 1
      done = true
    end
  elseif what == "todo" then
    local todo_cfg = require("org.files").get_buffer(bufnr).settings.todo
    local names = {}
    for _, kw in ipairs(todo_cfg.keywords) do
      names[#names + 1] = kw.name
    end
    names[#names + 1] = "(none)"
    local choice = utils.select(names, { prompt = "TODO state of " .. hl:plain_title() })
    if choice then
      require("org.todo").change_state(target, choice ~= "(none)" and choice or nil)
      save(bufnr)
      stats.todo = stats.todo + 1
      done = true
    end
  elseif what == "delete" then
    if not opts().confirm_delete or utils.confirm("Delete " .. hl:plain_title() .. "?") then
      vim.api.nvim_buf_set_lines(bufnr, hl.line - 1, hl.end_line, false, {})
      save(bufnr)
      stats.deleted = stats.deleted + 1
      done = true
    end
  else
    utils.warn("Unknown review action: " .. tostring(what))
    return
  end
  s.cursor_row = row
  if s.buf and vim.api.nvim_buf_is_valid(s.buf) then
    vim.api.nvim_set_current_win(s.win)
  end
  M.render()
  return done
end

--- <CR>: answer the question at the cursor, or go to the entry (the
--- review is paused; `:Org review` comes back to it).
function M.open(it)
  if not require_session() then
    return
  end
  it = it or M.item_at_cursor()
  if it and it.question then
    return M.note(it)
  end
  local bufnr, hl = resolve(it)
  if not bufnr then
    return
  end
  local s = M.session
  local origin = s.origin_win
  save_state()
  close_window()
  M.session = nil
  if origin and vim.api.nvim_win_is_valid(origin) then
    vim.api.nvim_set_current_win(origin)
  end
  vim.api.nvim_win_set_buf(0, bufnr)
  vim.api.nvim_win_set_cursor(0, { hl.line, 0 })
  pcall(require("org.fold").reveal_cursor)
  utils.notify("Weekly review paused: :Org review resumes it")
end

--- Answer the reflection question at the cursor.
function M.note(it)
  if not require_session() then
    return
  end
  it = it or M.item_at_cursor()
  if not (it and it.question) then
    return
  end
  local s = M.session
  local q = (opts().questions or {})[it.question]
  local key = tostring(it.question)
  -- the note buffer is a split: answer with the float hidden
  close_window()
  if s.origin_win and vim.api.nvim_win_is_valid(s.origin_win) then
    vim.api.nvim_set_current_win(s.origin_win)
  end
  local answer = utils.input_note({ prompt = q .. " ", default = s.state.notes[key], purpose = q })
  if answer ~= nil then
    s.state.notes[key] = vim.trim(answer)
  end
  if M.session == s then
    s.cursor_row = nil
    show()
  end
end

---------------------------------------------------------------------------
-- Finishing
---------------------------------------------------------------------------

local function log_path()
  local f = opts().log_file
  if f and f ~= "" then
    return utils.expand(f)
  end
  return utils.expand(require("org.config").opts.org_directory) .. "/review.org"
end
M.log_path = log_path

--- The lines of the review entry (an entry at level 1).
function M.entry_lines(s)
  s = s or M.session
  local o = opts()
  local st = s.state.stats
  local edit = require("org.edit")
  local body, answer = edit.body_indent(1), edit.body_indent(2)
  local lines = {
    "* " .. (o.log_heading or "Weekly review") .. " :review:",
    body .. "[" .. date.now():to_string({ brackets = false }) .. "]",
  }
  local processed = st.refiled + st.scheduled + st.todo + st.deleted
  lines[#lines + 1] = string.format(
    "%s- Inbox: %d processed (%d refiled, %d scheduled, %d state changes, %d deleted), %d skipped",
    body,
    processed,
    st.refiled,
    st.scheduled,
    st.todo,
    st.deleted,
    st.skipped
  )
  local counts = {}
  for _, step in ipairs(s.steps) do
    local n = s.state.counts[step.name]
    if n and step.name ~= "inbox" and step.name ~= "clock" and not step.reflect then
      counts[#counts + 1] = string.format("%s: %d", step.title or step.name, n)
    end
  end
  if #counts > 0 then
    lines[#lines + 1] = body .. "- " .. table.concat(counts, ", ")
  end
  for _, step in ipairs(s.steps) do
    if step.name == "clock" then
      local _, total =
        steps_mod.clock_summary(require("org.files").agenda_files(), date.now(), tonumber(o.clock_days) or 7)
      local days = tonumber(o.clock_days) or 7
      lines[#lines + 1] = string.format("%s- Clocked in the last %d days: %s", body, days, date.format_duration(total))
    end
  end
  for i, q in ipairs(o.questions or {}) do
    local a = s.state.notes[tostring(i)]
    if a and a ~= "" then
      lines[#lines + 1] = "** " .. q
      for _, l in ipairs(vim.split(a, "\n", { plain = true })) do
        -- an answer line must not turn into a headline
        if answer == "" and (l:match("^%*+%s") or l:match("^%*+$")) then
          l = " " .. l
        end
        lines[#lines + 1] = l ~= "" and answer .. l or l
      end
    end
  end
  return lines
end

-- With `adapt_indentation` the body lines are built indented for level 1
-- (and 2 under the questions); the date tree puts the entry deeper: shift
-- them as far as its headlines went.
local function indent_logged(bufnr, line)
  local file = require("org.files").get_buffer(bufnr)
  local hl = file:headline_at(line)
  if not hl or hl.line ~= line or hl.level <= 1 or require("org.edit").body_indent(1) == "" then
    return
  end
  local pad = string.rep(" ", hl.level - 1)
  local parser = require("org.parser")
  local lines = vim.api.nvim_buf_get_lines(bufnr, hl.line, hl.end_line, false)
  for i, l in ipairs(lines) do
    if l:match("%S") and not parser.headline_level(l) then
      lines[i] = pad .. l
    end
  end
  vim.api.nvim_buf_set_lines(bufnr, hl.line, hl.end_line, false, lines)
end

--- Finish the review: write the review entry into the log date tree (or
--- capture it with `capture_template`) and forget the saved state.
function M.finish()
  if not require_session() then
    return
  end
  local o = opts()
  local s = M.session
  local lines = M.entry_lines(s)
  local origin = s.origin_win
  close_window()
  M.session = nil
  M.clear_state()
  if origin and vim.api.nvim_win_is_valid(origin) then
    vim.api.nvim_set_current_win(origin)
  end
  local capture = require("org.capture")
  if o.capture_template then
    return capture.capture(o.capture_template, { initial = table.concat(vim.list_slice(lines, 2), "\n") })
  end
  local tpl = {
    type = "entry",
    target = log_path(),
    datetree = { tree_type = o.log_tree_type or "week" },
  }
  -- a date tree starts a new file with an empty line (like Emacs): not
  -- the review log's first line
  local path = log_path()
  local fresh = vim.fn.getfsize(path) <= 0
  local lbuf = utils.find_buffer(path)
  if lbuf then
    local l = vim.api.nvim_buf_get_lines(lbuf, 0, -1, false)
    fresh = #l == 1 and l[1] == ""
  end
  local bufnr, line = capture.store(tpl, lines, { date = date.today() })
  if not bufnr then
    utils.warn("The review could not be logged")
    return
  end
  local changed = false
  if fresh and vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1] == "" and line > 1 then
    vim.api.nvim_buf_set_lines(bufnr, 0, 1, false, {})
    line = line - 1
    changed = true
  end
  if require("org.edit").body_indent(1) ~= "" then
    indent_logged(bufnr, line)
    changed = true
  end
  if changed then
    utils.save_buffer_or_warn(bufnr)
  end
  utils.notify("Weekly review logged to " .. utils.abbreviate(log_path()))
  if o.open_log then
    vim.api.nvim_win_set_buf(0, bufnr)
    pcall(vim.api.nvim_win_set_cursor, 0, { line, 0 })
    pcall(require("org.fold").reveal_cursor)
  end
  return bufnr, line
end

---------------------------------------------------------------------------
-- Extension
---------------------------------------------------------------------------

M.actions = {
  review = { "org.extensions.review", "start", desc = "Weekly review: start or resume", global = true },
  review_restart = { "org.extensions.review", "restart", desc = "Weekly review: start over", global = true },
  review_next = { "org.extensions.review", "next", desc = "Weekly review: next step", global = true },
  review_prev = { "org.extensions.review", "prev", desc = "Weekly review: previous step", global = true },
  review_finish = { "org.extensions.review", "finish", desc = "Weekly review: log it and finish", global = true },
  review_quit = { "org.extensions.review", "quit", desc = "Weekly review: pause", global = true },
}

M.commands = {
  review = {
    "org.extensions.review",
    "command",
    desc = "Weekly review: :Org review [restart|step name|step number]",
    complete = function()
      local out = { "restart" }
      for _, st in ipairs((steps_mod.resolve(opts().steps))) do
        out[#out + 1] = st.name
      end
      return out
    end,
  },
}

M.mappings = {
  global = { review = "<prefix>W" },
}

function M.setup()
  define_highlights()
end

function M.teardown()
  if M.session then
    save_state()
    close_window()
    M.session = nil
  end
end

function M.health(h, o)
  local _, errors = steps_mod.resolve(o.steps)
  for _, e in ipairs(errors) do
    h.error("review: " .. e)
  end
  for _, p in ipairs(steps_mod.inbox_paths(o)) do
    if vim.fn.filereadable(p) == 1 then
      h.ok("review inbox: " .. p)
    else
      h.warn("review inbox not found: " .. p)
    end
  end
  h.info("review log: " .. log_path())
  if M.load_state() then
    h.info("an unfinished review is saved in " .. tostring(state_file()))
  end
end

return M
