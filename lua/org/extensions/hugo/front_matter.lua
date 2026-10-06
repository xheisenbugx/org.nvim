---@mod org.extensions.hugo.front_matter Hugo front matter (TOML and YAML)
---
--- The data of a post's front matter is an ordered list of `{ key, value }`
--- pairs, as in ox-hugo (`org-hugo--get-front-matter`). Values are strings,
--- numbers, booleans, arrays (`{ kind = "array", ... }`) and maps
--- (`{ kind = "map", entries = { { key, value }, ... } }`); an array of maps
--- (`resources`) is `{ kind = "array", maps = true, ... }`. TOML is written
--- like tomelr (what ox-hugo uses), YAML like ox-hugo's YAML generator.
--- This file also holds the Lisp-ish readers for property values
--- (`:key value ...` lists, `'((a . 1))` alists) and `slug`.

local M = {}

---------------------------------------------------------------------------
-- Readers
---------------------------------------------------------------------------

--- A float read from Lisp text keeps its spelling (`{ float = "12.3" }`).
---@param s string
---@return table
local function float(s)
  return { float = s }
end

local function is_float(v)
  return type(v) == "table" and v.float ~= nil
end
M.is_float = is_float

--- A Lisp atom: an integer, a float, `t` / `nil` or a symbol (a string).
local function atom(tok)
  if tok == "t" then
    return true
  elseif tok == "nil" then
    return nil
  end
  if tok:match("^[+-]?%d+$") then
    local n = tonumber(tok)
    if n and math.abs(n) < 2 ^ 53 then
      return n
    end
    return tok
  end
  if tok:match("^[+-]?%d*%.%d+$") or tok:match("^[+-]?%d+%.?%d*[eE][+-]?%d+$") then
    return float(tok)
  end
  return tok
end

--- Read one Lisp datum of `s` from `pos` (no evaluation): strings, atoms,
--- lists (`{ kind = "list", ... }`, with `tail` for a dotted pair) and
--- quotes. Returns the value and the next position.
---@param s string
---@param pos integer
---@return any value, integer next
local function read(s, pos)
  pos = s:find("[^%s]", pos) or (#s + 1)
  local c = s:sub(pos, pos)
  if c == "" then
    return nil, pos
  elseif c == "'" or c == "`" then
    return read(s, pos + 1)
  elseif c == '"' then
    local out = {}
    local k = pos + 1
    while k <= #s do
      local ch = s:sub(k, k)
      if ch == "\\" then
        local nx = s:sub(k + 1, k + 1)
        out[#out + 1] = nx == "n" and "\n" or nx
        k = k + 2
      elseif ch == '"' then
        return table.concat(out), k + 1
      else
        out[#out + 1] = ch
        k = k + 1
      end
    end
    return table.concat(out), k
  elseif c == "(" or c == "[" then
    local close = c == "(" and ")" or "]"
    local list = { kind = "list" }
    local k = pos + 1
    while true do
      k = s:find("[^%s]", k) or (#s + 1)
      local ch = s:sub(k, k)
      if ch == close or ch == "" then
        return list, k + 1
      end
      if ch == "." and s:sub(k + 1, k + 1):match("[%s(]") then
        local v, nk = read(s, k + 1)
        if type(v) == "table" and v.kind == "list" then
          -- (a . (b c)) is (a b c)
          for _, x in ipairs(v) do
            list[#list + 1] = x
          end
          list.tail = v.tail
        else
          list.tail = v
          list.dotted = true
        end
        k = nk
      else
        local v, nk = read(s, k)
        -- a nil element keeps its place (`(nothing)` is a key without value)
        list[#list + 1] = v == nil and vim.NIL or v
        k = nk
      end
    end
  end
  local tok = s:match("^[^%s()%[%]\"']+", pos) or c
  return atom(tok), pos + #tok
end
M.read = read

--- Value of a header argument (org-babel-read without evaluation): Lisp
--- data for `(`, `'`, `` ` `` and `[`, a string for a quoted string, a
--- number, else the trimmed text.
---@param s string
---@return any
function M.read_value(s)
  s = vim.trim(s)
  if s == "" then
    return nil
  end
  local c = s:sub(1, 1)
  if c == "(" or c == "'" or c == "`" or c == "[" or (c == '"' and s:sub(-1) == '"' and #s > 1) then
    local v = read(s, 1)
    return v
  end
  if s:match("^[+-]?%d+$") then
    return tonumber(s)
  elseif s:match("^[+-]?%d*%.%d+$") then
    return float(s)
  end
  return s
end

--- Split `:k1 v1 :k2 "two words" :k3 '(a b)` into `{ { "k1", v1 }, ... }`
--- (org-hugo--parse-property-arguments): a `:` after blanks starts a key,
--- unless inside quotes or parentheses. A first item without a colon
--- (`"auto :tags 3"`) has its word as key and no value.
---@param str string|nil
---@return { [1]: string, [2]: any }[]
function M.parse_arguments(str)
  local out = {}
  if type(str) ~= "string" or not str:match("%S") then
    return out
  end
  local parts, cur = {}, {}
  local depth, in_str = 0, false
  local i = 1
  local s = " " .. str
  while i <= #s do
    local ch = s:sub(i, i)
    if in_str then
      cur[#cur + 1] = ch
      if ch == "\\" then
        cur[#cur + 1] = s:sub(i + 1, i + 1)
        i = i + 1
      elseif ch == '"' then
        in_str = false
      end
    elseif ch == '"' then
      in_str = true
      cur[#cur + 1] = ch
    elseif ch == "(" then
      depth = depth + 1
      cur[#cur + 1] = ch
    elseif ch == ")" then
      depth = math.max(0, depth - 1)
      cur[#cur + 1] = ch
    elseif ch:match("%s") and depth == 0 and s:sub(i + 1):match("^%s*:") then
      parts[#parts + 1] = table.concat(cur)
      cur = {}
      i = i + #s:sub(i + 1):match("^%s*:")
    else
      cur[#cur + 1] = ch
    end
    i = i + 1
  end
  parts[#parts + 1] = table.concat(cur)
  for n, p in ipairs(parts) do
    p = vim.trim(p)
    if p ~= "" then
      local key, rest = p:match("^(%S+)%s+(.-)$")
      if n == 1 and not str:match("^%s*:") then
        -- text before the first :key
        out[#out + 1] = { key or p, key and M.read_value(rest) or nil }
      elseif key then
        out[#out + 1] = { key, M.read_value(rest) }
      else
        out[#out + 1] = { p, nil }
      end
    end
  end
  return out
end

--- Get a key of a parsed argument list.
---@param args table
---@param key string
---@return any value, boolean found
function M.arg(args, key)
  for _, kv in ipairs(args) do
    if kv[1] == key then
      return kv[2], true
    end
  end
  return nil, false
end

--- Split a newline-joined keyword value into words, keeping quoted words
--- whole (org-hugo--delim-str-to-list).
---@param str string|nil
---@return string[]|nil
function M.delim_list(str)
  if type(str) ~= "string" or not str:match("%S") then
    return nil
  end
  local out = {}
  for line in (vim.trim(str) .. "\n"):gmatch("(.-)\n") do
    local pos = 1
    while true do
      pos = line:find("%S", pos)
      if not pos then
        break
      end
      if line:sub(pos, pos) == '"' then
        local v, nxt = read(line, pos)
        out[#out + 1] = tostring(v)
        pos = nxt
      else
        local w = line:match("^%S+", pos)
        out[#out + 1] = w
        pos = pos + #w
      end
    end
  end
  return #out > 0 and out or nil
end

---------------------------------------------------------------------------
-- Slugs
---------------------------------------------------------------------------

--- `str` as a slug (org-hugo-slug): lower case, HTML tags and Markdown
--- link targets removed, `&` `.` `+` spelled out, parentheses turned into
--- double hyphens, everything else that is not a letter or a digit into
--- single hyphens. Non-ASCII letters are kept.
---@param str string
---@param allow_double_hyphens? boolean
---@return string
function M.slug(str, allow_double_hyphens)
  local s = vim.fn.tolower(str)
  -- <tag>..</tag>
  s = s:gsub("<(%a+)[^>]*>.*</%1>", "")
  -- ](http://..) of a Markdown link
  s = s:gsub("%]%(%a[%w+.-]*://[^)]+%)", "]")
  s = s:gsub("%+", " plus "):gsub("%.", " dot "):gsub("&", " and ")
  s = s:gsub("[^%w()\128-\255]", " ")
  s = vim.trim(s)
  s = s:gsub("%s%s+", " ")
  s = s:gsub("%s*%(%s*([^)]-)%s*%)%s*", " -%1- ")
  s = s:gsub("[()]", "")
  s = s:gsub(" ", "-")
  s = s:gsub("^%-+", ""):gsub("%-+$", "")
  if not allow_double_hyphens then
    s = s:gsub("%-%-+", "-")
  end
  return s
end

---------------------------------------------------------------------------
-- Scalars
---------------------------------------------------------------------------

--- RFC 3339 dates Hugo reads (org-hugo--date-time-regexp).
---@param s string
---@return boolean
function M.is_date(s)
  if not s:match("^%d%d%d%d%-%d%d%-%d%d") then
    return false
  end
  local rest = s:sub(11)
  if rest == "" then
    return true
  end
  local tz = rest:match("^T%d%d:%d%d:%d%d(.*)$")
  if not tz then
    return false
  end
  return tz == "" or tz == "Z" or tz:match("^[+-]%d%d:%d%d$") ~= nil
end

-- 2^61 - 1, Emacs' most-positive-fixnum on 64-bit systems
local FIXNUM_DIGITS = "2305843009213693951"

local function fixnum_string(s)
  if not s:match("^[+-]?[%d_]+$") then
    return false
  end
  local digits = s:gsub("[+_-]", ""):gsub("^0+", "")
  if #digits < #FIXNUM_DIGITS then
    return true
  end
  return #digits == #FIXNUM_DIGITS and digits <= FIXNUM_DIGITS
end

local function float_string(s)
  return s:match("^[+-]?[%d_]+%.[%d_]+$") ~= nil or s:match("^[+-]?[%d_]+%.?[%d_]*[eE][+-]?[%d_]+$") ~= nil
end

--- A string as a TOML basic string, or (like tomelr) a multi-line one,
--- indented, when it has a newline or a double quote.
local function toml_string(s, indent, single)
  local esc = s:gsub("\\", "\\\\")
  if not single and (s:find("\n", 1, true) or s:find('"', 1, true)) then
    esc = esc:gsub('"""', '""\\"')
    local pad = indent .. "  "
    local lines = vim.split(esc, "\n", { plain = true })
    for i, l in ipairs(lines) do
      lines[i] = l == "" and "" or (pad .. l)
    end
    return '"""\n' .. table.concat(lines, "\n") .. "\n" .. pad .. '"""'
  end
  esc = esc:gsub('"', '\\"'):gsub("\t", "\\t"):gsub("\r", "\\r")
  return '"' .. esc .. '"'
end

local function number_string(v)
  if is_float(v) then
    return v.float
  end
  if v == math.floor(v) and math.abs(v) < 2 ^ 53 then
    return string.format("%d", v)
  end
  return tostring(v)
end

--- A scalar in TOML (tomelr): booleans, integers and RFC 3339 dates
--- given as strings are written bare.
local function toml_scalar(v, indent, single)
  if v == true then
    return "true"
  elseif v == false or v == vim.NIL then
    return "false"
  elseif type(v) == "number" or is_float(v) then
    return number_string(v)
  end
  local s = tostring(v)
  if s == "true" or s == "false" or fixnum_string(s) or M.is_date(s) then
    return s
  end
  return toml_string(s, indent or "", single)
end
M.toml_scalar = toml_scalar

--- A scalar in YAML (org-hugo--yaml-quote-string): already quoted
--- strings, booleans, numbers and dates bare, multi-line strings folded,
--- the rest double-quoted. `prefer_no_quotes`: plain alphanumeric words
--- bare too.
local function yaml_scalar(v, prefer_no_quotes, indent)
  if v == true then
    return "true"
  elseif v == false or v == vim.NIL then
    return "false"
  elseif type(v) == "number" or is_float(v) then
    return number_string(v)
  end
  local s = tostring(v)
  if s == "" then
    return '""'
  end
  if
    (#s > 1 and s:sub(1, 1) == '"' and s:sub(-1) == '"')
    or (prefer_no_quotes and s:match("^[%w]+$"))
    or fixnum_string(s)
    or s == "true"
    or s == "false"
    or M.is_date(s)
    or float_string(s)
  then
    return s
  end
  if s:find("\n", 1, true) then
    local pad = (indent or "") .. "  "
    -- a blank line (a new paragraph) needs two in a folded scalar
    local body = s:gsub("\n[ \t]*\n", "\n\n\n")
    local lines = vim.split(body, "\n", { plain = true })
    for i, l in ipairs(lines) do
      lines[i] = l == "" and "" or (pad .. l)
    end
    return ">\n" .. table.concat(lines, "\n")
  end
  return '"' .. s:gsub("\\", "\\\\"):gsub('"', '\\"') .. '"'
end
M.yaml_scalar = yaml_scalar

---------------------------------------------------------------------------
-- Values
---------------------------------------------------------------------------

---@param ... any
---@return table
function M.array(...)
  return { kind = "array", ... }
end

---@param entries? table
---@return table
function M.map(entries)
  return { kind = "map", entries = entries or {} }
end

local function is_map(v)
  return type(v) == "table" and v.kind == "map"
end

local function is_array(v)
  return type(v) == "table" and v.kind == "array"
end

--- Skipped: nil, an empty array or map.
local function empty(v)
  if v == nil then
    return true
  end
  if is_array(v) then
    return #v == 0
  end
  if is_map(v) then
    return #v.entries == 0
  end
  return false
end

--- Convert a Lisp value read by `read` (an alist, a list) to a front
--- matter value.
---@param v any
---@return any
function M.from_lisp(v)
  if type(v) ~= "table" or v.kind ~= "list" then
    if v == vim.NIL then
      return nil
    end
    return v
  end
  -- an alist: every element is a list or a dotted pair
  local alist = #v > 0
  for _, x in ipairs(v) do
    if not (type(x) == "table" and x.kind == "list" and #x > 0) then
      alist = false
      break
    end
  end
  if alist then
    local entries = {}
    for _, pair in ipairs(v) do
      local key = tostring(pair[1])
      local value
      if pair.dotted then
        value = M.from_lisp(pair.tail)
      elseif #pair == 1 then
        value = vim.NIL -- (key): a key without value
      else
        local rest = { kind = "list" }
        for i = 2, #pair do
          rest[#rest + 1] = pair[i]
        end
        value = M.from_lisp(rest)
      end
      entries[#entries + 1] = { key, value }
    end
    return M.map(entries)
  end
  local arr = { kind = "array" }
  for _, x in ipairs(v) do
    if x ~= vim.NIL then
      arr[#arr + 1] = M.from_lisp(x)
    end
  end
  return arr
end

---------------------------------------------------------------------------
-- TOML
---------------------------------------------------------------------------

local function toml_key(k)
  if k:match("^[%w_-]+$") then
    return k
  end
  return toml_string(k, "", true)
end

local function toml_array(v, indent)
  local parts = {}
  for _, x in ipairs(v) do
    parts[#parts + 1] = toml_scalar(x, indent, true)
  end
  return "[" .. table.concat(parts, ", ") .. "]"
end

local function toml_table(entries, path, depth, out)
  local indent = string.rep("  ", depth)
  local tables = {}
  for _, kv in ipairs(entries) do
    local k, v = kv[1], kv[2]
    if is_map(v) or (is_array(v) and v.maps) then
      tables[#tables + 1] = kv
    elseif not empty(v) and v ~= vim.NIL then
      local val = is_array(v) and toml_array(v, indent) or toml_scalar(v, indent)
      out[#out + 1] = indent .. toml_key(k) .. " = " .. val
    end
  end
  for _, kv in ipairs(tables) do
    local k, v = kv[1], kv[2]
    local name = (path ~= "" and (path .. ".") or "") .. toml_key(k)
    if is_map(v) then
      local has = false
      for _, e in ipairs(v.entries) do
        if not empty(e[2]) and e[2] ~= vim.NIL then
          has = true
        end
      end
      if has then
        out[#out + 1] = indent .. "[" .. name .. "]"
        toml_table(v.entries, name, depth + 1, out)
      end
    else
      for _, m in ipairs(v) do
        out[#out + 1] = indent .. "[[" .. name .. "]]"
        toml_table(m.entries, name, depth + 1, out)
      end
    end
  end
end

--- Front matter in TOML, between `+++` lines.
---@param data { [1]: string, [2]: any }[]
---@return string
function M.toml(data)
  local out = {}
  toml_table(data, "", 0, out)
  return "+++\n" .. table.concat(out, "\n") .. (#out > 0 and "\n" or "") .. "+++\n"
end

---------------------------------------------------------------------------
-- YAML
---------------------------------------------------------------------------

local function yaml_array(v)
  local parts = {}
  for _, x in ipairs(v) do
    parts[#parts + 1] = yaml_scalar(x)
  end
  return "[" .. table.concat(parts, ", ") .. "]"
end

local function yaml_entries(entries, indent, out, key_quote)
  local maps = {}
  for _, kv in ipairs(entries) do
    local k, v = kv[1], kv[2]
    if is_map(v) or (is_array(v) and v.maps) then
      maps[#maps + 1] = kv
    elseif v == vim.NIL then
      out[#out + 1] = indent .. k .. ": false"
    elseif not empty(v) and not (indent == "" and v == "") then
      local val = is_array(v) and yaml_array(v) or yaml_scalar(v, false, indent)
      out[#out + 1] = indent .. (key_quote and yaml_scalar(k, true) or k) .. ": " .. val
    end
  end
  for _, kv in ipairs(maps) do
    local k, v = kv[1], kv[2]
    if is_map(v) then
      local sub = {}
      yaml_entries(v.entries, indent .. "  ", sub, v.quote_keys)
      if #sub > 0 then
        out[#out + 1] = indent .. (key_quote and yaml_scalar(k, true) or k) .. ":"
        vim.list_extend(out, sub)
      end
    elseif #v > 0 then
      out[#out + 1] = indent .. k .. ":"
      for _, m in ipairs(v) do
        local sub = {}
        yaml_entries(m.entries, indent .. "  ", sub)
        if sub[1] then
          sub[1] = indent .. "- " .. sub[1]:sub(#indent + 3)
        end
        vim.list_extend(out, sub)
      end
    end
  end
end

--- Front matter in YAML, between `---` lines.
---@param data { [1]: string, [2]: any }[]
---@return string
function M.yaml(data)
  local out = {}
  yaml_entries(data, "", out)
  return "---\n" .. table.concat(out, "\n") .. (#out > 0 and "\n" or "") .. "---\n"
end

--- Front matter of `data` in `format` ("toml" or "yaml").
---@param data { [1]: string, [2]: any }[]
---@param format string
---@return string
function M.encode(data, format)
  if format == "yaml" then
    return M.yaml(data)
  end
  return M.toml(data)
end

return M
