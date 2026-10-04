-- Agenda column view (org-agenda-columns).
local config = require("org.config")
local date = require("org.date")
local utils = require("org.utils")
vim.g.org_test = true

local today = date.today()
local function ts(offset)
  return "<" .. today:add(offset, "d"):to_string({ brackets = false }) .. ">"
end

describe("agenda column view", function()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local path = dir .. "/cols.org"
  local view = require("org.agenda.view")
  local cols = require("org.agenda.columns")
  local lines = {
    "#+COLUMNS: %25ITEM %TODO %Effort{:}",
    "* TODO Write report",
    "  SCHEDULED: " .. ts(0),
    "  :PROPERTIES:",
    "  :Effort: 1:30",
    "  :Effort_ALL: 0:30 1:00 1:30",
    "  :END:",
    "* TODO Call",
    "  SCHEDULED: " .. ts(0),
    "  :PROPERTIES:",
    "  :Effort: 0:15",
    "  :END:",
  }
  local function open()
    utils.writefile(path, lines)
    local b = utils.find_buffer(path)
    if b then
      vim.api.nvim_buf_delete(b, { force = true })
    end
    config.setup({ agenda_files = { path }, org_directory = dir })
    require("org.agenda").open_agenda({ span = "day" })
  end
  local function line_of(title)
    for l, it in pairs(view.state.line_items) do
      if it.title == title then
        return l
      end
    end
  end
  local function overlay_text(l)
    local ns = vim.api.nvim_create_namespace("org.agenda.columns")
    local m = vim.api.nvim_buf_get_extmarks(0, ns, { l - 1, 0 }, { l - 1, -1 }, { details = true })[1]
    return m and m[4].virt_text and m[4].virt_text[1][1]
  end

  it("overlays entries with their columns and sums the day", function()
    open()
    ok(cols.toggle())
    ok(cols.active())
    local l = line_of("Write report")
    eq({ "Write report", "TODO", "1:30" }, cols.cells(l))
    eq("Write report              | TODO | 1:30   |", (overlay_text(l):gsub("%s+$", "")))
    -- the date line shows the sum of the efforts of the day
    local dl
    for ln in pairs(view.state.day_lines) do
      dl = ln
    end
    ok(overlay_text(dl):find("| 1:45   |", 1, true), overlay_text(dl))
    -- the agenda entry under the cursor is unchanged
    vim.api.nvim_win_set_cursor(0, { l, 0 })
    eq("Write report", view.item_at_cursor().title)
    -- the titles are in the winbar (Emacs header-line)
    ok(vim.wo.winbar:find("ITEM                      | TODO | Effort |", 1, true), vim.wo.winbar)
    cols.toggle()
    ok(not cols.active())
    eq(nil, overlay_text(l))
    eq("", vim.wo.winbar)
    view.quit(true)
  end)

  it("switches to the next allowed value and writes it to the entry", function()
    open()
    cols.apply()
    local l = line_of("Write report")
    vim.api.nvim_win_set_cursor(0, { l, 0 })
    -- move to the Effort column (third)
    local text = overlay_text(l)
    local col = vim.fn.strdisplaywidth(text:match("^(.-| .-| )"))
    vim.api.nvim_win_set_cursor(0, { l, col })
    cols.next_allowed(1)
    local src = vim.api.nvim_buf_get_lines(utils.find_buffer(path), 0, -1, false)
    ok(vim.tbl_contains(src, "  :Effort:   0:30"), table.concat(src, "\n"))
    ok(cols.active())
    cols.quit()
    view.quit(true)
  end)

  it("uses overriding_columns_format", function()
    open()
    config.opts.agenda.overriding_columns_format = "%ITEM %Effort"
    cols.apply()
    eq({ "Call", "0:15" }, cols.cells(line_of("Call")))
    config.opts.agenda.overriding_columns_format = nil
    cols.quit()
    view.quit(true)
  end)

  -- org-agenda-columns collects every cell with org-columns--displayed-value
  -- (Emacs 9.8.10): `%13DEADLINE(Due) %34ITEM` on a DEADLINE of
  -- <2026-10-08 Thu 06:30> shows "[2026-10-08.. | " and the title.
  describe("displayed values", function()
    local saved = lines
    local deadline = "<" .. today:to_string({ brackets = false }) .. " 06:30>"
    local inactive = "[" .. today:to_string({ brackets = false }) .. " 06:30]"
    before_each(function()
      lines = {
        "* TODO Reading: Chapter 3",
        "  DEADLINE: " .. deadline,
        "  :PROPERTIES:",
        "  :N: 2.5",
        "  :Name: x",
        "  :END:",
      }
    end)
    after_each(function()
      lines = saved
      config.opts.agenda.overriding_columns_format = nil
      pcall(cols.quit)
      pcall(view.quit, true)
    end)

    it("shows active timestamps as inactive ones, truncated like Emacs", function()
      open()
      config.opts.agenda.overriding_columns_format = "%13DEADLINE(Due) %34ITEM"
      ok(cols.apply())
      local l = line_of("Reading: Chapter 3")
      eq({ inactive, "Reading: Chapter 3" }, cols.cells(l))
      eq({ deadline, "Reading: Chapter 3" }, cols.values(l))
      local text = overlay_text(l)
      eq(
        "["
          .. today:to_string({ brackets = false }):sub(1, 10)
          .. ".. | Reading: Chapter 3"
          .. string.rep(" ", 16)
          .. " |",
        text:sub(1, 13 + 3 + 34 + 2)
      )
      ok(vim.wo.winbar:find("Due           | ITEM", 1, true), vim.wo.winbar)
    end)

    it("applies the column's printf format", function()
      open()
      config.opts.agenda.overriding_columns_format = "%ITEM %N{+;%.2f}"
      ok(cols.apply())
      local l = line_of("Reading: Chapter 3")
      eq({ "Reading: Chapter 3", "2.50" }, cols.cells(l))
      eq("2.5", cols.values(l)[2])
    end)

    it("calls columns_modify_value_for_display_function with the title and real value", function()
      local calls = {}
      open()
      config.opts.columns_modify_value_for_display_function = function(title, value)
        calls[#calls + 1] = { title, value }
        if title == "Due" then
          return "due:" .. value
        elseif title == "ITEM" then
          return value:upper()
        end
      end
      config.opts.agenda.overriding_columns_format = "%DEADLINE(Due) %ITEM %Name"
      ok(cols.apply())
      config.opts.columns_modify_value_for_display_function = nil
      local l = line_of("Reading: Chapter 3")
      eq({ "due:" .. deadline, "READING: CHAPTER 3", "x" }, cols.cells(l))
      ok(#vim.tbl_filter(function(c)
        return c[1] == "Due" and c[2] == deadline
      end, calls) > 0)
      ok(#vim.tbl_filter(function(c)
        return c[1] == "ITEM" and c[2] == "Reading: Chapter 3"
      end, calls) > 0)
    end)

    it("edits and shows the real value, not the displayed one", function()
      open()
      config.opts.agenda.overriding_columns_format = "%ITEM %N{+;%.2f}"
      ok(cols.apply())
      local l = line_of("Reading: Chapter 3")
      local text = overlay_text(l)
      -- the second column, by screen column (the line has multibyte text)
      vim.api.nvim_win_set_cursor(0, { l, 0 })
      vim.cmd("normal! " .. (vim.fn.strdisplaywidth(text:match("^(.-| )")) + 1) .. "|")
      local default
      local orig_input = utils.input
      utils.input = function(o)
        default = o.default
        return "4"
      end
      local msg
      local orig_notify = utils.notify
      utils.notify = function(m)
        msg = m
      end
      local ok1, err = pcall(function()
        cols.show()
        cols.edit()
      end)
      utils.input, utils.notify = orig_input, orig_notify
      ok(ok1, err)
      eq("N: 2.5", msg)
      eq("2.5", default)
      local src = vim.api.nvim_buf_get_lines(utils.find_buffer(path), 0, -1, false)
      ok(vim.tbl_contains(src, "  :N:        4"), table.concat(src, "\n"))
    end)
  end)

  -- the relative due-date example under <prefix>C in doc/org.txt
  describe("the doc's relative due-date example", function()
    local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h")
    local function example()
      local doc = vim.fn.readfile(root .. "/doc/org.txt")
      local code, inside = {}, false
      for _, l in ipairs(doc) do
        if l:match("^    columns_modify_value_for_display_function = function") then
          inside = true
        end
        if inside then
          if l == "<" then
            break
          end
          code[#code + 1] = l
        end
      end
      ok(#code > 0, "example not found in doc/org.txt")
      local src = "return {" .. table.concat(code, "\n") .. "}"
      return assert(loadstring(src))().columns_modify_value_for_display_function
    end
    local function noon(offset)
      local d = today:add(offset, "d")
      return os.time({ year = d.year, month = d.month, day = d.day, hour = 12 })
    end
    local saved = lines

    it("turns a deadline into today, tomorrow, a weekday or a date", function()
      local fn = example()
      local function due(offset, time)
        return fn("Due", "<" .. today:add(offset, "d"):to_string({ brackets = false }) .. (time or "") .. ">")
      end
      eq("today", due(0))
      eq("today", due(0, " 06:30"))
      eq("tomorrow", due(1))
      eq(os.date("%a", noon(3)), due(3))
      eq(os.date("%b ", noon(9)) .. tonumber(os.date("%d", noon(9))), due(9))
      eq(nil, fn("Due", ""))
      eq(nil, fn("ITEM", "Task"))
    end)

    it("shows in the agenda column view", function()
      lines = {
        "* TODO Reading: Chapter 3",
        "  DEADLINE: <" .. today:add(1, "d"):to_string({ brackets = false }) .. " 06:30>",
      }
      open()
      config.opts.columns_modify_value_for_display_function = example()
      config.opts.agenda.overriding_columns_format = "%10DEADLINE(Due) %ITEM"
      local passed, err = pcall(function()
        ok(cols.apply())
        local l = line_of("Reading: Chapter 3")
        eq({ "tomorrow", "Reading: Chapter 3" }, cols.cells(l))
      end)
      lines = saved
      config.opts.columns_modify_value_for_display_function = nil
      config.opts.agenda.overriding_columns_format = nil
      pcall(cols.quit)
      view.quit(true)
      ok(passed, err)
    end)
  end)
end)

-- A custom command's settings set the column view of its agenda, like
-- Emacs's org-overriding-columns-format / org-agenda-view-columns-initially
-- let-bound by the command (org-agenda-finalize copies the format into the
-- buffer-local org-local-columns-format). Emacs 9.8.10 (emacs -Q --batch):
-- command-level and single-block settings show columns with that format,
-- kept after org-agenda-redo and after quitting and re-opening columns;
-- the same options in a block of a composite command are ignored.
describe("agenda column view of a custom command", function()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local path = dir .. "/ag.org"
  local view = require("org.agenda.view")
  local cols = require("org.agenda.columns")
  local agenda = require("org.agenda")
  local FMT = "%40ITEM %DEADLINE"
  local cmd_settings = { overriding_columns_format = FMT, view_columns_initially = true }
  local function setup(extra)
    utils.writefile(path, { "* TODO Reading: Chapter 3", "  DEADLINE: <2026-10-08 Thu 06:30>" })
    local b = utils.find_buffer(path)
    if b then
      vim.api.nvim_buf_delete(b, { force = true })
    end
    config.setup(vim.tbl_deep_extend("force", {
      agenda_files = { path },
      org_directory = dir,
      agenda = {
        custom_commands = {
          c = { description = "command-level", types = { { type = "todo", match = "TODO" } }, settings = cmd_settings },
          s = { description = "single", type = "todo", match = "TODO", settings = cmd_settings },
          e = {
            description = "Emacs names",
            types = { { type = "todo", match = "TODO" } },
            settings = { org_overriding_columns_format = FMT, org_agenda_view_columns_initially = true },
          },
          b = {
            description = "block-level",
            types = {
              { type = "todo", match = "TODO", overriding_columns_format = FMT, view_columns_initially = true },
            },
          },
        },
      },
    }, extra or {}))
  end
  local function line_of(title)
    for l, it in pairs(view.state.line_items) do
      if it.title == title then
        return l
      end
    end
  end
  local function cells()
    return cols.cells(line_of("Reading: Chapter 3"))
  end
  local WANT = { "Reading: Chapter 3", "<2026-10-08 Thu 06:30>" }
  after_each(function()
    cols.quit()
    pcall(view.quit, true)
  end)

  for _, key in ipairs({ "c", "s", "e" }) do
    it("shows the command's format initially (" .. key .. "), after redo and after columns off/on", function()
      setup()
      agenda.open_custom(key)
      ok(cols.active())
      eq(WANT, cells())
      view.redo()
      ok(cols.active())
      eq(WANT, cells())
      cols.toggle()
      ok(not cols.active())
      ok(cols.toggle())
      eq(WANT, cells())
      -- the global config is not touched
      eq(nil, config.opts.agenda.overriding_columns_format)
      eq(false, config.opts.agenda.view_columns_initially)
    end)
  end

  it("does not leak into an agenda opened afterwards", function()
    setup()
    agenda.open_custom("c")
    ok(cols.active())
    cols.quit()
    agenda.open_todo()
    ok(not cols.active())
    ok(cols.toggle())
    -- no COLUMNS anywhere: columns_default_format
    eq(#require("org.columns").parse_format(config.opts.columns_default_format), #cells())
  end)

  it("ignores the column options of a block of a composite command, like Emacs", function()
    setup()
    agenda.open_custom("b")
    ok(not cols.active())
    ok(cols.toggle())
    ok(#cells() ~= 2, vim.inspect(cells()))
  end)

  it("still uses the global options", function()
    setup({ agenda = { overriding_columns_format = "%ITEM %TODO", view_columns_initially = true } })
    agenda.open_todo()
    ok(cols.active())
    eq({ "Reading: Chapter 3", "TODO" }, cells())
    cols.quit()
    -- the command's settings come first (org-overriding-columns-format)
    agenda.open_custom("c")
    eq(WANT, cells())
  end)

  it("takes the start_with_* modes and dim_blocked_tasks from the command's settings", function()
    setup({
      agenda = {
        custom_commands = {
          m = {
            types = { { type = "todo", match = "TODO" } },
            settings = { start_with_entry_text_mode = true, start_with_log_mode = true, dim_blocked_tasks = false },
          },
        },
      },
    })
    agenda.open_custom("m")
    eq(true, view.state.entry_text)
    eq(true, view.state.log_mode)
    eq(false, view.state.dim_blocked)
    agenda.open_todo()
    eq(false, view.state.entry_text)
    eq(false, view.state.log_mode)
    eq(true, view.state.dim_blocked)
  end)

  it(":checkhealth names column options set on a composite block", function()
    setup()
    eq(
      { "b.types[1].overriding_columns_format", "b.types[1].view_columns_initially" },
      require("org.health").ignored_block_options(config.opts.agenda.custom_commands)
    )
  end)
end)
