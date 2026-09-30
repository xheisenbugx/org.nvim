---@mod org.extensions.drill.sm2 SM-2 scheduling as in org-drill (see also drill.schedule)
---
--- Pure functions, no buffer access. The algorithm is org-drill's
--- `org-drill-determine-next-interval-sm2`: a quality of 0-5 is given to
--- each answer; `failure_quality` (2) or less is a failure, which resets
--- the repetition count but keeps the ease. Otherwise the ease changes by
--- SM-2's formula and the interval grows 1, 6, then last interval * ease.

local M = {}

M.DEFAULT_EASE = 2.5

--- SM-2's new ease factor (org-drill `modify-e-factor`): an ease below 1.3
--- becomes 1.3, else EF + (0.1 - (5 - q) * (0.08 + (5 - q) * 0.02)).
---@param ef number
---@param quality integer 0-5
---@return number
function M.modify_ease(ef, quality)
  if ef < 1.3 then
    return 1.3
  end
  local d = 5 - quality
  return ef + (0.1 - d * (0.08 + d * 0.02))
end

---@class org.drill.ItemData
---@field last_interval number days (0 for a new item)
---@field repeats integer repetitions since the last failure (DRILL_REPEATS_SINCE_FAIL)
---@field failures integer DRILL_FAILURE_COUNT
---@field total_repeats integer DRILL_TOTAL_REPEATS
---@field meanq number|nil DRILL_AVERAGE_QUALITY
---@field ease number|nil DRILL_EASE

--- The item data after an answer of `quality`.
---@param data org.drill.ItemData
---@param quality integer 0-5
---@param failure_quality? integer answers of this quality or less fail (default 2)
---@return org.drill.ItemData next, boolean failed
function M.next(data, quality, failure_quality)
  assert(quality >= 0 and quality <= 5, "quality must be 0-5")
  failure_quality = failure_quality or 2
  local n = data.repeats or 0
  if n == 0 then
    n = 1
  end
  local ef = data.ease or M.DEFAULT_EASE
  local total = data.total_repeats or 0
  local meanq = data.meanq and (quality + data.meanq * total) / (total + 1) or quality
  local failures = data.failures or 0
  if quality <= failure_quality then
    -- the interval is reset, the ease kept
    return {
      last_interval = 0,
      repeats = 1,
      ease = ef,
      failures = failures + 1,
      meanq = meanq,
      total_repeats = total + 1,
    },
      true
  end
  local next_ef = M.modify_ease(ef, quality)
  local interval
  if n <= 1 then
    interval = 1
  elseif n == 2 then
    interval = 6
  else
    interval = (data.last_interval or 0) * next_ef
  end
  return {
    last_interval = interval,
    repeats = n + 1,
    ease = next_ef,
    failures = failures,
    meanq = meanq,
    total_repeats = total + 1,
  },
    false
end

--- Round like org-drill-round-float (Emacs `round`: halfway cases go to
--- the even number).
---@param x number
---@param places integer
function M.round(x, places)
  local m = 10 ^ places
  local v = x * m
  local f = math.floor(v)
  local d = v - f
  if d > 0.5 or (d == 0.5 and f % 2 == 1) then
    f = f + 1
  end
  return f / m
end

--- A float as Emacs `number-to-string` prints it after rounding: `6.0`,
--- `2.36`, `-1.0`.
---@param x number
---@param places integer
---@return string
function M.float_string(x, places)
  local s = string.format("%." .. places .. "f", M.round(x, places))
  s = s:gsub("0+$", "")
  if s:sub(-1) == "." then
    s = s .. "0"
  end
  if s == "-0.0" then
    s = "0.0"
  end
  return s
end

--- Days until the next review: the interval rounded to whole days (Emacs
--- `round`, halfway cases to the even number).
---@param interval number
---@return integer
function M.days_ahead(interval)
  if interval <= 0 then
    return 0
  end
  return math.floor(M.round(interval, 0))
end

return M
