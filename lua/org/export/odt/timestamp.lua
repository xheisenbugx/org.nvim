---@mod org.export.odt.timestamp ODT timestamps
---
--- Timestamps as date fields and their number:date-style definitions.
---
--- Part of org.export.odt, which loads it.

local ox = require("org.export.ox")
local shared = require("org.export.odt.shared")

local M = require("org.export.odt")

local fmt = string.format

local encode = shared.encode

---------------------------------------------------------------------------
-- Timestamps
---------------------------------------------------------------------------

local function custom_formats()
  local c = require("org.config").opts
  local f = c.time_stamp_custom_formats or { "%m/%d/%y %a", "%m/%d/%y %a %H:%M" }
  local function strip(s)
    return (s:gsub("^[<%[]", ""):gsub("[>%]]$", ""))
  end
  return strip(f[1]), strip(f[2])
end

--- org-odt--format-timestamp
local function format_timestamp(ts, use_end, iso_only)
  local has_time = not ts or ox.timestamp_has_time_p(ts)
  local function ftime(f)
    if ts then
      return ox.format_timestamp(ts, f, use_end)
    end
    return os.date(f)
  end
  local iso = ftime(has_time and "%Y-%m-%dT%H:%M:%S" or "%Y-%m-%d")
  if iso_only then
    return iso
  end
  local style = has_time and "OrgDate2" or "OrgDate1"
  local d1, d2 = custom_formats()
  local date = ftime(has_time and d2 or d1)
  local rep = ""
  if ts and ts.repeater_type then
    rep = (({ ["catch-up"] = "++", restart = ".+", cumulate = "+" })[ts.repeater_type] or "")
      .. (ts.repeater_value and tostring(ts.repeater_value) or "")
      .. (({ hour = "h", day = "d", week = "w", month = "m", year = "y" })[ts.repeater_unit] or ts.repeater_unit or "")
  end
  return fmt(
    '<text:date text:date-value="%s" style:data-style-name="%s" text:fixed="true">%s</text:date>',
    iso,
    style,
    date
  ) .. (rep ~= "" and (" " .. rep) or "")
end

--- org-odt--build-date-styles
function M.build_date_styles(f, style)
  if not (f and style) then
    return ""
  end
  local alist = {
    A = '<number:day-of-week number:style="long"/>',
    B = '<number:month number:textual="true" number:style="long"/>',
    H = '<number:hours number:style="long"/>',
    M = '<number:minutes number:style="long"/>',
    S = '<number:seconds number:style="long"/>',
    V = "<number:week-of-year/>",
    Y = '<number:year number:style="long"/>',
    a = '<number:day-of-week number:style="short"/>',
    b = '<number:month number:textual="true" number:style="short"/>',
    d = '<number:day number:style="long"/>',
    e = '<number:day number:style="short"/>',
    h = '<number:month number:textual="true" number:style="short"/>',
    k = '<number:hours number:style="short"/>',
    m = '<number:month number:style="long"/>',
    p = "<number:am-pm/>",
    y = '<number:year number:style="short"/>',
  }
  local pre = {
    { "%%%d*N", "" },
    { "%%C", "Y" },
    { "%%D", "%%m/%%d/%%y" },
    { "%%G", "Y" },
    { "%%I", "%%H" },
    { "%%R", "%%H:%%M" },
    { "%%T", "%%H:%%M:%%S" },
    { "%%[UW]", "%%V" },
    { "%%Z", "" },
    { "%%c", "%%Y-%%M-%%d %%a %%H:%%M" },
    { "%%g", "%%y" },
    { "%%X", "%%x" },
    { "%%j", "" },
    { "%%l", "%%k" },
    { "%%s", "" },
    { "%%n", "<text:line-break/>" },
    { "%%r", "%%I:%%M:%%S %%p" },
    { "%%t", "<text:tab/>" },
    { "%%[uw]", "" },
    { "%%x", "%%Y-%%M-%%d %%a" },
    { "%%z", "" },
  }
  for _, p in ipairs(pre) do
    -- lint: allow gsub: constant replacement pairs
    f = f:gsub(p[1], p[2])
  end
  local out = {}
  local pos = 1
  while true do
    local a, _, c = f:find("%%(%a)", pos)
    while a and not alist[c] do
      a, _, c = f:find("%%(%a)", a + 2)
    end
    if not a then
      break
    end
    local filler = f:sub(pos, a - 1)
    out[#out + 1] = "\n"
      .. (filler ~= "" and fmt("<number:text>%s</number:text>", encode(filler)) or "")
      .. "\n"
      .. alist[c]
    pos = a + 2
  end
  local filler = f:sub(pos)
  if filler ~= "" then
    out[#out + 1] = fmt("\n<number:text>%s</number:text>", encode(filler))
  end
  return fmt(
    '\n<number:date-style style:name="%s" %s>%s\n</number:date-style>',
    style,
    ' number:automatic-order="true" number:format-source="fixed"',
    table.concat(out)
  )
end

-- Locals the later parts share
shared.custom_formats = custom_formats
shared.format_timestamp = format_timestamp
