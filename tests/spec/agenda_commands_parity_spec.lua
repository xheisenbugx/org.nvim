-- Agenda commands pinned to Emacs Org 9.8.10: hour / minute date shifts,
-- remote undo, TODO changes with yesterday's time, habit toggles. The
-- expected texts came from Emacs 9.8.10 probes (org-agenda-do-date-later
-- and friends on the same entries).
local date = require("org.date")
local config = require("org.config")
local utils = require("org.utils")
local view = require("org.agenda.view")
local agenda = require("org.agenda")

local today = date.today()
local function ts(offset, extra)
  local s = today:add(offset, "d"):to_string({ brackets = false })
  return "<" .. s .. (extra and (" " .. extra) or "") .. ">"
end

local dir = vim.fn.tempname()
vim.fn.mkdir(dir, "p")
dir = vim.uv.fs_realpath(dir)
local path = dir .. "/c.org"

local function open(lines, opts)
  utils.writefile(path, lines)
  local b = utils.find_buffer(path)
  if b then
    vim.api.nvim_buf_delete(b, { force = true })
  end
  config.setup(vim.tbl_deep_extend("force", { agenda_files = { path }, org_directory = dir }, opts or {}))
  config.opts.clock.persist = false
  agenda.open_agenda({ span = "day" })
end

local function goto_title(title)
  local lines = vim.tbl_keys(view.state.line_items)
  table.sort(lines)
  for _, l in ipairs(lines) do
    if view.state.line_items[l].title == title then
      vim.api.nvim_win_set_cursor(0, { l, 0 })
      return l
    end
  end
  error("no line for " .. title)
end

local function source_lines()
  return vim.api.nvim_buf_get_lines(utils.find_buffer(path), 0, -1, false)
end

--- Move the cursor to the first line, as a user motion would.
local function move_away()
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  vim.api.nvim_exec_autocmds("CursorMoved", { buffer = 0 })
end

local function press(keys)
  vim.api.nvim_feedkeys(vim.keycode(keys), "mx", false)
end

describe("agenda hour and minute date shifts", function()
  after_each(function()
    pcall(view.quit, true)
  end)

  it("count 4 (C-u) shifts a time by one hour, 16 (C-u C-u) by 5 minutes", function()
    open({ "* A", "  " .. ts(0, "10:00") })
    goto_title("A")
    press("4<S-Right>")
    eq("  " .. ts(0, "11:00"), source_lines()[2])
    -- move away and back so the next key is not a repeat
    move_away()
    goto_title("A")
    press("16<S-Right>")
    eq("  " .. ts(0, "11:05"), source_lines()[2])
  end)

  it("shifts both ends of a time range", function()
    open({ "* C", "  " .. ts(0, "10:00-11:30") })
    goto_title("C")
    press("4<S-Right>")
    eq("  " .. ts(0, "11:00-12:30"), source_lines()[2])
    move_away()
    goto_title("C")
    press("16<S-Left>")
    eq("  " .. ts(0, "10:55-12:25"), source_lines()[2])
  end)

  it("an hour past midnight moves the day", function()
    open({ "* D", "  SCHEDULED: " .. ts(0, "23:30") })
    goto_title("D")
    press("4<S-Right>")
    eq("  SCHEDULED: " .. ts(1, "00:30"), source_lines()[2])
  end)

  it("a date without a time loses a day going one hour earlier", function()
    open({ "* B", "  " .. ts(0) })
    goto_title("B")
    press("4<S-Left>")
    eq("  " .. ts(-1), source_lines()[2])
  end)

  it("right after an hour shift, <S-Right> keeps shifting hours", function()
    open({ "* A", "  " .. ts(0, "10:00") })
    goto_title("A")
    press("4<S-Right>")
    press("<S-Right>")
    eq("  " .. ts(0, "12:00"), source_lines()[2])
    -- after moving the cursor it shifts days again
    move_away()
    goto_title("A")
    press("<S-Right>")
    eq("  " .. ts(1, "12:00"), source_lines()[2])
  end)

  it("date_later_hours / date_earlier_minutes take a count", function()
    open(
      { "* A", "  " .. ts(0, "10:00") },
      { mappings = { agenda = { date_later_hours = "gH", date_earlier_minutes = "gM" } } }
    )
    goto_title("A")
    press("3gH")
    eq("  " .. ts(0, "13:00"), source_lines()[2])
    move_away()
    goto_title("A")
    press("2gM")
    eq("  " .. ts(0, "12:50"), source_lines()[2])
  end)

  it("move_date_from_past_immediately_to_today = false shifts one day", function()
    open({ "* Past", "  " .. ts(-3) }, { agenda = { move_date_from_past_immediately_to_today = false } })
    view.quit(true)
    agenda.open_agenda({ span = "day", anchor = today:days() - 3 })
    goto_title("Past")
    view.actions.date_later()
    eq("  " .. ts(-2), source_lines()[2])
  end)
end)

--- Run `fn` with utils.notify / utils.error captured.
local function capture_msgs(fn)
  local msgs, errs = {}, {}
  local notify, uerr = utils.notify, utils.error
  utils.notify = function(m)
    msgs[#msgs + 1] = m
  end
  utils.error = function(m)
    errs[#errs + 1] = m
  end
  local ok, err = pcall(fn, msgs, errs)
  utils.notify, utils.error = notify, uerr
  if not ok then
    error(err, 0)
  end
end

describe("agenda remote undo", function()
  after_each(function()
    pcall(view.quit, true)
  end)

  -- Emacs 9.8.10: priority up then date later, then undo twice restores
  -- each step, and a third undo errors "No further undo information".
  it("undoes source edits one command at a time", function()
    open({ "* TODO A", "  SCHEDULED: " .. ts(0), "* TODO B", "  SCHEDULED: " .. ts(0) })
    goto_title("A")
    view.run_action("priority_up")
    goto_title("A")
    view.run_action("date_later")
    eq({ "* TODO [#B] A", "  SCHEDULED: " .. ts(1) }, vim.list_slice(source_lines(), 1, 2))
    capture_msgs(function(msgs, errs)
      press("<C-_>")
      eq({ "* TODO [#B] A", "  SCHEDULED: " .. ts(0) }, vim.list_slice(source_lines(), 1, 2))
      eq("`date_later' undone (buffer c.org)", msgs[#msgs])
      press("<C-_>")
      eq({ "* TODO A", "  SCHEDULED: " .. ts(0) }, vim.list_slice(source_lines(), 1, 2))
      press("<C-_>")
      eq("No further undo information", errs[#errs])
    end)
  end)

  it("r forgets the undo information", function()
    open({ "* TODO A", "  SCHEDULED: " .. ts(0) })
    goto_title("A")
    view.run_action("priority_up")
    eq(1, #view.undo_list)
    view.run_action("redo")
    eq(0, #view.undo_list)
  end)
end)

local function titles()
  local out = {}
  local lines = vim.tbl_keys(view.state.line_items)
  table.sort(lines)
  for _, l in ipairs(lines) do
    out[#out + 1] = view.state.line_items[l].title
  end
  return out
end

describe("agenda habit toggles", function()
  after_each(function()
    pcall(view.quit, true)
  end)

  local lines = {
    "* TODO Water",
    "  SCHEDULED: " .. ts(2, ".+3d"),
    "  :PROPERTIES:",
    "  :STYLE: habit",
    "  :END:",
    "* TODO Other",
    "  SCHEDULED: " .. ts(0),
  }

  -- Emacs 9.8.10: C-u K shows the habit that is not due yet on today, K
  -- then turns habits off ("Habits turned off"); in a TODO list it errors.
  it("vh with a count shows all habits today, vh turns habits off", function()
    open(lines)
    eq({ "Other" }, titles())
    press("1vh")
    eq({ "Other", "Water" }, titles())
    capture_msgs(function(msgs)
      press("vh")
      eq("Habits turned off", msgs[#msgs])
    end)
    eq({ "Other" }, titles())
    eq(false, config.opts.agenda.habits.show_habits)
  end)

  it("is refused outside a date agenda", function()
    open(lines)
    view.quit(true)
    agenda.open_todo()
    capture_msgs(function(_, errs)
      view.run_action("toggle_habits")
      eq("Not allowed in ’todo’-type agenda buffer or component", errs[#errs])
    end)
  end)
end)

describe("agenda show commands", function()
  after_each(function()
    pcall(view.quit, true)
    pcall(vim.cmd, "silent! only")
  end)

  local lines = { "* TODO A", "  SCHEDULED: " .. ts(0), "** B", "   text" }

  -- Emacs 9.8.10 (org-agenda-cycle-show pressed six times): the levels are
  -- 1, 2, 3, 0, 2, 3 with "Remote: CHILDREN", "Remote: SUBTREE",
  -- "Remote: FOLDED", ...; org-agenda-show-1 4 says "Remote: SUBTREE AND
  -- ALL DRAWERS".
  it("cycle_show cycles children, subtree, folded when repeated", function()
    open(lines, { mappings = { agenda = { cycle_show = "gz" } } })
    goto_title("A")
    capture_msgs(function(msgs)
      local levels = {}
      for _ = 1, 6 do
        press("gz")
        levels[#levels + 1] = view.cycle_counter
      end
      eq({ 1, 2, 3, 0, 2, 3 }, levels)
      eq({ "Remote: CHILDREN", "Remote: SUBTREE", "Remote: FOLDED", "Remote: CHILDREN", "Remote: SUBTREE" }, msgs)
      view.show_1(4)
      eq("Remote: SUBTREE AND ALL DRAWERS", msgs[#msgs])
    end)
  end)

  --- "V"/"H" per line of the source file as its window shows it.
  local function source_win()
    return vim.fn.win_findbuf(utils.find_buffer(path))[1]
  end

  local function visibility()
    local w = source_win()
    local out = {}
    vim.api.nvim_win_call(w, function()
      for l = 1, vim.api.nvim_buf_line_count(0) do
        out[#out + 1] = require("org.fold").line_visible(l) and "V" or "H"
      end
    end)
    return table.concat(out)
  end

  -- Emacs 9.8.10 (org-agenda-show-1 with these levels in turn, on files
  -- that start fully visible; "H" = invisible line): level 2 never hides
  -- what is visible, level 0 folds only the entry's own subtree.
  it("show_1 folds like Emacs at each level", function()
    local cases = {
      {
        lines = lines,
        title = "A",
        steps = { { 1, "VVVV" }, { 2, "VVVV" }, { 2, "VVVV" }, { 3, "VVVV" }, { 0, "VHHH" } },
        tail = { { 2, "VVVH" }, { 3, "VVVV" }, { 4, "VVVV" } },
      },
      {
        lines = { "* A", "** TODO B", "   SCHEDULED: " .. ts(0), "*** C", "    text" },
        title = "B",
        steps = { { 1, "VVVVV" }, { 2, "VVVVV" }, { 3, "VVVVV" }, { 0, "VVHHH" } },
        tail = { { 2, "VVVVH" }, { 0, "VVHHH" }, { 0, "VVHHH" } },
      },
      {
        lines = { "* TODO A", "  SCHEDULED: " .. ts(0), "** B", "   text", "** C", "*** D", "    x" },
        title = "A",
        steps = { { 0, "VHHHHHH" }, { 2, "VVVHVHH" }, { 3, "VVVVVVV" }, { 2, "VVVVVVV" } },
        tail = {},
      },
    }
    for _, c in ipairs(cases) do
      open(c.lines)
      goto_title(c.title)
      for _, s in ipairs(vim.list_extend(vim.deepcopy(c.steps), c.tail)) do
        view.show_1(s[1])
        eq(c.title .. " " .. s[1] .. " " .. s[2], c.title .. " " .. s[1] .. " " .. visibility())
      end
      view.quit(true)
      vim.cmd("silent! only")
    end
  end)

  it("cycle_show on an entry with a folded child keeps the entry open", function()
    open(lines, { mappings = { agenda = { cycle_show = "gz" } } })
    goto_title("A")
    press("gz")
    press("gz")
    vim.api.nvim_win_call(source_win(), function()
      eq(-1, vim.fn.foldclosed(1))
    end)
  end)

  it("shows the entry next to a modified buffer that can't be hidden", function()
    -- the other window holds an unsaved bufhidden=wipe buffer (E37 on a
    -- plain buffer switch): the file opens in a split, reused afterwards
    local scratch = org_buffer({ "* scratch" })
    open(lines)
    goto_title("A")
    view.show_1(3)
    view.show_1(0)
    local wins = vim.fn.win_findbuf(utils.find_buffer(path))
    eq(1, #wins)
    vim.api.nvim_win_call(wins[1], function()
      eq(1, vim.fn.foldclosed(1))
    end)
    ok(#vim.fn.win_findbuf(scratch) == 1)
    vim.bo[scratch].modified = false
  end)

  it("<Space> shows the entry, and pressed again scrolls it", function()
    local long = { "* TODO A", "  SCHEDULED: " .. ts(0) }
    for i = 1, 200 do
      long[#long + 1] = "  line " .. i
    end
    open(long)
    goto_title("A")
    press("<Space>")
    local w = view.show_window
    ok(w and vim.api.nvim_win_is_valid(w))
    eq(vim.api.nvim_get_current_win(), view.state.win)
    local top = vim.fn.getwininfo(w)[1].topline
    press("<Space>")
    ok(vim.fn.getwininfo(w)[1].topline > top, "scrolled forward")
    local top2 = vim.fn.getwininfo(w)[1].topline
    press("<BS>")
    ok(vim.fn.getwininfo(w)[1].topline < top2, "scrolled back")
  end)

  it("<C-c><C-x>b shows the subtree in an edit buffer in the other window", function()
    open(lines)
    goto_title("A")
    press("<C-c><C-x>b")
    local buf = view.state.indirect_buf
    ok(buf and vim.api.nvim_buf_is_valid(buf))
    eq(lines, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
    eq(vim.api.nvim_get_current_win(), view.state.win)
    ok(#vim.fn.win_findbuf(buf) == 1)
  end)

  it("follow_indirect makes follow mode show the subtree buffer", function()
    open(lines, { agenda = { follow_indirect = true } })
    goto_title("A")
    view.run_action("follow_mode")
    local buf = view.state.indirect_buf
    ok(buf and vim.api.nvim_buf_is_valid(buf))
    eq("* TODO A", vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1])
  end)

  it("a middle click goes to the entry under the mouse", function()
    open(lines)
    local l = goto_title("A")
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    local getmousepos = vim.fn.getmousepos
    vim.fn.getmousepos = function()
      return { winid = view.state.win, line = l, column = 5 }
    end
    local okc, err = pcall(view.run_action, "goto_mouse")
    vim.fn.getmousepos = getmousepos
    assert(okc, err)
    eq(utils.find_buffer(path), vim.api.nvim_get_current_buf())
    eq(1, vim.api.nvim_win_get_cursor(0)[1])
  end)

  -- org-agenda-mouse-1-follows-link binds [follow-link] to mouse-face:
  -- a short mouse-1 click without a drag follows, a longer one sets point
  it("with mouse_1_follows_link only a short click goes to the entry", function()
    open(lines, { agenda = { mouse_1_follows_link = true } })
    local maps = {}
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(0, "n")) do
      maps[m.lhs] = true
    end
    ok(maps["<LeftMouse>"] and maps["<LeftRelease>"])
    local l = goto_title("A")
    local getmousepos = vim.fn.getmousepos
    vim.fn.getmousepos = function()
      return { winid = view.state.win, line = l, column = 5, screenrow = 3, screencol = 5 }
    end
    local function click(press, release)
      vim.api.nvim_set_current_win(view.state.win)
      view._mouse_press, view._mouse_release = press, release
      view.mouse_1_release()
      return vim.api.nvim_get_current_buf()
    end
    local okc, err = pcall(function()
      local agenda_buf = vim.api.nvim_win_get_buf(view.state.win)
      -- held too long, then dragged: point only
      eq(agenda_buf, click({ time = 0, row = 3, col = 5 }, { time = 1000, row = 3, col = 5 }))
      eq(agenda_buf, click({ time = 0, row = 2, col = 5 }, { time = 10, row = 3, col = 5 }))
      local shown = click({ time = 0, row = 3, col = 5 }, { time = 100, row = 3, col = 5 })
      eq(utils.find_buffer(path), shown)
    end)
    vim.fn.getmousepos = getmousepos
    assert(okc, err)
  end)
end)

describe("agenda todo_yesterday", function()
  after_each(function()
    pcall(view.quit, true)
  end)

  -- Emacs 9.8.10 (org-log-done 'time), run on 2026-09-28:
  --   * DONE A
  --   CLOSED: [2026-09-27 Sun 23:59] SCHEDULED: <2026-09-28 Mon>
  --   * TODO R
  --   SCHEDULED: <2026-09-29 Tue .+2d>
  --   :PROPERTIES:
  --   :LAST_REPEAT: [2026-09-27 Sun 23:59]
  --   :END:
  --   - State "DONE"       from "TODO"       [2026-09-27 Sun 23:59]
  it("records 23:59 of yesterday as the time of the change", function()
    open(
      { "* TODO A", "SCHEDULED: " .. ts(0), "* TODO R", "SCHEDULED: " .. ts(0, ".+2d") },
      { log_done = "time", mappings = { agenda = { todo_yesterday = "gy" } } }
    )
    local y = "[" .. today:add(-1, "d"):to_string({ brackets = false }) .. " 23:59]"
    goto_title("A")
    press("gy")
    goto_title("R")
    press("gy")
    eq({
      "* DONE A",
      "CLOSED: " .. y .. " SCHEDULED: " .. ts(0),
      "* TODO R",
      "SCHEDULED: " .. ts(1, ".+2d"),
      ":PROPERTIES:",
      ":LAST_REPEAT: " .. y,
      ":END:",
      '- State "DONE"       from "TODO"       ' .. y,
    }, source_lines())
    eq(false, config.opts.use_effective_time)
  end)
end)

describe("agenda archive default", function()
  after_each(function()
    pcall(view.quit, true)
    config.setup({})
  end)

  -- org-agenda-archive-default runs org-archive-default-command without
  -- asking; `a` asks "Archive this subtree or entry? " first (Emacs 9.8.10).
  it("<C-c><C-x><C-a> runs archive_default_command; a asks first", function()
    open({ "* TODO A", "  SCHEDULED: " .. ts(0), "* TODO B", "  SCHEDULED: " .. ts(0) }, {
      archive_default_command = "set_tag",
    })
    goto_title("A")
    press("<C-c><C-x><C-a>")
    ok(source_lines()[1]:find(":ARCHIVE:$"), source_lines()[1])
    local asked
    local confirm = utils.confirm
    utils.confirm = function(q)
      asked = q
      return false
    end
    goto_title("B")
    capture_msgs(function(_, errs)
      press("a")
      eq("Abort", errs[#errs])
    end)
    utils.confirm = confirm
    eq("Archive this subtree or entry? ", asked)
    eq("* TODO B", source_lines()[3])
  end)
end)

describe("agenda_kill_all_buffers", function()
  after_each(function()
    config.setup({})
  end)

  local function agenda_bufs()
    return vim.tbl_filter(function(b)
      return vim.api.nvim_buf_is_valid(b) and vim.bo[b].filetype == "orgagenda"
    end, vim.api.nvim_list_bufs())
  end

  it("deletes every agenda buffer (org-agenda-kill-all-agenda-buffers)", function()
    open({ "* TODO A" }, { agenda = { sticky = true } })
    agenda.open({ type = "todo" })
    ok(#agenda_bufs() >= 2)
    vim.cmd("Org agenda_kill_all_buffers")
    eq(0, #agenda_bufs())
  end)

  it("toggling sticky agendas deletes the agenda buffers first", function()
    open({ "* TODO A" })
    ok(#agenda_bufs() >= 1)
    capture_msgs(function()
      agenda.toggle_sticky()
    end)
    eq(0, #agenda_bufs())
  end)
end)

describe("restriction lock highlight", function()
  after_each(function()
    pcall(agenda.remove_restriction_lock)
    pcall(vim.cmd, "bwipe!")
  end)

  local function lock_marks(buf)
    local ns = vim.api.nvim_create_namespace("org.agenda.lock")
    return vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
  end

  -- org-agenda-set-restriction-lock moves its overlay over the subtree, or
  -- only the headline line when org-agenda-restriction-lock-highlight-subtree
  -- is nil; removing the lock deletes it.
  it("highlights the locked subtree, or its headline", function()
    config.setup({})
    local buf = org_buffer({ "* A", "text", "** B", "* C" }, { 1, 0 })
    capture_msgs(function()
      agenda.set_restriction_lock()
    end)
    local m = lock_marks(buf)
    eq(1, #m)
    eq({ 0, 2 }, { m[1][2], m[1][4].end_row })
    capture_msgs(function()
      agenda.remove_restriction_lock()
    end)
    eq(0, #lock_marks(buf))
    config.opts.agenda.restriction_lock_highlight_subtree = false
    capture_msgs(function()
      agenda.set_restriction_lock()
    end)
    m = lock_marks(buf)
    eq({ 0, 0 }, { m[1][2], m[1][4].end_row })
  end)
end)

describe("columns_add_appointments_to_effort_sum", function()
  after_each(function()
    pcall(require("org.agenda.columns").quit)
    pcall(view.quit, true)
  end)

  -- org-columns--collect-values (Emacs 9.8.10): without an Effort, the
  -- `duration` of the agenda line (org-duration-from-minutes) is used when
  -- org-agenda-columns-add-appointments-to-effort-sum is set.
  it("counts an appointment's duration as its effort", function()
    local cols = require("org.agenda.columns")
    local lines = {
      "#+COLUMNS: %25ITEM %Effort{:}",
      "* Meeting",
      "  " .. ts(0, "10:00-11:30"),
      "* TODO Task",
      "  SCHEDULED: " .. ts(0),
      "  :PROPERTIES:",
      "  :Effort: 0:15",
      "  :END:",
    }
    open(lines, { agenda = { columns_add_appointments_to_effort_sum = true } })
    ok(cols.toggle())
    local l = goto_title("Meeting")
    eq({ "Meeting", "1:30" }, cols.cells(l))
    pcall(cols.quit)
    view.quit(true)
    open(lines)
    ok(cols.toggle())
    eq({ "Meeting", "" }, cols.cells(goto_title("Meeting")))
  end)
end)

-- leave the default options to the specs that follow
describe("agenda_commands_parity_spec cleanup", function()
  it("restores the default options", function()
    pcall(view.quit, true)
    config.setup({})
    ok(config.opts.agenda.skip_function_global == nil)
  end)
end)
