---@mod org.lint.util org-lint: string, list and date helpers

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

local function trim(s)
  return (s:gsub("^[ \t\r\n]+", ""):gsub("[ \t\r\n]+$", ""))
end

local function is_blank(l)
  return l == nil or l:match("^[ \t]*$") ~= nil
end

--- Lisp `prin1` of a string (`%S` in `format`).
local function lisp_str(s)
  return '"' .. s:gsub('[\\"]', "\\%0") .. '"'
end

local function nw(s)
  return s and s:match("%S") and s or nil
end

local function contains(list, v)
  for _, x in ipairs(list) do
    if x == v then
      return true
    end
  end
  return false
end

--- Index of the character closing the bracket opened at `p` (balanced on
--- `open`/`close` only, like Emacs' pair syntax tables), or nil.
local function balanced(s, p, open, close, last)
  last = last or #s
  local depth = 0
  for i = p, last do
    local c = s:sub(i, i)
    if c == open then
      depth = depth + 1
    elseif c == close then
      depth = depth - 1
      if depth == 0 then
        return i
      end
    end
  end
  return nil
end

local function word_char(c)
  return c ~= "" and (c:match("[%w_]") ~= nil or c:byte() >= 128)
end

local DAYS = { "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" }

local function days_from_civil(y, m, d)
  y = m <= 2 and y - 1 or y
  local era = math.floor(y / 400)
  local yoe = y - era * 400
  local mp = (m + 9) % 12
  local doy = math.floor((153 * mp + 2) / 5) + d - 1
  local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
  return era * 146097 + doe - 719468
end

local function civil_from_days(z)
  z = z + 719468
  local era = math.floor(z / 146097)
  local doe = z - era * 146097
  local yoe = math.floor((doe - math.floor(doe / 1460) + math.floor(doe / 36524) - math.floor(doe / 146096)) / 365)
  local y = yoe + era * 400
  local doy = doe - (365 * yoe + math.floor(yoe / 4) - math.floor(yoe / 100))
  local mp = math.floor((5 * doy + 2) / 153)
  local d = doy - math.floor((153 * mp + 2) / 5) + 1
  local m = mp < 10 and mp + 3 or mp - 9
  return m <= 2 and y + 1 or y, m, d
end

--- `format-time-string` of `org-timestamp-formats` (without brackets) for a
--- date that may be out of range (normalized like `encode-time`).
local function format_date(y, mo, d, h, mi)
  local total = (h or 0) * 60 + (mi or 0)
  y = y + math.floor((mo - 1) / 12)
  mo = (mo - 1) % 12 + 1
  local days = days_from_civil(y, mo, 1) + d - 1 + math.floor(total / 1440)
  total = total % 1440
  local yy, mm, dd = civil_from_days(days)
  local s = string.format("%04d-%02d-%02d %s", yy, mm, dd, DAYS[(days + 4) % 7 + 1])
  if h and mi then
    s = s .. string.format(" %02d:%02d", math.floor(total / 60), total % 60)
  end
  return s
end

return {
  trim = trim,
  is_blank = is_blank,
  lisp_str = lisp_str,
  nw = nw,
  contains = contains,
  balanced = balanced,
  word_char = word_char,
  format_date = format_date,
}
