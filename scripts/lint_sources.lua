-- Source lint for bug classes stylua can't see. Run it with
--
--   nvim --headless --clean -l scripts/lint_sources.lua [dir-or-file ...]
--
-- (default: lua). It prints `file:line: rule: message` for every hit and
-- exits non-zero when there is one. Plain Lua 5.1 / LuaJIT also works when
-- `find` is on PATH.
--
-- Rules:
--
--   expand        vim.fn.expand() (or fn.expand / expandcmd) on anything but
--                 a string literal. Vim expansion runs `backticks` as shell
--                 commands and interprets %, # and wildcards; paths that can
--                 come from a document must go through utils.expand_vars or
--                 utils.expand.
--   gsub          :gsub() / string.gsub() whose replacement is a string
--                 expression that isn't a literal (a variable, a
--                 concatenation): a `%` in the value is read as a capture
--                 reference. Use a literal, a function, a table, or wrap the
--                 value in utils.gsub_escape().
--   keyword-span  the column of a value captured from a `#+KEY: value` line
--                 looked up again with line:find(value [, 1, true]), which
--                 finds the value inside the keyword when it spells it
--                 (`#+name: name`). Capture the column with `()` instead.
--
-- An audited, safe use is allowed by a comment on the same line or the
-- line above, with a reason:
--
--   -- lint: allow expand: config option, never document text
--
-- An allow comment without a reason, or one that allows nothing, is a hit
-- too.

local M = {}

M.rules = { expand = true, gsub = true, ["keyword-span"] = true }

---------------------------------------------------------------------------
-- Tokenizer
---------------------------------------------------------------------------

local function long_bracket(src, i)
  -- `[` at i: returns the level of a long bracket `[==[` or nil
  local eqs = src:match("^%[(=*)%[", i)
  return eqs and #eqs or nil
end

--- Tokens { t = "name"|"string"|"number"|"op", v = text, line = n } and
--- comments[line] = text (all comments that start on that line).
function M.tokenize(src)
  local toks, comments = {}, {}
  local i, n, line = 1, #src, 1
  local function count_lines(s)
    local _, c = s:gsub("\n", "")
    return c
  end
  while i <= n do
    local c = src:sub(i, i)
    if c == "\n" then
      line = line + 1
      i = i + 1
    elseif c:match("%s") then
      i = i + 1
    elseif src:sub(i, i + 1) == "--" then
      local lvl = src:sub(i + 2, i + 2) == "[" and long_bracket(src, i + 2)
      local text, j
      if lvl then
        local close = "]" .. string.rep("=", lvl) .. "]"
        local e = src:find(close, i, true) or n
        j = e + #close
        text = src:sub(i, j - 1)
      else
        local e = src:find("\n", i, true) or n + 1
        j = e
        text = src:sub(i, e - 1)
      end
      comments[line] = (comments[line] and comments[line] .. " " or "") .. text
      line = line + count_lines(text)
      i = j
    elseif c == '"' or c == "'" then
      local j = i + 1
      while j <= n do
        local d = src:sub(j, j)
        if d == "\\" then
          j = j + 2
        elseif d == c or d == "\n" then
          break
        else
          j = j + 1
        end
      end
      local text = src:sub(i, j)
      toks[#toks + 1] = { t = "string", v = text, line = line }
      line = line + count_lines(text)
      i = j + 1
    elseif c == "[" and long_bracket(src, i) then
      local lvl = long_bracket(src, i)
      local close = "]" .. string.rep("=", lvl) .. "]"
      local e = src:find(close, i, true) or n
      local text = src:sub(i, e + #close - 1)
      toks[#toks + 1] = { t = "string", v = text, line = line }
      line = line + count_lines(text)
      i = e + #close
    elseif c:match("[%a_]") then
      local w = src:match("^[%w_]+", i)
      toks[#toks + 1] = { t = "name", v = w, line = line }
      i = i + #w
    elseif c:match("%d") or (c == "." and src:sub(i + 1, i + 1):match("%d")) then
      local w = src:match("^0[xX]%x+", i) or src:match("^[%d%.]+[eE][%+%-]?%d+", i) or src:match("^[%d%.]+", i)
      toks[#toks + 1] = { t = "number", v = w, line = line }
      i = i + #w
    else
      local op = src:match("^%.%.%.", i)
        or src:match("^[=~<>]=", i)
        or src:match("^%.%.", i)
        or src:match("^::", i)
        or c
      toks[#toks + 1] = { t = "op", v = op, line = line }
      i = i + #op
    end
  end
  return toks, comments
end

---------------------------------------------------------------------------
-- Helpers over tokens
---------------------------------------------------------------------------

local OPEN = { ["("] = ")", ["["] = "]", ["{"] = "}" }

--- Index of the token closing the bracket opened at `i`.
local function matching(toks, i)
  local depth = 0
  for j = i, #toks do
    local v = toks[j].t == "op" and toks[j].v
    if v and OPEN[v] then
      depth = depth + 1
    elseif v == ")" or v == "]" or v == "}" then
      depth = depth - 1
      if depth == 0 then
        return j
      end
    end
  end
  return #toks
end

--- The arguments of the call whose `(` is at `i`: a list of { from, to }
--- token ranges (to < from for an empty argument), and the `)` index.
local function call_args(toks, i)
  local close = matching(toks, i)
  local args, from, depth = {}, i + 1, 0
  for j = i + 1, close - 1 do
    local v = toks[j].t == "op" and toks[j].v
    if v and OPEN[v] then
      depth = depth + 1
    elseif v == ")" or v == "]" or v == "}" then
      depth = depth - 1
    elseif v == "," and depth == 0 then
      args[#args + 1] = { from, j - 1 }
      from = j + 1
    end
  end
  if close - 1 >= from then
    args[#args + 1] = { from, close - 1 }
  end
  return args, close
end

local function is(tok, t, v)
  return tok ~= nil and tok.t == t and (v == nil or tok.v == v)
end

--- Split the range [a, b] at top-level tokens equal to `word`.
local function split_top(toks, a, b, word)
  local parts, from, depth = {}, a, 0
  for j = a, b do
    local tk = toks[j]
    if tk.t == "op" and OPEN[tk.v] then
      depth = depth + 1
    elseif tk.t == "op" and (tk.v == ")" or tk.v == "]" or tk.v == "}") then
      depth = depth - 1
    elseif depth == 0 and tk.v == word and (tk.t == "name" or tk.t == "op") then
      parts[#parts + 1] = { from, j - 1 }
      from = j + 1
    end
  end
  parts[#parts + 1] = { from, b }
  return parts
end

--- Text of a dotted name occupying exactly [a, b], or nil.
local function dotted(toks, a, b)
  if b < a or not is(toks[a], "name") then
    return nil
  end
  local parts = { toks[a].v }
  local j = a + 1
  while j <= b do
    if is(toks[j], "op", ".") and is(toks[j + 1], "name") then
      parts[#parts + 1] = toks[j + 1].v
      j = j + 2
    else
      return nil
    end
  end
  return table.concat(parts, ".")
end

local KEYWORDS = {}
for w in
  ("and break do else elseif end false for function goto if in local nil not or repeat return then true until while"):gmatch(
    "%a+"
  )
do
  KEYWORDS[w] = true
end

--- Names the file defines as functions, tables or string constants
--- (`local function f`, `local t = {`, `M.f = function`,
--- `local SEP = "\1"`): passing one as a gsub replacement is safe.
local function callable_names(toks)
  local names = {}
  for i = 1, #toks do
    local tk = toks[i]
    if is(tk, "name", "function") then
      -- function a.b.c( / local function f(
      local j, parts = i + 1, {}
      while is(toks[j], "name") do
        parts[#parts + 1] = toks[j].v
        if is(toks[j + 1], "op", ".") or is(toks[j + 1], "op", ":") then
          j = j + 2
        else
          break
        end
      end
      if #parts > 0 then
        names[table.concat(parts, ".")] = true
        names[parts[#parts]] = true
      end
    elseif
      is(tk, "op", "=")
      and (
        is(toks[i + 1], "op", "{")
        or is(toks[i + 1], "name", "function")
        -- a constant: `local SEP = "x"`, not followed by `..`
        or (is(toks[i - 2], "name", "local") and is(toks[i + 1], "string") and not is(toks[i + 2], "op", ".."))
      )
    then
      -- walk back over a dotted name
      local j = i - 1
      while j >= 1 and ((is(toks[j], "name") and not KEYWORDS[toks[j].v]) or is(toks[j], "op", ".")) do
        j = j - 1
      end
      local name = dotted(toks, j + 1, i - 1)
      if name then
        names[name] = true
      end
    end
  end
  return names
end

--- Calls whose value can't carry a stray `%` (or is escaped).
local SAFE_CALLS = {
  tostring = true, -- numbers, in practice
  ["string.char"] = true,
  ["string.rep"] = "literal", -- string.rep(" ", n)
  ["string.format"] = "format", -- without %s / %q
}

--- Is the replacement expression [a, b] safe: can no unintended `%` reach
--- gsub through it?
local function safe_repl(toks, a, b, names)
  if b < a then
    return true
  end
  local first, last = toks[a], toks[b]
  if is(first, "name", "function") then
    return true
  end
  -- `x and "a" or "b"`: every value branch must be safe
  local ors = split_top(toks, a, b, "or")
  if #ors > 1 then
    for _, r in ipairs(ors) do
      local ands = split_top(toks, r[1], r[2], "and")
      local v = ands[#ands]
      if not safe_repl(toks, v[1], v[2], names) then
        return false
      end
    end
    return true
  end
  local ands = split_top(toks, a, b, "and")
  if #ands > 1 then
    local v = ands[#ands]
    return safe_repl(toks, v[1], v[2], names)
  end
  -- "%1" .. x: every piece must be safe
  local cat = split_top(toks, a, b, "..")
  if #cat > 1 then
    for _, r in ipairs(cat) do
      if not safe_repl(toks, r[1], r[2], names) then
        return false
      end
    end
    return true
  end
  if
    a == b
    and (
      first.t == "string"
      or first.t == "number"
      or is(first, "name", "nil")
      or is(first, "name", "true")
      or is(first, "name", "false")
    )
  then
    return true
  end
  if is(first, "op", "{") and matching(toks, a) == b then
    return true
  end
  if is(first, "op", "(") and matching(toks, a) == b then
    return safe_repl(toks, a + 1, b - 1, names)
  end
  -- x:gsub("%%", "%%%%"), the escape written out
  if
    b - a >= 6
    and is(toks[b - 6], "op", ":")
    and is(toks[b - 5], "name", "gsub")
    and is(toks[b - 3], "string")
    and toks[b - 3].v:sub(2, -2) == "%%"
    and is(toks[b - 1], "string")
    and toks[b - 1].v:sub(2, -2) == "%%%%"
    and is(last, "op", ")")
  then
    return true
  end
  -- a call of an escape helper or a %-free value: gsub_escape(x), tostring(n)
  if is(last, "op", ")") then
    -- the `(` of the call that ends the expression
    local j = a
    while j < b and not (is(toks[j], "op", "(") and matching(toks, j) == b) do
      j = j + 1
    end
    if j > a and is(toks[j - 1], "name", "gsub_escape") then
      return true
    end
    local callee = dotted(toks, a, j - 1)
    if callee and is(toks[j], "op", "(") then
      local kind = SAFE_CALLS[callee]
      local arg1 = toks[j + 1]
      if kind == true then
        return true
      elseif kind == "literal" and is(arg1, "string") then
        return true
      elseif kind == "format" and is(arg1, "string") and not arg1.v:find("%%[%-%d%.]*[sq]") then
        return true
      end
    end
  end
  -- a function, table or literal constant the file defines; string.upper
  local name = dotted(toks, a, b)
  if name and (names[name] or name:match("^string%.")) then
    return true
  end
  return false
end

local function src_text(toks, a, b)
  local out = {}
  for j = a, b do
    out[#out + 1] = toks[j].v
  end
  return table.concat(out, " ")
end

---------------------------------------------------------------------------
-- Rules
---------------------------------------------------------------------------

local function check_expand(toks, hits)
  for i = 1, #toks do
    local tk = toks[i]
    if
      is(tk, "name")
      and (tk.v == "expand" or tk.v == "expandcmd")
      and is(toks[i - 1], "op", ".")
      and is(toks[i - 2], "name", "fn")
      and is(toks[i + 1], "op", "(")
    then
      local args = call_args(toks, i + 1)
      local a = args[1]
      if not (a and a[1] == a[2] and toks[a[1]].t == "string") then
        hits[#hits + 1] = {
          line = tk.line,
          rule = "expand",
          msg = "vim.fn." .. tk.v .. "() on a non-literal runs `backticks`; use utils.expand_vars / utils.expand",
        }
      end
    end
  end
end

local function check_gsub(toks, hits)
  local names
  for i = 1, #toks do
    local tk = toks[i]
    if is(tk, "name", "gsub") and is(toks[i + 1], "op", "(") then
      local repl_arg
      if is(toks[i - 1], "op", ":") then
        repl_arg = 2
      elseif is(toks[i - 1], "op", ".") and is(toks[i - 2], "name", "string") then
        repl_arg = 3
      end
      if repl_arg then
        local args = call_args(toks, i + 1)
        local r = args[repl_arg]
        names = names or callable_names(toks)
        if r and not safe_repl(toks, r[1], r[2], names) then
          hits[#hits + 1] = {
            line = tk.line,
            rule = "gsub",
            msg = "gsub replacement `"
              .. src_text(toks, r[1], r[2])
              .. "` is not a literal: a `%` in it is a capture; wrap it in utils.gsub_escape()",
          }
        end
      end
    end
  end
end

-- keyword-span: `local a, b = S:match("...#%+...")` followed, within a few
-- lines, by `S:find(a [, 1 [, true]])`.
local KEYWORD_WINDOW = 25

local function check_keyword_span(toks, hits)
  local captured = {} -- name -> { subject = text, line = n }
  for i = 1, #toks do
    local tk = toks[i]
    if is(tk, "name", "match") and is(toks[i - 1], "op", ":") and is(toks[i + 1], "op", "(") then
      local args = call_args(toks, i + 1)
      local p = args[1]
      if p and p[1] == p[2] and toks[p[1]].t == "string" and toks[p[1]].v:find("#%+", 1, true) then
        -- subject: dotted name or indexed expression before `:`
        local j = i - 2
        while
          j >= 1
          and (is(toks[j], "name") or is(toks[j], "op", ".") or is(toks[j], "op", "]") or is(toks[j], "op", "["))
        do
          if is(toks[j], "op", "]") then
            -- skip to matching "["
            local depth = 0
            while j >= 1 do
              if is(toks[j], "op", "]") then
                depth = depth + 1
              elseif is(toks[j], "op", "[") then
                depth = depth - 1
                if depth == 0 then
                  break
                end
              end
              j = j - 1
            end
          end
          j = j - 1
        end
        local subject = src_text(toks, j + 1, i - 2)
        -- the assigned names: `local a, b =` (or `a, b =`) before the subject
        if is(toks[j], "op", "=") then
          local k = j - 1
          while k >= 1 and (is(toks[k], "name") or is(toks[k], "op", ",")) and not is(toks[k], "name", "local") do
            if is(toks[k], "name") then
              captured[toks[k].v] = { subject = subject, line = tk.line }
            end
            k = k - 1
          end
        end
      end
    elseif
      is(tk, "name", "find")
      and is(toks[i - 1], "op", ":")
      and is(toks[i + 1], "op", "(")
      and is(toks[i + 2], "name")
      and captured[toks[i + 2].v]
    then
      local cap = captured[toks[i + 2].v]
      local args = call_args(toks, i + 1)
      local init = args[2]
      local from_start = not init or (init[1] == init[2] and toks[init[1]].v == "1")
      if
        args[1]
        and args[1][1] == args[1][2]
        and from_start
        and tk.line - cap.line <= KEYWORD_WINDOW
        and tk.line >= cap.line
      then
        hits[#hits + 1] = {
          line = tk.line,
          rule = "keyword-span",
          msg = "`"
            .. toks[i + 2].v
            .. "` was captured from a #+KEY: line; searching for it from the line start can land in the keyword"
            .. " (#+name: name): capture its column with () instead",
        }
      end
    end
  end
end

---------------------------------------------------------------------------
-- Allow comments
---------------------------------------------------------------------------

--- allows[line] = { { rule = r, reason = s, line = n, used = false } }
local function parse_allows(comments)
  local allows, bad = {}, {}
  for line, text in pairs(comments) do
    for rule, rest in text:gmatch("lint:%s*allow%s+([%w%-]+)([^\n]*)") do
      local reason = rest:gsub("^[%s:%-]+", ""):gsub("%s+$", "")
      if not M.rules[rule] then
        bad[#bad + 1] = { line = line, rule = "allow", msg = "unknown lint rule `" .. rule .. "`" }
      elseif reason == "" then
        bad[#bad + 1] = { line = line, rule = "allow", msg = "`lint: allow " .. rule .. "` needs a reason" }
      else
        allows[line] = allows[line] or {}
        table.insert(allows[line], { rule = rule, line = line, used = false })
      end
    end
  end
  return allows, bad
end

--- Lint Lua source text. Returns a list of { line, rule, msg }, sorted.
function M.check(src)
  local toks, comments = M.tokenize(src)
  local raw = {}
  check_expand(toks, raw)
  check_gsub(toks, raw)
  check_keyword_span(toks, raw)
  local allows, out = parse_allows(comments)
  for _, h in ipairs(raw) do
    local allowed = false
    for _, l in ipairs({ h.line, h.line - 1 }) do
      for _, a in ipairs(allows[l] or {}) do
        if a.rule == h.rule then
          a.used = true
          allowed = true
        end
      end
    end
    if not allowed then
      out[#out + 1] = h
    end
  end
  for _, list in pairs(allows) do
    for _, a in ipairs(list) do
      if not a.used then
        out[#out + 1] = { line = a.line, rule = "allow", msg = "`lint: allow " .. a.rule .. "` allows nothing here" }
      end
    end
  end
  table.sort(out, function(x, y)
    if x.line ~= y.line then
      return x.line < y.line
    end
    return x.rule < y.rule
  end)
  return out
end

local function read(path)
  local f = assert(io.open(path, "rb"))
  local s = f:read("*a")
  f:close()
  return s
end

local function lua_files(root)
  local out = {}
  if root:match("%.lua$") then
    return { root }
  end
  if vim and vim.fs and vim.fs.dir then
    for name, t in vim.fs.dir(root, { depth = math.huge }) do
      if t == "file" and name:match("%.lua$") then
        out[#out + 1] = root .. "/" .. name
      end
    end
  else
    local p = io.popen('find "' .. root .. '" -name "*.lua" -type f')
    for l in p:lines() do
      out[#out + 1] = l
    end
    p:close()
  end
  table.sort(out)
  return out
end

--- Lint files and directories; returns the hits as `file:line: rule: msg`.
function M.run(paths)
  local lines = {}
  for _, root in ipairs(paths) do
    for _, file in ipairs(lua_files(root)) do
      for _, h in ipairs(M.check(read(file))) do
        lines[#lines + 1] = string.format("%s:%d: %s: %s", file, h.line, h.rule, h.msg)
      end
    end
  end
  return lines
end

if arg and arg[0] and arg[0]:match("lint_sources%.lua$") then
  local paths = {}
  for i = 1, #arg do
    paths[#paths + 1] = arg[i]
  end
  if #paths == 0 then
    paths = { "lua" }
  end
  local hits = M.run(paths)
  for _, l in ipairs(hits) do
    io.stdout:write(l, "\n")
  end
  if #hits > 0 then
    io.stdout:write(#hits, " lint hit(s)\n")
    os.exit(1)
  end
  os.exit(0)
end

return M
