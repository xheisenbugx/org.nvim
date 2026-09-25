-- Agenda buffer commands added for Emacs parity: acting on an item's own
-- timestamp, filters, limits, bulk actions, sticky buffers, windows.
local date = require("org.date")
local config = require("org.config")
local utils = require("org.utils")
local view = require("org.agenda.view")
local agenda = require("org.agenda")

local today = date.today()
local T = today:days()
local function ts(offset, extra)
  local s = today:add(offset, "d"):to_string({ brackets = false })
  return "<" .. s .. (extra and (" " .. extra) or "") .. ">"
end

local dir = vim.fn.tempname()
vim.fn.mkdir(dir, "p")
local path = dir .. "/v.org"

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

local function goto_title(title, nth)
  local lines = vim.tbl_keys(view.state.line_items)
  table.sort(lines)
  local n = 0
  for _, l in ipairs(lines) do
    if view.state.line_items[l].title == title then
      n = n + 1
      if n == (nth or 1) then
        vim.api.nvim_win_set_cursor(0, { l, 0 })
        return l
      end
    end
  end
  error("no line for " .. title)
end

local function shown()
  local out = {}
  for _, it in pairs(view.state.line_items) do
    out[#out + 1] = it.title
  end
  table.sort(out)
  return out
end

local function source_lines()
  return vim.api.nvim_buf_get_lines(utils.find_buffer(path), 0, -1, false)
end

--- Run `fn` with module fields replaced.
local function with_stubs(stubs, fn)
  local saved = {}
  for _, s in ipairs(stubs) do
    saved[#saved + 1] = { s[1], s[2], s[1][s[2]] }
    s[1][s[2]] = s[3]
  end
  local ok, err = pcall(fn)
  for _, s in ipairs(saved) do
    s[1][s[2]] = s[3]
  end
  if not ok then
    error(err, 0)
  end
end

--- A getchar stub returning `keys` one by one.
local function keys(list)
  local i = 0
  return function()
    i = i + 1
    return list[i]
  end
end

describe("agenda item dates", function()
  after_each(function()
    pcall(view.quit, true)
  end)

  it("S-Right shifts the item's own timestamp, not the first one", function()
    open({ "* Multiple stamps", "  " .. ts(0, "09:00") .. " " .. ts(0, "17:00") })
    local lines = vim.tbl_keys(view.state.line_items)
    table.sort(lines)
    -- the second item (17:00)
    local target
    for _, l in ipairs(lines) do
      if view.state.line_items[l].time == 17 * 60 then
        target = l
      end
    end
    vim.api.nvim_win_set_cursor(0, { target, 0 })
    view.actions.date_later()
    eq("  " .. ts(0, "09:00") .. " " .. ts(1, "17:00"), source_lines()[2])
  end)

  it("S-Right on a past date moves it to today; with a count it shifts", function()
    open({ "* Past", "  " .. ts(-3) }, {}, nil)
    view.quit(true)
    agenda.open_agenda({ span = "day", anchor = T - 3 })
    goto_title("Past")
    view.actions.date_later()
    eq("  " .. ts(0), source_lines()[2])
  end)

  it("> changes a plain timestamp and keeps its time", function()
    open({ "* Meet", "  " .. ts(0, "10:00") })
    goto_title("Meet")
    with_stubs({ {
      view,
      "pick_date",
      function()
        return today:add(2, "d")
      end,
    } }, function()
      view.actions.date_prompt()
    end)
    eq("  " .. ts(2, "10:00"), source_lines()[2])
  end)

  it("edits are not saved (save_after_edit = false, like Emacs)", function()
    open({ "* TODO Task", "  SCHEDULED: " .. ts(0) })
    goto_title("Task")
    view.actions.todo()
    ok(vim.bo[utils.find_buffer(path)].modified)
    eq("* TODO Task", utils.readfile(path)[1])
    ok(source_lines()[1]:find("DONE", 1, true))
  end)
end)

describe("agenda filters", function()
  local lines = {
    "#+CATEGORY: Main",
    "* TODO Alpha :work:",
    "  SCHEDULED: " .. ts(0),
    "  :PROPERTIES:",
    "  :Effort: 0:10",
    "  :END:",
    "* TODO Beta :home:",
    "  SCHEDULED: " .. ts(0),
    "  :PROPERTIES:",
    "  :Effort: 2:00",
    "  :END:",
    "* TODO Gamma plot twist",
    "  SCHEDULED: " .. ts(0),
    "* Other",
    "  :PROPERTIES:",
    "  :CATEGORY: Side",
    "  :END:",
    "** TODO Delta :work:",
    "   SCHEDULED: " .. ts(0),
  }
  after_each(function()
    pcall(view.quit, true)
  end)

  it("parses the combined / filter syntax", function()
    open(lines)
    local f = view.parse_filter("+work-home<0:30-/plot/")
    eq({ "+work", "-home" }, f.tag)
    eq({ "+<0:30" }, f.effort)
    eq({ "-plot" }, f.regexp)
    f = view.parse_filter("Side")
    eq({ "+Side" }, f.category)
    -- a single prefix negates everything
    f = view.parse_filter("+work", true)
    eq({ "-work" }, f.tag)
  end)

  it("/ applies the combined filter", function()
    open(lines)
    with_stubs({ {
      utils,
      "input_complete",
      function()
        return "+work<0:30"
      end,
    } }, function()
      view.actions.filter()
    end)
    eq({ "Alpha" }, shown())
    ok(view.filter_desc():find("Tag:+work", 1, true), view.filter_desc())
    view.actions.filter_remove()
    eq(4, #shown())
  end)

  it("\\ filters by tag: key, SPC any tag, - SPC and ? untagged", function()
    open(lines, { tags = { "work(w)", "home(h)" } })
    with_stubs({ { utils, "getchar", keys({ "w" }) } }, function()
      view.actions.filter_tag()
    end)
    eq({ "Alpha", "Delta" }, shown())
    with_stubs({ { utils, "getchar", keys({ " " }) } }, function()
      view.actions.filter_tag()
    end)
    eq({ "Alpha", "Beta", "Delta" }, shown())
    with_stubs({ { utils, "getchar", keys({ "-", " " }) } }, function()
      view.actions.filter_tag()
    end)
    eq({ "Gamma plot twist" }, shown())
    with_stubs({ { utils, "getchar", keys({ "?" }) } }, function()
      view.actions.filter_tag()
    end)
    eq({ "Gamma plot twist" }, shown())
    with_stubs({ { utils, "getchar", keys({ "\\" }) } }, function()
      view.actions.filter_tag()
    end)
    eq(4, #shown())
  end)

  it("< filters by category; with a count it excludes it", function()
    open(lines)
    goto_title("Delta")
    view.actions.filter_category()
    eq({ "Delta" }, shown())
    view.actions.filter_category()
    eq(4, #shown())
    goto_title("Delta")
    vim.cmd("normal 1<")
    eq({ "Alpha", "Beta", "Gamma plot twist" }, shown())
    -- reset v:count for the following tests
    vim.cmd("normal! \27")
  end)

  it("= filters by an Emacs regexp; _ by an Effort_ALL value", function()
    open(lines)
    with_stubs({ {
      utils,
      "input",
      function()
        return "pl\\(o\\|a\\)t"
      end,
    } }, function()
      view.actions.filter_regexp()
    end)
    eq({ "Gamma plot twist" }, shown())
    view.actions.filter_regexp()
    eq(4, #shown())
    -- `<` then the 3rd value of the default list (0:30): efforts <= 0:30
    with_stubs({ { utils, "getchar", keys({ "<", "3" }) } }, function()
      view.actions.filter_effort()
    end)
    eq({ "Alpha" }, shown())
    with_stubs({ { utils, "getchar", keys({ "_" }) } }, function()
      view.actions.filter_effort()
    end)
    eq(4, #shown())
  end)

  it("~ limits the entries; presets filter a custom command", function()
    open(lines)
    with_stubs({ { utils, "getchar", keys({ "e" }) }, {
      utils,
      "input",
      function()
        return "2"
      end,
    } }, function()
      view.actions.limit()
    end)
    eq(2, #shown())
    view.limit(1)
    eq(4, #shown())
    view.quit(true)
    agenda.open({ type = "agenda", span = "day", tag_filter_preset = { "+home" } })
    eq({ "Beta" }, shown())
  end)
end)

describe("agenda bulk actions", function()
  local lines = {
    "* TODO One",
    "  SCHEDULED: " .. ts(0),
    "* TODO Two",
    "  SCHEDULED: " .. ts(0),
    "* TODO Three",
  }
  after_each(function()
    pcall(view.quit, true)
  end)

  it("scatters entries over the next N days", function()
    open(lines)
    view.actions.mark_all()
    local ui = require("org.ui")
    with_stubs({
      {
        ui,
        "menu",
        function()
          return "S"
        end,
      },
      {
        utils,
        "input",
        function()
          return "3"
        end,
      },
    }, function()
      view.actions.bulk_action()
    end)
    local n = 0
    for _, l in ipairs(source_lines()) do
      local d = l:match("SCHEDULED: (<[^>]+>)")
      if d then
        local days = date.parse(d):days() - T
        ok(days >= 1 and days <= 3, l)
        n = n + 1
      end
    end
    eq(2, n)
    eq(0, vim.tbl_count(view.state.marks))
  end)

  it("scatter skips weekend days with a count", function()
    for _ = 1, 20 do
      local d = view.scatter_distance(5, true)
      local wd = today:add(d, "d"):weekday()
      ok(wd <= 5, "weekend day " .. d)
    end
    eq(2, view.scatter_distance(3, false, function()
      return 2
    end))
  end)

  it("s with ++N shifts each entry's own date; p keeps the marks", function()
    open(lines)
    view.actions.mark_all()
    local ui = require("org.ui")
    local answers = { "p", "s" }
    with_stubs({
      {
        ui,
        "menu",
        function()
          return table.remove(answers, 1)
        end,
      },
      {
        utils,
        "input",
        function()
          return "++2d"
        end,
      },
    }, function()
      view.actions.bulk_action()
    end)
    eq("  SCHEDULED: " .. ts(2), source_lines()[2])
    eq("  SCHEDULED: " .. ts(2), source_lines()[4])
    ok(vim.tbl_count(view.state.marks) > 0, "marks persisted")
  end)

  it("runs custom bulk functions and acts on the entry at point without marks", function()
    local seen = {}
    open(lines, {
      agenda = {
        bulk_custom_functions = {
          x = {
            desc = "Collect",
            fn = function(_, item)
              seen[#seen + 1] = item.title
            end,
          },
        },
      },
    })
    goto_title("Two")
    with_stubs({ {
      require("org.ui"),
      "menu",
      function()
        return { custom = "x" }
      end,
    } }, function()
      view.actions.bulk_action()
    end)
    eq({ "Two" }, seen)
  end)
end)

describe("agenda buffers and windows", function()
  local lines = { "* TODO One", "  SCHEDULED: " .. ts(0), "* TODO Two", "  SCHEDULED: " .. ts(0) }
  after_each(function()
    pcall(view.quit, true)
    config.opts.agenda.sticky = false
    pcall(vim.cmd, "silent! only")
  end)

  it("opens in a split (reorganize-frame) and closes it on quit", function()
    vim.cmd("silent! only")
    open(lines)
    eq(2, #vim.api.nvim_tabpage_list_wins(0))
    eq("orgagenda", vim.bo.filetype)
    view.quit(false)
    eq(1, #vim.api.nvim_tabpage_list_wins(0))
  end)

  it("restores the window layout after quit when asked", function()
    vim.cmd("silent! only")
    vim.cmd("vsplit")
    vim.cmd("split")
    eq(3, #vim.api.nvim_tabpage_list_wins(0))
    open(lines, { agenda = { restore_windows_after_quit = true } })
    eq(2, #vim.api.nvim_tabpage_list_wins(0))
    view.quit(false)
    eq(3, #vim.api.nvim_tabpage_list_wins(0))
  end)

  it("sticky agendas keep one buffer per command", function()
    open(lines, { agenda = { sticky = true } })
    local a = view.state.buf
    agenda.open_todo()
    local t = view.state.buf
    ok(a ~= t)
    ok(vim.api.nvim_buf_get_name(t):find("agenda%(t%)"), vim.api.nvim_buf_get_name(t))
    -- reopening the day agenda shows the existing buffer without rebuilding
    local lines_before = vim.api.nvim_buf_line_count(a)
    agenda.open_agenda({ span = "day" })
    eq(a, view.state.buf)
    eq(lines_before, vim.api.nvim_buf_line_count(a))
    view.redo_all()
    view.quit(true)
    vim.api.nvim_buf_delete(t, { force = true })
  end)

  it("drags lines, appends views and selects TODO keywords by number", function()
    open(lines)
    local l1 = goto_title("One")
    view.actions.drag_line_forward()
    eq("Two", view.state.line_items[l1].title)
    eq("One", view.state.line_items[l1 + 1].title)
    with_stubs({ {
      require("org.ui"),
      "menu",
      function()
        return { type = "todo" }
      end,
    } }, function()
      view.actions.append()
    end)
    eq(2, #view.state.view.blocks)
    ok(view.state.view.multi)
    -- (1) is the last keyword of the file's sequence, like Emacs
    eq({ "DONE", "TODO" }, view.todo_names())
  end)

  it("x kills the buffers the agenda loaded", function()
    utils.writefile(path, lines)
    local b = utils.find_buffer(path)
    if b then
      vim.api.nvim_buf_delete(b, { force = true })
    end
    config.setup({ agenda_files = { path }, org_directory = dir })
    agenda.open_agenda({ span = "day" })
    goto_title("One")
    view.resolve_target(view.item_at_cursor())
    ok(utils.find_buffer(path))
    view.exit()
    ok(not utils.find_buffer(path))
  end)
end)

describe("agenda items and sorting helpers", function()
  local items = require("org.agenda.items")
  local render = require("org.agenda.render")
  local parser = require("org.parser")

  it("finds times of day like org-get-time-of-day", function()
    eq(600, items.find_time("Call Bob 10:00").start)
    eq(20 * 60 + 30, items.find_time("at 8:30pm").start)
    eq(12 * 60, items.find_time("12pm lunch").start)
    local r = items.find_time("Meeting 14:00-15:30 here")
    eq({ 840, 930, "14:00-15:30" }, { r.start, r.stop, r.text })
    eq(nil, items.find_time("version 2026-09-25"))
    eq(nil, items.find_time("x10:00"))
  end)

  it("errors on unknown sorting strategies and supports user-defined", function()
    local ok1 = pcall(items.sort, {}, { "no-such-strategy" })
    ok(not ok1)
    config.opts.agenda.cmp_user_defined = function(a, b)
      if a.title < b.title then
        return 1
      elseif a.title > b.title then
        return -1
      end
    end
    local list = { { title = "a", order = 1 }, { title = "c", order = 2 }, { title = "b", order = 3 } }
    items.sort(list, { "user-defined-up" })
    config.opts.agenda.cmp_user_defined = nil
    eq({ "c", "b", "a" }, { list[1].title, list[2].title, list[3].title })
  end)

  it("computes habit urgency like org-habit-get-urgency", function()
    local habits = require("org.agenda.habits")
    local h = { scheduled_days = T - 2, min_days = 1, max_days = 1, has_max = false }
    -- 1000 + 2 days late * 10 + slip (T - (T - 3)) * 100
    eq(1000 + 20 + 300, habits.urgency(h, T))
  end)

  it("evaluates %(lua) prefix elements and category icons", function()
    local saved = vim.deepcopy(config.opts.agenda)
    config.opts.agenda.prefix_format = { todo = "%i %(item.category:upper()) " }
    config.opts.agenda.category_icons = { { "^Wo", "W" } }
    local file = parser.parse({ "#+CATEGORY: Work", "* TODO Task" }, "/tmp/icon.org")
    local it = items.todo({ file })[1]
    local b = render.builder()
    render.add_item(b, it, { width = 40, today = T, kind = "todo" })
    config.opts.agenda = saved
    eq("W WORK TODO Task", b.lines[1])
  end)

  it("splits sexp results on \"; \"", function()
    local file = parser.parse({ "* Dates", "%%(diary-block 1 1 2000 12 31 2100) One; Two" }, "/tmp/sexp.org")
    local by_day = items.agenda({ file }, T, T, { today = T })
    local titles = {}
    for _, it in ipairs(by_day[T]) do
      titles[#titles + 1] = it.title
    end
    eq({ "One", "Two" }, titles)
  end)

  it("stuck projects accept * wildcards and check the project heading", function()
    local file = parser.parse({
      "* Projects",
      "** TODO Active project",
      "** Tagged :someday:",
      "** Plain",
      "*** notes",
    }, "/tmp/stuck.org")
    local function stuck(sp)
      local out = {}
      for _, it in ipairs(items.stuck({ file }, { block = { stuck_projects = sp } })) do
        out[#out + 1] = it.title
      end
      return out
    end
    eq({ "Tagged", "Plain" }, stuck({ match = "+LEVEL=2", todo_keywords = { "TODO" }, tags = {} }))
    eq({ "Plain" }, stuck({ match = "+LEVEL=2", todo_keywords = { "*" }, tags = { "*" } }))
  end)
end)
