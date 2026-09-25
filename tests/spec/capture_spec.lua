local capture = require("org.capture")
local config = require("org.config")
local utils = require("org.utils")
local date = require("org.date")

vim.g.org_test = true
local root = vim.fn.getcwd()

local function base_setup(extra)
  config.setup(vim.tbl_deep_extend("force", {
    org_directory = root .. "/tests/fixtures",
    agenda_files = { root .. "/tests/fixtures/*.org" },
  }, extra or {}))
end

local function tmpfile(lines)
  local p = vim.fn.tempname() .. ".org"
  if lines then
    utils.writefile(p, lines)
  end
  return p
end

local function run(fn, ...)
  local res
  local args = { ... }
  local finished = utils.run(function()
    res = { fn(unpack(args)) }
  end)
  ok(finished, "coroutine did not finish")
  return unpack(res or {})
end

local function file_lines(path)
  local b = utils.find_buffer(path)
  if b then
    return vim.api.nvim_buf_get_lines(b, 0, -1, false)
  end
  return utils.readfile(path)
end

describe("capture.expand", function()
  it("expands dates, literals and cursor", function()
    local text = run(capture.expand, "* TODO %?\n  %U %% %<%Y>", {})
    local lines = vim.split(text, "\n")
    eq("* TODO \30", lines[1])
    ok(lines[2]:match("^  %[%d%d%d%d%-%d%d%-%d%d %a%a%a %d%d:%d%d%] %% %d%d%d%d$"), lines[2])
    local t = run(capture.expand, "%t", {})
    eq(date.today():to_string(), t)
  end)

  it("prompts with defaults, options and backrefs", function()
    local orig_input, orig_ic = utils.input, utils.input_complete
    utils.input = function(opts)
      return "Alice"
    end
    utils.input_complete = function(prompt, cands, default)
      eq({ "low", "high" }, cands)
      return "high"
    end
    local text, ctx = run(capture.expand, "%^{Name} %^{Prio|low|high} %\\1 %^{Owner}p", {})
    utils.input, utils.input_complete = orig_input, orig_ic
    eq("Alice high Alice ", text)
    eq({ { "Owner", "Alice" } }, ctx.properties)
  end)

  it("inserts initial content with indentation and annotations", function()
    local text = run(capture.expand, "- %i\n%a %:link", { initial = "one\ntwo", annotation = "[[file:x][x]]", link = "file:x" })
    eq("- one\n  two\n[[file:x][x]] file:x", text)
  end)
end)

describe("capture.store", function()
  before_each(function()
    base_setup()
  end)

  it("creates file+headline entries and relevels", function()
    local p = tmpfile({ "#+TITLE: Inbox", "* Other" })
    local tpl = { target = p, headline = "Tasks", template = "* TODO %?", immediate_finish = true }
    run(capture.capture, tpl)
    local lines = file_lines(p)
    eq({ "#+TITLE: Inbox", "* Other", "* Tasks", "** TODO" }, vim.tbl_map(function(l)
      return (l:gsub("%s+$", ""))
    end, lines))
    run(capture.capture, vim.tbl_extend("force", tpl, { template = "* Second" }))
    lines = file_lines(p)
    eq("** Second", lines[5])
    run(capture.capture, vim.tbl_extend("force", tpl, { template = "* First", prepend = true }))
    lines = file_lines(p)
    eq("** First", lines[4])
  end)

  it("follows an outline path and adds properties", function()
    local p = tmpfile({ "* Work", "** Meetings", "*** Old" })
    run(capture.capture, {
      target = p,
      olp = { "Work", "Meetings" },
      template = "* Standup",
      properties = { Where = "Room 1" },
      immediate_finish = true,
    })
    local lines = file_lines(p)
    eq({ "* Work", "** Meetings", "*** Old", "*** Standup", ":PROPERTIES:", ":Where: Room 1", ":END:" }, lines)
  end)

  it("builds datetrees", function()
    local p = tmpfile({ "* 2027" })
    local d = date.parse("<2026-09-23 Wed>")
    run(capture.capture, { target = p, datetree = true, template = "* Entry", immediate_finish = true }, { date = d })
    local lines = file_lines(p)
    eq({ "* 2026", "** 2026-09 September", "*** 2026-09-23 Wednesday", "**** Entry", "* 2027" }, lines)
    run(capture.capture, { target = p, datetree = true, template = "* Again", immediate_finish = true }, { date = d })
    eq("**** Again", file_lines(p)[5])
    run(capture.capture, { target = p, datetree = { tree_type = "month" }, template = "* M", immediate_finish = true }, { date = d })
    eq("*** M", file_lines(p)[6])
  end)

  it("adds list items and table lines", function()
    local p = tmpfile({ "* Groceries", "  - milk", "  - eggs", "", "* Log", "| a | b |", "|---+---|", "| 1 | 2 |", "", "text" })
    run(capture.capture, { target = p, headline = "Groceries", type = "checkitem", template = "bread", immediate_finish = true })
    local lines = file_lines(p)
    eq("  - [ ] bread", lines[4])
    run(capture.capture, { target = p, headline = "Log", type = "table-line", template = "| 3 | 4 |", immediate_finish = true })
    lines = file_lines(p)
    local found = false
    for _, l in ipairs(lines) do
      if l:match("^| 3") then
        found = true
      end
    end
    ok(found, vim.inspect(lines))
    eq("| 3 | 4 |", lines[10]:gsub("%s+", " "))
  end)

  it("captures under an entry with an ID", function()
    local p = tmpfile({ "* A", "* B", ":PROPERTIES:", ":ID: cap-id-1", ":END:", "** Old", "* C" })
    base_setup({ agenda_files = { p } })
    run(capture.capture, { id = "cap-id-1", template = "* New", immediate_finish = true })
    eq({ "* A", "* B", ":PROPERTIES:", ":ID: cap-id-1", ":END:", "** Old", "** New", "* C" }, file_lines(p))
  end)

  it("captures under the clocked task", function()
    local clock = require("org.clock")
    local p = tmpfile({ "* Task", "* Other" })
    vim.cmd("edit! " .. p)
    clock.clock_in({ bufnr = vim.api.nvim_get_current_buf(), lnum = 1 })
    run(capture.capture, { target = "clock", template = "* Note", immediate_finish = true })
    local lines = file_lines(p)
    eq("** Note", lines[#lines - 1])
    eq("* Other", lines[#lines])
    clock.clock_cancel()
    -- no clock: nothing happens
    local r = run(capture.capture, { target = "clock", template = "* X", immediate_finish = true })
    eq(nil, r)
  end)

  it("evaluates %(lua) and runs hooks", function()
    local text = run(capture.expand, "%(1 + 2) %(string.upper('x')) %(", {})
    eq("3 X %(", text)
    local p = tmpfile({ "* Inbox" })
    local calls = {}
    run(capture.capture, {
      target = p,
      template = "* Hooked",
      immediate_finish = true,
      before_finalize = function(b, l)
        calls[#calls + 1] = "before:" .. vim.api.nvim_buf_get_lines(b, l - 1, l, false)[1]
      end,
      after_finalize = function()
        calls[#calls + 1] = "after"
      end,
    })
    eq({ "before:* Hooked", "after" }, calls)
  end)

  it("goes to the last stored entry and to a template target", function()
    local p = tmpfile({ "* Inbox", "* Other" })
    local tpl = { template = "* X", target = p, headline = "Other", immediate_finish = true }
    base_setup({ capture = { templates = { t = tpl } } })
    run(capture.capture, "t", {})
    vim.cmd("enew!")
    run(capture.goto_last_stored)
    eq(vim.uv.fs_realpath(p), vim.uv.fs_realpath(vim.api.nvim_buf_get_name(0)))
    eq("** X", vim.api.nvim_get_current_line())
    vim.cmd("enew!")
    run(capture.goto_target, "t")
    eq("* Other", vim.api.nvim_get_current_line())
  end)

  it("plain text at top level", function()
    local p = tmpfile({ "#+TITLE: x", "* H" })
    run(capture.capture, { target = p, type = "plain", template = "Just text", immediate_finish = true, prepend = true })
    eq({ "#+TITLE: x", "Just text", "* H" }, file_lines(p))
  end)
end)

describe("capture buffer", function()
  before_each(function()
    base_setup()
  end)

  it("opens a buffer and finalizes into the target", function()
    local p = tmpfile({ "* Inbox" })
    base_setup({
      capture = {
        templates = { t = { description = "Task", template = "* TODO %?", target = p, headline = "Inbox" } },
        window = "split",
      },
    })
    local buf = run(capture.capture, "t")
    ok(capture.sessions[buf])
    eq("org", vim.bo[buf].filetype)
    eq("acwrite", vim.bo[buf].buftype)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "* TODO Write tests", "" })
    run(capture.finalize, buf)
    eq(nil, capture.sessions[buf])
    eq(false, vim.api.nvim_buf_is_valid(buf))
    eq({ "* Inbox", "** TODO Write tests" }, file_lines(p))
  end)

  it("kill discards", function()
    local p = tmpfile({ "* Inbox" })
    base_setup({ capture = { templates = { t = { template = "* X", target = p } }, window = "split" } })
    local buf = run(capture.capture, "t")
    capture.kill(buf)
    eq({ "* Inbox" }, file_lines(p))
  end)

  it("menu items from keys", function()
    base_setup({
      capture = {
        templates = {
          t = { description = "Task", template = "x" },
          w = "Work",
          wm = { description = "Meeting", template = "y" },
        },
      },
    })
    local items = capture.menu_items()
    eq(2, #items)
    local work
    for _, i in ipairs(items) do
      if i.key == "w" then
        work = i
      end
    end
    eq("Work", work.label)
    eq("wm", work.items[1].value)
  end)
end)
