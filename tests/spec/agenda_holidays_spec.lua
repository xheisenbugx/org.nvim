-- %%(org-calendar-holiday) and the agenda.holidays list (calendar-holidays).
-- Expected values come from Emacs 31 in batch: `(calendar-check-holidays DATE)`
-- with `calendar-holidays` bound to the groups under test.
local config = require("org.config")
local date = require("org.date")
local holidays = require("org.agenda.holidays")
local items = require("org.agenda.items")
local parser = require("org.parser")
local sexp = require("org.agenda.sexp")

local DEFAULTS = config.defaults.agenda.holidays

local function only(groups, flags)
  local opts = {}
  for _, g in ipairs(groups) do
    opts[g] = DEFAULTS[g]
  end
  for k, v in pairs(flags or {}) do
    opts[k] = v
  end
  return opts
end

--- Holidays of a year as "YYYY-MM-DD A; B" lines.
local function year_lines(year, opts)
  local out = {}
  for d = date.days_from_civil(year, 1, 1), date.days_from_civil(year, 12, 31) do
    local hl = holidays.check(d, opts)
    if #hl > 0 then
      local y, m, dd = date.civil_from_days(d)
      out[#out + 1] = string.format("%04d-%02d-%02d %s", y, m, dd, table.concat(hl, "; "))
    end
  end
  return out
end

describe("calendar holidays", function()
  local saved
  before_each(function()
    saved = config.opts.agenda.holidays
  end)
  after_each(function()
    config.opts.agenda.holidays = saved
  end)

  it("general and Christian holidays match Emacs", function()
    eq({
      "2026-01-01 New Year's Day",
      "2026-01-19 Martin Luther King Day",
      "2026-02-02 Groundhog Day",
      "2026-02-14 Valentine's Day",
      "2026-02-16 President's Day",
      "2026-02-18 Ash Wednesday",
      "2026-03-17 St. Patrick's Day",
      "2026-04-01 April Fools' Day",
      "2026-04-03 Good Friday",
      "2026-04-05 Easter Sunday",
      "2026-05-10 Mother's Day",
      "2026-05-25 Memorial Day",
      "2026-06-14 Flag Day",
      "2026-06-21 Father's Day",
      "2026-07-04 Independence Day",
      "2026-09-07 Labor Day",
      "2026-10-12 Columbus Day",
      "2026-10-31 Halloween",
      "2026-11-11 Veteran's Day",
      "2026-11-26 Thanksgiving",
      "2026-12-25 Christmas",
    }, year_lines(2026, only({ "general", "christian" })))
  end)

  it("the default holidays of 2026 match Emacs (without the time-zone dependent solar ones)", function()
    local opts = vim.deepcopy(DEFAULTS)
    opts.solar = {}
    eq({
      "2026-01-01 New Year's Day",
      "2026-01-19 Martin Luther King Day",
      "2026-02-02 Groundhog Day",
      "2026-02-14 Valentine's Day",
      "2026-02-16 President's Day",
      "2026-02-17 Chinese New Year (Bing-Wu)",
      "2026-02-18 Ramadan Begins; Ash Wednesday",
      "2026-03-17 St. Patrick's Day",
      "2026-03-21 Bahá’í New Year (Naw-Ruz) 183",
      "2026-04-01 April Fools' Day",
      "2026-04-02 Passover",
      "2026-04-03 Good Friday",
      "2026-04-05 Easter Sunday",
      "2026-04-21 First Day of Ridvan",
      "2026-04-29 Ninth Day of Ridvan",
      "2026-05-02 Twelfth Day of Ridvan",
      "2026-05-10 Mother's Day",
      "2026-05-22 Shavuot",
      "2026-05-24 Declaration of the Báb",
      "2026-05-25 Memorial Day",
      "2026-05-29 Ascension of Bahá’u’lláh",
      "2026-06-14 Flag Day",
      "2026-06-17 Islamic New Year 1448",
      "2026-06-21 Father's Day",
      "2026-07-04 Independence Day",
      "2026-07-10 Martyrdom of the Báb",
      "2026-09-07 Labor Day",
      "2026-09-12 Rosh HaShanah 5787",
      "2026-09-21 Yom Kippur",
      "2026-09-26 Sukkot",
      "2026-10-03 Shemini Atzeret",
      "2026-10-04 Simchat Torah",
      "2026-10-12 Columbus Day",
      "2026-10-31 Halloween",
      "2026-11-10 Birth of the Báb",
      "2026-11-11 Birth of Bahá’u’lláh; Veteran's Day",
      "2026-11-26 Thanksgiving",
      "2026-12-05 Hanukkah",
      "2026-12-25 Christmas",
    }, year_lines(2026, opts))
  end)

  it("Easter by the Nicaean rule, and the extra Christian holidays", function()
    local easters = {}
    for _, y in ipairs({ 1990, 2000, 2008, 2011, 2019, 2024, 2038 }) do
      local _, m, d = date.civil_from_days(holidays.easter(y))
      easters[#easters + 1] = string.format("%d-%02d-%02d", y, m, d)
    end
    eq({ "1990-04-15", "2000-04-23", "2008-03-23", "2011-04-24", "2019-04-21", "2024-03-31", "2038-04-25" }, easters)
    local opts = { christian = DEFAULTS.christian }
    eq({}, holidays.check(date.days_from_civil(2026, 5, 14), opts))
    opts = { christian = DEFAULTS.christian, christian_all = true }
    eq({ "Ascension Day" }, holidays.check(date.days_from_civil(2026, 5, 14), opts))
    eq({ "Advent" }, holidays.check(date.days_from_civil(2026, 11, 29), opts))
    eq({ "Epiphany" }, holidays.check(date.days_from_civil(2026, 1, 6), opts))
  end)

  it("lists same-day holidays in Emacs's order", function()
    -- calendar-holiday-list prepends each item's holidays, then sorts by date
    local opts = {
      general = { { "holiday-fixed", 3, 1, "First" }, { "holiday-fixed", 3, 1, "Second" } },
      other = { { "holiday-fixed", 3, 1, "Third" } },
    }
    eq({ "Third", "Second", "First" }, holidays.check(date.days_from_civil(2026, 3, 1), opts))
  end)

  it("holiday-float handles negative N, a base DAY and month crossings", function()
    local function float(...)
      local opts = { other = { { "holiday-float", ... } } }
      local out = {}
      for d = date.days_from_civil(2026, 1, 1), date.days_from_civil(2027, 12, 31) do
        if #holidays.check(d, opts) > 0 then
          local y, m, dd = date.civil_from_days(d)
          out[#out + 1] = string.format("%d-%02d-%02d", y, m, dd)
        end
      end
      return out
    end
    eq({ "2026-05-25", "2027-05-31" }, float(5, 1, -1, "Memorial Day"))
    -- the first Monday on or after December 30 lands in the next year
    eq({ "2026-01-05", "2027-01-04" }, float(12, 1, 1, "x", 30))
    eq({ "2026-11-27", "2027-11-26" }, float(11, 5, 4, "Black Friday", 1))
    -- the last Sunday on or before January 3 is often in December
    eq({ "2027-01-03" }, float(1, 0, -1, "y", 3))
  end)

  it("Lua functions, flags and local holidays", function()
    local opts = {
      ["local"] = {
        function(year)
          return { { 5, 5, "Batalla de Puebla " .. (year - 1862) } }
        end,
      },
      other = { { "if", "mine", { "holiday-fixed", 9, 16, "Independencia" } } },
    }
    eq({ "Batalla de Puebla 164" }, holidays.check(date.days_from_civil(2026, 5, 5), opts))
    eq({}, holidays.check(date.days_from_civil(2026, 9, 16), opts))
    opts = vim.tbl_extend("force", opts, { mine = true })
    eq({ "Independencia" }, holidays.check(date.days_from_civil(2026, 9, 16), opts))
  end)

  it("warns once about a bad item and keeps the others", function()
    local notify, msgs = vim.notify, {}
    vim.notify = function(m)
      msgs[#msgs + 1] = m
    end
    local opts = { other = { { "holiday-sexp", "x" }, { "holiday-fixed", 1, 1, "New Year" } } }
    eq({ "New Year" }, holidays.check(date.days_from_civil(2026, 1, 1), opts))
    eq({ "New Year" }, holidays.check(date.days_from_civil(2027, 1, 1), opts))
    vim.wait(50, function()
      return false
    end)
    vim.notify = notify
    eq(1, #msgs)
    ok(msgs[1]:find("unsupported holiday function holiday%-sexp"), msgs[1])
  end)

  it("org-calendar-holiday joins the day's holidays like Emacs", function()
    config.opts.agenda.holidays = {
      general = DEFAULTS.general,
      solar = { { "holiday-fixed", 6, 21, "Summer Solstice" } },
    }
    eq("Summer Solstice; Father's Day", sexp.eval("(org-calendar-holiday)", date.days_from_civil(2026, 6, 21)))
    eq(false, sexp.eval("(org-calendar-holiday)", date.days_from_civil(2026, 6, 22)))
  end)

  it("shows holidays in the agenda without a bad sexp warning", function()
    config.opts.agenda.holidays = { general = DEFAULTS.general, christian = DEFAULTS.christian }
    local notify, msgs = vim.notify, {}
    vim.notify = function(m)
      msgs[#msgs + 1] = m
    end
    local lines = { "* Holidays", "  :PROPERTIES:", "  :CATEGORY: Holiday", "  :END:", "%%(org-calendar-holiday)" }
    local file = parser.parse(lines, "/tmp/holidays.org")
    local T = date.days_from_civil(2026, 11, 26)
    local by_day = items.agenda({ file }, T - 1, T + 1, { today = T })
    vim.wait(50, function()
      return false
    end)
    vim.notify = notify
    eq({}, msgs)
    eq(nil, by_day[T - 1] and by_day[T - 1][1])
    eq("Thanksgiving", by_day[T][1].title)
    eq("Holiday", by_day[T][1].category)
  end)
end)
