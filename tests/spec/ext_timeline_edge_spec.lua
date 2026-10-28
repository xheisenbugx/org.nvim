-- Edge cases of the timeline extension: no tasks, a deadline before its
-- scheduled day, odd and huge efforts, wide titles, tiny windows and bad
-- sources or filters.
local date = require("org.date")
local utils = require("org.utils")

local root = vim.fs.normalize(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h"))

local today = date.today_days()
local function ts(offset, extra)
  return "<"
    .. date.from_days(today + offset):to_string({ brackets = false })
    .. (extra and (" " .. extra) or "")
    .. ">"
end

local dir = vim.fn.tempname()
vim.fn.mkdir(dir, "p")
local path = dir .. "/edge.org"

local function write(lines)
  local b = utils.find_buffer(path)
  if b then
    vim.api.nvim_buf_delete(b, { force = true })
  end
  utils.writefile(path, lines)
  require("org.files").invalidate(path)
end

local function setup(ext)
  require("org").setup({
    org_directory = dir,
    agenda_files = { path },
    extensions = ext ~= nil and { timeline = ext } or nil,
  })
end

local timeline = require("org.extensions.timeline")

local function row(st, title)
  for _, r in ipairs(st.rows) do
    if r.title == title then
      return r
    end
  end
end

describe("timeline edge cases", function()
  local errors, real_error
  before_each(function()
    errors = {}
    real_error = utils.error
    utils.error = function(m)
      errors[#errors + 1] = m
    end
  end)
  after_each(function()
    utils.error = real_error
    timeline.close()
    require("org").setup({
      org_directory = root .. "/tests/fixtures",
      agenda_files = { root .. "/tests/fixtures/*.org" },
    })
  end)

  it("says there's nothing to show for an empty file", function()
    write({})
    setup({})
    local st = timeline.open()
    eq({}, st.rows)
    ok(table.concat(buf_lines(st.buf), "\n"):find("No scheduled tasks or deadlines", 1, true))
    -- keys on an empty chart do nothing harmful
    timeline.jump()
    timeline.pan(1)
    timeline.zoom(1)
    eq({}, errors)
  end)

  it("spans a deadline that comes before the scheduled day", function()
    write({ "* TODO Backwards", "  SCHEDULED: " .. ts(5) .. " DEADLINE: " .. ts(1) })
    setup({})
    local st = timeline.open()
    local r = row(st, "Backwards")
    eq({ today + 1, today + 5 }, { r.start, r.finish })
  end)

  it("treats an unreadable Effort as none", function()
    write({
      "* TODO Odd effort",
      "  DEADLINE: " .. ts(3),
      "  :PROPERTIES:",
      "  :Effort: a while",
      "  :END:",
    })
    setup({})
    local st = timeline.open()
    local r = row(st, "Odd effort")
    eq({ today + 3, today + 3 }, { r.start, r.finish })
  end)

  it("draws a huge effort past the edge without growing the lines", function()
    write({
      "* TODO Long haul",
      "  SCHEDULED: " .. ts(0),
      "  :PROPERTIES:",
      "  :Effort: 8000:00",
      "  :END:",
      "* TODO Short",
      "  SCHEDULED: " .. ts(0),
    })
    setup({})
    local st = timeline.open()
    eq(today + 999, row(st, "Long haul").finish)
    local widths = {}
    for _, l in ipairs(buf_lines(st.buf)) do
      if l:find("Long haul", 1, true) or l:find("Short", 1, true) then
        widths[#widths + 1] = vim.fn.strdisplaywidth(l)
      end
    end
    eq(2, #widths)
    eq(widths[1], widths[2])
  end)

  it("keeps the chart aligned after wide and combining characters in titles", function()
    write({
      "* TODO 日本語のタスクとても長いタイトルです日本語のタスク",
      "  SCHEDULED: " .. ts(0),
      "* TODO Café crème 🍰",
      "  SCHEDULED: " .. ts(0),
      "* TODO Plain",
      "  SCHEDULED: " .. ts(0),
    })
    setup({})
    local st = timeline.open()
    local cols = {}
    for lnum in pairs(st.line_rows) do
      local l = buf_lines(st.buf)[lnum]
      local at = l:find("│", 1, true)
      cols[#cols + 1] = vim.fn.strdisplaywidth(l:sub(1, at - 1))
    end
    eq(3, #cols)
    eq(cols[1], cols[2])
    eq(cols[1], cols[3])
  end)

  it("draws in a window narrower than its labels", function()
    write({ "* TODO Task", "  SCHEDULED: " .. ts(0) })
    setup({ layout = "current" })
    vim.cmd("vsplit")
    vim.cmd("vertical resize 12")
    local st = timeline.open()
    ok(#buf_lines(st.buf) > 0)
    eq({}, errors)
    timeline.close()
    vim.cmd("only")
  end)

  it("pans a long way and comes back to today", function()
    write({ "* TODO Task", "  SCHEDULED: " .. ts(0) })
    setup({})
    local st = timeline.open()
    local start = st.start
    for _ = 1, 200 do
      timeline.pan(1)
    end
    ok(st.start > start + 100)
    timeline.goto_today()
    eq(start, st.start)
    eq({}, errors)
  end)

  it("shows clocked days of a task with no dates only when asked", function()
    write({
      "* TODO Clocked only",
      "  :LOGBOOK:",
      "  CLOCK: [2026-01-05 Mon 10:00]--[2026-01-05 Mon 11:00] =>  1:00",
      "  :END:",
    })
    setup({})
    local st = timeline.open()
    eq(nil, row(st, "Clocked only"))
    timeline.toggle_clocks()
    st = timeline.state
    ok(row(st, "Clocked only"))
  end)

  it("reports a filter it can't read instead of opening", function()
    write({ "* TODO Task", "  SCHEDULED: " .. ts(0) })
    setup({})
    eq(nil, timeline.command("(and (todo"))
    eq(nil, timeline.command("(nonsense-pred 1)"))
    eq({ "missing ) in query", "unknown query predicate: nonsense-pred" }, errors)
    eq(nil, timeline.state)
  end)

  it("refuses the buffer source outside an org buffer", function()
    setup({})
    vim.cmd("enew")
    eq(nil, timeline.open({ source = "buffer" }))
    eq({ "timeline: Not an org buffer" }, errors)
  end)

  it("opens on a file source that doesn't exist with no rows", function()
    setup({})
    local st = timeline.open({ source = dir .. "/missing/*.org" })
    eq({}, st.rows)
    eq({}, errors)
  end)
end)
