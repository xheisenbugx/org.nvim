---@mod org.table.plot Plotting tables (Emacs org-plot and orgtbl-ascii-plot)
---
--- - `ascii_plot()` (C-c " a) adds a column with a bar plot of the numbers
---   of the current column, computed by a `'(orgtbl-ascii-draw ...)`
---   formula, so it follows the table when recalculated.
--- - `gnuplot()` (C-c " g, or C-c C-c on a `#+PLOT:` line) plots the
---   table with gnuplot (`plot_gnuplot_program`), using the `#+PLOT:`
---   options above it: title, ind, deps, type (2d, 3d, grid), with, file,
---   labels, line, set, map, script, timefmt, transpose. The radar type of
---   Emacs is not supported.

local utils = require("org.utils")

local M = {}

local function tbl()
  return require("org.table")
end

---------------------------------------------------------------------------
-- ASCII plot
---------------------------------------------------------------------------

--- Add a column right of the current one with an ASCII bar plot of its
--- numbers (12 characters wide; a count gives the width, count 4 asks).
--- Emacs orgtbl-ascii-plot.
---@param width? integer
function M.ascii_plot(width)
  local count = vim.v.count
  if not width then
    if count == 4 then
      local w = utils.input({ prompt = "Length of column: ", default = "12" })
      width = tonumber(w or "")
      if not width then
        return
      end
    elseif count > 0 then
      width = count
    else
      width = 12
    end
  end
  local info = tbl().at_cursor()
  if not info then
    utils.warn("Not in a table")
    return false
  end
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local rows = require("org.table.orgtbl").to_lisp(info.lines)
  while rows[1] == "hline" do
    table.remove(rows, 1)
  end
  local line = vim.api.nvim_get_current_line()
  local col = 0
  local c1 = vim.api.nvim_win_get_cursor(0)[2] + 1
  for i = 1, c1 - 1 do
    if line:sub(i, i) == "|" then
      col = col + 1
    end
  end
  col = math.max(col, 1)
  -- skip the header (rows before the first hline) when there is one
  local start = 1
  for i, r in ipairs(rows) do
    if r == "hline" then
      start = i + 1
      break
    end
  end
  local min, max = math.huge, -math.huge
  for i = start, #rows do
    local r = rows[i]
    if r ~= "hline" then
      local x = r[col] or ""
      if x:match("^[-+]?%d*%.?%d*$") or x:match("^[-+]?%d*%.?%d*[eE][-+]?%d+$") then
        local n = require("org.table.formula").string_to_number(x)
        min, max = math.min(min, n), math.max(max, n)
      end
    end
  end
  local f = require("org.table.formula")
  local function num(n)
    if n == math.huge or n == -math.huge then
      return f.number_to_string(n, true)
    end
    return f.number_to_string(n, n ~= math.floor(n))
  end
  vim.api.nvim_win_set_cursor(0, { lnum, c1 - 1 })
  tbl().insert_column()
  tbl().move_column(1)
  info = tbl().find(0, lnum)
  local parts = tbl().formula_parts(0, info)
  table.insert(
    parts,
    1,
    string.format("$%d='(%s $%d %s %s %d)", col + 1, "orgtbl-ascii-draw", col, num(min), num(max), width)
  )
  tbl()._write_formulas(0, info, parts)
  tbl().recalc(0, lnum)
  return true
end

---------------------------------------------------------------------------
-- gnuplot
---------------------------------------------------------------------------

M.default_options = { plot_type = "2d", with = "lines", ind = 0 }

local OPTION_KEYS = {
  { "type", "plot_type" },
  { "script", "script" },
  { "line", "line" },
  { "set", "set" },
  { "title", "title" },
  { "ind", "ind" },
  { "deps", "deps" },
  { "with", "with" },
  { "file", "file" },
  { "labels", "labels" },
  { "map", "map" },
  { "timeind", "timeind" },
  { "timefmt", "timefmt" },
  { "min", "ymin" },
  { "ymin", "ymin" },
  { "max", "ymax" },
  { "ymax", "ymax" },
  { "xmin", "xmin" },
  { "xmax", "xmax" },
  { "ticks", "ticks" },
  { "trans", "transpose" },
  { "transpose", "transpose" },
}

--- A value of a #+PLOT: option: "string", (list) or a word/number.
local function read_value(v)
  if v:match('^".*"$') then
    return v:sub(2, -2)
  elseif v:match("^%(.*%)$") then
    local out = {}
    for item in v:sub(2, -2):gmatch('"[^"]*"') do
      out[#out + 1] = item:sub(2, -2)
    end
    if #out == 0 then
      for item in v:sub(2, -2):gmatch("%S+") do
        out[#out + 1] = tonumber(item) or item
      end
    end
    return out
  end
  return tonumber(v) or v
end

--- Parse a `#+PLOT:` options string into `opts` (org-plot/add-options-to-plist).
function M.parse_options(opts, str)
  opts = opts or {}
  for _, o in ipairs(OPTION_KEYS) do
    local key, field = o[1], o[2]
    local multiple = key == "set" or key == "line"
    local init = 1
    while true do
      local a, b = str:find(key .. ":", init, true)
      if not a then
        break
      end
      local rest = str:sub(b + 1)
      local v = rest:match('^("[^"]-")') or rest:match("^(%([^%)]-%))") or rest:match("^([^ \t\n\r;,.]*)")
      if multiple then
        opts[field] = opts[field] or {}
        table.insert(opts[field], 1, read_value(v))
        init = b + 1 + #v
      else
        opts[field] = read_value(v)
        break
      end
    end
  end
  return opts
end

--- Quote a field for the gnuplot data file (org-plot-quote-tsv-field).
local function quote_field(s, timefmt)
  if tbl().is_number(s) then
    return s
  end
  local item = require("org.date").parse_all(s)[1]
  if item then
    return os.date(timefmt or "%Y-%m-%d-%H:%M:%S", item.date:to_time())
  end
  return '"' .. s:gsub('"', '""') .. '"'
end

--- The gnuplot data file text of `rows` (org-plot/gnuplot-to-data).
function M.data(rows, opts)
  return require("org.table.orgtbl").generic(rows, {
    sep = "\t",
    fmt = function(s)
      return quote_field(s, opts.timefmt)
    end,
  })
end

--- Data file text for the grid type (org-plot/gnuplot-to-grid-data).
--- Returns the text and the y labels.
function M.grid_data(rows, opts)
  local ind = (tonumber(opts.ind) or 0) - 1
  local deps
  if type(opts.deps) == "table" then
    deps = {}
    for _, d in ipairs(opts.deps) do
      deps[#deps + 1] = d - 1
    end
  else
    deps = {}
    for c = #(rows[1] or {}) - 1, 0, -1 do
      deps[#deps + 1] = c
    end
  end
  local ylabels
  if ind >= 0 then
    ylabels = {}
    for i, r in ipairs(rows) do
      ylabels[#ylabels + 1] = { i, r[ind + 1] }
    end
  end
  local keep = {}
  for _, d in ipairs(deps) do
    if d ~= ind then
      keep[d] = true
    end
  end
  local t = {}
  for i, r in ipairs(rows) do
    t[i] = {}
    for c = 0, #r - 1 do
      if keep[c] then
        t[i][#t[i] + 1] = r[c + 1]
      end
    end
  end
  local f = require("org.table.formula")
  local out = {}
  local function row_text(col, row, value)
    col, row = col + 1, row + 1
    return string.format("%f  %f  %f\n%f  %f  %f\n", col, row - 0.5, value, col, row + 0.5, value)
  end
  local ncols = #(t[1] or {})
  for col = 0, ncols - 1 do
    local back, front = {}, {}
    for row = 0, #t - 1 do
      local v = f.string_to_number(t[row + 1][col + 1] or "")
      back[#back + 1] = row_text(col - 1, row, v)
      front[#front + 1] = row_text(col, row, v)
    end
    out[#out + 1] = table.concat(back) .. "\n" .. table.concat(front) .. "\n"
  end
  return table.concat(out), ylabels
end

--- The gnuplot script for `rows` (org-plot/gnuplot-script).
function M.script(rows, data_file, ncols, opts)
  local lines = { "reset" }
  local function add(l)
    if l then
      lines[#lines + 1] = l
    end
  end
  local file = opts.file
  local cfg = require("org.config").opts
  add(
    string.format(
      "set term %s %s",
      file and (tostring(file):match("%.(%w+)$") or "") or "GNUTERM",
      cfg.plot_gnuplot_term_extra or ""
    )
  )
  if file then
    add(string.format("set output '%s'", vim.fn.fnamemodify(tostring(file), ":p")))
  end
  local ptype = tostring(opts.plot_type)
  if ptype == "3d" and opts.map then
    add("set map")
  elseif ptype == "grid" then
    add(opts.map and "set pm3d map" or "set map")
  end
  add(cfg.plot_gnuplot_script_preamble or "")
  if opts.title then
    add(string.format("set title '%s'", opts.title))
  end
  for _, l in ipairs(opts.line or {}) do
    add(l)
  end
  for _, s in ipairs(opts.set or {}) do
    add("set " .. s)
  end
  if not table.concat(lines, "\n"):find("\nset datafile separator") then
    add('set datafile separator "\\t"')
  end
  if opts.ylabels then
    local parts = {}
    for _, p in ipairs(opts.ylabels) do
      parts[#parts + 1] = string.format('"%s" %d', p[2], p[1])
    end
    add(string.format("set ytics (%s)", table.concat(parts, ", ")))
  end
  if opts.timeind then
    add("set xdata time")
    add('set timefmt "' .. (opts.timefmt or "%Y-%m-%d-%H:%M:%S") .. '"')
  end
  if opts.script then
    return table.concat(lines, "\n")
  end
  local plot_lines = {}
  if ptype == "2d" then
    local ind = tonumber(opts.ind)
    local deps = type(opts.deps) == "table" and opts.deps or nil
    local text_ind = opts.textind or opts.with == "histograms"
    for col = 0, ncols - 1 do
      local skip = (ind and ind == col + 1) or (deps and not vim.tbl_contains(deps, col + 1))
      if not skip then
        plot_lines[#plot_lines + 1] = string.format(
          "'%s' using %s%d%s with %s title '%s'",
          data_file,
          (ind and ind > 0 and not text_ind) and (ind .. ":") or "",
          col + 1,
          text_ind and string.format(":xticlabel(%d)", ind) or "",
          tostring(opts.with),
          (opts.labels or {})[col + 1] or tostring(col + 1)
        )
      end
    end
    add("plot " .. table.concat(plot_lines, ",\\\n    "))
  elseif ptype == "3d" then
    add(string.format("splot '%s' matrix with %s title ''", data_file, tostring(opts.with)))
  elseif ptype == "grid" then
    add(string.format("splot '%s' with pm3d title ''", data_file))
  else
    error("Org-plot type `" .. ptype .. "' is undefined")
  end
  return table.concat(lines, "\n")
end

--- Options (from `#+PLOT:` lines above it) and rows of the table at
--- `lnum`, or of the table following a `#+PLOT:` line.
function M.collect(bufnr, lnum)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local l = lnum
  while lines[l] and not tbl().is_table_line(lines[l]) do
    l = l + 1
  end
  if not lines[l] then
    return nil
  end
  local info = tbl().find(bufnr, l)
  local opts = vim.deepcopy(M.default_options)
  local k = info.start - 1
  local plots = {}
  while k >= 1 and lines[k]:match("^%s*#%+") do
    local o = lines[k]:match("^%s*#%+[Pp][Ll][Oo][Tt]: +(.*)$")
    if o then
      table.insert(plots, 1, o)
    end
    k = k - 1
  end
  for _, o in ipairs(plots) do
    M.parse_options(opts, o)
  end
  local rows = require("org.table.orgtbl").to_lisp(info.lines)
  local tr = opts.transpose
  if tr == "y" or tr == "yes" or tr == "t" or tr == true then
    local data = vim.tbl_filter(function(r)
      return r ~= "hline"
    end, rows)
    local had_hline = #data ~= #rows
    local t = {}
    for c = 1, #(data[1] or {}) do
      local row = {}
      for i, r in ipairs(data) do
        row[i] = r[c] or ""
      end
      t[#t + 1] = row
    end
    rows = t
    if had_hline then
      table.insert(rows, 2, "hline")
    end
  end
  local ncols = #(rows[1] == "hline" and rows[2] or rows[1] or {})
  if rows[2] == "hline" then
    opts.labels = opts.labels or rows[1]
    local data = {}
    for i = 3, #rows do
      if rows[i] ~= "hline" then
        data[#data + 1] = rows[i]
      end
    end
    rows = data
  end
  return opts, rows, ncols
end

--- Plot the table at the cursor with gnuplot. Emacs org-plot/gnuplot.
function M.gnuplot(bufnr, lnum)
  bufnr = (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
  lnum = lnum or vim.api.nvim_win_get_cursor(0)[1]
  local prog = require("org.config").opts.plot_gnuplot_program or "gnuplot"
  local opts, rows, ncols = M.collect(bufnr, lnum)
  if not opts then
    utils.warn("No table to plot")
    return false
  end
  local ptype = tostring(opts.plot_type)
  if ptype ~= "2d" and ptype ~= "3d" and ptype ~= "grid" then
    utils.warn("Org-plot type `" .. ptype .. "' is not supported")
    return false
  end
  local data_file = vim.fn.tempname() .. "-org-plot"
  local data
  if ptype == "grid" then
    local ylabels
    data, ylabels = M.grid_data(rows, opts)
    opts.ylabels = ylabels
  else
    data = M.data(rows, opts)
  end
  -- the type of the independent column: timestamps or text
  if ptype == "2d" then
    local ind = (tonumber(opts.ind) or 0)
    if ind > 0 then
      local all_ts, all_num = true, true
      for _, r in ipairs(rows) do
        local v = r[ind] or ""
        all_ts = all_ts and require("org.date").parse_all(v)[1] ~= nil
        all_num = all_num and tbl().is_number(v)
      end
      if all_ts then
        opts.timeind = true
      elseif opts.with == "hist" or not all_num then
        opts.textind = true
      end
    end
  end
  utils.writefile(data_file, vim.split(data, "\n", { plain = true }))
  local script = M.script(rows, data_file, ncols, opts)
  if opts.script then
    local user = utils.readfile(vim.fn.fnamemodify(tostring(opts.script), ":p")) or {}
    script = script .. "\n" .. table.concat(user, "\n"):gsub("%$datafile", data_file)
  end
  local script_file = vim.fn.tempname() .. ".gp"
  utils.writefile(script_file, vim.split(script, "\n", { plain = true }))
  M.last_script = script
  if vim.fn.executable(prog) ~= 1 then
    utils.warn("Cannot plot: " .. prog .. " is not installed (plot_gnuplot_program)")
    return false
  end
  vim.system({ prog, "-persist", script_file }, { text = true }, function(res)
    if res.code ~= 0 then
      vim.schedule(function()
        utils.warn("gnuplot: " .. vim.trim(res.stderr or ""))
      end)
    end
  end)
  return true
end

return M
