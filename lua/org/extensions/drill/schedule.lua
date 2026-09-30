---@mod org.extensions.drill.schedule org-drill's scheduling algorithms
---
--- Pure functions, no buffer access: org-drill's SM-2
--- (`org-drill-determine-next-interval-sm2`), SM-5 (`...-sm5`, the default
--- of `org-drill-spaced-repetition-algorithm`) and Simple8 (`...-simple8`),
--- and `org-drill-hypothetical-next-review-dates`, which picks the interval
--- that is stored and scheduled. Intervals are in days; a failure returns
--- -1 like org-drill.

local sm2 = require("org.extensions.drill.sm2")

local M = {}

M.ALGORITHMS = { sm2 = true, sm5 = true, simple8 = true }

--- Emacs `round` on a float: halfway cases go to the even integer.
---@param x number
---@return integer
function M.round(x)
  local f = math.floor(x)
  local d = x - f
  if d > 0.5 then
    return f + 1
  elseif d < 0.5 then
    return f
  end
  return f % 2 == 0 and f or f + 1
end

--- org-drill-round-float: `x` rounded to `places` decimals.
---@param x number
---@param places integer
---@return number
function M.round_float(x, places)
  local m = 10 ^ places
  return M.round(x * m) / m
end

local function mean(data, quality)
  local total = data.total_repeats or 0
  if data.meanq then
    return (quality + data.meanq * total) / (total + 1)
  end
  return quality
end

---------------------------------------------------------------------------
-- SM-5
---------------------------------------------------------------------------

--- Key of an ease in the optimal factor matrix. org-drill looks the ease
--- up with `assoc` (exact float equality); "%.17g" keeps that exactness
--- and survives a JSON round trip.
---@param ef number
---@return string
function M.ef_key(ef)
  return string.format("%.17g", ef)
end

--- org-drill-get-optimal-factor-sm5: the factor stored for (n, ef), else
--- the initial one (`initial_interval` for n = 1, else ef).
---@param n integer
---@param ef number
---@param matrix table<string, table<string, number>>|nil
---@param initial number org-drill-sm5-initial-interval
function M.optimal_factor(n, ef, matrix, initial)
  local row = matrix and matrix[tostring(n)]
  local of = row and row[M.ef_key(ef)]
  if of then
    return of
  end
  return n == 1 and initial or ef
end

local function copy_matrix(matrix)
  local out = {}
  for n, row in pairs(matrix or {}) do
    out[n] = {}
    for k, v in pairs(row) do
      out[n][k] = v
    end
  end
  return out
end

---@class org.drill.ScheduleOpts
---@field failure_quality? integer (2)
---@field learn_fraction? number org-drill-learn-fraction (0.5)
---@field sm5_initial_interval? number (4.0)

--- org-drill-determine-next-interval-sm5.
---@param data org.drill.ItemData
---@param quality integer
---@param matrix table|nil optimal factors (not changed)
---@param o? org.drill.ScheduleOpts
---@return org.drill.ItemData next, table matrix the new matrix
function M.sm5(data, quality, matrix, o)
  o = o or {}
  assert(quality >= 0 and quality <= 5, "quality must be 0-5")
  local fq = o.failure_quality or 2
  local lf = o.learn_fraction or 0.5
  local initial = o.sm5_initial_interval or 4.0
  local n = data.repeats or 0
  if n == 0 then
    n = 1
  end
  local ef = data.ease or sm2.DEFAULT_EASE
  local meanq = mean(data, quality)
  local next_ef = sm2.modify_ease(ef, quality)
  local of = M.optimal_factor(n, ef, matrix, initial)
  -- org-drill-modify-of
  local new_of = (1 - lf) * of + lf * (of * (0.72 + quality * 0.07))
  local m = copy_matrix(matrix)
  m[tostring(n)] = m[tostring(n)] or {}
  m[tostring(n)][M.ef_key(next_ef)] = M.round_float(new_of, 3)
  local failures = data.failures or 0
  local total = (data.total_repeats or 0) + 1
  if quality <= fq then
    return {
      last_interval = -1,
      repeats = 1,
      ease = ef,
      failures = failures + 1,
      meanq = meanq,
      total_repeats = total,
    },
      m
  end
  local factor = M.optimal_factor(n, next_ef, m, initial)
  local interval = n == 1 and factor or factor * (data.last_interval or 0)
  return {
    last_interval = interval,
    repeats = n + 1,
    ease = next_ef,
    failures = failures,
    meanq = meanq,
    total_repeats = total,
  },
    m
end

---------------------------------------------------------------------------
-- Simple8
---------------------------------------------------------------------------

--- org-drill-simple8-quality->ease
---@param q number
function M.simple8_ease(q)
  return 0.0542 * q ^ 4 - 0.4848 * q ^ 3 + 1.4916 * q ^ 2 - 1.2403 * q + 1.4515
end

--- org-drill-determine-next-interval-simple8 (without the early/late
--- adjustment, off by default in org-drill).
---@param data org.drill.ItemData
---@param quality integer
---@param o? org.drill.ScheduleOpts
---@return org.drill.ItemData
function M.simple8(data, quality, o)
  o = o or {}
  assert(quality >= 0 and quality <= 5, "quality must be 0-5")
  local fq = o.failure_quality or 2
  local lf = o.learn_fraction or 0.5
  local repeats = data.repeats or 0
  local failures = data.failures or 0
  local total = data.total_repeats or 0
  local last = data.last_interval or 0
  local meanq = mean(data, quality)
  local interval
  if quality <= fq then
    -- org-drill neither counts this repetition in the total
    failures = failures + 1
    repeats = 0
    interval = -1
  elseif repeats == 0 or last == 0 then
    interval = 2.4849 * math.exp(-0.057 * failures)
    repeats = repeats + 1
    total = total + 1
  else
    local factor = 1.2 + (M.simple8_ease(meanq) - 1.2) * lf ^ (math.log(repeats) / math.log(2))
    interval = last * factor
    repeats = repeats + 1
    total = total + 1
  end
  return {
    last_interval = interval,
    repeats = repeats,
    ease = M.simple8_ease(meanq),
    failures = failures,
    meanq = meanq,
    total_repeats = total,
  }
end

---------------------------------------------------------------------------
-- Dispatch
---------------------------------------------------------------------------

--- The next item data by `algorithm` ("sm2", "sm5" or "simple8").
---@param algorithm string
---@param data org.drill.ItemData
---@param quality integer
---@param matrix table|nil SM-5 optimal factors
---@param o? org.drill.ScheduleOpts
---@return org.drill.ItemData next, table|nil matrix
function M.next(algorithm, data, quality, matrix, o)
  o = o or {}
  if algorithm == "sm5" then
    return M.sm5(data, quality, matrix, o)
  elseif algorithm == "simple8" then
    return M.simple8(data, quality, o)
  end
  local d = sm2.next(data, quality, o.failure_quality)
  if quality <= (o.failure_quality or 2) then
    d.last_interval = -1
  end
  return d, matrix
end

--- org-drill-hypothetical-next-review-date: days until the next review
--- after an answer of `quality`, 0 for a failure. `weight` is the card's
--- DRILL_CARD_WEIGHT.
---@return number
function M.hypothetical(algorithm, data, quality, matrix, o, weight)
  local d = M.next(algorithm, data, quality, matrix, o)
  local next = d.last_interval
  if not (next > 0) then
    return 0
  end
  if weight and weight > 0 then
    local last = data.last_interval or 0
    return last + math.max(1.0, (next - last) / weight)
  end
  return next
end

--- org-drill-hypothetical-next-review-dates: the days ahead for each
--- quality 0-5, never less than for a lower quality. Index q + 1.
---@return number[]
function M.review_dates(algorithm, data, matrix, o, weight)
  local out = {}
  local prev = 0
  for q = 0, 5 do
    prev = math.max(prev, M.hypothetical(algorithm, data, q, matrix, o, weight))
    out[q + 1] = prev
  end
  return out
end

--- What an answer of `quality` stores (org-drill-reschedule and
--- org-drill-smart-reschedule): the new data, whose `last_interval` is the
--- days ahead from `review_dates`, the whole days until the next review,
--- whether it failed, the new matrix, and whether the card is unscheduled
--- (0 days ahead: org-drill removes SCHEDULED, so it is due at once).
---@return org.drill.ItemData data, integer days, boolean failed, table|nil matrix, boolean unschedule
function M.answer(algorithm, data, quality, matrix, o, weight)
  o = o or {}
  local ahead = M.review_dates(algorithm, data, matrix, o, weight)[quality + 1]
  local d, m = M.next(algorithm, data, quality, matrix, o)
  d.last_interval = ahead
  return d, math.max(0, M.round(ahead)), quality <= (o.failure_quality or 2), m, ahead == 0
end

return M
