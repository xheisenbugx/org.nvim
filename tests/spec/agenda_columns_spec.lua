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
