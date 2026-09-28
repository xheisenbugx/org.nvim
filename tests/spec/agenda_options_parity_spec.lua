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
