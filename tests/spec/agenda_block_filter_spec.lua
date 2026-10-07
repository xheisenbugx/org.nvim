-- The `filter` option of agenda blocks: a per-item predicate, on top of
-- the per-entry `skip` and the runtime filters.
local date = require("org.date")
local config = require("org.config")
local utils = require("org.utils")
local view = require("org.agenda.view")
local agenda = require("org.agenda")

local today = date.today()
local function ts(offset)
  return "<" .. today:add(offset, "d"):to_string({ brackets = false }) .. ">"
end

local dir = utils.realpath((function()
  local d = vim.fn.tempname()
  vim.fn.mkdir(d, "p")
  return d
end)())
local path = dir .. "/filter.org"

local function open(lines, spec)
  utils.writefile(path, lines)
  local b = utils.find_buffer(path)
  if b then
    vim.api.nvim_buf_delete(b, { force = true })
  end
  config.setup({ agenda_files = { path }, org_directory = dir, agenda = { deadline_warning_days = 0 } })
  config.opts.clock.persist = false
  agenda.open(spec)
end

--- The items of the view, in order, as "title kind".
local function items()
  local out = {}
  local nums = vim.tbl_keys(view.state.line_items)
  table.sort(nums)
  for _, l in ipairs(nums) do
    local it = view.state.line_items[l]
    out[#out + 1] = it.title .. " " .. it.ts_type
  end
  return out
end

local LINES = {
  "* TODO Both",
  "SCHEDULED: " .. ts(1) .. " DEADLINE: " .. ts(3),
  "* TODO Deadline only",
  "DEADLINE: " .. ts(2),
  "* TODO Scheduled only",
  "SCHEDULED: " .. ts(4),
}

-- "Effective date": the scheduled day, else the deadline day.
local function effective(item)
  return not (item.type == "deadline" and item.headline and item.headline.scheduled)
end

describe("agenda block filter", function()
  after_each(function()
    pcall(view.quit, true)
  end)

  it("lists both dates of an entry without a filter", function()
    open(LINES, { type = "agenda", span = 7, start_day = "+0d" })
    eq({ "Both scheduled", "Deadline only deadline", "Both deadline", "Scheduled only scheduled" }, items())
  end)

  it("keeps one occurrence of an entry with both dates", function()
    open(LINES, { type = "agenda", span = 7, start_day = "+0d", filter = effective })
    eq({ "Both scheduled", "Deadline only deadline", "Scheduled only scheduled" }, items())
  end)

  it("gets items in the public API shape", function()
    local seen = {}
    open(LINES, {
      type = "agenda",
      span = 7,
      start_day = "+0d",
      filter = function(item)
        seen[#seen + 1] = { item.title, item.type, item.day }
        return true
      end,
    })
    eq({ "Both", "scheduled", today:add(1, "d"):to_date_string() }, seen[1])
    eq(4, #items())
  end)

  it("applies to list blocks and composes with the runtime filters", function()
    open({ "* TODO A :x:", "* TODO B :x:", "* TODO C" }, {
      type = "todo",
      filter = function(item)
        return item.title ~= "B"
      end,
    })
    eq({ "A todo", "C todo" }, items())
    view.state.filters.tag = { "+x" }
    view.refresh()
    eq({ "A todo" }, items())
  end)

  it("keeps the item when the filter errors", function()
    open({ "* TODO A" }, {
      type = "todo",
      filter = function()
        error("boom")
      end,
    })
    eq({ "A todo" }, items())
  end)

  it("is scoped to its block in a composite view", function()
    open({ "* TODO A", "* TODO B" }, {
      blocks = {
        {
          type = "todo",
          filter = function(item)
            return item.title == "A"
          end,
        },
        { type = "todo" },
      },
    })
    eq({ "A todo", "A todo", "B todo" }, items())
  end)
end)
