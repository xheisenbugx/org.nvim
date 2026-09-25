---@mod org.babel.results Formatting of evaluation results
---
--- Mirrors `org-babel-insert-result`: a result is a Babel value (see
--- `org.babel.lisp`): a string is inserted as `: ` lines (or an example
--- block), a list as a table (or a plain list with `:results list`), and
--- `:wrap`, `raw`, `drawer`, `org`, `html`, `latex` and `code` wrap it.

local blocks_mod = require("org.babel.blocks")
local lisp = require("org.babel.lisp")

local M = {}

--- The `:results` words of merged header args, as a set
--- (Emacs `:result-params`).
function M.result_params(args)
  local rp = {}
  for _, v in pairs(args.results_spec or {}) do
    if type(v) == "string" then
      rp[v] = true
    end
  end
  for _, w in ipairs(args.results_extra or {}) do
    rp[w] = true
  end
  return rp
end

--- Emacs `format "%s"` of a value (lists as `(a b)`).
M.stringify = lisp.princ

local function is_null(v)
  return v == nil or (lisp.is_list(v) and #v == 0)
end
M.is_null = is_null

--- Split text into lines, dropping one final newline.
local function text_lines(s)
  if s == "" then
    return {}
  end
  s = s:gsub("\n$", "")
  return vim.split(s, "\n", { plain = true })
end
M.text_lines = text_lines

--- Lines of a table value (rows of cells and "hline").
function M.table_lines(v)
  local rows = v
  for _, e in ipairs(v) do
    if e ~= "hline" and not lisp.is_list(e) then
      rows = { v }
      break
    end
  end
  local norm = {}
  for i, row in ipairs(rows) do
    if row == "hline" then
      norm[i] = "hline"
    else
      local cells = {}
      for j, c in ipairs(row) do
        cells[j] = lisp.cell(c)
      end
      norm[i] = cells
    end
  end
  return require("org.table").rows_to_lines(norm, "")
end

--- Lines of `:results list` (org-list-to-org): items of a list value, or
--- the non-empty lines of a string.
local function list_lines(v)
  local items = {}
  if type(v) == "string" then
    for _, l in ipairs(vim.split(v, "\n", { plain = true, trimempty = false })) do
      if l ~= "" then
        items[#items + 1] = { l }
      end
    end
  else
    for _, e in ipairs(v) do
      if type(e) == "string" then
        items[#items + 1] = { e }
      elseif lisp.is_list(e) then
        local parts = {}
        for i, x in ipairs(e) do
          parts[i] = type(x) == "string" and x or lisp.prin1(x)
        end
        items[#items + 1] = parts
      else
        items[#items + 1] = { lisp.prin1(e) }
      end
    end
  end
  local out = {}
  for _, item in ipairs(items) do
    for i, s in ipairs(item) do
      for k, l in ipairs(vim.split(s, "\n", { plain = true })) do
        if i == 1 and k == 1 then
          out[#out + 1] = "- " .. l
        else
          out[#out + 1] = l == "" and "" or ("  " .. l)
        end
      end
    end
  end
  -- org-trim of the whole list
  while #out > 0 and vim.trim(out[#out]) == "" do
    out[#out] = nil
  end
  return out
end

--- Align a table at the start of `lines` (Emacs `(org-cycle)` at a table).
local function align_table(lines)
  if not lines[1] or not lines[1]:match("^%s*|") then
    return lines
  end
  local n = 1
  while lines[n + 1] and lines[n + 1]:match("^%s*|") do
    n = n + 1
  end
  local t = require("org.table").parse(vim.list_slice(lines, 1, n))
  local rows = {}
  for i, r in ipairs(t.rows) do
    rows[i] = r.hline and "hline" or r.cells
  end
  local out = require("org.table").rows_to_lines(rows, "")
  for i = n + 1, #lines do
    out[#out + 1] = lines[i]
  end
  return out
end

--- Directory-relative form of `path` (file-relative-name).
local function relative(path, dir)
  path = vim.fs.normalize(path)
  dir = vim.fs.normalize(dir)
  if path == dir then
    return "."
  end
  local p = vim.split(path, "/", { plain = true })
  local d = vim.split(dir, "/", { plain = true })
  local i = 1
  while p[i] and d[i] and p[i] == d[i] do
    i = i + 1
  end
  local out = {}
  for _ = i, #d do
    out[#out + 1] = ".."
  end
  for k = i, #p do
    out[#out + 1] = p[k]
  end
  return table.concat(out, "/")
end
M.relative = relative

--- The description `:file-desc` gives a file link to `result`
--- (org-babel--file-desc): nil without the argument, the file name when it
--- has no value, none for `[]`.
function M.file_desc(args, result)
  local d = args["file-desc"]
  if d == nil then
    return nil
  end
  d = vim.trim(d)
  if d == "" then
    return result
  end
  if d:match("^%[.*%]$") or d:match("^%(.*%)$") or d:match("^'") then
    local ok, v = pcall(lisp.read, d)
    if ok and type(v) == "string" then
      return v
    end
    return nil
  end
  return blocks_mod.unquote(d)
end

--- `org-babel-result-to-file`: a link to `result` (a file name). With
--- `ctx.cwd` (the `:dir`) differing from `ctx.base_dir` (the Org file's
--- directory), the path is made relative to the Org file.
function M.result_to_file(result, desc, ctx)
  ctx = ctx or {}
  local path = result
  if ctx.base_dir and ctx.cwd and vim.fs.normalize(ctx.cwd) ~= vim.fs.normalize(ctx.base_dir) then
    local full = path:match("^[/~]") and vim.fn.fnamemodify(path, ":p") or (ctx.cwd:gsub("/$", "") .. "/" .. path)
    path = relative(full, ctx.base_dir)
  end
  return string.format("[[file:%s]%s]", path, desc and ("[" .. desc .. "]") or "")
end

--- Lines to insert below `#+RESULTS:` (unindented), like
--- `org-babel-insert-result` for a block or `#+CALL`. The second value
--- tells whether the result ends with an example block, which, like Emacs,
--- takes the place of an empty line following it.
---@param result any a Babel value
---@param args table merged header args
---@param lang? string
---@param ctx? { base_dir?: string, cwd?: string }
---@return string[] lines, boolean example
function M.format(result, args, lang, ctx)
  local rp = M.result_params(args)
  local cfg = require("org.config").opts.babel or {}
  local min_lines = cfg.min_lines_for_block_output or 10
  if type(result) == "string" then
    if rp.file then
      result = M.result_to_file(result, M.file_desc(args, result), ctx)
    end
  elseif not lisp.is_list(result) and result ~= nil then
    result = lisp.prin1(result)
  end
  local null = is_null(result)
  local tabulable = lisp.is_list(result)
  if type(result) == "string" and result:match("%S") and result:sub(-1) ~= "\n" then
    result = result .. "\n"
  end
  local lines
  if null then
    lines = {}
  elseif rp.list then
    lines = list_lines(result)
  elseif tabulable then
    lines = M.table_lines(result)
  else
    lines = text_lines(result)
  end
  local function wrap(start, finish, no_escape)
    local out = { start }
    vim.list_extend(out, no_escape and lines or blocks_mod.escape(lines))
    out[#out + 1] = finish
    return out
  end
  local switches = args.results_switches and (" " .. args.results_switches) or ""
  if args.wrap ~= nil then
    local full = vim.trim(blocks_mod.unquote(args.wrap) or "")
    if full == "" then
      full = "results"
    end
    local wtype = full:match("^(%S+)")
    local lw = wtype:lower()
    if lw == "nil" or lw == "no" then
      return lines, false
    end
    local escape = lw == "export" or lw == "example" or lw == "src"
    return wrap("#+begin_" .. full, "#+end_" .. wtype, not escape), false
  elseif rp.html then
    return wrap("#+begin_export html", "#+end_export"), false
  elseif rp.latex then
    return wrap("#+begin_export latex", "#+end_export"), false
  elseif rp.org then
    lines = align_table(lines)
    return wrap("#+begin_src org", "#+end_src"), false
  elseif rp.code then
    return wrap("#+begin_src " .. ((lang and lang ~= "") and lang or "none") .. switches, "#+end_src"), false
  elseif rp.raw then
    return align_table(lines), false
  elseif rp.drawer or rp.wrap then
    lines = align_table(lines)
    return wrap(":results:", ":end:", true), false
  elseif not tabulable and not rp.file then
    -- org-babel-examplify-region
    if #lines == 0 then
      return lines, false
    elseif #lines < min_lines then
      local out = {}
      for i, l in ipairs(lines) do
        out[i] = ": " .. l
      end
      return out, false
    end
    return wrap("#+begin_example" .. switches, "#+end_example"), true
  end
  return lines, false
end

--- Escape a macro argument (org-macro-escape-arguments).
local function macro_escape(s)
  return (
    s:gsub("(\\*),", function(bs)
      return string.rep("\\", 2 * #bs + 1) .. ","
    end)
  )
end

--- Text inserted after an inline src block or call, like
--- `org-babel-insert-result` for inline elements: `{{{results(=v=)}}}`,
--- or the bare value with `:results raw`. Returns nil and an error message
--- for results that cannot be inline.
---@return string|nil text, string|nil err
function M.format_inline(result, args, lang, ctx)
  local rp = M.result_params(args)
  if type(result) == "string" then
    if rp.file then
      result = M.result_to_file(result, M.file_desc(args, result), ctx)
    end
  elseif not lisp.is_list(result) and result ~= nil then
    result = lisp.prin1(result)
  end
  local warning = (rp.table and "`:results table'")
    or (rp.drawer and "`:results drawer'")
    or (lisp.is_list(result) and not is_null(result) and "list result")
    or (type(result) == "string" and result:find("\n.") and "multiline result")
    or (rp.list and "`:results list'")
  if warning then
    return nil, "Inline error: " .. warning .. " cannot be used"
  end
  local text
  if is_null(result) then
    text = ""
  elseif rp.file then
    text = macro_escape(result)
  elseif not rp.raw then
    text = macro_escape((result:gsub("\n+$", "")))
  else
    text = result
  end
  local function wrap(s, e)
    return s .. text .. e
  end
  local switches = args.results_switches and (" " .. args.results_switches) or ""
  if args.wrap ~= nil then
    local full = vim.trim(blocks_mod.unquote(args.wrap) or "")
    if full == "" then
      full = "results"
    end
    local split = vim.split(full, "%s+", { trimempty = true })
    local wtype = split[1]:lower()
    if wtype == "nil" or wtype == "no" then
      return text
    elseif wtype == "export" then
      return wrap("{{{results(@@" .. (split[2] or "none") .. ":", "@@)}}}")
    elseif wtype == "example" then
      return wrap("{{{results(=", "=)}}}")
    elseif wtype == "src" then
      local open
      if not split[2] then
        open = "{{{results(src_none{"
      elseif not split[3] then
        open = "{{{results(src_" .. split[2] .. "{"
      else
        open = "{{{results(src_" .. split[2] .. "[" .. table.concat(split, " ", 3) .. "]{"
      end
      return wrap(open, "})}}}")
    end
    return wrap("{{{results(", ")}}}")
  elseif rp.html then
    return wrap("{{{results(@@html:", "@@)}}}")
  elseif rp.latex then
    return wrap("{{{results(@@latex:", "@@)}}}")
  elseif rp.org then
    return wrap("{{{results(src_org{", "})}}}")
  elseif rp.code then
    return wrap("{{{results(src_" .. ((lang and lang ~= "") and lang or "none") .. "[" .. switches .. "]{", "})}}}")
  elseif rp.raw then
    return text
  elseif rp.file then
    return wrap("{{{results(", ")}}}")
  end
  local inline_wrap = (require("org.config").opts.babel or {}).inline_result_wrap or "=%s="
  return "{{{results(" .. inline_wrap:gsub("%%s", (text:gsub("%%", "%%%%"))) .. ")}}}"
end

--- Parse existing results lines back into a value (for :var references).
--- With `raw`, tables keep their header row and "hline" markers.
function M.read(lines, raw)
  if #lines == 0 then
    return ""
  end
  if lines[1]:match("^%s*|") then
    local t = require("org.table").parse(lines)
    local rows = {}
    local drop = not raw and #t.rows > 2 and t.rows[2].hline
    for i, r in ipairs(t.rows) do
      if r.hline then
        if raw then
          rows[#rows + 1] = "hline"
        end
      elseif not (drop and i == 1) then
        local cells = {}
        for j, c in ipairs(r.cells) do
          cells[j] = lisp.read(c, true)
        end
        rows[#rows + 1] = cells
      end
    end
    return rows
  end
  local out = {}
  local in_block = false
  for _, l in ipairs(lines) do
    if l:match("^%s*#%+[Bb][Ee][Gg][Ii][Nn]_") or l:match("^%s*:[Rr][Ee][Ss][Uu][Ll][Tt][Ss]:") then
      in_block = true
    elseif l:match("^%s*#%+[Ee][Nn][Dd]_") or l:match("^%s*:[Ee][Nn][Dd]:") then
      in_block = false
    elseif in_block then
      out[#out + 1] = l
    else
      local s = l:match("^%s*: (.*)$") or (l:match("^%s*:$") and "") or l:match("^%s*[-+] (.*)$") or l
      out[#out + 1] = s
    end
  end
  return table.concat(out, "\n")
end

return M
