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
    cols.toggle()
    ok(not cols.active())
    eq(nil, overlay_text(l))
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
