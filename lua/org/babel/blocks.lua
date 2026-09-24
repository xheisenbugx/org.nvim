---@mod org.babel.blocks Source block parsing and header arguments

local M = {}

local RESULT_CATEGORIES = {
  collection = { value = true, output = true },
  type = { table = true, vector = true, list = true, scalar = true, verbatim = true, file = true },
  format = {
    code = true,
    drawer = true,
    html = true,
    latex = true,
    link = true,
    graphics = true,
    org = true,
    pp = true,
    raw = true,
  },
  handling = { replace = true, silent = true, none = true, append = true, prepend = true, discard = true },
}

--- Tokenize a header argument string, respecting quotes and parens.
local function tokenize(str)
  local tokens = {}
  local i, n = 1, #str
  while i <= n do
    local c = str:sub(i, i)
    if c:match("%s") then
      i = i + 1
    else
      local j = i
      local depth, quote = 0, nil
      while j <= n do
        local ch = str:sub(j, j)
        if quote then
          if ch == "\\" then
            j = j + 1
          elseif ch == quote then
            quote = nil
          end
        elseif ch == '"' then
          quote = ch
        elseif ch == "(" or ch == "[" then
          depth = depth + 1
        elseif ch == ")" or ch == "]" then
          depth = depth - 1
        elseif ch:match("%s") and depth <= 0 then
          break
        end
        j = j + 1
      end
      tokens[#tokens + 1] = str:sub(i, j - 1)
      i = j
    end
  end
  return tokens
end

--- Parse `:key value :key2 value2` into a list of {key, value} pairs.
function M.parse_header_string(str)
  local out = {}
  local cur
  for _, tok in ipairs(tokenize(str or "")) do
    if tok:match("^:[%w_%-]+$") then
      cur = { key = tok:sub(2):lower(), parts = {} }
      out[#out + 1] = cur
    elseif cur then
      table.insert(cur.parts, tok)
    end
  end
  for _, p in ipairs(out) do
    p.value = table.concat(p.parts, " ")
    p.parts = nil
  end
  return out
end

--- Split `:var` values like "x=1 y=2" or "x=1, y=2" into assignments.
local function split_vars(value)
  local out = {}
  for _, tok in ipairs(tokenize((value or ""):gsub(",%s*", " "))) do
    local name, v = tok:match("^([%w_%-]+)=(.*)$")
    if name then
      out[#out + 1] = { name = name, value = v }
    elseif #out > 0 then
      out[#out].value = out[#out].value .. " " .. tok
    end
  end
  return out
end

--- Merge header pairs into an args table (later wins; vars accumulate;
--- :results merges by category).
function M.merge(args, pairs_list)
  args.vars = args.vars or {}
  args.results_spec = args.results_spec or {}
  for _, p in ipairs(pairs_list) do
    if p.key == "var" then
      for _, v in ipairs(split_vars(p.value)) do
        -- later definitions of the same var override
        local replaced = false
        for i, existing in ipairs(args.vars) do
          if existing.name == v.name then
            args.vars[i] = v
            replaced = true
          end
        end
        if not replaced then
          table.insert(args.vars, v)
        end
      end
    elseif p.key == "results" then
      for word in p.value:gmatch("%S+") do
        for cat, set in pairs(RESULT_CATEGORIES) do
          if set[word] then
            args.results_spec[cat] = word
          end
        end
      end
    else
      args[p.key] = p.value
    end
  end
  return args
end

--- Unquote a header value.
function M.unquote(v)
  if not v then
    return v
  end
  local q = v:match('^"(.*)"$')
  return q or v
end

---------------------------------------------------------------------------
-- Block parsing
---------------------------------------------------------------------------

local function lower(s)
  return s and s:lower() or s
end

--- Find where a #+RESULTS element that starts at `s` ends.
local function results_end(lines, s)
  local k = s + 1
  local n = #lines
  local line = lines[k]
  if not line or line:match("^%s*$") or line:match("^%*+%s") then
    return s
  end
  local drawer = line:match("^%s*:([%w_%-]+):%s*$")
  if drawer then
    while k <= n and not (k > s + 1 and lines[k]:match("^%s*:[Ee][Nn][Dd]:%s*$")) do
      k = k + 1
    end
    return math.min(k, n)
  end
  if line:match("^%s*:%s") or line:match("^%s*:$") then
    while k + 1 <= n and (lines[k + 1]:match("^%s*:%s") or lines[k + 1]:match("^%s*:$")) do
      k = k + 1
    end
    return k
  end
  local bname = line:match("^%s*#%+[Bb][Ee][Gg][Ii][Nn]_(%S+)")
  if bname then
    local pat = "^%s*#%+[Ee][Nn][Dd]_" .. vim.pesc(bname:lower())
    while k <= n and not lines[k]:lower():match(pat) do
      k = k + 1
    end
    return math.min(k, n)
  end
  if line:match("^%s*|") then
    while k + 1 <= n and (lines[k + 1]:match("^%s*|") or lines[k + 1]:match("^%s*#%+[Tt][Bb][Ll][Ff][Mm]:")) do
      k = k + 1
    end
    return k
  end
  -- list or paragraph: until blank line / headline / keyword
  while
    k + 1 <= n
    and not lines[k + 1]:match("^%s*$")
    and not lines[k + 1]:match("^%*+%s")
    and not lines[k + 1]:match("^%s*#%+")
  do
    k = k + 1
  end
  return k
end
M.results_end = results_end

local RESULTS_PAT = "^%s*#%+[Rr][Ee][Ss][Uu][Ll][Tt][Ss](%b[]):%s*(.-)%s*$"
local RESULTS_PAT2 = "^%s*#%+[Rr][Ee][Ss][Uu][Ll][Tt][Ss]:%s*(.-)%s*$"

local function match_results(line)
  if not line then
    return nil
  end
  local _, name = line:match(RESULTS_PAT)
  if name then
    return name
  end
  return line:match(RESULTS_PAT2)
end
M.match_results = match_results

--- Unescape `,*` and `,#+` at line starts.
function M.unescape(lines)
  local out = {}
  for i, l in ipairs(lines) do
    out[i] = l:gsub("^(%s*),([%*#])", "%1%2")
  end
  return out
end

--- Escape lines starting with `*` or `#+` (or already escaped ones).
function M.escape(lines)
  local out = {}
  for i, l in ipairs(lines) do
    if l:match("^%s*,*%*") or l:match("^%s*,*#%+") then
      out[i] = l:gsub("^(%s*)", "%1,", 1)
    else
      out[i] = l
    end
  end
  return out
end

--- Parse all src blocks (and #+CALL lines) of a list of lines.
---@return table[] blocks
function M.parse_blocks(lines)
  local blocks = {}
  local n = #lines
  local i = 1
  while i <= n do
    local line = lines[i]
    local indent, rest = line:match("^(%s*)#%+[Bb][Ee][Gg][Ii][Nn]_[Ss][Rr][Cc](.*)$")
    local call = not indent and line:match("^%s*#%+[Cc][Aa][Ll][Ll]:%s*(.-)%s*$")
    if indent and (rest == "" or rest:match("^%s")) then
      local j = i + 1
      while j <= n and not lines[j]:match("^%s*#%+[Ee][Nn][Dd]_[Ss][Rr][Cc]") do
        j = j + 1
      end
      if j > n then
        break
      end
      local lang, after = vim.trim(rest):match("^(%S+)%s*(.*)$")
      lang = lang or ""
      after = after or ""
      -- switches (-n, -r, -l "fmt") come before header args
      local switches, params = after:match("^(.-)%s*(:.*)$")
      if not switches then
        switches, params = after, ""
      end
      local block = {
        start = i,
        finish = j,
        indent = indent,
        lang = lang,
        switches = switches,
        params = params,
        header_lines = {},
        body = M.unescape(vim.list_slice(lines, i + 1, j - 1)),
      }
      -- affiliated keywords above
      local k = i - 1
      while k >= 1 and lines[k]:match("^%s*#%+%a") do
        local key, val = lines[k]:match("^%s*#%+([%w_]+):%s*(.-)%s*$")
        key = lower(key)
        if key == "name" then
          block.name = val
          block.name_line = k
        elseif key == "header" or key == "headers" then
          table.insert(block.header_lines, 1, val)
        elseif not key or key:match("^begin") or key:match("^end") then
          break
        end
        k = k - 1
      end
      -- results after the block
      local r = j + 1
      while r <= n and lines[r]:match("^%s*$") do
        r = r + 1
      end
      local rname = match_results(lines[r])
      if rname and (rname == "" or rname == block.name) then
        block.results = { start = r, finish = results_end(lines, r), name = rname }
      elseif block.name then
        for x = 1, n do
          local nm = match_results(lines[x])
          if nm and nm == block.name then
            block.results = { start = x, finish = results_end(lines, x), name = nm }
            break
          end
        end
      end
      blocks[#blocks + 1] = block
      i = j + 1
    elseif call then
      local name = call:match("^([^%(%s%[]+)") or ""
      local rest2 = call:sub(#name + 1)
      local inside = rest2:match("^%s*(%b[])")
      if inside then
        rest2 = rest2:gsub("^%s*%b[]", "", 1)
      end
      local args_str = rest2:match("^%s*(%b())")
      if args_str then
        rest2 = rest2:gsub("^%s*%b()", "", 1)
      end
      local block = {
        call = true,
        start = i,
        finish = i,
        indent = line:match("^(%s*)"),
        target = name,
        call_args = args_str and args_str:sub(2, -2) or "",
        params = vim.trim(rest2 or ""),
        header_lines = inside and { inside:sub(2, -2) } or {},
        body = {},
        name = nil,
      }
      local r = i + 1
      while r <= n and lines[r]:match("^%s*$") do
        r = r + 1
      end
      local rname = match_results(lines[r])
      if rname then
        block.results = { start = r, finish = results_end(lines, r), name = rname }
      end
      blocks[#blocks + 1] = block
      i = i + 1
    else
      i = i + 1
    end
  end
  return blocks
end

--- Header args for a block, merged in Emacs order:
--- defaults < #+PROPERTY header-args(:lang) < headline HEADER-ARGS(:LANG)
--- (inherited) < #+HEADER lines < #+begin_src line.
---@param file org.File|nil
function M.header_args(block, file, lang)
  lang = lang or block.lang
  local cfg = require("org.config").opts.babel or {}
  local args = { vars = {}, results_spec = {} }
  local defaults = {}
  for k, v in pairs(cfg.default_header_args or {}) do
    if k == "results" then
      table.insert(defaults, 1, { key = k, value = v })
    else
      defaults[#defaults + 1] = { key = k, value = tostring(v) }
    end
  end
  M.merge(args, defaults)
  local LANG = (lang or ""):upper()
  if file then
    local props = file.settings.properties or {}
    M.merge(args, M.parse_header_string(props["HEADER-ARGS"]))
    M.merge(args, M.parse_header_string(props["HEADER-ARGS:" .. LANG]))
    local hl = file:headline_at(block.start)
    local chain = {}
    while hl do
      table.insert(chain, 1, hl)
      hl = hl.parent
    end
    for _, h in ipairs(chain) do
      M.merge(args, M.parse_header_string(h.properties["HEADER-ARGS"]))
      M.merge(args, M.parse_header_string(h.properties["HEADER-ARGS:" .. LANG]))
    end
  end
  for _, h in ipairs(block.header_lines or {}) do
    M.merge(args, M.parse_header_string(h))
  end
  M.merge(args, M.parse_header_string(block.params))
  args.results_spec.collection = args.results_spec.collection or "value"
  args.results_spec.handling = args.results_spec.handling or "replace"
  return args
end

return M
