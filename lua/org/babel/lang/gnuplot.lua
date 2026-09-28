---@mod org.babel.lang.gnuplot gnuplot blocks (ob-gnuplot)
---
--- Table variables are written to data files (like the table plots of
--- `org.table.plot`) whose names replace `$name` in the body.

local ob = require("org.babel.ob")
local lisp = require("org.babel.lisp")

local M = {}

--- `org-babel-gnuplot-quote-tsv-field`
local function quote_field(v, missing)
  local s = type(v) == "string" and v or lisp.princ(v)
  if require("org.table").is_number(s) then
    return s
  end
  local item = s:match("^[<%[]%d%d%d%d%-%d%d%-%d%d") and require("org.date").parse_all(s)[1]
  if item then
    return os.date("%Y-%m-%d-%H:%M:%S", item.date:to_time())
  end
  if s == "" then
    return missing or s
  end
  if s:find('[ "]') then
    return '"' .. s:gsub('"', '""') .. '"'
  end
  return s
end

--- `org-babel-gnuplot-table-to-data`: the rows as tab-separated lines.
local function table_to_data(rows, missing)
  local out = {}
  for _, row in ipairs(rows) do
    if row ~= "hline" then
      local cells = {}
      for i, c in ipairs(lisp.is_list(row) and row or { row }) do
        cells[i] = quote_field(c, missing)
      end
      out[#out + 1] = table.concat(cells, "\t")
    end
  end
  return table.concat(out, "\n")
end

--- `org-babel-gnuplot-process-vars`: lists are written to data files
--- (stable names, so :cache keeps working).
local function process_vars(vars, args)
  local missing = ob.unq(args.missing)
  local out = {}
  for _, v in ipairs(vars) do
    local val = v.value
    if lisp.is_list(val) then
      local rows = val
      local first = val[1]
      if not (lisp.is_list(first) or first == "hline" or first == nil) then
        rows = {}
        for i, x in ipairs(val) do
          rows[i] = { x }
        end
      end
      local text = table_to_data(rows, missing)
      local file = vim.fn.fnamemodify(vim.fn.tempname(), ":h")
        .. "/gnuplot-"
        .. vim.fn.sha256(text .. "\0" .. vim.inspect(args)):sub(1, 16)
      ob.write(file, text)
      out[#out + 1] = { name = v.name, value = file }
    else
      out[#out + 1] = { name = v.name, value = type(val) == "string" and val or lisp.princ(val) }
    end
  end
  return out
end

--- A list header argument (`:set '("grid" "key off")`), as strings.
local function list_arg(v)
  local r = ob.list_or_string(v)
  if r == nil then
    return nil
  end
  if type(r) == "string" then
    return { r }
  end
  local out = {}
  for i, x in ipairs(r) do
    out[i] = lisp.princ(x)
  end
  return out
end

--- `:xlabels '((1 . "one") (2 . "two"))` as `"one" 1, "two" 2`.
local function labels(v)
  local s = ob.unq(v)
  local parts = {}
  for n, label in s:gmatch('%(%s*(%-?%d+)%s*%.%s*"([^"]*)"%s*%)') do
    parts[#parts + 1] = string.format('"%s" %d', label, tonumber(n))
  end
  return table.concat(parts, ", ")
end

---@param dir? string the block's directory (default-directory)
function M.expand(body, args, vars, _, dir)
  local text = ob.body_text(body)
  local pvars = process_vars(vars, args)
  local out_file = ob.unq(args.file)
  local term = ob.unq(args.term)
  if not term and out_file then
    local ext = (out_file:match("%.([^./]+)$") or ""):lower()
    local terms = (ob.opts("gnuplot") or {}).terms or {}
    term = terms[ext] or ext
  end
  local timefmt = ob.unq(args.timefmt)
  local time_ind = args.timeind or (timefmt and 1)
  local function add(s)
    text = s .. "\n" .. text
  end
  if args.missing then
    add(string.format("set datafile missing '%s'", ob.unq(args.missing)))
  end
  if args.title then
    add(string.format("set title '%s'", ob.unq(args.title)))
  end
  for _, l in ipairs(list_arg(args.line) or {}) do
    add(l)
  end
  for _, l in ipairs(list_arg(args.set) or {}) do
    add("set " .. l)
  end
  if args.xlabels then
    add(string.format("set xtics (%s)", labels(args.xlabels)))
  end
  if args.ylabels then
    add(string.format("set ytics (%s)", labels(args.ylabels)))
  end
  if time_ind then
    add("set xdata time")
    add('set timefmt "' .. (timefmt or "%Y-%m-%d-%H:%M:%S") .. '"')
  end
  if out_file then
    add(string.format('set output "%s"', out_file))
    text = text .. "\nset output\n"
  end
  if term then
    add("set term " .. term)
  end
  local assigns = {}
  for i, v in ipairs(pvars) do
    assigns[i] = string.format('%s = "%s"', v.name, v.value)
  end
  add(table.concat(assigns, "\n"))
  for _, v in ipairs(pvars) do
    text = text:gsub("%$" .. vim.pesc(v.name), (v.value:gsub("%%", "%%%%")))
  end
  if args.prologue then
    add(ob.unq(args.prologue))
  end
  if args.epilogue then
    text = text .. "\n" .. ob.unq(args.epilogue)
  end
  dir = dir or ob.default_directory(args)
  add(string.format("cd '%s'", dir:sub(-1) == "/" and dir or (dir .. "/")))
  return text
end

function M.prepare(body, args, vars, ctx)
  local o = ctx.opts
  -- the script starts with `cd` to the block's directory
  local script = ob.write(ob.temp(), M.expand(body, args, vars, nil, ctx.cwd) .. "\n")
  local output = args.results_spec.collection == "output"
  return {
    steps = { { cmd = string.format('%s "%s" 2>&1', o.cmd or "gnuplot", script) } },
    convert = function(raw)
      if output then
        return raw
      end
      return nil
    end,
  }
end

return M
