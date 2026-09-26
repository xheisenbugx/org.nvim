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

local RESULT_WORDS = {}
for cat, set in pairs(RESULT_CATEGORIES) do
  for w in pairs(set) do
    RESULT_WORDS[w] = cat
  end
end

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

--- Replace the commas that separate arguments (outside quotes, brackets
--- and parentheses) with `sep` (default a space), like
--- org-babel-ref-split-args.
local function top_level_commas(str, sep)
  local out, depth, quote = {}, 0, false
  local i = 1
  while i <= #str do
    local ch = str:sub(i, i)
    if quote then
      if ch == "\\" then
        out[#out + 1] = str:sub(i, i + 1)
        i = i + 1
        ch = nil
      elseif ch == '"' then
        quote = false
      end
    elseif ch == '"' then
      quote = true
    elseif ch == "(" or ch == "[" then
      depth = depth + 1
    elseif ch == ")" or ch == "]" then
      depth = depth - 1
    elseif ch == "," and depth <= 0 then
      ch = sep or " "
    end
    if ch then
      out[#out + 1] = ch
    end
    i = i + 1
  end
  return table.concat(out)
end

--- Split `:var` values like "x=1 y=2" or "x=1, y=2" into assignments
--- (org-babel-parse-multiple-vars; commas are also accepted).
local function split_vars(value)
  local out = {}
  for _, tok in ipairs(tokenize(top_level_commas(value or ""))) do
    local name, v = tok:match("^([^=%s]+)=(.*)$")
    if name then
      out[#out + 1] = { name = name, value = v }
    elseif #out > 0 then
      out[#out].value = out[#out].value .. " " .. tok
    end
  end
  return out
end

--- The arguments of a call `name(a, b=2)`, split at top-level commas
--- (org-babel-ref-split-args), as `:var` header pairs. Arguments without
--- `name=` are positional: they give values to the target's variables in
--- order (org-babel-merge-params).
---@return { key: "var", value: string, positional?: boolean }[]
function M.call_args(str)
  local out = {}
  for _, a in ipairs(vim.split(top_level_commas(str or "", "\1"), "\1", { plain = true })) do
    a = vim.trim(a)
    if a ~= "" then
      local name, v = a:match("^([^=%s]+)%s*=%s*(.*)$")
      if name then
        out[#out + 1] = { key = "var", value = name .. "=" .. v }
      else
        out[#out + 1] = { key = "var", value = a, positional = true }
      end
    end
  end
  return out
end

--- Merge header pairs into an args table (later wins; vars accumulate;
--- :results merges by category, like org-babel-merge-params). Positional
--- `:var` pairs replace the values of the variables in order; `state`
--- carries that position across the merges of one org-babel-merge-params.
---@param state? { pos: integer }
function M.merge(args, pairs_list, state)
  args.vars = args.vars or {}
  args.results_spec = args.results_spec or {}
  state = state or { pos = 0 }
  for _, p in ipairs(pairs_list) do
    if p.key == "var" and p.positional then
      state.pos = state.pos + 1
      local target = args.vars[state.pos]
      if target then
        args.vars[state.pos] = { name = target.name, value = p.value }
      end
    elseif p.key == "var" then
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
        local cat = RESULT_WORDS[word]
        if cat then
          args.results_spec[cat] = word
          if cat == "collection" then
            args.default_collection = nil
          end
        else
          args.results_extra = args.results_extra or {}
          if not vim.tbl_contains(args.results_extra, word) then
            table.insert(args.results_extra, word)
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

local function blank(l)
  return l:match("^%s*$") ~= nil
end

local function item_indent(l)
  local ind = l:match("^(%s*)[-+] ") or l:match("^(%s*)[-+]$") or l:match("^(%s*)%d+[.)] ") or l:match("^( +)%* ")
  return ind and #ind or nil
end

--- Last line of the Org element starting at line `k` (paragraphs
--- included), for reading named elements.
---@return integer last, string kind
function M.element_end(lines, k)
  local n = #lines
  local line = lines[k]
  if not line or blank(line) then
    return k - 1, "none"
  end
  local drawer = line:match("^%s*:([%w_%-]+):%s*$")
  if drawer and drawer:upper() ~= "END" then
    for j = k + 1, n do
      if lines[j]:match("^%s*:[Ee][Nn][Dd]:%s*$") then
        return j, "drawer"
      elseif lines[j]:match("^%*+%s") then
        break
      end
    end
  end
  if line:match("^%s*:%s") or line:match("^%s*:$") then
    while k + 1 <= n and (lines[k + 1]:match("^%s*:%s") or lines[k + 1]:match("^%s*:$")) do
      k = k + 1
    end
    return k, "fixed-width"
  end
  local bname = line:match("^%s*#%+[Bb][Ee][Gg][Ii][Nn]_(%S+)")
  if bname then
    local pat = "^%s*#%+[Ee][Nn][Dd]_" .. vim.pesc(bname:lower()) .. "%f[%s%z]"
    for j = k + 1, n do
      if lines[j]:lower():match(pat) then
        local kind = bname:lower()
        if kind ~= "src" and kind ~= "example" and kind ~= "export" then
          kind = (kind == "quote" or kind == "center" or kind == "verse" or kind == "comment") and kind or "special"
        end
        return j, kind
      end
    end
  end
  if line:match("^%s*|") then
    while k + 1 <= n and (lines[k + 1]:match("^%s*|") or lines[k + 1]:match("^%s*#%+[Tt][Bb][Ll][Ff][Mm]:")) do
      k = k + 1
    end
    return k, "table"
  end
  local env = line:match("^%s*\\begin{([^}]+)}")
  if env then
    for j = k, n do
      if lines[j]:find("\\end{" .. env .. "}", 1, true) then
        return j, "latex"
      end
    end
  end
  local base = item_indent(line)
  if base then
    local last = k
    local j = k + 1
    while j <= n do
      local l = lines[j]
      if blank(l) then
        local nxt = lines[j + 1]
        if not nxt or blank(nxt) then
          break
        end
        local ind = #nxt:match("^(%s*)")
        if not (ind > base or item_indent(nxt) == base) then
          break
        end
      elseif l:match("^%*+%s") then
        break
      else
        local ind = #l:match("^(%s*)")
        if not (ind > base or item_indent(l) == base) then
          break
        end
        last = j
      end
      j = j + 1
    end
    return last, "list"
  end
  -- paragraph: until a blank line, a headline or a keyword
  while
    k + 1 <= n
    and not blank(lines[k + 1])
    and not lines[k + 1]:match("^%*+%s")
    and not lines[k + 1]:match("^%s*#%+")
  do
    k = k + 1
  end
  return k, "paragraph"
end

local RESULT_KINDS = {
  drawer = true,
  example = true,
  export = true,
  ["fixed-width"] = true,
  special = true,
  src = true,
  list = true,
  table = true,
  latex = true,
}

--- Last line of the result below the `#+RESULTS` line `s`, like
--- org-babel-result-end: a lone link, a drawer, block, fixed-width area,
--- list, table or LaTeX environment. Anything else (a paragraph, a blank
--- line) is not part of the result: `s` is returned.
local function results_end(lines, s)
  local k = s + 1
  local line = lines[k]
  if not line or blank(line) or line:match("^%*+%s") then
    return s
  end
  if line:match("^%s*%[%[.*%]%]%s*$") then
    return k
  end
  -- affiliated keywords belong to the element that follows them
  local e = k
  while lines[e] and lines[e]:match("^%s*#%+[%w_]+:") and not lines[e]:match("^%s*#%+[Bb][Ee][Gg][Ii][Nn]_") do
    e = e + 1
  end
  local last, kind = M.element_end(lines, e)
  if RESULT_KINDS[kind] then
    return last
  end
  return s
end
M.results_end = results_end

local RESULTS_PAT = "^%s*#%+[Rr][Ee][Ss][Uu][Ll][Tt][Ss](%b[]):%s*(.-)%s*$"
local RESULTS_PAT2 = "^%s*#%+[Rr][Ee][Ss][Uu][Ll][Tt][Ss]:%s*(.-)%s*$"

local function match_results(line)
  if not line then
    return nil
  end
  local hash, name = line:match(RESULTS_PAT)
  if name then
    -- org-babel-hash-show-time writes "[(2024-01-02 10:00:00) hash]"
    return name, (hash:sub(2, -2):gsub("^%(%d%d%d%d%-%d%d%-%d%d %d%d:%d%d:%d%d%)%s*", ""))
  end
  return line:match(RESULTS_PAT2)
end
M.match_results = match_results

--- Lua pattern matching a coderef label such as `(ref:name)` at the end of
--- a line (capture 1 = the label). `switches` may set another format with
--- `-l "fmt"`, like Emacs.
function M.coderef_pattern(switches)
  local fmt = (switches or ""):match('%-l%s+"(.-)"') or "(ref:%s)"
  local s, e = fmt:find("%s", 1, true)
  if not s then
    fmt, s, e = "(ref:%s)", 6, 7
  end
  return "%s*" .. vim.pesc(fmt:sub(1, s - 1)) .. "([%w_%-][%w_%- ]*)" .. vim.pesc(fmt:sub(e + 1)) .. "%s*$"
end

--- Remove one comma before `*` and `#+`, including nested escapes.
function M.unescape(lines)
  local out = {}
  for i, l in ipairs(lines) do
    if l:match("^%s*,+%*") or l:match("^%s*,+#%+") then
      out[i] = l:gsub("^(%s*),", "%1", 1)
    else
      out[i] = l
    end
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

--- Remove the common indentation of lines (org-remove-indentation; a tab
--- counts as `tabstop` columns).
function M.dedent(lines)
  local min
  local ts = vim.o.tabstop > 0 and vim.o.tabstop or 8
  local function width(ws)
    local w = 0
    for c in ws:gmatch(".") do
      w = c == "\t" and (math.floor(w / ts) + 1) * ts or w + 1
    end
    return w
  end
  for _, l in ipairs(lines) do
    if l:match("%S") then
      local n = width(l:match("^(%s*)"))
      if not min or n < min then
        min = n
      end
    end
  end
  if not min or min == 0 then
    return lines
  end
  local out = {}
  for i, l in ipairs(lines) do
    local ws = l:match("^(%s*)")
    if not l:match("%S") then
      out[i] = ""
    elseif not ws:find("\t", 1, true) then
      out[i] = l:sub(min + 1)
    else
      out[i] = string.rep(" ", width(ws) - min) .. l:sub(#ws + 1)
    end
  end
  return out
end

--- Does a block keep its indentation (`-i`, org-src-preserve-indentation)?
function M.preserve_indentation(switches)
  if (" " .. (switches or "") .. " "):match("%s%-i%s") then
    return true
  end
  return require("org.config").opts.src_preserve_indentation == true
end

local function literal_end(lines, start, kind)
  for j = start + 1, #lines do
    if lines[j]:match("^%*+%s") then
      break
    elseif lines[j]:lower():match("^%s*#%+end_" .. kind .. "%s*$") then
      return j
    end
  end
end

--- Lines whose contents cannot contain inline Babel objects. Greater
--- elements (quote, center, special) and verse blocks do contain objects.
function M.inline_literal_lines(lines)
  local hidden, i = {}, 1
  while i <= #lines do
    local kind = lines[i]:lower():match("^%s*#%+begin_(%S+)")
    local literal = kind == "src" or kind == "example" or kind == "export" or kind == "comment"
    local finish = literal and literal_end(lines, i, kind)
    if finish then
      for j = i, finish do
        hidden[j] = true
      end
    end
    i = finish and (finish + 1) or (i + 1)
  end
  return hidden
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
    local finish = indent and (rest == "" or rest:match("^%s")) and literal_end(lines, i, "src")
    if finish then
      local j = finish
      local lang, after = vim.trim(rest):match("^(%S+)%s*(.*)$")
      lang = lang or ""
      after = after or ""
      -- switches (-n, -r, -l "fmt") come before header args
      local switches, params = after:match("^(.-)%s*(:.*)$")
      if not switches then
        switches, params = after, ""
      end
      local raw = M.unescape(vim.list_slice(lines, i + 1, j - 1))
      local block = {
        start = i,
        finish = j,
        indent = indent,
        lang = lang,
        switches = switches,
        params = params,
        header_lines = {},
        body_raw = raw,
        -- like org-babel--normalize-body: common indentation removed
        -- unless -i or `src_preserve_indentation`
        body = M.preserve_indentation(switches) and raw or M.dedent(raw),
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
      local rname, rhash = match_results(lines[r])
      if rname and (rname == "" or rname == block.name) then
        block.results = { start = r, finish = results_end(lines, r), name = rname, hash = rhash }
      elseif block.name then
        for x = 1, n do
          local nm, h = match_results(lines[x])
          if nm and nm == block.name then
            block.results = { start = x, finish = results_end(lines, x), name = nm, hash = h }
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
      local k = i - 1
      while k >= 1 and lines[k]:match("^%s*#%+[%w_]+:") do
        local nm = lines[k]:match("^%s*#%+[Nn][Aa][Mm][Ee]:%s*(.-)%s*$")
        if nm then
          block.name = nm
          block.name_line = k
          break
        end
        k = k - 1
      end
      local r = i + 1
      while r <= n and lines[r]:match("^%s*$") do
        r = r + 1
      end
      local rname, rhash = match_results(lines[r])
      if rname and (rname == "" or rname == block.name) then
        block.results = { start = r, finish = results_end(lines, r), name = rname, hash = rhash }
      elseif block.name then
        for x = 1, n do
          local nm, h = match_results(lines[x])
          if nm and nm == block.name then
            block.results = { start = x, finish = results_end(lines, x), name = nm, hash = h }
            break
          end
        end
      end
      blocks[#blocks + 1] = block
      i = i + 1
    else
      -- These elements contain literal text, not nested Org elements.
      -- In particular, examples documenting Babel must never be executed
      -- or tangled (org-babel-active-location-p).
      local kind = line:lower():match("^%s*#%+begin_(%S+)")
      local literal = kind == "example" or kind == "export" or kind == "comment" or kind == "verse"
      local finish = literal and literal_end(lines, i, kind)
      i = finish and (finish + 1) or (i + 1)
    end
  end
  return blocks
end

---------------------------------------------------------------------------
-- Header arguments
---------------------------------------------------------------------------

--- Properties of the property drawer at the top of the file (before the
--- first headline and any other element), like Org's `org-data` node.
local function top_properties(file)
  if file._babel_top_props then
    return file._babel_top_props
  end
  local props, extend = {}, {}
  local lines = file.lines or {}
  local i = 1
  while lines[i] and (lines[i]:match("^%s*$") or lines[i]:match("^%s*#%s") or lines[i]:match("^%s*#$")) do
    i = i + 1
  end
  if lines[i] and lines[i]:match("^%s*:PROPERTIES:%s*$") then
    local bases, extra, order = {}, {}, {}
    local j = i + 1
    while lines[j] and not lines[j]:match("^%s*:END:%s*$") and not lines[j]:match("^%*+%s") do
      local key, value = lines[j]:match("^%s*:(%S+):%s+(.-)%s*$")
      if not key then
        key, value = lines[j]:match("^%s*:(%S+):%s*$"), ""
      end
      if key then
        local base = key:match("^(.-)%+$")
        local k = (base or key):upper()
        if not bases[k] and not extra[k] then
          order[#order + 1] = k
        end
        if base then
          extra[k] = extra[k] or {}
          table.insert(extra[k], value)
        else
          bases[k] = value
        end
      end
      j = j + 1
    end
    for _, k in ipairs(order) do
      local parts = { bases[k] }
      vim.list_extend(parts, extra[k] or {})
      props[k] = table.concat(parts, " ")
      extend[k] = bases[k] == nil or nil
    end
  end
  file._babel_top_props = { props = props, extend = extend }
  return file._babel_top_props
end

--- Value of the property `key` at line `lnum` with inheritance, like
--- `(org-entry-get POS KEY 'inherit)`: the nearest entry that sets `KEY`
--- wins; `KEY+` values accumulate onto it; without any entry the
--- `#+PROPERTY` keyword (or `global_properties`) is used.
---@param file org.File
---@return string|nil
function M.inherited_property(file, lnum, key)
  key = key:upper()
  local values = {}
  local found = false
  local hl = file.headline_at and file:headline_at(lnum) or nil
  while hl do
    local v = hl.properties and hl.properties[key]
    if v ~= nil then
      table.insert(values, 1, v)
      if not (hl.properties_extend and hl.properties_extend[key]) then
        found = true
        break
      end
    end
    hl = hl.parent
  end
  if not found then
    local top = top_properties(file)
    if top.props[key] ~= nil then
      table.insert(values, 1, top.props[key])
      found = not top.extend[key]
    end
  end
  if not found then
    local global = (file.settings and file.settings.properties or {})[key]
    if global == nil then
      for k, v in pairs(require("org.config").opts.global_properties or {}) do
        if k:upper() == key then
          global = v
        end
      end
    end
    if global ~= nil then
      table.insert(values, 1, global)
    end
  end
  if #values == 0 then
    return nil
  end
  return table.concat(values, " ")
end

--- Header pairs of a config table of default header args.
local function dict_pairs(dict)
  local out = {}
  local keys = vim.tbl_keys(dict or {})
  table.sort(keys)
  for _, k in ipairs(keys) do
    local v = dict[k]
    if v ~= false and v ~= nil then
      out[#out + 1] = { key = k, value = type(v) == "string" and v or tostring(v) }
    end
  end
  return out
end
M.dict_pairs = dict_pairs

--- Finish merged header args: default `:results` collection and handling.
function M.finish(args)
  -- shells use the exit status only for an explicit `:results value`
  args.default_collection = args.results_spec.collection == nil or nil
  args.results_spec.collection = args.results_spec.collection or "value"
  args.results_spec.handling = args.results_spec.handling or "replace"
  return args
end

--- Header args for a block, merged in Emacs order (org-babel-get-src-block-info):
--- `babel.default_header_args` (inline blocks: `default_inline_header_args`)
--- < the language's `default_header_args` < `header-args` and
--- `header-args:LANG` (inherited properties or #+PROPERTY) < the
--- `#+begin_src` line < `#+HEADER` lines.
---@param file org.File|nil
---@param opts? { inline?: boolean, no_finish?: boolean, state?: table, extra_defaults?: table }
function M.header_args(block, file, lang, opts)
  opts = opts or {}
  lang = lang or block.lang
  local cfg = require("org.config").opts.babel or {}
  local args = { vars = {}, results_spec = {} }
  local state = opts.state or { pos = 0 }
  local defaults = opts.inline and cfg.default_inline_header_args or cfg.default_header_args
  M.merge(args, dict_pairs(defaults), state)
  if opts.extra_defaults then
    M.merge(args, dict_pairs(opts.extra_defaults), state)
  end
  local lcfg = (cfg.languages or {})[lang]
  if type(lcfg) == "table" and lcfg.default_header_args then
    M.merge(args, dict_pairs(lcfg.default_header_args), state)
  end
  if file and not block.lob then
    M.merge(args, M.parse_header_string(M.inherited_property(file, block.start, "HEADER-ARGS")), state)
    if lang and lang ~= "" then
      M.merge(args, M.parse_header_string(M.inherited_property(file, block.start, "HEADER-ARGS:" .. lang)), state)
    end
  end
  M.merge(args, M.parse_header_string(block.params), state)
  for _, h in ipairs(block.header_lines or {}) do
    M.merge(args, M.parse_header_string(h), state)
  end
  if opts.no_finish then
    return args
  end
  return M.finish(args)
end

return M
