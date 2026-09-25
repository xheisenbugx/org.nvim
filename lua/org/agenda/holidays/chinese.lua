---@mod org.agenda.holidays.chinese Chinese calendar holidays (cal-china.el)
---
--- Ports of `holiday-chinese-new-year', `holiday-chinese',
--- `holiday-chinese-qingming' and `holiday-chinese-winter-solstice' with
--- Emacs's default Chinese calendar settings (`calendar-chinese-time-zone':
--- UT+7:45:40 before 1928, UT+8 since, no daylight saving time), so the results
--- do not depend on the local time zone.
---
--- Each function returns what `calendar-check-holidays' finds for every day of
--- a Gregorian year: the holiday form is evaluated in the one-month window
--- Emacs binds for each month and the entries dated in that month are kept.

local astro = require("org.agenda.holidays.astro")

local M = {}

local floor = math.floor
local EPOCH_ABS = astro.EPOCH_ABS
local ASTRO = astro.ASTRO
local abs_from_greg = astro.absolute_from_gregorian
local greg_from_abs = astro.gregorian_from_absolute

---@alias org.agenda.holidays.ChineseMonth { [1]: number, [2]: integer } month number (x.5 = leap) and absolute start

--- The zone of `calendar-chinese-time-zone' and friends for YEAR.
---@type table<boolean, org.agenda.holidays.Zone>
local ZONES = {
  [true] = {
    tz = 465 + 40.0 / 60.0,
    dst_offset = 0,
    std_name = "PMT",
    dst_name = "CDT",
    starts_time = 0,
    ends_time = 0,
  },
  [false] = { tz = 480, dst_offset = 0, std_name = "CST", dst_name = "CDT", starts_time = 0, ends_time = 0 },
}

local function zone_for(d)
  local _, _, year = greg_from_abs(d)
  return ZONES[year < 1928]
end

--- calendar-chinese-zodiac-sign-on-or-after: absolute date of the first new
--- zodiac sign (solar longitude a multiple of 30 degrees) on or after D.
---@param d integer
---@return integer
local function zodiac_sign_on_or_after(d)
  return floor(astro.date_next_longitude(zone_for(d), d + ASTRO, 30) - ASTRO)
end

--- calendar-chinese-new-moon-on-or-after
---@param d integer
---@return integer
local function new_moon_on_or_after(d)
  return floor(astro.new_moon_on_or_after(zone_for(d), d + ASTRO) - ASTRO)
end

--- calendar-chinese-month-list: starting dates of the months from START to END.
local function month_list(start, finish)
  local list = {}
  while start <= finish do
    local new_moon = new_moon_on_or_after(start)
    if new_moon > finish then
      break
    end
    list[#list + 1] = new_moon
    start = new_moon + 1
  end
  return list
end

--- calendar-chinese-number-months: number the months of LIST (from index I)
--- from START, with half numbers for leap months; appends to RES.
local function number_months(list, i, start, res)
  while list[i] do
    res[#res + 1] = { start, list[i] }
    local len = #list - i + 1
    if 12 - start - len == 0 then
      -- List is too short for a leap month.
      i, start = i + 1, start + 1
    elseif list[i + 2] and list[i + 2] <= zodiac_sign_on_or_after(list[i + 1]) then
      -- Next month is a leap month.
      res[#res + 1] = { start + 0.5, list[i + 1] }
      i, start = i + 2, start + 1
    else
      i, start = i + 1, start + 1
    end
  end
  return res
end

--- calendar-chinese-compute-year: the months from the one after the winter
--- solstice of Y-1 to the one of the winter solstice of Y.
---@param y integer
---@return org.agenda.holidays.ChineseMonth[]
local function compute_year(y)
  local next_solstice = zodiac_sign_on_or_after(abs_from_greg(12, 15, y))
  local list = month_list(1 + zodiac_sign_on_or_after(abs_from_greg(12, 15, y - 1)), next_solstice)
  local next_sign = zodiac_sign_on_or_after(list[1])
  if #list == 12 then
    return number_months(list, 2, 1, { { 12, list[1] } })
  end
  if list[1] > next_sign or next_sign >= list[2] then
    -- First month on list is a leap month, second is not.
    return number_months(list, 3, 1, { { 11.5, list[1] }, { 12, list[2] } })
  end
  if zodiac_sign_on_or_after(list[2]) >= list[3] then
    -- Second month on list is a leap month.
    return number_months(list, 3, 1, { { 12, list[1] }, { 12.5, list[2] } })
  end
  return number_months(list, 2, 1, { { 12, list[1] } })
end

-- calendar-chinese-year-cache: Emacs's precomputed years, used as is.
local PRECOMPUTED = {
  [2018] = {
    12,
    736711,
    1,
    736741,
    2,
    736770,
    3,
    736800,
    4,
    736829,
    5,
    736859,
    6,
    736888,
    7,
    736917,
    8,
    736947,
    9,
    736976,
    10,
    737006,
    11,
    737035,
  },
  [2019] = {
    12,
    737065,
    1,
    737095,
    2,
    737125,
    3,
    737154,
    4,
    737184,
    5,
    737213,
    6,
    737243,
    7,
    737272,
    8,
    737301,
    9,
    737331,
    10,
    737360,
    11,
    737389,
  },
  [2020] = {
    12,
    737419,
    1,
    737449,
    2,
    737478,
    3,
    737508,
    4,
    737538,
    4.5,
    737568,
    5,
    737597,
    6,
    737627,
    7,
    737656,
    8,
    737685,
    9,
    737715,
    10,
    737744,
    11,
    737774,
  },
  [2021] = {
    12,
    737803,
    1,
    737833,
    2,
    737862,
    3,
    737892,
    4,
    737922,
    5,
    737951,
    6,
    737981,
    7,
    738010,
    8,
    738040,
    9,
    738069,
    10,
    738099,
    11,
    738128,
  },
  [2022] = {
    12,
    738158,
    1,
    738187,
    2,
    738217,
    3,
    738246,
    4,
    738276,
    5,
    738305,
    6,
    738335,
    7,
    738365,
    8,
    738394,
    9,
    738424,
    10,
    738453,
    11,
    738483,
  },
  [2023] = {
    12,
    738512,
    1,
    738542,
    2,
    738571,
    2.5,
    738601,
    3,
    738630,
    4,
    738659,
    5,
    738689,
    6,
    738719,
    7,
    738748,
    8,
    738778,
    9,
    738808,
    10,
    738837,
    11,
    738867,
  },
  [2024] = {
    12,
    738896,
    1,
    738926,
    2,
    738955,
    3,
    738985,
    4,
    739014,
    5,
    739043,
    6,
    739073,
    7,
    739102,
    8,
    739132,
    9,
    739162,
    10,
    739191,
    11,
    739221,
  },
  [2025] = {
    12,
    739251,
    1,
    739280,
    2,
    739310,
    3,
    739339,
    4,
    739369,
    5,
    739398,
    6,
    739427,
    6.5,
    739457,
    7,
    739486,
    8,
    739516,
    9,
    739545,
    10,
    739575,
    11,
    739605,
  },
  [2026] = {
    12,
    739635,
    1,
    739664,
    2,
    739694,
    3,
    739723,
    4,
    739753,
    5,
    739782,
    6,
    739811,
    7,
    739841,
    8,
    739870,
    9,
    739899,
    10,
    739929,
    11,
    739959,
  },
  [2027] = {
    12,
    739989,
    1,
    740018,
    2,
    740048,
    3,
    740078,
    4,
    740107,
    5,
    740137,
    6,
    740166,
    7,
    740195,
    8,
    740225,
    9,
    740254,
    10,
    740283,
    11,
    740313,
  },
  [2028] = {
    12,
    740343,
    1,
    740372,
    2,
    740402,
    3,
    740432,
    4,
    740462,
    5,
    740491,
    5.5,
    740521,
    6,
    740550,
    7,
    740579,
    8,
    740609,
    9,
    740638,
    10,
    740667,
    11,
    740697,
  },
  [2029] = {
    12,
    740727,
    1,
    740756,
    2,
    740786,
    3,
    740816,
    4,
    740845,
    5,
    740875,
    6,
    740904,
    7,
    740934,
    8,
    740963,
    9,
    740993,
    10,
    741022,
    11,
    741051,
  },
  [2030] = {
    12,
    741081,
    1,
    741111,
    2,
    741140,
    3,
    741170,
    4,
    741199,
    5,
    741229,
    6,
    741259,
    7,
    741288,
    8,
    741318,
    9,
    741347,
    10,
    741377,
    11,
    741406,
  },
  [2031] = {
    12,
    741436,
    1,
    741465,
    2,
    741494,
    3,
    741524,
    3.5,
    741554,
    4,
    741583,
    5,
    741613,
    6,
    741642,
    7,
    741672,
    8,
    741702,
    9,
    741731,
    10,
    741761,
    11,
    741790,
  },
  [2032] = {
    12,
    741820,
    1,
    741849,
    2,
    741879,
    3,
    741908,
    4,
    741937,
    5,
    741967,
    6,
    741996,
    7,
    742026,
    8,
    742056,
    9,
    742085,
    10,
    742115,
    11,
    742145,
  },
  [2033] = {
    12,
    742174,
    1,
    742204,
    2,
    742233,
    3,
    742263,
    4,
    742292,
    5,
    742321,
    6,
    742351,
    7,
    742380,
    8,
    742410,
    9,
    742439,
    10,
    742469,
    11,
    742499,
  },
  [2034] = {
    11.5,
    742529,
    12,
    742558,
    1,
    742588,
    2,
    742617,
    3,
    742647,
    4,
    742676,
    5,
    742705,
    6,
    742735,
    7,
    742764,
    8,
    742794,
    9,
    742823,
    10,
    742853,
    11,
    742883,
  },
  [2035] = {
    12,
    742912,
    1,
    742942,
    2,
    742972,
    3,
    743001,
    4,
    743031,
    5,
    743060,
    6,
    743089,
    7,
    743119,
    8,
    743148,
    9,
    743177,
    10,
    743207,
    11,
    743237,
  },
  [2036] = {
    12,
    743266,
    1,
    743296,
    2,
    743326,
    3,
    743356,
    4,
    743385,
    5,
    743415,
    6,
    743444,
    6.5,
    743473,
    7,
    743503,
    8,
    743532,
    9,
    743561,
    10,
    743591,
    11,
    743620,
  },
  [2037] = {
    12,
    743650,
    1,
    743680,
    2,
    743710,
    3,
    743740,
    4,
    743769,
    5,
    743799,
    6,
    743828,
    7,
    743857,
    8,
    743887,
    9,
    743916,
    10,
    743945,
    11,
    743975,
  },
  [2038] = {
    12,
    744004,
    1,
    744034,
    2,
    744064,
    3,
    744094,
    4,
    744123,
    5,
    744153,
    6,
    744182,
    7,
    744212,
    8,
    744241,
    9,
    744271,
    10,
    744300,
    11,
    744329,
  },
}

local year_cache = {} ---@type table<integer, org.agenda.holidays.ChineseMonth[]>
for y, flat in pairs(PRECOMPUTED) do
  local months = {}
  for i = 1, #flat, 2 do
    months[#months + 1] = { flat[i], flat[i + 1] }
  end
  year_cache[y] = months
end

--- calendar-chinese-year (cached like `calendar-chinese-year-cache').
---@param y integer
---@return org.agenda.holidays.ChineseMonth[]
local function chinese_year(y)
  local list = year_cache[y]
  if not list then
    list = compute_year(y)
    year_cache[y] = list
  end
  return list
end
M.chinese_year = chinese_year

--- (cadr (assoc MONTH LIST))
local function month_start(list, month, from)
  for i = from or 1, #list do
    if list[i][1] == month then
      return list[i][2]
    end
  end
end

--- calendar-chinese-to-absolute; nil where Emacs signals an error.
---@return integer?
local function to_absolute(cycle, year, month, day)
  local g_year = (cycle - 1) * 60 + (year - 1) + -2636
  -- (append (memq (assoc 1 this-year) this-year) next-year)
  local this = chinese_year(g_year)
  local first
  for i, e in ipairs(this) do
    if e[1] == 1 then
      first = i
      break
    end
  end
  local start = first and month_start(this, month, first)
  if not start then
    start = month_start(chinese_year(g_year + 1), month)
  end
  return start and (day - 1) + start
end

--- calendar-chinese-from-absolute: cycle, year, month, day of absolute DATE.
local function from_absolute(date)
  local _, _, g_year = greg_from_abs(date)
  local c_year = g_year + 2695
  local list = {}
  vim.list_extend(list, chinese_year(g_year - 1))
  vim.list_extend(list, chinese_year(g_year))
  vim.list_extend(list, chinese_year(g_year + 1))
  local i = 1
  while list[i + 1][2] <= date do
    if list[i + 1][1] == 1 then
      c_year = c_year + 1
    end
    i = i + 1
  end
  return floor((c_year - 1) / 60), 1 + (c_year - 1) % 60, list[i][1], 1 + (date - list[i][2])
end

local STEMS = { "Jia", "Yi", "Bing", "Ding", "Wu", "Ji", "Geng", "Xin", "Ren", "Gui" }
local BRANCHES = { "Zi", "Chou", "Yin", "Mao", "Chen", "Si", "Wu", "Wei", "Shen", "You", "Xu", "Hai" }

--- calendar-chinese-sexagesimal-name
---@param n integer
---@return string
function M.sexagesimal_name(n)
  return STEMS[(n - 1) % 10 + 1] .. "-" .. BRANCHES[(n - 1) % 12 + 1]
end

---------------------------------------------------------------------------
-- Holiday forms, evaluated in a calendar window
---------------------------------------------------------------------------

--- Append the entries of HLIST (absolute date, name) visible in window W
--- (holiday-filter-visible-calendar).
local function filter_visible(w, hlist)
  local res = {}
  for _, h in ipairs(hlist) do
    local m, d, y = greg_from_abs(h[1])
    if astro.date_is_visible_p(w, m, d, y) then
      res[#res + 1] = h
    end
  end
  return res
end

--- holiday-chinese-new-year in window W.
local function new_year_in(w)
  local hs = {}
  for _, y in
    ipairs(astro.month_visible_p(w, 1, 1) --[[@as integer[] ]])
  do
    table.insert(hs, 1, { month_start(chinese_year(y), 1), "Chinese New Year (" .. M.sexagesimal_name(y + 57) .. ")" })
  end
  return filter_visible(w, hs)
end

--- holiday-chinese in window W.
local function holiday_chinese_in(w, month, day, name)
  local dates = {}
  if
    not next(astro.month_visible_p(w, 1, 1) --[[@as integer[] ]])
  then
    -- Simple form for when new years are not visible.
    local start = month_start(chinese_year(w.y1), month)
    if not start then
      return {}
    end
    dates[1] = start + (day - 1)
  else
    local start_date, end_date = astro.date_range_abs(w)
    local c1, y1, m1 = from_absolute(start_date)
    local c2, y2, m2 = from_absolute(end_date)
    local cdates = {}
    local function push(c, y)
      table.insert(cdates, 1, { c, y })
    end
    if y1 == y2 then
      push(c1, y1)
    else
      for i = 0, y2 - y1 - 2 do
        push(y1 + i + 1 >= 60 and c1 + 1 or c1, y1 + i + 1)
      end
      if month >= m1 then
        push(c1, y1)
      end
      if month <= m2 then
        push(c2, y2)
      end
    end
    for _, cd in ipairs(cdates) do
      local a = to_absolute(cd[1], cd[2], month, day)
      if not a then
        return {}
      end
      dates[#dates + 1] = a
    end
  end
  local hs = {}
  for i, a in ipairs(dates) do
    hs[i] = { a, name }
  end
  return filter_visible(w, hs)
end

--- holiday-chinese-qingming in window W.
local function qingming_in(w)
  local y = astro.month_visible_p(w, 4)
  if not y then
    return {}
  end
  return { { 15 + zodiac_sign_on_or_after(abs_from_greg(3, 15, y)), "Qingming Festival" } }
end

--- holiday-chinese-winter-solstice in window W.
local function winter_solstice_in(w)
  local y = astro.month_visible_p(w, 12)
  if not y then
    return {}
  end
  return { { zodiac_sign_on_or_after(abs_from_greg(12, 15, y)), "Winter Solstice Festival" } }
end

local results = {} ---@type table<string, org.agenda.holidays.Entry[]>

--- What `calendar-check-holidays' finds with holiday form FN over Gregorian
--- YEAR: FN is run in each month's window and the entries of that month kept.
---@param key string cache key
---@param year integer
---@param fn fun(w: org.agenda.holidays.Window): table[]
---@param months? integer[] the only months whose windows can hold an entry
---@return org.agenda.holidays.Entry[]
local function over_year(key, year, fn, months)
  key = key .. "|" .. year
  local cached = results[key]
  if cached then
    return cached
  end
  local res = {}
  for _, m in ipairs(months or { 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12 }) do
    local w = astro.check_window(m, year)
    for _, h in ipairs(fn(w)) do
      local hm, _, hy = greg_from_abs(h[1])
      if hm == m and hy == year then
        res[#res + 1] = { day = h[1] - EPOCH_ABS, name = h[2] }
      end
    end
  end
  results[key] = res
  return res
end

--- holiday-chinese-new-year: "Chinese New Year (Bing-Wu)" in Gregorian YEAR.
---@param year integer
---@param opts? table unused
---@return org.agenda.holidays.Entry[]
function M.new_year(year, opts) ---@diagnostic disable-line: unused-local
  return over_year("cny", year, new_year_in, { 1, 2 })
end

--- holiday-chinese: the Chinese MONTH/DAY holiday NAME in Gregorian YEAR.
---@param year integer
---@param month number
---@param day integer
---@param name string
---@param opts? table unused
---@return org.agenda.holidays.Entry[]
function M.holiday_chinese(year, month, day, name, opts) ---@diagnostic disable-line: unused-local
  return over_year("c" .. month .. "|" .. day .. "|" .. name, year, function(w)
    return holiday_chinese_in(w, month, day, name)
  end)
end

--- holiday-chinese-qingming: "Qingming Festival" in Gregorian YEAR.
---@param year integer
---@param opts? table unused
---@return org.agenda.holidays.Entry[]
function M.qingming(year, opts) ---@diagnostic disable-line: unused-local
  return over_year("qingming", year, qingming_in, { 4 })
end

--- holiday-chinese-winter-solstice: "Winter Solstice Festival" in Gregorian YEAR.
---@param year integer
---@param opts? table unused
---@return org.agenda.holidays.Entry[]
function M.winter_solstice(year, opts) ---@diagnostic disable-line: unused-local
  return over_year("winter", year, winter_solstice_in, { 12 })
end

return M
