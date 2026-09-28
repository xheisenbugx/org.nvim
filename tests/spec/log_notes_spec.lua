-- Notes typed in the `*Org Note*` buffer (org-add-log-note): agenda notes,
-- clock-out notes and refile notes, with their headings and placement.
local config = require("org.config")
local utils = require("org.utils")
local date = require("org.date")
vim.g.org_test = true

--- Run `fn` as an action with a (fake) UI so the note buffer opens, type
--- `text` in it and store it with C-c C-c (or cancel with C-c C-k when
--- `text` is nil). Returns the buffer's header lines.
local function with_note(fn, text)
  local list_uis = vim.api.nvim_list_uis
  vim.api.nvim_list_uis = function()
    return { {} }
  end
  local ok_run, err = pcall(utils.run, fn)
  vim.api.nvim_list_uis = list_uis
  ok(ok_run, err)
  local note_buf
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_get_name(b):match("%*Org Note%*$") then
      note_buf = b
    end
  end
  ok(note_buf, "no *Org Note* buffer")
  local header = vim.api.nvim_buf_get_lines(note_buf, 0, 2, false)
  vim.cmd("stopinsert")
  local key = "<C-C><C-C>"
  if text then
    vim.api.nvim_buf_set_lines(note_buf, 2, -1, false, vim.split(text, "\n"))
  else
    key = "<C-C><C-K>"
  end
  local map = vim.api.nvim_buf_call(note_buf, function()
    return vim.fn.maparg(key, "n", false, true)
  end)
  map.callback()
  vim.wait(200, function()
    return not vim.api.nvim_buf_is_valid(note_buf)
  end)
  vim.wait(20)
  return header
end

local function file_buffer(lines)
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local p = dir .. "/notes.org"
  utils.writefile(p, lines)
  vim.cmd("edit! " .. p)
  return vim.api.nvim_get_current_buf(), dir
end

describe("log notes in the *Org Note* buffer", function()
  after_each(function()
    config.setup({})
  end)

  it("takes a clock-out note below the CLOCK line", function()
    local clock = require("org.clock")
    config.setup({ log_note_clock_out = true })
    config.opts.clock.persist = false
    local buf = file_buffer({ "* TODO A" })
    clock.clock_in(nil, { at = date.now():add(-10, "min") })
    local header = with_note(function()
      clock.clock_out()
    end, "stopped here\nsecond line")
    eq({ "# Insert note for stopped clock.", "# Finish with C-c C-c, or cancel with C-c C-k." }, header)
    eq({
      "* TODO A",
      ":LOGBOOK:",
      "CLOCK: " .. buf_lines(buf)[3]:sub(8),
      "- stopped here",
      "  second line",
      ":END:",
    }, buf_lines(buf))
  end)

  it("uses the clock-out note heading and stores nothing when cancelled", function()
    local clock = require("org.clock")
    config.setup({ log_note_clock_out = true, log_note_headings = { ["clock-out"] = "Out at %t" } })
    config.opts.clock.persist = false
    local buf = file_buffer({ "* TODO A" })
    clock.clock_in(nil, { at = date.now():add(-10, "min") })
    with_note(function()
      clock.clock_out()
    end, "why")
    local l = buf_lines(buf)
    ok(l[4]:match("^%- Out at %[.-%] \\\\$"), l[4])
    eq("  why", l[5])
    buf = file_buffer({ "* TODO B" })
    clock.clock_in(nil, { at = date.now():add(-10, "min") })
    with_note(function()
      clock.clock_out()
    end, nil)
    eq(4, #buf_lines(buf))
  end)

  it("names the state change and logs nothing for a cancelled note", function()
    config.setup({ log_done = "note" })
    local buf = file_buffer({ "* TODO A" })
    local header = with_note(function()
      require("org.todo").change_state(nil, "DONE")
    end, nil)
    eq("# Insert note for closed todo item.", header[1])
    eq("* DONE A", buf_lines(buf)[1])
    ok(buf_lines(buf)[2]:match("^CLOSED: "), buf_lines(buf)[2])
    eq(2, #buf_lines(buf))
    config.setup({ todo_keywords = { "TODO(t@) | DONE(d)" } })
    buf = file_buffer({ "* DONE B" })
    header = with_note(function()
      require("org.todo").change_state(nil, "TODO")
    end, "again")
    eq('# Insert note for state change from "DONE" to "TODO".', header[1])
    ok(buf_lines(buf)[2]:match('^%- State "TODO"%s+from "DONE"%s+%[.-%] \\\\$'), buf_lines(buf)[2])
    eq("  again", buf_lines(buf)[3])
  end)

  it("takes a refile note under the moved entry", function()
    local _, dir = file_buffer({ "* Target" })
    vim.cmd("write")
    utils.writefile(dir .. "/a.org", { "* Move me" })
    config.setup({
      org_directory = dir,
      agenda_files = { dir },
      refile = { targets = { { files = "agenda", level = 1 } }, log = "note" },
    })
    vim.cmd("edit! " .. dir .. "/a.org")
    local refile = require("org.refile")
    local dest
    for _, t in ipairs(refile.targets()) do
      if t.label:match("Target") then
        dest = t
      end
    end
    local header = with_note(function()
      refile.refile({ lnum = 1 }, { dest = dest })
    end, "moved it")
    eq("# Insert note for refiling.", header[1])
    local b = vim.api.nvim_buf_get_lines(utils.find_buffer(dir .. "/notes.org"), 0, -1, false)
    eq("** Move me", b[2])
    ok(b[3]:match("^%- Refiled on %[.-%] \\\\$"), b[3])
    eq("  moved it", b[4])
  end)

  it("takes an agenda note (z) in the note buffer", function()
    local view = require("org.agenda.view")
    local _, dir = file_buffer({ "* TODO Task", "  SCHEDULED: <" .. date.today():to_string({ brackets = false }) .. ">" })
    vim.cmd("write")
    local path = vim.api.nvim_buf_get_name(0)
    config.setup({ agenda_files = { path }, org_directory = dir })
    config.opts.clock.persist = false
    require("org.agenda").open_agenda({ span = "day" })
    for l, it in pairs(view.state.line_items) do
      if it.title == "Task" then
        vim.api.nvim_win_set_cursor(0, { l, 0 })
      end
    end
    local header = with_note(view.actions.add_note, "an agenda note")
    eq("# Insert note for this entry.", header[1])
    local b = vim.api.nvim_buf_get_lines(utils.find_buffer(path), 0, -1, false)
    ok(b[3]:match("^%- Note taken on %[.-%] \\\\$"), b[3])
    eq("  an agenda note", b[4])
    pcall(vim.cmd, "only")
  end)
end)
