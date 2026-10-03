---@mod org.lint.timestamp org-lint: the timestamp object parser

local util = require("org.lint.util")

local format_date = util.format_date

--- Timestamp object at `p` in `s` (`org-element-timestamp-parser`).
---@return table|nil
local function parse_timestamp(s, p, last)
  last = last or #s
  local c = s:sub(p, p)
  if c ~= "<" and c ~= "[" then
    return nil
  end
  local raw_end, date_start, date_end
  if s:sub(p, p + 2) == "<%%" and s:sub(p + 3, p + 3) == "(" then
    -- "<%%(...)...>"
    local close = s:find(")", p + 4, true)
    local gt = s:find(">", p + 3, true)
    local nl = s:find("\n", p, true)
    if not close or not gt or (nl and nl < gt) or close > gt then
      return nil
    end
    -- "(?:([^>\n]+))" greedy: last ")" before ">"
    local lastclose = close
    local x = close
    while true do
      local y = s:find(")", x + 1, true)
      if not y or y > gt then
        break
      end
      lastclose = y
      x = y
    end
    raw_end = gt
    date_start = s:sub(lastclose + 1, gt - 1)
    local ts = { kind = "diary", b = p, sexp = s:sub(p + 3, lastclose) }
    local h, mi, h2, m2 = date_start:match("([012]?%d):([0-5]%d)%-([012]?%d):([0-5]%d)")
    if not h then
      h, mi = date_start:match("([012]?%d):([0-5]%d)")
    end
    ts.hour_start, ts.minute_start = tonumber(h), tonumber(mi)
    ts.hour_end, ts.minute_end = tonumber(h2), tonumber(m2)
    ts.range_type = h2 and "timerange" or nil
    ts.raw_end = raw_end
    local post = s:match("^[ \t]*", raw_end + 1)
    ts.e = raw_end + 1 + #post
    ts.post_blank = #post
    return ts
  end
  if not s:sub(p + 1, p + 10):match("^%d%d%d%d%-%d%d%-%d%d$") then
    return nil
  end
  local q = p + 11
  local qc = s:sub(q, q)
  local close
  if qc == "]" or qc == ">" then
    close = q
  elseif qc == " " then
    local x = q + 1
    while x <= last do
      local ch = s:sub(x, x)
      if ch == "\n" then
        break
      end
      if ch == "]" or ch == ">" then
        close = x
        break
      end
      x = x + 1
    end
  end
  if not close then
    return nil
  end
  date_start = s:sub(p + 1, close - 1)
  raw_end = close
  if s:sub(close + 1, close + 2) == "--" then
    local r = close + 3
    local rc = s:sub(r, r)
    if (rc == "<" or rc == "[") and s:sub(r + 1, r + 10):match("^%d%d%d%d%-%d%d%-%d%d$") then
      local q2 = r + 11
      local c2 = s:sub(q2, q2)
      local close2
      if c2 == "]" or c2 == ">" then
        close2 = q2
      elseif c2 == " " then
        local x = q2 + 1
        while x <= last do
          local ch = s:sub(x, x)
          if ch == "\n" then
            break
          end
          if ch == "]" or ch == ">" then
            close2 = x
            break
          end
          x = x + 1
        end
      end
      if close2 then
        date_end = s:sub(r + 1, close2 - 1)
        raw_end = close2
      end
    end
  end
  local raw = s:sub(p, raw_end)
  local active = c == "<"
  local ts = { b = p, raw = raw, raw_end = raw_end }
  local function parse_time(str)
    local y, mo, d, rest = str:match("(%d%d%d%d)%-(%d%d)%-(%d%d)(.*)$")
    local h, mi
    local r2 = rest:match("^ +[^%]+0-9>\r\n %-]+(.*)$") or rest
    h, mi = r2:match("^ +(%d%d?):(%d%d)")
    return tonumber(y), tonumber(mo), tonumber(d), tonumber(h), tonumber(mi)
  end
  ts.year_start, ts.month_start, ts.day_start, ts.hour_start, ts.minute_start = parse_time(date_start)
  local th, tm = date_start:match("[012]?%d:[0-5]%d%-([012]?%d):([0-5]%d)")
  local time_range = th and { tonumber(th), tonumber(tm) } or nil
  if date_end then
    local y, mo, d, h, mi = parse_time(date_end)
    ts.year_end, ts.month_end, ts.day_end = y, mo, d
    ts.hour_end = h or (time_range and time_range[1]) or ts.hour_start
    ts.minute_end = mi or (time_range and time_range[2]) or ts.minute_start
  else
    ts.year_end, ts.month_end, ts.day_end = ts.year_start, ts.month_start, ts.day_start
    ts.hour_end = (time_range and time_range[1]) or ts.hour_start
    ts.minute_end = (time_range and time_range[2]) or ts.minute_start
  end
  if active then
    ts.kind = (date_end or time_range) and "active-range" or "active"
  else
    ts.kind = (date_end or time_range) and "inactive-range" or "inactive"
  end
  ts.range_type = date_end and "daterange" or (time_range and "timerange" or nil)
  -- repeater: first "+", "++" or ".+" followed by N unit
  local x = 1
  while x <= #raw do
    local sub = raw:sub(x)
    local rt, rv, ru, dv, du
    for _, pat in ipairs({ "^(%+)(%d+)([hdwmy])", "^(%+%+)(%d+)([hdwmy])", "^(%.%+)(%d+)([hdwmy])" }) do
      rt, rv, ru = sub:match(pat)
      if rt then
        break
      end
    end
    if rt then
      ts.repeater_type = rt == "++" and "catch-up" or (rt == ".+" and "restart" or "cumulate")
      ts.repeater_value = tonumber(rv)
      ts.repeater_unit = ru
      dv, du = sub:match("^/(%d+)([hdwmy])", #rt + #rv + #ru + 1)
      ts.repeater_deadline_value, ts.repeater_deadline_unit = tonumber(dv), du
      break
    end
    x = x + 1
  end
  local wfirst, wv, wu = raw:match("(%-?)%-(%d+)([hdwmy])")
  if wv then
    ts.warning_type = wfirst == "-" and "first" or "all"
    ts.warning_value = tonumber(wv)
    ts.warning_unit = wu
  end
  local post = s:match("^[ \t]*", raw_end + 1)
  ts.e = raw_end + 1 + #post
  ts.post_blank = #post
  return ts
end

--- `org-element-timestamp-interpreter`
local function interpret_timestamp(ts)
  if not ts then
    return nil
  end
  local t = ts.kind
  if t ~= "diary" and not (ts.day_start and ts.month_start and ts.year_start) then
    return nil
  end
  local rep = ""
  if ts.repeater_type then
    rep = (ts.repeater_type == "cumulate" and "+" or (ts.repeater_type == "catch-up" and "++" or ".+"))
      .. ts.repeater_value
      .. ts.repeater_unit
    if ts.repeater_deadline_value and ts.repeater_deadline_unit then
      rep = rep .. "/" .. ts.repeater_deadline_value .. ts.repeater_deadline_unit
    end
  end
  local warn = ""
  if ts.warning_type then
    warn = (ts.warning_type == "first" and "--" or "-") .. ts.warning_value .. ts.warning_unit
  end
  local open, close = "<", ">"
  if t == "inactive" or t == "inactive-range" then
    open, close = "[", "]"
  end
  local tail = (rep ~= "" and (" " .. rep) or "") .. (warn ~= "" and (" " .. warn) or "") .. close
  local out = { open }
  if t == "diary" then
    out[#out + 1] = "%%" .. ts.sexp
    if ts.minute_start and ts.hour_start then
      out[#out + 1] = string.format(" %02d:%02d", ts.hour_start, ts.minute_start)
    end
  else
    out[#out + 1] = format_date(ts.year_start, ts.month_start, ts.day_start, ts.hour_start, ts.minute_start)
  end
  local he, me = ts.hour_end, ts.minute_end
  if t == "active" or t == "inactive" then
    if ts.hour_start and he and ts.minute_start and me and (ts.hour_start ~= he or ts.minute_start ~= me) then
      out[#out + 1] = string.format("-%02d:%02d", he, me)
    end
  elseif t == "active-range" or t == "inactive-range" or (t == "diary" and ts.range_type == "timerange") then
    if ts.range_type == "timerange" then
      out[#out + 1] = string.format("-%02d:%02d", he or ts.hour_start, me or ts.minute_start)
    else
      out[#out + 1] = tail .. "--" .. open
      out[#out + 1] = format_date(
        ts.year_end or ts.year_start,
        ts.month_end or ts.month_start,
        ts.day_end or ts.day_start,
        (me and he) and he or nil,
        (me and he) and me or nil
      )
    end
  end
  out[#out + 1] = tail
  return table.concat(out)
end

return {
  parse_timestamp = parse_timestamp,
  interpret_timestamp = interpret_timestamp,
}
