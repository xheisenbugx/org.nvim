---@mod org.extensions.sidebar A "Today" side window
---
--- A narrow window at the side of the tab that keeps today in view: the
--- running clock against its effort, the next appointment with a
--- countdown, today's scheduled items and deadlines, the habits due and
--- the number of entries waiting in the inbox. It is redrawn by a timer
--- while it is open and whenever an org file is written.
---
--- ```lua
--- require("org").setup({ extensions = { sidebar = { position = "left" } } })
--- ```

local views = require("org.extensions.views_util")
local date = require("org.date")
local utils = require("org.utils")

local M = {}

local MOD = "org.extensions.sidebar"
local ns = vim.api.nvim_create_namespace("org_sidebar")
local augroup = vim.api.nvim_create_augroup("OrgSidebar", { clear = true })

M.defaults = {
  --- Side of the tab: "left" or "right".
  position = "right",
  --- Width in columns.
  width = 40,
  --- Seconds between redraws while it is open.
  interval = 30,
  --- Sections, top to bottom: "clock", "next", "today", "habits", "inbox".
  sections = { "clock", "next", "today", "habits", "inbox" },
  --- Keep DONE entries in the lists.
  show_done = false,
  --- Upcoming deadlines are listed from this many days before they are
  --- due (the agenda's warning period applies too).
  deadline_days = 7,
  --- The file whose top-level entries the inbox counts (default:
  --- `default_notes_file`).
  ---@type string|nil
  inbox_file = nil,
  --- Move the cursor into the sidebar when it opens.
  focus = false,
  --- Symbols before the section names and entries.
  icons = {
    clock = "◷",
    next = "»",
    today = "▣",
    habits = "↻",
    inbox = "✉",
    deadline = "◆",
    scheduled = "▸",
  },
  --- Keys in the sidebar.
  keys = { jump = "<CR>", refresh = "r", close = "q" },
}

M.actions = {
  sidebar_toggle = { MOD, "toggle", desc = "Toggle the Today sidebar" },
  sidebar_open = { MOD, "open", desc = "Open the Today sidebar" },
  sidebar_close = { MOD, "close", desc = "Close the Today sidebar" },
}

M.mappings = { global = { sidebar_toggle = "<prefix>Vs" } }
M.groups = { { "V", "views" } }

---@type table|nil
M.state = nil

local function opts()
  return require("org.extensions").opts("sidebar") or M.defaults
end

function M.setup()
  views.highlights(augroup, {
    OrgSidebarTitle = { link = "Title" },
    OrgSidebarDate = { link = "Comment" },
    OrgSidebarSection = { link = "Function" },
    OrgSidebarCount = { link = "Comment" },
    OrgSidebarTime = { link = "Number" },
    OrgSidebarPast = { link = "Comment" },
    OrgSidebarText = {},
    OrgSidebarEmpty = { link = "NonText" },
    OrgSidebarCountdown = { link = "DiagnosticWarn" },
    OrgSidebarOverdue = { link = "DiagnosticError" },
    OrgSidebarDue = { link = "DiagnosticWarn" },
    OrgSidebarScheduled = { link = "Comment" },
    OrgSidebarProgress = { link = "DiagnosticOk" },
    OrgSidebarProgressEmpty = { link = "NonText" },
    OrgSidebarOverrun = { link = "DiagnosticError" },
  })
end

function M.teardown()
  M.close()
  vim.api.nvim_clear_autocmds({ group = augroup })
end

function M.health(h, o)
  local inbox = (o and o.inbox_file) or require("org.config").opts.default_notes_file
  if inbox and not utils.exists(utils.expand(inbox)) then
    h.warn("sidebar: inbox file not found: " .. inbox)
  else
    h.ok("sidebar: toggle with the sidebar_toggle action")
  end
end

---------------------------------------------------------------------------
-- Data
---------------------------------------------------------------------------

local function item_ref(item)
  return { filename = item.filename, bufnr = item.bufnr, lnum = item.lnum, raw = item.raw }
end

--- What the sidebar shows: `{ clock, next, timed, today, habits, inbox }`.
---@param o table options
---@return table
function M.collect(o)
  local today = date.today_days()
  local now = date.now()
  local now_min = now.hour * 60 + now.min
  local habits = require("org.agenda.habits")
  local files = require("org.files").agenda_files()
  local by_day = require("org.agenda.items").agenda(files, today, today, {})
  local data = { timed = {}, today = {}, habits = {}, now_min = now_min, today_days = today }
  local seen = {}
  for _, item in ipairs(by_day[today] or {}) do
    local hl = item.headline
    local key = hl and (tostring(item.filename) .. ":" .. item.lnum .. ":" .. tostring(item.time)) or nil
    local keep = hl ~= nil and not (key and seen[key]) and (o.show_done or not item.done)
    if keep and item.type == "deadline" and hl.planning.deadline then
      -- the agenda's warning period, cut to `deadline_days`
      keep = hl.planning.deadline:days() - today <= (o.deadline_days or 7)
    end
    if keep then
      seen[key] = true
      local entry = {
        ref = item_ref(item),
        todo = item.todo,
        title = views.title(hl),
        time = item.time,
        end_time = item.end_time,
        type = item.type,
        done = item.done,
      }
      if item.type == "deadline" and hl.planning.deadline then
        entry.deadline = hl.planning.deadline:days() - today
      elseif item.type == "scheduled" and hl.planning.scheduled then
        entry.scheduled = hl.planning.scheduled:days() - today
      end
      if habits.is_habit(hl) then
        data.habits[#data.habits + 1] = entry
      elseif item.time then
        data.timed[#data.timed + 1] = entry
      else
        data.today[#data.today + 1] = entry
      end
    end
  end
  table.sort(data.timed, function(a, b)
    return a.time < b.time
  end)
  -- deadlines first (the most overdue first), then scheduled items
  table.sort(data.today, function(a, b)
    local ka = a.deadline or (a.scheduled and 1000 + a.scheduled) or 2000
    local kb = b.deadline or (b.scheduled and 1000 + b.scheduled) or 2000
    if ka ~= kb then
      return ka < kb
    end
    return a.title < b.title
  end)
  for _, e in ipairs(data.timed) do
    local stop = e.end_time or e.time
    if not e.done and stop >= now_min then
      data.next = e
      break
    end
  end
  local a = require("org.clock").active()
  if a then
    data.clock = a
  end
  local inbox = o.inbox_file or require("org.config").opts.default_notes_file
  if inbox then
    local path = utils.expand(inbox)
    local f = require("org.files").get(path)
    if f then
      local n = 0
      for _, hl in ipairs(f.headlines) do
        if hl.level == 1 and not hl:is_done() then
          n = n + 1
        end
      end
      data.inbox = { path = path, count = n }
    end
  end
  return data
end

---------------------------------------------------------------------------
-- Rendering
---------------------------------------------------------------------------

local function hhmm(min)
  return string.format("%02d:%02d", math.floor(min / 60) % 24, min % 60)
end

--- A progress bar of `width` cells for `frac` (0-1, more is full).
function M.bar(frac, width)
  local full = math.max(0, math.min(width, math.floor(frac * width + 0.5)))
  return string.rep("▰", full), string.rep("▱", width - full)
end

--- Draw the sidebar.
function M.render(st)
  if not vim.api.nvim_buf_is_valid(st.buf) then
    return
  end
  local o = st.opts
  local icons = o.icons or {}
  local data = M.collect(o)
  st.data = data
  local w = st.win and vim.api.nvim_win_is_valid(st.win) and vim.api.nvim_win_get_width(st.win) or o.width
  local inner = math.max(10, w - 3)
  local cv = views.Canvas.new()
  local refs = {}
  local todo_cfg = require("org.todo_keywords").global()

  local function section(icon, name, count, count_hl)
    cv:add("")
    cv:line()
    cv:put(" " .. (icon and icon ~= "" and (icon .. " ") or ""), "OrgSidebarSection")
    cv:put(name, "OrgSidebarSection")
    if count then
      cv:put("  " .. count, count_hl or "OrgSidebarCount")
    end
  end

  -- an entry line: optional time, keyword, title and a right-aligned note
  local function entry(e, lead, lead_hl, note, note_hl)
    local lnum = cv:line()
    refs[lnum] = e.ref
    cv:put("  ")
    local used = 2
    if lead then
      cv:put(lead .. " ", lead_hl)
      used = used + utils.width(lead) + 1
    end
    if e.todo then
      cv:put(e.todo .. " ", views.todo_group(e.todo, todo_cfg))
      used = used + utils.width(e.todo) + 1
    end
    local room = inner + 1 - used - (note and (utils.width(note) + 1) or 0)
    local title = views.fit(e.title, math.max(4, room))
    cv:put(title, e.done and "OrgSidebarPast" or "OrgSidebarText")
    if note then
      cv:put(" " .. note, note_hl)
    end
  end

  local today = date.from_days(data.today_days)
  cv:add({ { " Today", "OrgSidebarTitle" }, { "  " .. today:strftime("%a %b %d"), "OrgSidebarDate" } })

  for _, name in ipairs(o.sections or {}) do
    if name == "clock" then
      section(icons.clock, "Clock", nil)
      local c = data.clock
      if c then
        local lnum = cv:line()
        refs[lnum] = { clock = true }
        cv:put("  ")
        cv:put(views.fit(c.title, inner), "OrgSidebarText")
        cv:line()
        refs[lnum + 1] = { clock = true }
        local spent = date.format_duration(c.clocked)
        cv:put("  ")
        if c.effort and c.effort > 0 then
          local label = spent .. " / " .. date.format_duration(c.effort) .. " "
          cv:put(label, c.overrun and "OrgSidebarOverrun" or "OrgSidebarTime")
          local full, empty = M.bar(c.clocked / c.effort, math.max(4, inner - utils.width(label) - 1))
          cv:put(full, c.overrun and "OrgSidebarOverrun" or "OrgSidebarProgress")
          cv:put(empty, "OrgSidebarProgressEmpty")
        else
          cv:put(spent, "OrgSidebarTime")
          cv:put("  since " .. hhmm(c.start.hour * 60 + c.start.min), "OrgSidebarCount")
        end
      else
        cv:add({ { "  not clocked in", "OrgSidebarEmpty" } })
      end
    elseif name == "next" then
      local e = data.next
      local countdown
      if e then
        local diff = e.time - data.now_min
        countdown = diff <= 0 and "now" or ("in " .. views.short_duration(diff))
      end
      section(icons.next, "Next", countdown, "OrgSidebarCountdown")
      if e then
        entry(e, hhmm(e.time), "OrgSidebarTime")
      else
        cv:add({ { "  nothing else today", "OrgSidebarEmpty" } })
      end
    elseif name == "today" then
      local n = #data.timed + #data.today
      section(icons.today, "Agenda", n > 0 and tostring(n) or nil)
      for _, e in ipairs(data.timed) do
        local past = (e.end_time or e.time) < data.now_min
        entry(e, hhmm(e.time), past and "OrgSidebarPast" or "OrgSidebarTime")
      end
      for _, e in ipairs(data.today) do
        if e.deadline then
          local hl = e.deadline < 0 and "OrgSidebarOverdue"
            or (e.deadline == 0 and "OrgSidebarDue" or "OrgSidebarCount")
          entry(e, icons.deadline, hl, views.relative_days(e.deadline), hl)
        else
          local d = e.scheduled or 0
          entry(e, icons.scheduled, "OrgSidebarScheduled", d < 0 and views.relative_days(d) or nil, "OrgSidebarCount")
        end
      end
      if n == 0 then
        cv:add({ { "  nothing planned", "OrgSidebarEmpty" } })
      end
    elseif name == "habits" then
      section(icons.habits, "Habits", #data.habits > 0 and tostring(#data.habits) or nil)
      for _, e in ipairs(data.habits) do
        entry(e, nil, nil)
      end
      if #data.habits == 0 then
        cv:add({ { "  all done", "OrgSidebarEmpty" } })
      end
    elseif name == "inbox" and data.inbox then
      local n = data.inbox.count
      section(icons.inbox, "Inbox", n == 1 and "1 entry" or (n .. " entries"), n > 0 and "OrgSidebarCountdown" or nil)
      local lnum = #cv.lines
      refs[lnum] = { filename = data.inbox.path, inbox = true }
    end
  end
  st.refs = refs
  local view = st.win and vim.api.nvim_win_is_valid(st.win) and vim.api.nvim_win_call(st.win, vim.fn.winsaveview)
  cv:draw(st.buf, ns)
  if view then
    vim.api.nvim_win_call(st.win, function()
      vim.fn.winrestview(view)
    end)
  end
end

---------------------------------------------------------------------------
-- Window
---------------------------------------------------------------------------

local function is_open(st)
  return st and st.win and vim.api.nvim_win_is_valid(st.win) and vim.api.nvim_buf_is_valid(st.buf)
end

--- Whether the sidebar is open.
function M.is_open()
  return is_open(M.state) and true or false
end

local function stop(st)
  if st.timer then
    pcall(function()
      st.timer:stop()
      st.timer:close()
    end)
    st.timer = nil
  end
  pcall(vim.api.nvim_del_augroup_by_id, st.watch)
end

function M.refresh()
  local st = M.state
  if is_open(st) then
    M.render(st)
  end
end

--- A window of the tab to open entries in: the last one used that is not
--- the sidebar nor floating, else a new split.
local function edit_window(st)
  local prev = vim.fn.win_getid(vim.fn.winnr("#"))
  local function usable(win)
    return win ~= 0
      and win ~= st.win
      and vim.api.nvim_win_is_valid(win)
      and vim.api.nvim_win_get_config(win).relative == ""
      and vim.api.nvim_win_get_tabpage(win) == vim.api.nvim_get_current_tabpage()
  end
  if usable(prev) then
    return prev
  end
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if usable(win) then
      return win
    end
  end
  vim.api.nvim_set_current_win(st.win)
  vim.cmd(st.opts.position == "left" and "rightbelow vsplit" or "leftabove vsplit")
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, vim.api.nvim_create_buf(true, false))
  vim.api.nvim_win_set_width(st.win, st.opts.width)
  return win
end

--- Open the entry on the cursor line in the window next to the sidebar.
function M.jump()
  local st = M.state
  if not is_open(st) then
    return
  end
  local ref = st.refs[vim.api.nvim_win_get_cursor(st.win)[1]]
  if not ref then
    return
  end
  local target
  if ref.clock then
    local bufnr, lnum = require("org.clock").find_open_clock()
    if not bufnr then
      return
    end
    local hl = require("org.files").get_buffer(bufnr):headline_at(lnum)
    target = { bufnr = bufnr, lnum = hl and hl.line or lnum }
  elseif ref.inbox then
    target = { bufnr = utils.find_buffer(ref.filename) or utils.load_buffer(ref.filename), lnum = 1 }
  else
    target = views.target(ref)
  end
  if not target then
    return
  end
  local win = edit_window(st)
  vim.api.nvim_set_current_win(win)
  utils.set_current_buf(target.bufnr)
  vim.api.nvim_win_set_cursor(win, { target.lnum, 0 })
  pcall(vim.cmd, "normal! zv")
end

--- Open the sidebar in the current tab (closing it in another tab).
function M.open()
  local st = M.state
  if is_open(st) then
    if vim.api.nvim_win_get_tabpage(st.win) == vim.api.nvim_get_current_tabpage() then
      return st
    end
    M.close()
  end
  local o = vim.deepcopy(opts())
  local prev = vim.api.nvim_get_current_win()
  local buf = views.scratch("org://sidebar", "orgsidebar")
  local cmd = (o.position == "left" and "topleft " or "botright ") .. tostring(o.width) .. "vsplit"
  vim.cmd(cmd)
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, buf)
  local wo = vim.wo[win]
  wo.number = false
  wo.relativenumber = false
  wo.signcolumn = "no"
  wo.foldcolumn = "0"
  wo.statuscolumn = ""
  wo.colorcolumn = ""
  wo.spell = false
  wo.list = false
  wo.wrap = false
  wo.cursorline = true
  wo.winfixwidth = true
  -- a blank status line of its own; the global one (laststatus=3) is kept
  if vim.o.laststatus ~= 3 then
    wo.statusline = " "
  end
  wo.winbar = ""
  wo.fillchars = "eob: "
  if vim.fn.exists("+winfixbuf") == 1 then
    wo.winfixbuf = true
  end
  st = { buf = buf, win = win, opts = o }
  M.state = st
  views.map(buf, o.keys, { jump = M.jump, refresh = M.refresh, close = M.close }, "sidebar")
  st.watch = views.watch("OrgSidebarWatch", M.refresh, 200)
  vim.api.nvim_create_autocmd({ "WinClosed" }, {
    group = st.watch,
    pattern = tostring(win),
    callback = function()
      stop(st)
      if M.state == st then
        M.state = nil
      end
    end,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = st.watch,
    buffer = buf,
    callback = function()
      stop(st)
      if M.state == st then
        M.state = nil
      end
    end,
  })
  local interval = math.max(1, tonumber(o.interval) or 30) * 1000
  st.timer = vim.uv.new_timer()
  st.timer:start(
    interval,
    interval,
    vim.schedule_wrap(function()
      if M.state == st and is_open(st) then
        M.render(st)
      end
    end)
  )
  M.render(st)
  pcall(vim.api.nvim_win_set_cursor, win, { 1, 0 })
  if not o.focus and vim.api.nvim_win_is_valid(prev) then
    vim.api.nvim_set_current_win(prev)
  end
  return st
end

function M.close()
  local st = M.state
  M.state = nil
  if not st then
    return
  end
  stop(st)
  if st.win and vim.api.nvim_win_is_valid(st.win) then
    if #vim.api.nvim_tabpage_list_wins(vim.api.nvim_win_get_tabpage(st.win)) > 1 then
      pcall(vim.api.nvim_win_close, st.win, true)
    else
      pcall(vim.api.nvim_win_set_buf, st.win, vim.api.nvim_create_buf(true, true))
    end
  end
  if vim.api.nvim_buf_is_valid(st.buf) then
    pcall(vim.api.nvim_buf_delete, st.buf, { force = true })
  end
end

function M.toggle()
  local st = M.state
  if is_open(st) and vim.api.nvim_win_get_tabpage(st.win) == vim.api.nvim_get_current_tabpage() then
    M.close()
  else
    M.open()
  end
end

return M
