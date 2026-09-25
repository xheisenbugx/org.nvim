---@mod org.agenda.holidays Calendar holidays for `%%(org-calendar-holiday)`
---
--- Emacs's `org-calendar-holiday` returns the holidays of `calendar-holidays`
--- falling on the agenda day, joined with "; ". The holiday list is built
--- from `agenda.holidays` (the `holiday-*-holidays` variables), whose items
--- mirror Emacs's holiday forms:
---
---   { "holiday-fixed", MONTH, DAY, NAME }
---   { "holiday-float", MONTH, DAYNAME, N, NAME [, DAY] }
---   { "holiday-easter-etc" [, N, NAME] }   { "holiday-greek-orthodox-easter" [, N, NAME] }
---   { "holiday-advent" [, N, NAME] }        { "holiday-julian", MONTH, DAY, NAME }
---   { "holiday-hebrew", MONTH, DAY, NAME }  { "holiday-islamic", MONTH, DAY, NAME }
---   { "holiday-bahai", MONTH, DAY, NAME }   { "holiday-chinese", MONTH, DAY, NAME }
---   the argument-less calendar holidays (`holiday-hebrew-passover`, ...),
---   `solar-equinoxes-solstices`, `holiday-daylight-saving`,
---   { "if", FLAG, ITEM... } (items used when `holidays[FLAG]` is true), or
---   a Lua function(year) returning `{ { MONTH, DAY, NAME }, ... }`, the
---   counterpart of Emacs's `holiday-sexp`.

local date = require("org.date")

local M = {}

--- Emacs's `calendar-holidays` is the concatenation of these groups.
M.groups = { "general", "local", "other", "christian", "hebrew", "islamic", "bahai", "oriental", "solar" }

local function lazy(name)
  return setmetatable({}, {
    __index = function(t, k)
      local mod = require("org.agenda.holidays." .. name)
      setmetatable(t, { __index = mod })
      return mod[k]
    end,
  })
end

local hebrew, islamic, julian = lazy("hebrew"), lazy("islamic"), lazy("julian")
local solar, chinese, bahai = lazy("solar"), lazy("chinese"), lazy("bahai")

--- 0 = Sunday ... 6 = Saturday (calendar-day-of-week)
local function dow(day)
  return (day + 4) % 7
end

--- calendar-dayname-on-or-before
local function dayname_on_or_before(dayname, day)
  return day - ((dow(day) - dayname) % 7)
end

--- calendar-nth-named-absday
local function nth_named_absday(n, dayname, month, year, day)
  if n > 0 then
    return 7 * (n - 1) + dayname_on_or_before(dayname, 6 + date.days_from_civil(year, month, day or 1))
  end
  day = day or date.days_in_month(year, month)
  return 7 * (n + 1) + dayname_on_or_before(dayname, date.days_from_civil(year, month, day))
end

--- holiday-easter-etc-abs: Gregorian Easter by the Nicaean rule.
function M.easter(y)
  local century = math.floor(y / 100) + 1
  local shifted_epact = (14 + 11 * (y % 19) - math.floor(3 * century / 4) + math.floor((5 + 8 * century) / 25)
    + 30 * century) % 30
  local adjusted_epact = (shifted_epact == 0 or (shifted_epact == 1 and 10 < y % 19)) and shifted_epact + 1
    or shifted_epact
  local paschal_moon = date.days_from_civil(y, 4, 19) - adjusted_epact
  return dayname_on_or_before(0, paschal_moon + 7)
end

--- Advent Sunday (the reference day of holiday-advent).
local function advent(y)
  return dayname_on_or_before(0, date.days_from_civil(y, 12, 3))
end

--- holiday-after: the day N days from REF(y), for the years whose result
--- can land in YEAR.
local function after(year, ref, n, name)
  local out = {}
  for y = year - 1, year + 1 do
    local d = ref(y) + n
    if date.civil_from_days(d) == year then
      out[#out + 1] = { day = d, name = name }
    end
  end
  return out
end

-- holiday-easter-etc with no arguments
local EASTER_ALL = {
  { -63, "Septuagesima Sunday" },
  { -56, "Sexagesima Sunday" },
  { -49, "Shrove Sunday" },
  { -48, "Shrove Monday" },
  { -47, "Shrove Tuesday" },
  { -14, "Passion Sunday" },
  { -7, "Palm Sunday" },
  { -3, "Maundy Thursday" },
  { 35, "Rogation Sunday" },
  { 39, "Ascension Day" },
  { 49, "Pentecost (Whitsunday)" },
  { 50, "Whitmonday" },
  { 56, "Trinity Sunday" },
  { 60, "Corpus Christi" },
}
local EASTER_DEFAULT = { { -46, "Ash Wednesday" }, { -2, "Good Friday" }, { 0, "Easter Sunday" } }

local function concat(lists)
  local out = {}
  for _, l in ipairs(lists) do
    vim.list_extend(out, l)
  end
  return out
end

---@type table<string, fun(year: integer, opts: table, ...): { day: integer, name: string }[]>
local ITEMS = {
  ["holiday-fixed"] = function(year, _, month, day, name)
    return { { day = date.days_from_civil(year, month, day), name = name } }
  end,
  ["holiday-float"] = function(year, _, month, dayname, n, name, day)
    local out = {}
    for y = year - 1, year + 1 do
      local d = nth_named_absday(n, dayname, month, y, day)
      if date.civil_from_days(d) == year then
        out[#out + 1] = { day = d, name = name }
      end
    end
    return out
  end,
  ["holiday-easter-etc"] = function(year, opts, n, name)
    if n then
      return after(year, M.easter, n, name)
    end
    -- (the combined list is not in date order, like Emacs's)
    local specs = opts.christian_all and vim.list_extend(vim.list_slice(EASTER_ALL), EASTER_DEFAULT) or EASTER_DEFAULT
    local list = {}
    for _, e in ipairs(specs) do
      list[#list + 1] = after(year, M.easter, e[1], e[2])
    end
    return concat(list)
  end,
  ["holiday-advent"] = function(year, _, n, name)
    if not n then
      return after(year, advent, 0, "Advent")
    end
    return after(year, advent, n, name)
  end,
  ["holiday-julian"] = function(year, _, month, day, name)
    return julian.holiday_julian(year, month, day, name)
  end,
  ["holiday-greek-orthodox-easter"] = function(year, _, n, name)
    return julian.greek_orthodox_easter(year, n, name)
  end,
  ["holiday-hebrew"] = function(year, _, month, day, name)
    return hebrew.holiday_hebrew(year, month, day, name)
  end,
  ["holiday-hebrew-passover"] = function(year, opts)
    return hebrew.passover(year, { all = opts.hebrew_all })
  end,
  ["holiday-hebrew-rosh-hashanah"] = function(year, opts)
    return hebrew.rosh_hashanah(year, { all = opts.hebrew_all })
  end,
  ["holiday-hebrew-hanukkah"] = function(year, opts)
    return hebrew.hanukkah(year, { all = opts.hebrew_all })
  end,
  ["holiday-hebrew-tisha-b-av"] = function(year, opts)
    return hebrew.tisha_b_av(year, { all = opts.hebrew_all })
  end,
  ["holiday-hebrew-misc"] = function(year, opts)
    return hebrew.misc(year, { all = opts.hebrew_all })
  end,
  ["holiday-islamic"] = function(year, _, month, day, name)
    return islamic.holiday_islamic(year, month, day, name)
  end,
  ["holiday-islamic-new-year"] = function(year, opts)
    return islamic.new_year(year, { all = opts.islamic_all })
  end,
  ["holiday-bahai"] = function(year, _, month, day, name)
    return bahai.holiday_bahai(year, month, day, name)
  end,
  ["holiday-bahai-new-year"] = function(year)
    return bahai.new_year(year)
  end,
  ["holiday-bahai-ridvan"] = function(year, opts)
    return bahai.ridvan(year, { all = opts.bahai_all })
  end,
  ["holiday-bahai-twin-holy-birthdays"] = function(year)
    return bahai.twin_holy_birthdays(year)
  end,
  ["holiday-chinese"] = function(year, _, month, day, name)
    return chinese.holiday_chinese(year, month, day, name)
  end,
  ["holiday-chinese-new-year"] = function(year)
    return chinese.new_year(year)
  end,
  ["holiday-chinese-qingming"] = function(year)
    return chinese.qingming(year)
  end,
  ["holiday-chinese-winter-solstice"] = function(year)
    return chinese.winter_solstice(year)
  end,
  ["solar-equinoxes-solstices"] = function(year)
    return solar.equinoxes_solstices(year)
  end,
  ["holiday-daylight-saving"] = function(year)
    return solar.dst(year)
  end,
}
M.item_names = vim.tbl_keys(ITEMS)

--- Entries of one holiday item for YEAR (dates outside YEAR are dropped).
---@param item table|function
---@param year integer
---@param opts table the `agenda.holidays` options
---@return { day: integer, name: string }[]
local function eval_item(item, year, opts)
  if type(item) == "function" then
    local out = {}
    for _, e in ipairs(item(year) or {}) do
      out[#out + 1] = { day = date.days_from_civil(e.year or year, e[1], e[2]), name = e[3] }
    end
    return out
  end
  if type(item) ~= "table" or type(item[1]) ~= "string" then
    error("invalid holiday item " .. vim.inspect(item), 0)
  end
  local head = item[1]
  if head == "if" then
    if not opts[item[2]] then
      return {}
    end
    local list = {}
    for i = 3, #item do
      list[#list + 1] = eval_item(item[i], year, opts)
    end
    return concat(list)
  end
  local f = ITEMS[head]
  if not f then
    error("unsupported holiday function " .. head, 0)
  end
  local res = f(year, opts, unpack(item, 2, table.maxn(item)))
  local out = {}
  for _, e in ipairs(res) do
    if date.civil_from_days(e.day) == year then
      out[#out + 1] = e
    end
  end
  return out
end

local cache, cache_opts = {}, nil
local warned = {}

--- Holidays of YEAR by day: `{ [day] = { name, ... } }`, in the order
--- calendar-check-holidays lists them (calendar-holiday-list prepends each
--- item's holidays, then stable-sorts by date).
---@param year integer
---@param opts? table defaults to `config.opts.agenda.holidays`
---@return table<integer, string[]>
function M.year(year, opts)
  opts = opts or require("org.config").opts.agenda.holidays or {}
  if opts ~= cache_opts then
    cache, cache_opts = {}, opts
  end
  if cache[year] then
    return cache[year]
  end
  local items = {}
  for _, g in ipairs(M.groups) do
    for _, item in ipairs(opts[g] or {}) do
      items[#items + 1] = item
    end
  end
  local by_day = {}
  for i = #items, 1, -1 do
    local ok, res = pcall(eval_item, items[i], year, opts)
    if ok then
      for _, e in ipairs(res) do
        by_day[e.day] = by_day[e.day] or {}
        table.insert(by_day[e.day], e.name)
      end
    else
      -- Emacs: display-warning "Bad holiday list item"
      local key = vim.inspect(items[i])
      if not warned[key] then
        warned[key] = true
        vim.schedule(function()
          vim.notify(string.format("org: bad holiday list item %s: %s", key, tostring(res)), vim.log.levels.WARN)
        end)
      end
    end
  end
  cache[year] = by_day
  return by_day
end

--- Forget the computed holidays (the agenda calls this on every build, so
--- changes to `agenda.holidays` show up on the next redo).
function M.reset()
  cache, cache_opts = {}, nil
end

--- calendar-check-holidays: the holiday names on DAY.
---@param day integer org.date day number
---@param opts? table
---@return string[]
function M.check(day, opts)
  local y = date.civil_from_days(day)
  return M.year(y, opts)[day] or {}
end

--- org-calendar-holiday: the holidays on DAY joined with "; ", or nil.
---@param day integer
---@return string|nil
function M.org_calendar_holiday(day)
  local hl = M.check(day)
  if #hl == 0 then
    return nil
  end
  return table.concat(hl, "; ")
end

return M
