---@mod org.babel.results Formatting of evaluation results

local blocks_mod = require("org.babel.blocks")

local M = {}

local function is_matrix(v)
  if type(v) ~= "table" or #v == 0 then
    return false
  end
  for _, row in ipairs(v) do
    if type(row) ~= "table" and row ~= "hline" then
      return false
    end
  end
  return true
end

local function stringify(v)
  if type(v) == "table" then
    if vim.islist(v) then
      local parts = {}
      for i, x in ipairs(v) do
        parts[i] = stringify(x)
      end
      return "(" .. table.concat(parts, " ") .. ")"
    end
    return vim.inspect(v)
  elseif type(v) == "number" then
    if v == math.floor(v) and math.abs(v) < 1e15 then
      return string.format("%d", v)
    end
    return tostring(v)
  elseif v == nil or v == vim.NIL then
    return ""
  end
  return tostring(v)
end
M.stringify = stringify

--- Split plain text into table rows (tabs, or runs of whitespace).
local function text_to_rows(text)
  local rows = {}
  for _, l in ipairs(vim.split(text, "\n", { plain = true })) do
    if l:match("%S") then
      if l:find("\t") then
        rows[#rows + 1] = vim.split(l, "\t", { plain = true })
      else
        rows[#rows + 1] = vim.split(vim.trim(l), "%s+")
      end
    end
  end
  return rows
end

--- Produce the lines to insert after `#+RESULTS:` (unindented).
---@param result { value?: any, text?: string }
---@param args table merged header args
---@param lang string
---@return string[]|nil lines (nil = silent)
function M.format(result, args, lang)
  local spec = args.results_spec or {}
  local cfg = require("org.config").opts.babel or {}
  local min_lines = cfg.min_lines_for_block_output or 10
  local v = result.value
  if v == nil or v == vim.NIL then
    v = result.text or ""
  end

  -- file results: link to the file
  if spec.type == "file" or (args.file and spec.format ~= "raw") then
    local path = blocks_mod.unquote(args.file)
    if path then
      local desc = args["file-desc"]
      if desc and desc ~= "" then
        return { string.format("[[file:%s][%s]]", path, blocks_mod.unquote(desc)) }
      end
      return { string.format("[[file:%s]]", path) }
    end
    return { stringify(v) }
  end

  local body
  local is_table_like = false
  if type(v) == "table" and spec.type ~= "verbatim" and spec.type ~= "scalar" then
    if spec.type == "list" then
      body = {}
      for _, x in ipairs(v) do
        body[#body + 1] = "- " .. stringify(x)
      end
    else
      local rows = is_matrix(v) and v or { v }
      if not vim.islist(v) then
        rows = {}
        for k, x in pairs(v) do
          rows[#rows + 1] = { tostring(k), stringify(x) }
        end
        table.sort(rows, function(a, b)
          return a[1] < b[1]
        end)
      end
      local norm = {}
      for i, row in ipairs(rows) do
        if row == "hline" then
          norm[i] = "hline"
        else
          local cells = {}
          for j, c in ipairs(row) do
            cells[j] = stringify(c)
          end
          norm[i] = cells
        end
      end
      body = require("org.table").rows_to_lines(norm, "")
      is_table_like = true
    end
  else
    local text = type(v) == "table" and stringify(v) or stringify(v)
    text = text:gsub("\n+$", "")
    if spec.type == "table" or spec.type == "vector" then
      body = require("org.table").rows_to_lines(text_to_rows(text), "")
      is_table_like = true
    elseif spec.type == "list" then
      body = {}
      for _, l in ipairs(vim.split(text, "\n", { plain = true })) do
        if l:match("%S") then
          body[#body + 1] = "- " .. l
        end
      end
      is_table_like = true
    else
      body = text == "" and {} or vim.split(text, "\n", { plain = true })
    end
  end

  local fmt = spec.format
  -- :wrap [type [params]] wraps the raw result in a #+begin_TYPE block
  local wrap = args.wrap
  if wrap then
    wrap = vim.trim(blocks_mod.unquote(wrap) or "")
    if wrap == "" then
      wrap = "results"
    end
    local wtype = wrap:match("^(%S+)")
    if wtype:lower() == "no" or wtype:lower() == "nil" then
      return body
    end
    local verbatim = ({ export = true, example = true, src = true })[wtype:lower()]
    local inner = verbatim and blocks_mod.escape(body) or body
    return vim.list_extend(vim.list_extend({ "#+begin_" .. wrap }, inner), { "#+end_" .. wtype })
  end
  if fmt == "raw" then
    return body
  elseif fmt == "org" then
    return vim.list_extend(vim.list_extend({ "#+begin_src org" }, blocks_mod.escape(body)), { "#+end_src" })
  elseif fmt == "drawer" then
    return vim.list_extend(vim.list_extend({ ":RESULTS:" }, body), { ":END:" })
  elseif fmt == "html" or fmt == "latex" then
    return vim.list_extend(vim.list_extend({ "#+begin_export " .. fmt }, body), { "#+end_export" })
  elseif fmt == "code" then
    return vim.list_extend(vim.list_extend({ "#+begin_src " .. (lang or "") }, blocks_mod.escape(body)), { "#+end_src" })
  end
  if is_table_like then
    return body
  end
  -- verbatim
  if #body == 0 then
    return {}
  end
  if #body >= min_lines then
    return vim.list_extend(vim.list_extend({ "#+begin_example" }, blocks_mod.escape(body)), { "#+end_example" })
  end
  local out = {}
  for i, l in ipairs(body) do
    out[i] = l == "" and ":" or (": " .. l)
  end
  return out
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
        rows[#rows + 1] = r.cells
      end
    end
    return rows
  end
  local out = {}
  local in_block = false
  for _, l in ipairs(lines) do
    if l:match("^%s*#%+[Bb][Ee][Gg][Ii][Nn]_") or l:match("^%s*:RESULTS:") then
      in_block = true
    elseif l:match("^%s*#%+[Ee][Nn][Dd]_") or l:match("^%s*:END:") then
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
