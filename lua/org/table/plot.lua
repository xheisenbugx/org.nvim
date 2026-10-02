---@mod org.table.plot Plotting tables (Emacs org-plot and orgtbl-ascii-plot)
---
--- - `ascii_plot()` (C-c " a) adds a column with a bar plot of the numbers
---   of the current column, computed by a `'(orgtbl-ascii-draw ...)`
---   formula, so it follows the table when recalculated.
--- - `gnuplot()` (C-c " g, or C-c C-c on a `#+PLOT:` line) plots the
---   table with gnuplot (`plot_gnuplot_program`), using the `#+PLOT:`
---   options above it: title, ind, deps, type (2d, 3d, grid), with, file,
---   labels, line, set, map, script, timefmt, transpose, and for the radar
---   type (a spider chart; the first column names the axes) min, max and
---   ticks.

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

---------------------------------------------------------------------------
-- Radar plots (org--plot/radar)
---------------------------------------------------------------------------

--- `format "%s"` of an Emacs number.
local function num_str(v)
  if type(v) == "number" and v == math.floor(v) then
    return string.format("%d", v)
  end
  return tostring(v)
end

--- An Emacs float printed like `format "%s"` (`2.0`, `0.5`).
local function float_str(x)
  return require("org.babel.lisp").float_str(x)
end

--- Emacs string-to-number of a cell (an integer or a float).
local function cell_number(s)
  local n = require("org.table.formula").string_to_number(s or "")
  return n or 0
end

--- Rounding half to even, like Emacs `round` on floats.
local function round_even(x)
  local f = math.floor(x)
  local d = x - f
  if d > 0.5 or (d == 0.5 and f % 2 == 1) then
    return f + 1
  end
  return f
end

--- org--plot/values-stats: min, max and "nice" ends of the numbers.
local function values_stats(nums, hard_min, hard_max)
  local minimum, maximum = hard_min, hard_max
  if not minimum then
    minimum = math.huge
    for _, n in ipairs(nums) do
      minimum = math.min(minimum, n)
    end
  end
  if not maximum then
    maximum = -math.huge
    for _, n in ipairs(nums) do
      maximum = math.max(maximum, n)
    end
  end
  local range = maximum - minimum
  local order = range == 0 and 0 or math.ceil(1 - math.log10(range))
  local factor = 10 ^ order
  local nice_min, nice_max
  if range == 0 then
    nice_min, nice_max = nums[1], nums[1]
  else
    nice_min = { float = math.floor(minimum * factor) / factor }
    nice_max = { float = math.ceil(maximum * factor) / factor }
  end
  local function value(v)
    return type(v) == "table" and v.float or v
  end
  return {
    range_factor = factor,
    nice_min = nice_min,
    nice_max = nice_max,
    nice_range = value(nice_max) - value(nice_min),
  }
end

--- org--plot/prime-factors: the prime factors, largest first.
local function prime_factors(value)
  local factors, i = {}, 1
  while value > 1 do
    i = i + 1
    if value % i == 0 then
      table.insert(factors, 1, i)
      value = value / i
      i = i - 1
    end
  end
  return factors
end

--- org--plot/item-frequencies (normalized), in order of first appearance.
local function item_frequencies(values)
  local out, index = {}, {}
  for _, v in ipairs(values) do
    if not index[v] then
      out[#out + 1] = { v, 0 }
      index[v] = out[#out]
    end
    index[v][2] = index[v][2] + 1 / #values
  end
  return out
end

--- org--plot/merge-alists with + and 0 (key order of cl-union).
local function merge_alists(lists)
  if #lists == 1 then
    return lists[1]
  end
  local a1 = lists[1]
  local a2 = #lists > 2 and merge_alists(vim.list_slice(lists, 2)) or lists[2]
  local function lookup(key, alist)
    for _, p in ipairs(alist) do
      if p[1] == key then
        return p[2]
      end
    end
    return 0
  end
  local k1, k2 = {}, {}
  for _, p in ipairs(a1) do
    k1[#k1 + 1] = p[1]
  end
  for _, p in ipairs(a2) do
    k2[#k2 + 1] = p[1]
  end
  local keys
  if #k1 == 0 then
    keys = k2
  elseif #k2 == 0 or vim.deep_equal(k1, k2) then
    keys = k1
  else
    if #k1 < #k2 then
      k1, k2 = k2, k1
    end
    keys = {}
    for _, k in ipairs(k2) do
      if not vim.tbl_contains(k1, k) then
        keys[#keys + 1] = k
      end
    end
    vim.list_extend(keys, k1)
  end
  local out = {}
  for _, k in ipairs(keys) do
    out[#out + 1] = { k, lookup(k, a1) + lookup(k, a2) }
  end
  return out
end

--- org--plot/nice-frequency-pick.
local function nice_frequency_pick(freqs)
  if #freqs == 0 then
    return { 1 }
  elseif #freqs == 1 then
    return { freqs[1][1] }
  elseif #freqs == 2 then
    if freqs[1][2] / freqs[2][2] >= 3 then
      return { freqs[1][1], freqs[1][1] }
    end
    return { freqs[1][1], freqs[2][1] }
  end
  local total = 0
  for _, f in ipairs(freqs) do
    total = total + f[2]
  end
  local n = {}
  for i, f in ipairs(freqs) do
    n[i] = { f[1], f[2] / total }
  end
  local pick = { n[1][1] }
  local r12, r23 = n[1][2] / n[2][2], n[2][2] / n[3][2]
  local r13 = r12 * r23
  local function product()
    local p = 1
    for _, x in ipairs(pick) do
      p = p * x
    end
    return p
  end
  if r12 > 4 then
    table.insert(pick, 1, n[1][1])
  end
  if r12 < n[2][1] and product() * n[2][1] < 30 then
    table.insert(pick, 1, n[2][1])
  end
  if r13 < n[3][1] and product() * n[3][1] < 30 then
    table.insert(pick, 1, n[3][1])
  end
  return pick
end

--- org--plot/sensible-tick-num: a number of ticks for the rows' values.
local function sensible_tick_num(rows, hard_min, hard_max)
  local lists = {}
  for _, r in ipairs(rows) do
    local nums = {}
    for c = 2, #r do
      nums[#nums + 1] = cell_number(r[c])
    end
    local st = values_stats(nums, hard_min, hard_max)
    local val = round_even(st.range_factor * st.nice_range)
    if val % 10 == 0 then
      val = val / 10
    end
    lists[#lists + 1] = item_frequencies(prime_factors(val))
  end
  local weighted = merge_alists(lists)
  -- a stable sort by decreasing weight
  for i, p in ipairs(weighted) do
    p[3] = i
  end
  table.sort(weighted, function(a, b)
    if a[2] ~= b[2] then
      return a[2] > b[2]
    end
    return a[3] < b[3]
  end)
  local p = 1
  for _, x in ipairs(nice_frequency_pick(weighted)) do
    p = p * x
  end
  return p
end

local RADAR_TEMPLATE = [[
### spider plot/chart with gnuplot
# also known as: radar chart, web chart, star chart, cobweb chart,
#                radar plot,  web plot,  star plot,  cobweb plot,  etc. ...
set datafile separator ' '
set size square
unset tics
set angles degree
set key bmargin center horizontal
unset border

# Load data and setup
load "@SETUP@"

# General settings
DataColCount = words($Data[1])-1
AxesCount = |$Data|-HeaderLines-1
AngleOffset = 90
Max = 1
d=0.1*Max
Direction = -1   # counterclockwise=1, clockwise = -1

# Tic settings
TicCount = @TICKS@
TicOffset = 0.1
TicValue(axis,i) = real(i)*(word($Settings[axis],3)-word($Settings[axis],2)) \
	  / word($Settings[axis],4)+word($Settings[axis],2)
TicLabelPosX(axis,i) = PosX(axis,i/TicCount) + PosY(axis, TicOffset)
TicLabelPosY(axis,i) = PosY(axis,i/TicCount) - PosX(axis, TicOffset)
TicLen = 0.03
TicdX(axis,i) = 0.5*TicLen*cos(alpha(axis)-90)
TicdY(axis,i) = 0.5*TicLen*sin(alpha(axis)-90)

# Label
LabOffset = 0.10
LabX(axis) = PosX(axis+1,Max+2*d) + PosY(axis, LabOffset)
LabY(axis) = PosY($0+1,Max+2*d)

# Functions
alpha(axis) = (axis-1)*Direction*360.0/AxesCount+AngleOffset
PosX(axis,R) = R*cos(alpha(axis))
PosY(axis,R) = R*sin(alpha(axis))
Scale(axis,value) = real(value-word($Settings[axis],2))/(word($Settings[axis],3)-word($Settings[axis],2))

# Spider settings
set style arrow 1 dt 1 lw 1.0 @fgal head filled size 0.06,25     # style for axes
set style arrow 2 dt 2 lw 0.5 @fgal nohead   # style for weblines
set style arrow 3 dt 1 lw 1 @fgal nohead     # style for axis tics
set samples AxesCount
set isosamples TicCount
set urange[1:AxesCount]
set vrange[1:TicCount]
set style fill transparent solid 0.2

set xrange[-Max-4*d:Max+4*d]
set yrange[-Max-4*d:Max+4*d]
plot \
    '+' u (0):(0):(PosX($0,Max+d)):(PosY($0,Max+d)) w vec as 1 not, \
    $Data u (LabX($0)): \
	(LabY($0)):1 every ::HeaderLines w labels center enhanced @fgt not, \
    for [i=1:DataColCount] $Data u (PosX($0+1,Scale($0+1,column(i+1)))): \
	(PosY($0+1,Scale($0+1,column(i+1)))) every ::HeaderLines w filledcurves lt i title word($Data[1],i+1), \
@TICKLINES@
#    '++' u (PosX($1,$2/TicCount)-TicdX($1,$2/TicCount)): \
#        (PosY($1,$2/TicCount)-TicdY($1,$2/TicCount)): \
#        (2*TicdX($1,$2/TicCount)):(2*TicdY($1,$2/TicCount)) \
#        w vec as 3 not, \
### end of code
]]

local RADAR_TICKS = [[
    '++' u (PosX($1,$2/TicCount)):(PosY($1,$2/TicCount)): \
	(PosX($1+1,$2/TicCount)-PosX($1,$2/TicCount)):  \
	(PosY($1+1,$2/TicCount)-PosY($1,$2/TicCount)) w vec as 2 not, \
    '++' u (TicLabelPosX(@A@,$2)):(TicLabelPosY(@A@,$2)): \
	(sprintf('%g',TicValue(@A@,$2))) w labels font ',8' @fgat not]]

--- The setup text (data and per-axis scales) and the gnuplot code of a
--- radar plot of `rows` (the first cell of a row names its axis).
function M.radar(rows, opts)
  local labels = opts.labels or {}
  local closed = vim.list_extend(vim.deepcopy(rows), { rows[1] })
  local data = { '"' .. table.concat(labels, '" "') .. '"' }
  for _, r in ipairs(closed) do
    data[#data + 1] = string.format('"%s" %s', r[1] or "", table.concat(vim.list_slice(r, 2), " "))
  end
  local ymin, ymax = tonumber(opts.ymin), tonumber(opts.ymax)
  local ticks = tonumber(opts.ticks) or sensible_tick_num(rows, ymin, ymax)
  local tic_count = ticks == 0 and 2 or ticks
  local settings = {}
  for _, r in ipairs(closed) do
    local nums = {}
    for c = 2, #r do
      nums[#nums + 1] = cell_number(r[c])
    end
    local st = values_stats(nums)
    local function show(v)
      return type(v) == "table" and float_str(v.float) or num_str(v)
    end
    settings[#settings + 1] = string.format(
      '"%s" %s %s %s',
      r[1] or "",
      ymin and num_str(ymin) or show(st.nice_min),
      ymax and num_str(ymax) or show(st.nice_max),
      num_str(tic_count)
    )
  end
  local setup = "# Data\n$Data <<HEREHAVESOMEDATA\n"
    .. table.concat(data, "\n")
    .. "\nHEREHAVESOMEDATA\nHeaderLines = 1\n\n"
    .. "# Settings for scale and offset adjustments\n"
    .. "# axis min max tics axisLabelXoff axisLabelYoff\n"
    .. "$Settings <<EOD\n"
    .. table.concat(settings, "\n")
    .. "\nEOD\n"
  local axis = (ymin and ymax) and "1" or "$1"
  -- lint: allow gsub: "1" or "$1"
  local tick_lines = ticks == 0 and "" or RADAR_TICKS:gsub("@A@", axis)
  local setup_file = opts.setup_file or (vim.fn.tempname() .. "-org-plot-setup")
  local code = RADAR_TEMPLATE:gsub("@SETUP@", function()
    return setup_file
  end)
    :gsub("@TICKS@", function()
      return num_str(tic_count)
    end)
    :gsub("@TICKLINES@", function()
      return tick_lines
    end)
  return code, setup, setup_file
end

--- A plot type of `plot_preset_plot_types` (org-plot/preset-plot-types).
function M.custom_type(name)
  local types = require("org.config").opts.plot_preset_plot_types or {}
  return types[name]
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
  local custom = M.custom_type(ptype)
  local plot_str = custom and custom.plot_str or "'%s' using %s%d%s with %s title '%s'"
  if custom then
    local pre = custom.plot_pre
    if type(pre) == "function" then
      pre = pre(rows, data_file, ncols, opts, plot_str)
    end
    add(pre)
  elseif ptype == "3d" and opts.map then
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
  if custom then
    if custom.plot_func then
      plot_lines = custom.plot_func(rows, data_file, ncols, opts, plot_str) or {}
    end
    add((custom.plot_cmd and (custom.plot_cmd .. " ") or "") .. table.concat(plot_lines, ",\\\n    "))
  elseif ptype == "2d" then
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
  elseif ptype == "radar" then
    local code, setup, setup_file = M.radar(rows, opts)
    local fh = io.open(setup_file, "wb")
    if fh then
      fh:write(setup)
      fh:close()
    end
    add(code)
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
  local custom = M.custom_type(ptype)
  if not custom and ptype ~= "2d" and ptype ~= "3d" and ptype ~= "grid" and ptype ~= "radar" then
    utils.warn("Org-plot type `" .. ptype .. "' is undefined")
    return false
  end
  local data_file = vim.fn.tempname() .. "-org-plot"
  local data
  if custom and custom.data_dump then
    data = custom.data_dump(rows, data_file, ncols, opts) or M.data(rows, opts)
  elseif ptype == "grid" then
    local ylabels
    data, ylabels = M.grid_data(rows, opts)
    opts.ylabels = ylabels
  else
    data = M.data(rows, opts)
  end
  -- the type of the independent column: timestamps or text
  if (custom and custom.check_ind_type) or (not custom and ptype == "2d") then
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
    script = script .. "\n" .. table.concat(user, "\n"):gsub("%$datafile", utils.gsub_escape(data_file))
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
