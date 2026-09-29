-- Agenda options pinned to Emacs Org 9.8.10: skipping, line format,
-- dispatcher and window options. Expected texts come from Emacs 9.8.10
-- probes on the same files (noted per test).
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

local dir = vim.uv.fs_realpath((function()
  local d = vim.fn.tempname()
  vim.fn.mkdir(d, "p")
  return d
end)())
local path = dir .. "/skip.org"

local function open(lines, opts, spec)
  utils.writefile(path, lines)
  local b = utils.find_buffer(path)
  if b then
    vim.api.nvim_buf_delete(b, { force = true })
  end
  config.setup(vim.tbl_deep_extend("force", { agenda_files = { path }, org_directory = dir }, opts or {}))
  config.opts.clock.persist = false
  if spec then
    agenda.open(spec)
  else
    agenda.open_agenda({ span = "day" })
  end
end

local function buf_text()
  return vim.api.nvim_buf_get_lines(view.state.buf, 0, -1, false)
end

--- The agenda lines of items (no headers).
local function item_lines()
  local out = {}
  local lines = buf_text()
  local nums = vim.tbl_keys(view.state.line_items)
  table.sort(nums)
  for _, l in ipairs(nums) do
    out[#out + 1] = lines[l]
  end
  return out
end

local function press(keys)
  vim.api.nvim_feedkeys(vim.keycode(keys), "mx", false)
end

describe("agenda skipping", function()
  after_each(function()
    pcall(view.quit, true)
  end)

  local lines = { "* COMMENT Proj", "** TODO Inside", "* TODO Keep", "* TODO Skip me" }

  -- Emacs 9.8.10, org-todo-list with org-agenda-skip-comment-trees nil:
  --   "  skip:       TODO Inside", "  skip:       TODO Keep", "  skip:       TODO Skip me"
  it("skip_comment_trees = false lists entries of COMMENT trees", function()
    open(lines, { agenda = { skip_comment_trees = false } }, { type = "todo" })
    eq({ "  skip:       TODO Inside", "  skip:       TODO Keep", "  skip:       TODO Skip me" }, item_lines())
  end)

  -- Emacs 9.8.10, with org-agenda-skip-function-global skipping "Skip me":
  --   "  skip:       TODO Keep"
  it("skip_function_global applies to every view", function()
    local skip = function(hl)
      return hl:plain_title():find("Skip me", 1, true) ~= nil
    end
    open(lines, { agenda = { skip_function_global = skip } }, { type = "todo" })
    eq({ "  skip:       TODO Keep" }, item_lines())
    view.quit(true)
    agenda.open_search("TODO")
    for _, l in ipairs(item_lines()) do
      ok(not l:find("Skip me", 1, true), l)
    end
  end)
end)

describe("custom command contexts", function()
  -- Emacs 9.8.10 (org-contextualize-keys in a fundamental-mode buffer):
  -- p (only in text-mode) is dropped, q runs r's command, r is hidden, z
  -- has no rule and stays: ((q R cmd tags x) (z Z alltodo ""))
  it("filters and remaps custom commands by the current buffer", function()
    config.setup({
      agenda = {
        custom_commands = {
          p = { description = "P cmd", type = "todo" },
          r = { description = "R cmd", type = "tags", match = "x" },
          q = { description = "Q cmd", type = "search" },
          z = { description = "Z", type = "todo" },
        },
        custom_commands_contexts = {
          { "p", { { in_mode = "^text$" } } },
          { "q", "r", { { not_in_mode = "^text$" } } },
        },
      },
    })
    vim.cmd("enew")
    local cmds = agenda.custom_commands()
    eq({ "q", "z" }, vim.fn.sort(vim.tbl_keys(cmds)))
    eq("R cmd", cmds.q.description)
    vim.bo.filetype = "text"
    eq({ "p", "r", "z" }, vim.fn.sort(vim.tbl_keys(agenda.custom_commands())))
    vim.cmd("bwipe!")
  end)
end)

describe("dispatcher custom command lines", function()
  -- org-agenda-get-restriction-and-command (Emacs 9.8.10): the
  -- description, or a name for the type, then ": MATCH" with
  -- org-agenda-menu-show-matcher; two columns split the lines in halves.
  local function menu_lines(opts)
    config.setup({
      agenda = vim.tbl_extend("force", {
        custom_commands = {
          p = { description = "Projects", type = "tags", match = "+project" },
          w = { type = "todo", match = "WAITING" },
          x = { type = "search" },
          y = { description = "Block", types = { { type = "agenda" } } },
        },
      }, opts or {}),
    })
    local shown
    local ui = require("org.ui")
    local float = ui.float
    ui.float = function(lines, o)
      shown = lines
      return float(lines, o)
    end
    local getchar = utils.getchar
    utils.getchar = function()
      return nil
    end
    local ok2, err = pcall(agenda.prompt)
    ui.float, utils.getchar = float, getchar
    assert(ok2, err)
    local out = {}
    local on = false
    for _, l in ipairs(shown) do
      if l == "Custom commands" then
        on = true
      elseif on and l ~= "" and not l:find("Esc", 1, true) then
        out[#out + 1] = l
      end
    end
    return out
  end

  it("shows the match after the description", function()
    eq({
      " [p]  Projects: +project",
      " [w]  TODO keyword: WAITING",
      " [x]  Word search",
      " [y]  Block",
    }, menu_lines())
  end)

  it("menu_show_matcher = false hides it; menu_two_columns pairs the lines", function()
    eq({
      " [p]  Projects                            [x]  Word search",
      " [w]  TODO keyword                        [y]  Block",
    }, menu_lines({ menu_show_matcher = false, menu_two_columns = true }))
  end)
end)

describe("agenda line format options", function()
  after_each(function()
    pcall(view.quit, true)
  end)

  local function d(o)
    return today:add(o, "d"):to_string({ brackets = false })
  end
  local lines = {
    "* Trip <" .. d(-1) .. " 10:00>--<" .. d(1) .. " 12:00> now",
    "* TODO [#A] Hi prio",
    "  SCHEDULED: " .. ts(0),
    "* TODO [#C] Low prio",
    "  SCHEDULED: " .. ts(0),
    "* TODO Upcoming",
    "  DEADLINE: " .. ts(3),
    "* TODO Far",
    "  DEADLINE: " .. ts(10),
  }

  --- Highlight groups of the agenda line `lnum` (0-based ranges).
  local function groups_at(lnum)
    local ns = vim.api.nvim_create_namespace("org.agenda")
    local out = {}
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(view.state.buf, ns, { lnum - 1, 0 }, { lnum - 1, -1 }, {
      details = true,
    })) do
      if m[4].hl_group then
        out[#out + 1] = { m[3], m[4].end_col, m[4].hl_group }
      end
    end
    return out
  end

  local function has(list, want)
    for _, g in ipairs(list) do
      if vim.deep_equal(g, want) then
        return true
      end
    end
    return false
  end

  local function line_of(text)
    for l, s in ipairs(buf_text()) do
      if s:find(text, 1, true) then
        return l, s
      end
    end
    error("no line with " .. text)
  end

  -- Emacs 9.8.10 (org-agenda-list for the day, default options):
  --   "  block:      Scheduled:  TODO [#A] Hi prio"
  --   "  block:      (2/3):  Trip <...>--<...> now"
  --   "  block:      In   3 d.:  TODO Upcoming"
  --   "  block:      In  10 d.:  TODO Far"
  --   "  block:      Scheduled:  TODO [#C] Low prio"
  -- with overlays (26 30 (bold org-priority)) on [#A] and (italic
  -- org-priority) on [#C], and the faces org-upcoming-deadline (3 days of
  -- 14) and org-upcoming-distant-deadline (10 days).
  it("defaults: cookies bold / italic, deadline faces by closeness", function()
    open(vim.list_extend({}, lines), {}, nil)
    eq({
      "  skip:       Scheduled:  TODO [#A] Hi prio",
      "  skip:       (2/3):  Trip <" .. d(-1) .. " 10:00>--<" .. d(1) .. " 12:00> now",
      "  skip:       In   3 d.:  TODO Upcoming",
      "  skip:       In  10 d.:  TODO Far",
      "  skip:       Scheduled:  TODO [#C] Low prio",
    }, item_lines())
    local hi = line_of("[#A]")
    ok(has(groups_at(hi), { 31, 35, "OrgAgendaPriorityHighest" }), vim.inspect(groups_at(hi)))
    local lo = line_of("[#C]")
    ok(has(groups_at(lo), { 31, 35, "OrgAgendaPriorityLowest" }), vim.inspect(groups_at(lo)))
    local up = line_of("Upcoming")
    ok(has(groups_at(up), { 31, 39, "OrgAgendaDeadlineUpcoming" }), vim.inspect(groups_at(up)))
    local far = line_of("Far")
    ok(has(groups_at(far), { 31, 34, "OrgAgendaDeadlineDistant" }), vim.inspect(groups_at(far)))
  end)

  -- Emacs 9.8.10 with org-agenda-remove-timeranges-from-blocks t and
  -- org-agenda-todo-keyword-format "%-6s":
  --   "  block:      Scheduled:  TODO   [#A] Hi prio"
  --   "  block:      (2/3):  Trip  now"
  -- and with the format "": "  block:      Scheduled:  [#A] Hi prio"
  it("remove_timeranges_from_blocks and todo_keyword_format", function()
    open(vim.list_extend({}, lines), { agenda = { remove_timeranges_from_blocks = true, todo_keyword_format = "%-6s" } })
    local got = item_lines()
    eq("  skip:       Scheduled:  TODO   [#A] Hi prio", got[1])
    eq("  skip:       (2/3):  Trip  now", got[2])
    view.quit(true)
    open(vim.list_extend({}, lines), { agenda = { todo_keyword_format = "" } })
    eq("  skip:       Scheduled:  [#A] Hi prio", item_lines()[1])
  end)

  it("fontify_priorities = true faces the line from the cookie", function()
    open(vim.list_extend({}, lines), { agenda = { fontify_priorities = true } })
    local hi, s = line_of("[#A]")
    ok(has(groups_at(hi), { 31, #s, "OrgAgendaPriorityHighest" }), vim.inspect(groups_at(hi)))
  end)

  it("fontify_priorities = false leaves the cookie to the entry face", function()
    open(vim.list_extend({}, lines), { agenda = { fontify_priorities = false } })
    local hi = line_of("[#A]")
    for _, g in ipairs(groups_at(hi)) do
      ok(not g[3]:find("Priority"), g[3])
    end
  end)

  it("day_face_function and bulk_mark_char", function()
    open(vim.list_extend({}, lines), {
      agenda = {
        day_face_function = function(day)
          return day:days() == today:days() and "ErrorMsg" or nil
        end,
        bulk_mark_char = "*",
      },
    })
    local l = line_of(today.year .. " W")
    eq({ { 0, #buf_text()[l], "ErrorMsg" } }, groups_at(l))
    local hi = line_of("[#A]")
    vim.api.nvim_win_set_cursor(0, { hi, 0 })
    view.actions.mark()
    local ns = vim.api.nvim_create_namespace("org.agenda.marks")
    local m = vim.api.nvim_buf_get_extmarks(view.state.buf, ns, 0, -1, { details = true })[1]
    eq("*", m[4].virt_text[1][1])
  end)
end)

describe("diary_sexp_prefix", function()
  after_each(function()
    pcall(view.quit, true)
  end)

  -- Emacs 9.8.10, prefix format " %-12:c%-10s": with the regexp "^Bday: *"
  -- the line is " skip:       Bday:     John"; "^bday: *" does not match
  -- (case-sensitive): " skip:                 Bday: John"
  it("moves the matching part of a diary sexp's text to the leader", function()
    local d = today
    local lines = { "* Dates", string.format("%%%%(diary-date %d %d %d) Bday: John", d.month, d.day, d.year) }
    open(lines, { agenda = { diary_sexp_prefix = "^Bday: *", prefix_format = { agenda = " %-12:c%-10s" } } })
    eq({ " skip:       Bday:     John" }, item_lines())
    view.quit(true)
    open(lines, { agenda = { diary_sexp_prefix = "^bday: *", prefix_format = { agenda = " %-12:c%-10s" } } })
    eq({ " skip:                 Bday: John" }, item_lines())
  end)
end)

describe("start_with_archives_mode", function()
  after_each(function()
    pcall(view.quit, true)
  end)

  -- Emacs 9.8.10 with org-agenda-start-with-archives-mode 'trees: the
  -- day agenda lists "TODO Keep" and the ARCHIVE-tagged "TODO Old".
  it("opens agendas with archived trees included", function()
    local lines = { "* TODO Keep", "  SCHEDULED: " .. ts(0), "* TODO Old :ARCHIVE:", "  SCHEDULED: " .. ts(0) }
    open(lines)
    eq(1, #item_lines())
    view.quit(true)
    open(lines, { agenda = { start_with_archives_mode = "trees" } })
    eq("trees", view.state.archives)
    local got = item_lines()
    eq(2, #got)
    ok(got[2]:find("^  skip:       Scheduled:  TODO Old%s+:ARCHIVE:$"), got[2])
  end)
end)

--- Run `fn` with utils.getchar / utils.input answering from `answers`.
local function answering(answers, fn)
  local getchar, input = utils.getchar, utils.input
  local i = 0
  local function nxt()
    i = i + 1
    return answers[i]
  end
  utils.getchar = nxt
  utils.input = nxt
  local ok2, err = pcall(fn)
  utils.getchar, utils.input = getchar, input
  if not ok2 then
    error(err, 0)
  end
end

describe("agenda diary entries (i)", function()
  local diary = dir .. "/diary"
  local function today_line()
    for l, d in pairs(view.state.day_lines) do
      if d == today:days() then
        return l
      end
    end
  end
  local function open_week(opts)
    utils.writefile(path, { "* x" })
    config.setup(vim.tbl_deep_extend("force", { agenda_files = { path } }, opts or {}))
    agenda.open_agenda({ span = "week" })
    vim.api.nvim_win_set_cursor(0, { today_line(), 0 })
  end
  after_each(function()
    pcall(view.quit, true)
    pcall(vim.cmd, "silent! only")
    for _, f in ipairs({ diary, dir .. "/diary.org" }) do
      local b = utils.find_buffer(f)
      if b then
        vim.api.nvim_buf_delete(b, { force = true })
      end
      os.remove(f)
    end
  end)

  local y, m, dd = today.year, today.month, today.day
  local mon = date.MONTH_NAMES[m]
  local dayname = date.DAY_NAMES_LONG[today:weekday()]

  -- Emacs 9.8.10 (diary-insert-*-entry from the agenda; the probe used
  -- Wednesday 2026-09-30, with Monday 09-28 as the mark for blocks):
  --   american  9/30/2026 | Wednesday | * 30 | Sep 30 |
  --             %%(diary-anniversary 9 30 2026) | %%(diary-cyclic 3 9 30 2026)
  --   european  30/9/2026 | 30 *  | 30 Sep | %%(diary-anniversary 30 9 2026)
  --   iso       2026-09-30 | *-*-30 | *-09-30 | %%(diary-anniversary 2026 09 30)
  -- each followed by a space for the entry text.
  it("adds the entries of the calendar's i commands to the diary file", function()
    utils.writefile(diary, { "Sep 1, 2026 existing" })
    open_week({ agenda = { diary_file = diary } })
    local expect = { "Sep 1, 2026 existing" }
    local cases = {
      { "d", string.format("%d/%d/%d ", m, dd, y) },
      { "w", dayname .. " " },
      { "m", string.format("* %d ", dd) },
      { "y", string.format("%s %d ", mon, dd) },
      { "a", string.format("%%%%(diary-anniversary %d %d %d) ", m, dd, y) },
      { "c", string.format("%%%%(diary-cyclic 3 %d %d %d) ", m, dd, y), "3" },
    }
    for _, c in ipairs(cases) do
      vim.api.nvim_set_current_win(view.state.win)
      vim.api.nvim_win_set_cursor(0, { today_line(), 0 })
      answering({ c[1], c[3] }, function()
        view.run_action("diary_entry")
      end)
      expect[#expect + 1] = c[2]
      -- the cursor waits at the end of the new line, in the diary file
      eq(diary, vim.api.nvim_buf_get_name(0))
    end
    eq(expect, vim.api.nvim_buf_get_lines(utils.find_buffer(diary), 0, -1, false))
  end)

  it("follows calendar_date_style; a count makes a non-marking entry", function()
    open_week({ agenda = { diary_file = diary, calendar_date_style = "iso" } })
    answering({ "y" }, function()
      view.run_action("diary_entry")
    end)
    vim.api.nvim_set_current_win(view.state.win)
    vim.api.nvim_win_set_cursor(0, { today_line(), 0 })
    answering({ "d" }, function()
      vim.api.nvim_feedkeys("1i", "mx", false)
    end)
    eq(
      { string.format("*-%02d-%02d ", m, dd), string.format("&%d-%02d-%02d ", y, m, dd) },
      vim.api.nvim_buf_get_lines(utils.find_buffer(diary), 0, -1, false)
    )
    local de = require("org.agenda.diary_entry")
    config.opts.agenda.calendar_date_style = "european"
    eq(string.format("%d *  ", dd), de.diary_line("monthly", today:days()))
    eq(string.format("%d %s ", dd, mon), de.diary_line("yearly", today:days()))
    eq(
      string.format("%%%%(diary-block %d %d %d %d %d %d) ", dd, m, y, dd, m, y),
      de.diary_line("block", today:days(), today:days())
    )
  end)

  -- Emacs 9.8.10, org-agenda-diary-file an Org file (probe on 2026-09-30):
  --   * Anniversaries
  --   %%(org-anniversary 1990  9 30) Birthday %d
  --
  --   * 2026
  --   ** 2026-09 September
  --   *** 2026-09-30 Wednesday
  --   **** New day entry            <- date-tree: the first child
  --   <2026-09-30 Wed>
  --   **** Existing
  --        <2026-09-30 Wed>
  --   **** Last entry               <- date-tree-last
  --   <2026-09-30 Wed>
  --   **** Meeting                  <- insert-diary-extract-time
  --   <2026-09-30 Wed 10:30-11:00>
  --   * Top entry                   <- top-level
  --   <2026-09-30 Wed>
  it("adds entries to an Org diary file", function()
    local file = dir .. "/diary.org"
    local node = string.format("%04d-%02d-%02d %s", y, m, dd, dayname)
    local month = string.format("%04d-%02d %s", y, m, date.MONTH_NAMES_LONG[m])
    utils.writefile(file, {
      "#+TITLE: Diary",
      "* " .. y,
      "** " .. month,
      "*** " .. node,
      "**** Existing",
      "     " .. ts(0),
    })
    open_week({ agenda = { diary_entry_file = file } })
    local function add(answers, opts)
      for k, v in pairs(opts or {}) do
        config.opts.agenda[k] = v
      end
      vim.api.nvim_set_current_win(view.state.win)
      vim.api.nvim_win_set_cursor(0, { today_line(), 0 })
      answering(answers, function()
        view.run_action("diary_entry")
      end)
    end
    add({ "d", "New day entry" })
    add({ "d", "Last entry" }, { insert_diary_strategy = "date-tree-last" })
    add({ "d", "10:30-11:00 Meeting" }, { insert_diary_extract_time = true })
    add({ "d", "Top entry" }, { insert_diary_strategy = "top-level", insert_diary_extract_time = false })
    add({ "a", "1990", "Birthday %d" })
    local stamp = ts(0)
    eq({
      "#+TITLE: Diary",
      "* Anniversaries",
      string.format("%%%%(org-anniversary 1990 %2d %2d) Birthday %%d", m, dd),
      "",
      "* " .. y,
      "** " .. month,
      "*** " .. node,
      "**** New day entry",
      stamp,
      "**** Existing",
      "     " .. stamp,
      "**** Last entry",
      stamp,
      "**** Meeting",
      stamp:sub(1, -2) .. " 10:30-11:00>",
      "* Top entry",
      stamp,
    }, vim.api.nvim_buf_get_lines(utils.find_buffer(file), 0, -1, false))
  end)

  -- Emacs 9.8.10: a block from the mark (Monday) to point (Wednesday) goes
  -- under the first day: "**** Trip" / "<2026-09-28 Mon>--<2026-09-30 Wed>"
  it("a block entry spans the Visual selection", function()
    local file = dir .. "/diary.org"
    utils.writefile(file, { "" })
    open_week({ agenda = { diary_entry_file = file } })
    local l1 = today_line()
    local l2
    for l, d in pairs(view.state.day_lines) do
      if d == today:days() + 2 then
        l2 = l
      end
    end
    vim.api.nvim_win_set_cursor(0, { l1, 0 })
    answering({ "b", "Trip" }, function()
      vim.api.nvim_feedkeys("V" .. (l2 - l1) .. "ji", "mx", false)
    end)
    local lines = vim.api.nvim_buf_get_lines(utils.find_buffer(file), 0, -1, false)
    eq({ "**** Trip", ts(0) .. "--" .. ts(2) }, vim.list_slice(lines, #lines - 1, #lines))
  end)
end)

describe("Visual-mode commands on several entries", function()
  after_each(function()
    pcall(view.quit, true)
  end)

  it("<C-c><C-t> in Visual mode changes every selected entry", function()
    open({ "* TODO A", "  SCHEDULED: " .. ts(0), "* TODO B", "  SCHEDULED: " .. ts(0) })
    local lines = vim.tbl_keys(view.state.line_items)
    table.sort(lines)
    vim.api.nvim_win_set_cursor(0, { lines[1], 0 })
    vim.api.nvim_feedkeys(vim.keycode("V" .. (lines[#lines] - lines[1]) .. "j<C-c><C-t>"), "mx", false)
    local src = vim.api.nvim_buf_get_lines(utils.find_buffer(path), 0, -1, false)
    eq("* DONE A", src[1])
    eq("* DONE B", src[3])
  end)
end)

describe("missing agenda files", function()
  after_each(function()
    pcall(view.quit, true)
  end)

  local function write_fresh(lines)
    local b = utils.find_buffer(path)
    if b then
      vim.api.nvim_buf_delete(b, { force = true })
    end
    utils.writefile(path, lines)
  end

  -- org-check-agenda-file (Emacs 9.8.10): "Non-existent agenda file %s.
  -- [R]emove from list or [A]bort?"; r removes it, anything else aborts.
  it("asks to remove a missing file, or aborts", function()
    write_fresh({ "* TODO A" })
    local missing = dir .. "/missing.org"
    config.setup({ agenda_files = { path, missing } })
    local prompts = {}
    local getchar = utils.getchar
    utils.getchar = function(p)
      prompts[#prompts + 1] = p
      return "a"
    end
    local ok2, err = pcall(function()
      agenda.open({ type = "todo" })
      ok(not (view.state.buf and vim.api.nvim_get_current_buf() == view.state.buf and view.state.view))
      utils.getchar = function(p)
        prompts[#prompts + 1] = p
        return "r"
      end
      agenda.open({ type = "todo" })
    end)
    utils.getchar = getchar
    assert(ok2, err)
    local short = vim.fn.fnamemodify(missing, ":~")
    eq(string.format("Non-existent agenda file %s.  [R]emove from list or [A]bort?", short), prompts[1])
    eq({ path }, config.opts.agenda_files)
    eq({ "  skip:       TODO A" }, item_lines())
    require("org.files").removed = {}
  end)

  it("skip_unavailable_files skips them silently", function()
    write_fresh({ "* TODO A" })
    config.setup({ agenda_files = { path, dir .. "/missing.org" }, agenda = { skip_unavailable_files = true } })
    local getchar = utils.getchar
    local asked = false
    utils.getchar = function()
      asked = true
    end
    agenda.open({ type = "todo" })
    utils.getchar = getchar
    ok(not asked)
    eq({ "  skip:       TODO A" }, item_lines())
  end)
end)

describe("occur in agenda files", function()
  it("also searches text_search_extra_files (org-agenda-multi-occur-extra-files)", function()
    local extra = dir .. "/notes.org"
    utils.writefile(extra, { "* Notes", "needle here" })
    local b = utils.find_buffer(path)
    if b then
      vim.api.nvim_buf_delete(b, { force = true })
    end
    utils.writefile(path, { "* needle in agenda" })
    config.setup({ agenda_files = { path }, agenda = { text_search_extra_files = { extra } } })
    local quiet = utils.notify
    utils.notify = function() end
    local n = agenda.occur("needle")
    utils.notify = quiet
    pcall(vim.cmd, "cclose")
    eq(2, n)
  end)
end)

describe("scheduled_delay_days", function()
  after_each(function()
    pcall(view.quit, true)
  end)

  -- Emacs 9.8.10, org-scheduled-delay-days 2: "Sched. 3x:  TODO Three
  -- ago" and "Sched. 1x:  TODO One ago cookie" (its -1d wins); with -2
  -- only "Three ago" (the negative value overrides the cookie).
  it("hides scheduled entries for that many days", function()
    local lines = {
      "* TODO Today",
      "  SCHEDULED: " .. ts(0),
      "* TODO Three ago",
      "  SCHEDULED: " .. ts(-3),
      "* TODO One ago cookie",
      "  SCHEDULED: " .. ts(-1, "-1d"),
    }
    open(lines, { scheduled_delay_days = 2 })
    eq({ "  skip:       Sched. 3x:  TODO Three ago", "  skip:       Sched. 1x:  TODO One ago cookie" }, item_lines())
    view.quit(true)
    open(lines, { scheduled_delay_days = -2 })
    eq({ "  skip:       Sched. 3x:  TODO Three ago" }, item_lines())
  end)
end)

describe("query register", function()
  after_each(function()
    pcall(view.quit, true)
  end)

  it("keeps the search query built with [ ] { } in register o", function()
    open({ "* TODO Call mom", "* TODO Call work" }, {}, { type = "search", match = "call" })
    vim.fn.setreg("o", "")
    view.manipulate_query("-", false, "work")
    eq(view.state.view.blocks[1].match, vim.fn.getreg("o"))
    eq("+call -work", vim.fn.getreg("o"))
  end)
end)

-- leave the default options to the specs that follow
describe("agenda_options_parity_spec cleanup", function()
  it("restores the default options", function()
    pcall(view.quit, true)
    config.setup({})
    ok(config.opts.agenda.skip_function_global == nil)
  end)
end)
