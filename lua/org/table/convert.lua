---@mod org.table.convert Creating, importing and exporting tables
---
--- C-c | (create or convert the region), org-table-import and
--- org-table-export.
---
--- Part of org.table, which loads it.

local utils = require("org.utils")
local shared = require("org.table.shared")

local M = require("org.table")

local empty_row = shared.empty_row
local is_table_line = shared.is_table_line
local pad_rows = shared.pad_rows

---------------------------------------------------------------------------
-- Creation / conversion
---------------------------------------------------------------------------

local function split_csv(line)
  local out, i, n = {}, 1, #line
  while i <= n + 1 do
    local c = line:sub(i, i)
    if c == '"' then
      local buf = {}
      i = i + 1
      while i <= n do
        local ch = line:sub(i, i)
        if ch == '"' then
          if line:sub(i + 1, i + 1) == '"' then
            buf[#buf + 1] = '"'
            i = i + 2
          else
            i = i + 1
            break
          end
        else
          buf[#buf + 1] = ch
          i = i + 1
        end
      end
      out[#out + 1] = table.concat(buf)
      -- skip to comma
      local nxt = line:find(",", i, true)
      i = (nxt or n + 1) + 1
    else
      local nxt = line:find(",", i, true)
      out[#out + 1] = vim.trim(line:sub(i, (nxt or n + 1) - 1))
      i = (nxt or n + 1) + 1
    end
  end
  return out
end

--- Convert lines of CSV/TSV/whitespace data into table lines.
---@param sep? "tab"|"csv"|"space"|integer an integer N splits on N+ spaces or tabs
function M.convert_lines(lines, sep)
  local indent = (lines[1] or ""):match("^(%s*)")
  if not sep then
    local joined = table.concat(lines, "\n")
    if joined:find("\t") then
      sep = "tab"
    elseif joined:find(",") then
      sep = "csv"
    else
      sep = "space"
    end
  end
  local t = { indent = indent, rows = {}, ncols = 1 }
  for _, l in ipairs(lines) do
    if not l:match("^%s*$") then
      local cells
      if sep == "tab" then
        cells = vim.split(vim.trim(l), "\t", { plain = true })
      elseif sep == "csv" then
        cells = split_csv(vim.trim(l))
      elseif type(sep) == "number" then
        -- N or more spaces, or a tab (Emacs C-N C-c |)
        cells = vim.split((vim.trim(l):gsub(string.rep(" ", sep) .. "+", "\t")), "%s*\t%s*")
      else
        cells = vim.split(vim.trim(l), "%s+")
      end
      for i, c in ipairs(cells) do
        cells[i] = vim.trim(c):gsub("|", "\\vert{}")
      end
      t.rows[#t.rows + 1] = { cells = cells }
      t.ncols = math.max(t.ncols, #cells)
    end
  end
  pad_rows(t)
  return M.render(t)
end

--- Separator for a count given to a conversion command, like Emacs'
--- prefix argument: 4 (C-u) comma, 16 (C-u C-u) tab, another N that many
--- spaces (or a tab); no count guesses from the data.
function M.separator_for_count(count)
  if not count or count == 0 then
    return nil
  elseif count == 4 then
    return "csv"
  elseif count == 16 then
    return "tab"
  end
  return count
end

--- Refuse to convert more than table_convert_region_max_lines lines
--- (org-table-convert-region-max-lines).
local function too_long(n)
  local max = require("org.config").opts.table_convert_region_max_lines
  if max and n > max then
    utils.warn(string.format("Region is longer than `table_convert_region_max_lines' (%d) lines; not converting", max))
    return true
  end
  return false
end

--- Create an empty table (normal mode) or convert the visual selection.
function M.create_or_convert()
  local mode = vim.fn.mode()
  if mode == "v" or mode == "V" or mode == "\22" then
    local sep = M.separator_for_count(vim.v.count)
    local srow, _, erow = utils.visual_range()
    utils.exit_visual()
    if too_long(erow - srow + 1) then
      return
    end
    local lines = vim.api.nvim_buf_get_lines(0, srow - 1, erow, false)
    vim.api.nvim_buf_set_lines(0, srow - 1, erow, false, M.convert_lines(lines, sep))
    return
  end
  local line = vim.api.nvim_get_current_line()
  if is_table_line(line) then
    return M.align()
  end
  -- org-table-default-size
  local default = require("org.config").opts.table_default_size or "5x2"
  local size = utils.input({ prompt = "Table size Columns x Rows [e.g. " .. default .. "]: ", default = default })
  if not size then
    return
  end
  if vim.trim(size) == "" then
    size = default
  end
  local cols, rows = size:match("^%s*(%d+)%s*[xX]%s*(%d+)%s*$")
  cols, rows = tonumber(cols), tonumber(rows)
  if not cols or cols < 1 or rows < 1 then
    utils.warn("Invalid table size: " .. size)
    return
  end
  local t = { indent = line:match("^(%s*)"), rows = {}, ncols = cols }
  for r = 1, rows do
    t.rows[#t.rows + 1] = empty_row(cols)
    if r == 1 and rows > 1 then
      t.rows[#t.rows + 1] = { hline = true }
    end
  end
  local lines = M.render(t)
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local at = line:match("^%s*$") and lnum - 1 or lnum
  if line:match("^%s*$") then
    vim.api.nvim_buf_set_lines(0, at, at + 1, false, lines)
  else
    vim.api.nvim_buf_set_lines(0, at, at, false, lines)
  end
  vim.api.nvim_win_set_cursor(0, { at + 1, #t.indent + 2 })
end

--- Insert a CSV/TSV/whitespace separated file as a table below the cursor
--- line (replacing it when blank). The separator is guessed unless given
--- (or set with a count, see `separator_for_count`). Emacs org-table-import.
---@param path? string
---@param sep? "tab"|"csv"|"space"|integer
function M.import(path, sep)
  sep = sep or M.separator_for_count(vim.v.count)
  path = path or utils.input({ prompt = "Import table from file: ", completion = "file" })
  if not path or vim.trim(path) == "" then
    return
  end
  -- lint: allow expand: a file the user typed
  path = vim.fn.fnamemodify(vim.fn.expand(vim.trim(path)), ":p")
  local data = utils.readfile(path)
  if not data then
    utils.warn("Cannot read file: " .. path)
    return
  end
  if too_long(#data) then
    return
  end
  local lines = M.convert_lines(data, sep)
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local blank = vim.api.nvim_get_current_line():match("^%s*$") ~= nil
  local at = blank and lnum - 1 or lnum
  vim.api.nvim_buf_set_lines(0, at, blank and lnum or lnum, false, lines)
  vim.api.nvim_win_set_cursor(0, { at + 1, 2 })
end

--- Lines of `rows` (lists of cells) as "tsv" or "csv" text.
function M.to_separated(rows, format)
  local out = {}
  for _, cells in ipairs(rows) do
    local parts = {}
    for i, c in ipairs(cells) do
      if format == "csv" and c:find('[",\n]') then
        c = '"' .. c:gsub('"', '""') .. '"'
      end
      parts[i] = c
    end
    out[#out + 1] = table.concat(parts, format == "csv" and "," or "\t")
  end
  return out
end

--- Translators offered for `table_export` (org-table-export).
local EXPORT_FORMATS = {
  { value = "orgtbl-to-tsv", desc = "tab-separated values" },
  { value = "orgtbl-to-csv", desc = "comma-separated values" },
  { value = "orgtbl-to-latex", desc = "LaTeX tabular" },
  { value = "orgtbl-to-html", desc = "HTML table" },
  { value = "orgtbl-to-generic", desc = "generic, set by parameters" },
  { value = "orgtbl-to-texinfo", desc = "Texinfo multitable" },
  { value = "orgtbl-to-orgtbl", desc = "Org table" },
}

--- Write the table at the cursor to a file with a translator (see
--- |org-table-translators|). The file and format come from the
--- TABLE_EXPORT_FILE / TABLE_EXPORT_FORMAT properties (inherited) when
--- set, else they are asked for; the suggested format matches the file
--- extension, else `table_export_default_format`. A format is a
--- translator name with parameters, `orgtbl-to-latex :splice t`. Emacs
--- org-table-export.
---@param path? string
---@param format? string
function M.export(path, format)
  local info = M.at_cursor()
  if not info then
    return false
  end
  local interactive = path == nil
  local hl = require("org.files").get_buffer(0):headline_at(info.start)
  path = path or (hl and hl:get_property("TABLE_EXPORT_FILE", true))
  if not path then
    path = utils.input({ prompt = "Export table to: ", completion = "file" })
    if not path or vim.trim(path) == "" then
      return
    end
    path = vim.fs.normalize(vim.fn.fnamemodify(utils.expand_vars(vim.trim(path)), ":p"))
    if utils.exists(path) and not utils.confirm("Overwrite file " .. path .. "?") then
      utils.notify("File not written")
      return
    end
  end
  -- TABLE_EXPORT_FILE is document text: never vim.fn.expand() (`backticks`)
  path = vim.fs.normalize(vim.fn.fnamemodify(utils.expand_vars(vim.trim(path)), ":p"))
  if utils.is_dir(path) then
    utils.warn("This is a directory path, not a file")
    return
  end
  if path == vim.fs.normalize(vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":p")) then
    utils.warn("Please specify a file name that is different from current")
    return
  end
  format = format or (hl and hl:get_property("TABLE_EXPORT_FORMAT", true))
  if not format then
    local ext = (path:match("%.(%w+)$") or ""):lower()
    local default = require("org.config").opts.table_export_default_format or "orgtbl-to-tsv"
    for _, f in ipairs(EXPORT_FORMATS) do
      if ext ~= "" and f.value:sub(-#ext) == ext then
        default = f.value
        break
      end
    end
    if interactive then
      format = require("org.ui").choose({
        prompt = "Format: ",
        title = "Export table as",
        items = EXPORT_FORMATS,
        default = default,
        edit = true,
      })
      if not format or vim.trim(format) == "" then
        return
      end
    else
      format = default
    end
  end
  local name, params = vim.trim(format):match("^(%S+)%s*(.*)$")
  local orgtbl = require("org.table.orgtbl")
  if not name or not orgtbl.translator(name) then
    utils.warn("No such transformation function " .. tostring(name))
    return
  end
  local text = orgtbl.translate(name, orgtbl.to_lisp(info.lines), params)
  utils.writefile(path, vim.split(text, "\n", { plain = true }))
  utils.notify("Export done: " .. path)
  return path
end
