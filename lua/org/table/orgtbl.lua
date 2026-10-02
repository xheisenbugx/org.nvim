---@mod org.table.orgtbl Table translators, radio tables and orgtbl-mode
---
--- - Translators (Emacs orgtbl-to-*): turn a table (rows of cells, or
---   "hline") into another format: `generic`, `tsv`, `csv`, `latex`,
---   `html`, `texinfo`, `orgtbl`, `table.el` and `unicode` (:narrow), with
---   the `orgtbl-to-generic` parameters (:splice :skip :skipcols :hline
---   :sep :hsep :tstart :tend
---   :lstart :lend :llstart :llend :hlstart :hlend :hllstart :hllend
---   :lfmt :llfmt :hlfmt :hllfmt :fmt :hfmt :efmt), plus :booktabs and
---   :environment (latex), :attributes (html) and :columns (texinfo).
---   Parameters that take Lisp functions in Emacs take Lua functions here
---   (from the Lua API) or format strings.
--- - Radio tables: `#+ORGTBL: SEND name translator :params` above a table
---   sends the translated table between `BEGIN RECEIVE ORGTBL name` and
---   `END RECEIVE ORGTBL name` lines anywhere in the buffer.
--- - orgtbl-mode: table editing keys in buffers of any filetype.

local utils = require("org.utils")

local M = {}

local function tbl()
  return require("org.table")
end

---------------------------------------------------------------------------
-- Tables as data
---------------------------------------------------------------------------

--- Rows of table lines: lists of trimmed cells, or "hline"
--- (org-table-to-lisp).
function M.to_lisp(lines)
  local out = {}
  for _, l in ipairs(lines) do
    if l:match("^%s*|%-") then
      out[#out + 1] = "hline"
    elseif l:match("^%s*|") then
      out[#out + 1] = tbl().split_cells(l)
    end
  end
  return out
end

local SPECIAL_MARKS = {
  ["#"] = true,
  ["*"] = true,
  ["!"] = true,
  ["$"] = true,
  ["^"] = true,
  ["_"] = true,
  ["/"] = true,
}

--- Whether the first column only holds recalculation marks (and at least
--- one): org-export-table-has-special-column-p.
local function has_special_column(rows)
  local any = false
  for _, r in ipairs(rows) do
    if r ~= "hline" then
      local c = r[1] or ""
      if c ~= "" and not SPECIAL_MARKS[c] then
        return false
      end
      any = any or c ~= ""
    end
  end
  return any
end

--- Rows the export drops: `! ^ _ $ /` rows of a special column and rows
--- made only of width/alignment cookies (org-export-table-row-is-special-p).
local function is_special_row(r, special)
  if r == "hline" then
    return false
  end
  if special and (r[1] == "!" or r[1] == "^" or r[1] == "_" or r[1] == "$" or r[1] == "/") then
    return true
  end
  local cookie = false
  for i, c in ipairs(r) do
    if not (special and i == 1) then
      if c:match("^<[lrc]?%d*>$") then
        cookie = true
      elseif c ~= "" then
        return false
      end
    end
  end
  return cookie
end

--- Whether a row only holds width/alignment cookies (and empty cells).
local function is_cookie_row(r, special)
  if r == "hline" then
    return false
  end
  local cookie = false
  for i, c in ipairs(r) do
    if not (special and i == 1) then
      if c:match("^<[lrc]?%d*>$") then
        cookie = true
      elseif c ~= "" then
        return false
      end
    end
  end
  return cookie
end

--- Rows after :skip, :skipcols and the special rows/column, like the
--- export parse tree orgtbl-to-generic works on. `opts.keep_special` keeps
--- special and cookie rows (the org backend does); `opts.info` collects the column
--- groups of a `/` row (`info.groups`) and the cookies of dropped cookie
--- rows (`info.cookies[c] = "<l5>"`), as the ASCII export uses them.
local function prepare(rows, params, opts)
  opts = opts or {}
  rows = vim.deepcopy(rows)
  local skip = tonumber(params.skip)
  if skip then
    for _ = 1, skip do
      table.remove(rows, 1)
    end
  end
  local special = has_special_column(rows)
  local info = opts.info
  local out = {}
  for _, r in ipairs(rows) do
    if info and not opts.keep_special and r ~= "hline" and r[1] == "/" then
      -- a column-groups row: always special for the ASCII export
      local groups = vim.deepcopy(r)
      if special then
        table.remove(groups, 1)
      else
        groups[1] = ""
      end
      info.groups = groups
    elseif opts.keep_special and is_special_row(r, special) then
      if special then
        table.remove(r, 1)
      end
      out[#out + 1] = r
    elseif not is_special_row(r, special) then
      if r ~= "hline" and special then
        table.remove(r, 1)
      end
      out[#out + 1] = r
    elseif info and is_cookie_row(r, special) then
      info.cookies = info.cookies or {}
      info.align = info.align or {}
      for c, v in ipairs(r) do
        local col = special and c - 1 or c
        if col >= 1 and v ~= "" and not info.cookies[col] then
          info.cookies[col] = v
        end
        -- the export takes the last alignment cookie of a column
        local a = col >= 1 and v:match("^<([lrc])%d*>$")
        if a then
          info.align[col] = a
        end
      end
    end
  end
  local skipcols = params.skipcols
  if type(skipcols) == "table" and #skipcols > 0 then
    local drop = {}
    for _, c in ipairs(skipcols) do
      drop[tonumber(c)] = true
    end
    local function filter(r, n)
      local kept = {}
      for c = 1, n or #r do
        if not drop[c] then
          kept[#kept + 1] = r[c] or false
        end
      end
      return kept
    end
    for i, r in ipairs(out) do
      if r ~= "hline" then
        out[i] = filter(r)
      end
    end
    if info and info.groups then
      info.groups = filter(info.groups)
    end
    for _, key in ipairs({ "cookies", "align" }) do
      if info and info[key] then
        local n = 0
        for c in pairs(info[key]) do
          n = math.max(n, c)
        end
        local kept = filter(info[key], n)
        info[key] = {}
        for c, v in ipairs(kept) do
          info[key][c] = v or nil
        end
      end
    end
  end
  -- leading and trailing hlines and repeated ones are not rows
  while out[1] == "hline" do
    table.remove(out, 1)
  end
  while out[#out] == "hline" do
    table.remove(out)
  end
  local clean = {}
  for _, r in ipairs(out) do
    if not (r == "hline" and clean[#clean] == "hline") then
      clean[#clean + 1] = r
    end
  end
  return clean
end

--- Number of header rows (before the first hline, when a data row
--- follows it).
local function header_count(rows)
  for i, r in ipairs(rows) do
    if r == "hline" then
      return i - 1
    end
  end
  return 0
end

--- Parse a Lisp list parameter like `(2 3)` or `(2 "$%s$" 4 "%s")`.
local function lisp_list(v)
  if type(v) ~= "string" or not v:match("^%(") then
    return v
  end
  local out, i, s = {}, 2, v
  while i <= #s do
    local ch = s:sub(i, i)
    if ch:match("%s") or ch == ")" then
      i = i + 1
    elseif ch == '"' then
      local j, buf = i + 1, {}
      while j <= #s and s:sub(j, j) ~= '"' do
        if s:sub(j, j) == "\\" then
          j = j + 1
        end
        buf[#buf + 1] = s:sub(j, j)
        j = j + 1
      end
      out[#out + 1] = table.concat(buf)
      i = j + 1
    else
      local tok = s:match("^[^%s%)]+", i)
      out[#out + 1] = tonumber(tok) or tok
      i = i + #tok
    end
  end
  return out
end

--- Parameters of a `#+ORGTBL: SEND` line or a Lua call.
function M.parse_params(str)
  local p = require("org.dblock").parse_params(str or "")
  for k, v in pairs(p) do
    p[k] = lisp_list(v)
  end
  return p
end

---------------------------------------------------------------------------
-- Cell transcoders for the backends
---------------------------------------------------------------------------

local function emphasis(s, map)
  local out, i, n = {}, 1, #s
  while i <= n do
    local ch = s:sub(i, i)
    local prev = i == 1 and " " or s:sub(i - 1, i - 1)
    local close
    if map[ch] and prev:match("[%s%-({'\"]") and s:sub(i + 1, i + 1):match("%S") then
      local j = i
      while true do
        j = s:find(ch, j + 1, true)
        if not j then
          break
        end
        local after = j == n and " " or s:sub(j + 1, j + 1)
        if s:sub(j - 1, j - 1):match("%S") and after:match("[%s%-%.,:!?;'\")}%]]") then
          close = j
          break
        end
      end
    end
    if close then
      out[#out + 1] = map[ch](s:sub(i + 1, close - 1))
      i = close + 1
    else
      out[#out + 1] = map.text(ch)
      i = i + 1
    end
  end
  return table.concat(out)
end

--- Org markup of a cell as LaTeX (ox-latex, simplified).
local function latex_cell(s)
  local special = {
    ["\\"] = "\\textbackslash{}",
    ["~"] = "\\textasciitilde{}",
    ["^"] = "\\textasciicircum{}",
  }
  local function esc(t)
    -- one pass: the braces of \textbackslash{} are not escaped again
    return (t:gsub("[\\~^%%$#&{}_]", function(ch)
      return special[ch] or ("\\" .. ch)
    end))
  end
  s = s:gsub("(%w)_(%w+)", "%1\1%2\2"):gsub("(%w)%^(%w+)", "%1\3%2\4")
  local map = {
    text = esc,
    ["*"] = function(t)
      return "\\textbf{" .. esc(t) .. "}"
    end,
    ["/"] = function(t)
      return "\\emph{" .. esc(t) .. "}"
    end,
    ["_"] = function(t)
      return "\\uline{" .. esc(t) .. "}"
    end,
    ["+"] = function(t)
      return "\\sout{" .. esc(t) .. "}"
    end,
    ["="] = function(t)
      return "\\verb~" .. t .. "~"
    end,
    ["~"] = function(t)
      return "\\texttt{" .. esc(t) .. "}"
    end,
  }
  local out = emphasis(s, map)
  return (out:gsub("\1", "\\textsubscript{"):gsub("\2", "}"):gsub("\3", "\\textsuperscript{"):gsub("\4", "}"))
end

--- Org markup of a cell as HTML (ox-html, simplified).
local function html_cell(s)
  local function esc(t)
    return (t:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"))
  end
  s = s:gsub("(%w)_(%w+)", "%1\1%2\2"):gsub("(%w)%^(%w+)", "%1\3%2\4")
  local map = {
    text = esc,
    ["*"] = function(t)
      return "<b>" .. esc(t) .. "</b>"
    end,
    ["/"] = function(t)
      return "<i>" .. esc(t) .. "</i>"
    end,
    ["_"] = function(t)
      return '<span class="underline">' .. esc(t) .. "</span>"
    end,
    ["+"] = function(t)
      return "<del>" .. esc(t) .. "</del>"
    end,
    ["="] = function(t)
      return "<code>" .. esc(t) .. "</code>"
    end,
    ["~"] = function(t)
      return "<code>" .. esc(t) .. "</code>"
    end,
  }
  local out = emphasis(s, map)
  return (out:gsub("\1", "<sub>"):gsub("\2", "</sub>"):gsub("\3", "<sup>"):gsub("\4", "</sup>"))
end

--- Org markup of a cell as Texinfo (ox-texinfo, simplified).
local function texinfo_cell(s)
  local function esc(t)
    return (t:gsub("([@{}])", "@%1"))
  end
  s = s:gsub("(%w)_(%w+)", "%1\1%2\2"):gsub("(%w)%^(%w+)", "%1\3%2\4")
  local map = {
    text = esc,
    ["*"] = function(t)
      return "@strong{" .. esc(t) .. "}"
    end,
    ["/"] = function(t)
      return "@emph{" .. esc(t) .. "}"
    end,
    ["_"] = function(t)
      return "@underline{" .. esc(t) .. "}"
    end,
    ["+"] = function(t)
      return "@w{}" .. esc(t)
    end,
    ["="] = function(t)
      return "@samp{" .. esc(t) .. "}"
    end,
    ["~"] = function(t)
      return "@code{" .. esc(t) .. "}"
    end,
  }
  local out = emphasis(s, map)
  return (out:gsub("\1", "@math{_"):gsub("\2", "}"):gsub("\3", "@math{^"):gsub("\4", "}"))
end

---------------------------------------------------------------------------
-- orgtbl-to-generic
---------------------------------------------------------------------------

--- Apply a string (format) or function parameter.
local function apply(v, ...)
  if v == nil or v == false then
    return nil
  elseif type(v) == "function" then
    return v(...)
  elseif select("#", ...) == 0 then
    return v
  end
  local args = { ... }
  if type(args[1]) == "table" then
    args = args[1]
  end
  local ok, s = pcall(string.format, v, unpack(args))
  if not ok then
    error("wrong format parameter: " .. v)
  end
  return s
end

--- `body` between :tstart and :tend.
local function frame(body, params)
  local head = params.tstart and (apply(params.tstart) .. "\n") or ""
  local tail = params.tend and ("\n" .. apply(params.tend)) or ""
  return head .. body .. tail
end

--- A per-column format: a string or function, or a list `{ col, fmt, ... }`.
local function column_format(v, col)
  if type(v) == "table" and not vim.is_callable(v) then
    for i = 1, #v - 1, 2 do
      if tonumber(v[i]) == col then
        return v[i + 1]
      end
    end
    return nil
  end
  return v
end

local EXP = "^([-+]?%d*%.?%d+)[eE]([-+]?%d+)$"

--- Emacs orgtbl-to-generic without a backend: every row made of
--- :lstart/:lend/:sep (or :lfmt), hlines as :hline (dropped when unset),
--- cells through :efmt / :fmt / :hfmt. `cell` translates the cell text
--- (the backend's transcoder).
---@param rows (string[]|string)[]
---@param params table
---@param backend? { cell?: fun(s: string): string, row?: fun(cells: string[], info: table): string,
---   hline?: fun(info: table): string?, table?: fun(body: string, info: table): string }
function M.generic(rows, params, backend)
  params = params or {}
  -- without a backend, Emacs exports through the Org backend, which keeps
  -- the special rows (org-org-with-special-rows)
  local keep = backend == nil and params.backend == nil
  backend = backend or {}
  local pinfo = {}
  rows = prepare(rows, params, { keep_special = keep, info = pinfo })
  local tx = backend.cells and not params.raw and backend.cells(rows) or nil
  local nheader = header_count(rows)
  local ndata = 0
  for _, r in ipairs(rows) do
    if r ~= "hline" then
      ndata = ndata + 1
    end
  end
  local out, datai = {}, 0
  for i, r in ipairs(rows) do
    if r == "hline" then
      local h
      if params.hline ~= nil then
        h = apply(params.hline)
      elseif backend.hline then
        h = backend.hline({ index = i, header = i == nheader + 1, rows = rows })
      end
      if h then
        out[#out + 1] = h
      end
    else
      datai = datai + 1
      local header = i <= nheader
      local last_header = header and i == nheader
      local last = datai == ndata
      local cells = {}
      for c, v in ipairs(r) do
        local s = tx and tx[i] and tx[i][c]
        if s == nil then
          s = backend.cell and not params.raw and backend.cell(v) or v
        end
        if s ~= "" then
          local efmt = column_format(params.efmt, c)
          if efmt then
            local mant, exp = s:match(EXP)
            if mant then
              s = apply(efmt, mant, exp)
            end
          end
          local f = header and column_format(params.hfmt, c) or nil
          f = f or column_format(params.fmt, c)
          if f then
            s = apply(f, s)
          end
        end
        cells[c] = s
      end
      local line
      local lfmt = (last_header and params.hllfmt)
        or (header and params.hlfmt)
        or (last and params.llfmt)
        or params.lfmt
      if lfmt then
        line = apply(lfmt, cells)
      else
        local sep = header and params.hsep or params.sep
        local body
        if sep ~= nil then
          body = table.concat(cells, apply(sep))
        elseif backend.row then
          body = nil
        else
          body = table.concat(cells)
        end
        local ls, le
        if last_header and (params.hllstart or params.hllend) then
          ls, le = params.hllstart, params.hllend
        elseif header and (params.hlstart or params.hlend) then
          ls, le = params.hlstart, params.hlend
        elseif last and (params.llstart or params.llend) then
          ls, le = params.llstart, params.llend
        else
          ls, le = params.lstart, params.lend
        end
        if ls or le or not backend.row then
          line = (apply(ls) or "") .. (body or table.concat(cells)) .. (apply(le) or "")
        else
          line = backend.row(cells, { header = header, index = i, rows = rows, sep = body })
        end
      end
      out[#out + 1] = line
    end
  end
  local body = table.concat(out, "\n")
  if params.splice then
    return body
  end
  if params.tstart or params.tend then
    return frame(body, params)
  end
  if backend.table then
    return backend.table(body, { rows = rows, params = params, cells = tx, align = pinfo.align })
  end
  return body
end

--- The cells of the prepared `rows` as the export backend `name`
--- transcodes them: orgtbl-to-latex and friends export the table through
--- `org-export-as` in Emacs, so links, entities, LaTeX fragments,
--- sub/superscripts and the like come out as in a real export. Returns
--- `tx[i][c]` for every data row `i`, or nil when the export fails.
local function export_cells(name, rows)
  local ox = require("org.export.ox")
  local lines, rowlen = {}, {}
  for i, r in ipairs(rows) do
    if r ~= "hline" then
      -- a first column that is never a special one, so that no row or
      -- column is dropped by the export
      local cells = { "x" }
      for c = 1, #r do
        cells[c + 1] = type(r[c]) == "string" and r[c] or ""
      end
      lines[#lines + 1] = "| " .. table.concat(cells, " | ") .. " |"
      rowlen[#rowlen + 1] = { i, #r }
    end
  end
  if #lines == 0 then
    return nil
  end
  local got = {}
  local backend = ox.create_backend(name, {
    ["table-cell"] = function(_, contents)
      got[#got + 1] = contents or ""
      return ""
    end,
    ["table-row"] = function()
      return ""
    end,
    table = function()
      return ""
    end,
  })
  local ok = pcall(ox.export_as, backend, lines, { body_only = true })
  local want = 0
  for _, rl in ipairs(rowlen) do
    want = want + rl[2] + 1
  end
  if not ok or #got ~= want then
    return nil
  end
  local tx, k = {}, 0
  for _, rl in ipairs(rowlen) do
    local i, n = rl[1], rl[2]
    k = k + 1 -- the "x" cell
    tx[i] = {}
    for c = 1, n do
      k = k + 1
      tx[i][c] = type(rows[i][c]) == "string" and got[k] or nil
    end
  end
  return tx
end

--- Alignment ("l"/"r"/"c") of each column of `rows` as the export
--- computes it (org-export-table-cell-alignment): the last alignment
--- cookie of the column (`cookies[c]`), else right when at least
--- `table_number_fraction` of all its cells are numbers once transcoded
--- (`tx`, see `export_cells`), an empty cell after a number counting as
--- one.
local function export_alignments(rows, tx, cookies)
  local ox = require("org.export.ox")
  local fraction = require("org.config").opts.table_number_fraction or 0.5
  local ncols = 0
  for _, r in ipairs(rows) do
    if r ~= "hline" then
      ncols = math.max(ncols, #r)
    end
  end
  local align = {}
  for c = 1, ncols do
    local numbers, total, prev = 0, 0, false
    for i, r in ipairs(rows) do
      if r ~= "hline" then
        local v = tx and tx[i] and tx[i][c] or (type(r[c]) == "string" and r[c] or "")
        total = total + 1
        if ox.table_number_p(v) or (v == "" and prev) then
          prev = true
          numbers = numbers + 1
        else
          prev = false
        end
      end
    end
    align[c] = cookies and cookies[c] or (total > 0 and numbers >= fraction * total and "r" or "l")
  end
  return align, ncols
end

--- Alignment ("l"/"r"/"c") of each column of `rows` (like the export).
local function alignments(rows)
  local t = { rows = {}, ncols = 0, indent = "" }
  for _, r in ipairs(rows) do
    if r == "hline" then
      t.rows[#t.rows + 1] = { hline = true }
    else
      t.rows[#t.rows + 1] = { cells = r }
      t.ncols = math.max(t.ncols, #r)
    end
  end
  local _, align = tbl().layout(t)
  return align, t.ncols
end

---------------------------------------------------------------------------
-- Translators
---------------------------------------------------------------------------

M.translators = {}

function M.translators.generic(rows, params)
  return M.generic(rows, params)
end

function M.translators.tsv(rows, params)
  return M.generic(rows, vim.tbl_extend("keep", params or {}, { sep = "\t" }))
end

--- Quote a CSV field when needed (org-quote-csv-field).
function M.quote_csv(s)
  if s:find('[",\n]') then
    return '"' .. s:gsub('"', '""') .. '"'
  end
  return s
end

function M.translators.csv(rows, params)
  return M.generic(rows, vim.tbl_extend("keep", params or {}, { sep = ",", fmt = M.quote_csv }))
end

function M.translators.latex(rows, params)
  params = params or {}
  local booktabs = params.booktabs
  local env = params.environment or "tabular"
  return M.generic(rows, params, {
    cell = latex_cell,
    cells = function(prepared)
      return export_cells("latex", prepared)
    end,
    row = function(cells)
      return table.concat(cells, " & ") .. "\\\\"
    end,
    hline = function()
      -- leading and trailing hlines are gone: every rule is a mid one
      return booktabs and "\\midrule" or "\\hline"
    end,
    table = function(body, info)
      local align, ncols = export_alignments(info.rows, info.cells, info.align)
      local spec = table.concat(align, "", 1, ncols)
      local lines = { "\\begin{" .. env .. "}{" .. spec .. "}" }
      if booktabs then
        lines[#lines + 1] = "\\toprule"
      end
      lines[#lines + 1] = body
      if booktabs then
        lines[#lines + 1] = "\\bottomrule"
      end
      lines[#lines + 1] = "\\end{" .. env .. "}"
      return table.concat(lines, "\n")
    end,
  })
end

function M.translators.html(rows, params)
  params = params or {}
  local attrs = params.attributes
  local attr_text
  if attrs == nil then
    attr_text = ' border="2" cellspacing="0" cellpadding="6" rules="groups" frame="hsides"'
  elseif attrs == false then
    attr_text = ""
  else
    local parts = {}
    if type(attrs) == "table" then
      for i = 1, #attrs - 1, 2 do
        parts[#parts + 1] = string.format(' %s="%s"', tostring(attrs[i]):gsub("^:", ""), attrs[i + 1])
      end
    end
    attr_text = table.concat(parts)
  end
  local pinfo = {}
  local prepared = prepare(rows, params, { info = pinfo })
  local tx = not params.raw and export_cells("html", prepared) or nil
  local align = export_alignments(prepared, tx, pinfo.align)
  local names = { l = "left", r = "right", c = "center" }
  local nheader = header_count(prepared)
  return M.generic(rows, params, {
    cell = html_cell,
    cells = function()
      return tx
    end,
    row = function(cells, info)
      local tag = info.header and "th" or "td"
      local out = { "<tr>" }
      for c, v in ipairs(cells) do
        local scope = info.header and ' scope="col"' or ""
        out[#out + 1] = string.format(
          '<%s%s class="org-%s">%s</%s>',
          tag,
          scope,
          names[align[c]] or "left",
          v == "" and "&nbsp;" or v,
          tag
        )
      end
      out[#out + 1] = "</tr>"
      return table.concat(out, "\n")
    end,
    hline = function()
      return nil
    end,
    table = function(_, info)
      -- rebuild with row groups: thead for the header, tbody per group
      local lines = { "<table" .. attr_text .. ">", "", "", "<colgroup>" }
      for c = 1, #align do
        lines[#lines + 1] = '<col  class="org-' .. (names[align[c]] or "left") .. '" />'
        if c < #align then
          lines[#lines + 1] = ""
        end
      end
      lines[#lines + 1] = "</colgroup>"
      local groups, cur = {}, {}
      for i, r in ipairs(info.rows) do
        if r == "hline" then
          if #cur > 0 then
            groups[#groups + 1] = cur
            cur = {}
          end
        else
          cur[#cur + 1] = { cells = r, header = i <= nheader, tx = tx and tx[i] }
        end
      end
      if #cur > 0 then
        groups[#groups + 1] = cur
      end
      for _, g in ipairs(groups) do
        local header = g[1].header
        lines[#lines + 1] = header and "<thead>" or "<tbody>"
        for k, row in ipairs(g) do
          local cells = {}
          for c, v in ipairs(row.cells) do
            local s = row.tx and row.tx[c]
            if s == nil then
              s = params.raw and v or html_cell(v)
            end
            local f = row.header and column_format(params.hfmt, c) or nil
            f = f or column_format(params.fmt, c)
            if f and s ~= "" then
              s = apply(f, s)
            end
            cells[c] = s
          end
          local tag = header and "th" or "td"
          lines[#lines + 1] = "<tr>"
          for c, v in ipairs(cells) do
            lines[#lines + 1] = string.format(
              '<%s%s class="org-%s">%s</%s>',
              tag,
              header and ' scope="col"' or "",
              names[align[c]] or "left",
              v == "" and "&nbsp;" or v,
              tag
            )
          end
          lines[#lines + 1] = "</tr>"
          if k < #g then
            lines[#lines + 1] = ""
          end
        end
        lines[#lines + 1] = header and "</thead>" or "</tbody>"
      end
      lines[#lines + 1] = "</table>"
      return table.concat(lines, "\n")
    end,
  })
end

function M.translators.texinfo(rows, params)
  params = params or {}
  local out = M.generic(rows, params, {
    cell = texinfo_cell,
    cells = function(prepared)
      return export_cells("texinfo", prepared)
    end,
    row = function(cells, info)
      local lines = { (info.header and "@headitem " or "@item ") .. (cells[1] or "") }
      for c = 2, #cells do
        lines[#lines + 1] = "@tab " .. cells[c]
      end
      return table.concat(lines, "\n")
    end,
    hline = function()
      return nil
    end,
    table = function(body, info)
      -- column prototypes: the widest cell of each column, as a's
      local widths = {}
      for _, r in ipairs(info.rows) do
        if r ~= "hline" then
          for c, v in ipairs(r) do
            widths[c] = math.max(widths[c] or 0, utils.width(v))
          end
        end
      end
      local protos = {}
      for c, w in ipairs(widths) do
        protos[c] = "{" .. string.rep("a", w) .. "}"
      end
      return "@multitable " .. table.concat(protos, " ") .. "\n" .. body .. "\n@end multitable"
    end,
  })
  local columns = params.columns
  if columns then
    if not (columns:find("{") or columns:find("@columnfractions ")) then
      columns = "@columnfractions " .. columns
    end
    out = out:gsub("@multitable [^\n]*", function()
      return "@multitable " .. columns
    end, 1)
  end
  return out
end

function M.translators.orgtbl(rows, params)
  params = params or {}
  local prepared = prepare(rows, params, { keep_special = true })
  local lines = {}
  for _, r in ipairs(prepared) do
    lines[#lines + 1] = r == "hline" and "|-" or ("| " .. table.concat(r, " | ") .. " |")
  end
  local rendered = tbl().render(tbl().parse(lines))
  local body = table.concat(rendered, "\n")
  if params.tstart or params.tend then
    body = frame(body, params)
  end
  return body
end

--- orgtbl-to-table.el: the aligned Org table with `+` where rules meet
--- the column separators.
M.translators["table.el"] = function(rows, params)
  local body = M.translators.orgtbl(rows, params)
  return (body:gsub("%-|", "-+"):gsub("|%-", "+-"))
end

--- Cell text as the ASCII export writes it (simplified): verbatim and
--- code in `quotes', links as their description, entities as UTF-8.
local function ascii_cell(s)
  s = s:gsub("%[%[([^%]]+)%]%[([^%]]+)%]%]", "[%2]"):gsub("%[%[([^%]]+)%]%]", "<%1>")
  local function quote(t)
    return "`" .. t .. "'"
  end
  s = emphasis(s, {
    ["="] = quote,
    ["~"] = quote,
    text = function(ch)
      return ch
    end,
  })
  return (
    s:gsub("\\(%a+)({?}?)", function(name, braces)
      return require("org.entities").utf8(name) or ("\\" .. name .. braces)
    end)
  )
end

--- orgtbl-to-unicode: the table as the ASCII export draws it with UTF-8
--- characters (heavy rules around the table, light ones for hlines,
--- vertical bars at column groups). `:narrow t` cuts columns to their
--- width cookie, ending cut cells with `=>`.
function M.translators.unicode(rows, params)
  params = params or {}
  local info = {}
  local data = prepare(rows, params, { info = info })
  local ncols = 0
  for _, r in ipairs(data) do
    if r ~= "hline" then
      ncols = math.max(ncols, #r)
    end
  end
  if ncols == 0 then
    return ""
  end
  local align = alignments(data)
  local cookies = info.cookies or {}
  local widths = {}
  for c = 1, ncols do
    local w = 0
    for _, r in ipairs(data) do
      if r ~= "hline" then
        w = math.max(w, vim.fn.strdisplaywidth(ascii_cell(r[c] or "")))
      end
    end
    local cookie = cookies[c]
    local cw = cookie and tonumber(cookie:match("(%d+)"))
    if cw then
      w = params.narrow and cw or math.max(w, cw)
    end
    local ca = cookie and cookie:match("^<([lrc])")
    if ca then
      align[c] = ca
    end
    widths[c] = w
  end
  -- bar[c]: a vertical line before column c (ncols + 1: after the last)
  local bar = {}
  for c, g in ipairs(info.groups or {}) do
    if g == "<" or g == "<>" then
      bar[c] = true
    end
    if g == ">" or g == "<>" then
      bar[c + 1] = true
    end
  end
  local function rule(fill, left, mid, right)
    local parts = {}
    for c = 1, ncols do
      parts[#parts + 1] = (bar[c] and (c == 1 and left or mid) or "") .. string.rep(fill, widths[c] + 2)
    end
    return table.concat(parts) .. (bar[ncols + 1] and right or "")
  end
  local function cell(text, c)
    local w = widths[c]
    local len = vim.fn.strdisplaywidth(text)
    if len > w then
      -- only with :narrow: cut to the cookie width, with an ellipsis
      local cut = ""
      for _, ch in ipairs(vim.fn.split(text, [[\zs]])) do
        if vim.fn.strdisplaywidth(cut .. ch) > w - 2 then
          break
        end
        cut = cut .. ch
      end
      text, len = cut .. "=>", vim.fn.strdisplaywidth(cut) + 2
    end
    local pad = w - len
    if align[c] == "r" then
      return string.rep(" ", pad) .. text
    elseif align[c] == "c" then
      return string.rep(" ", math.floor(pad / 2)) .. text .. string.rep(" ", pad - math.floor(pad / 2))
    end
    return text .. string.rep(" ", pad)
  end
  local out = { rule("━", "┍", "┯", "┑") }
  for _, r in ipairs(data) do
    if r == "hline" then
      out[#out + 1] = rule("─", "├", "┼", "┤")
    else
      local parts = {}
      for c = 1, ncols do
        parts[#parts + 1] = (bar[c] and "│" or "") .. " " .. cell(ascii_cell(r[c] or ""), c) .. " "
      end
      out[#out + 1] = table.concat(parts) .. (bar[ncols + 1] and "│" or "")
    end
  end
  out[#out + 1] = rule("━", "┕", "┷", "┙")
  return table.concat(out, "\n")
end

--- The translator named `name` ("orgtbl-to-latex", "latex", or a global
--- Lua function name).
function M.translator(name)
  local short = name:gsub("^orgtbl%-to%-", "")
  if M.translators[short] then
    return M.translators[short]
  end
  local fn = _G[name] or _G[name:gsub("%-", "_")]
  if type(fn) == "function" then
    return fn
  end
  return nil
end

--- Translate `rows` with translator `name` and `params` (a table or a
--- parameter string).
function M.translate(name, rows, params)
  local fn = M.translator(name)
  if not fn then
    error("No such transformation function " .. name)
  end
  if type(params) == "string" then
    params = M.parse_params(params)
  end
  return fn(rows, params or {})
end

---------------------------------------------------------------------------
-- Radio tables
---------------------------------------------------------------------------

local SEND = "^%s*#%+[Oo][Rr][Gg][Tt][Bb][Ll][:%s]%s*SEND%s+(%S+)%s+(%S+)(.*)$"

--- `#+ORGTBL: SEND` definitions above the table starting at `start`.
local function send_defs(bufnr, start)
  local out = {}
  local l = start - 1
  while l >= 1 do
    local line = vim.api.nvim_buf_get_lines(bufnr, l - 1, l, false)[1]
    local name, transform, params = line:match(SEND)
    if not name then
      break
    end
    table.insert(out, 1, { name = name, transform = transform, params = params })
    l = l - 1
  end
  return out
end

--- Replace the lines between `BEGIN RECEIVE ORGTBL name` and `END
--- RECEIVE ORGTBL name` (every such location) with `text`.
local function replace_receiver(bufnr, name, text)
  local pat = vim.pesc(name)
  local found = false
  local l = 1
  while l <= vim.api.nvim_buf_line_count(bufnr) do
    local line = vim.api.nvim_buf_get_lines(bufnr, l - 1, l, false)[1]
    if line:match("BEGIN +RECEIVE +ORGTBL +" .. pat .. "%f[%s%z]") then
      found = true
      local e = l + 1
      local n = vim.api.nvim_buf_line_count(bufnr)
      while e <= n do
        local el = vim.api.nvim_buf_get_lines(bufnr, e - 1, e, false)[1]
        if el:match("END +RECEIVE +ORGTBL +" .. pat .. "%f[%s%z]") then
          break
        end
        e = e + 1
      end
      if e > n then
        error("Cannot find end of receiver location at " .. l)
      end
      local new = vim.split(text, "\n", { plain = true })
      vim.api.nvim_buf_set_lines(bufnr, l, e - 1, false, new)
      l = l + #new + 2
    else
      l = l + 1
    end
  end
  if not found then
    error("No valid receiver location found in the buffer")
  end
end

--- Send the table at `lnum` to its receivers (orgtbl-send-table). With
--- `maybe`, do nothing quietly when there is no `#+ORGTBL: SEND` line.
---@return integer|nil count of receivers
function M.send_table(bufnr, lnum, maybe)
  bufnr = (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
  lnum = lnum or vim.api.nvim_win_get_cursor(0)[1]
  local info = tbl().find(bufnr, lnum)
  if not info then
    if not maybe then
      utils.warn("Not at a table")
    end
    return nil
  end
  local defs = send_defs(bufnr, info.start)
  if #defs == 0 then
    if not maybe then
      utils.warn("Don't know how to transform this table")
    end
    return nil
  end
  local rows = M.to_lisp(info.lines)
  local n = 0
  for _, d in ipairs(defs) do
    local ok, err = pcall(function()
      replace_receiver(bufnr, d.name, M.translate(d.transform, rows, d.params))
    end)
    if not ok then
      utils.warn(tostring(err):gsub("^.-:%d+: ", ""))
      return nil
    end
    n = n + 1
  end
  utils.notify(string.format("Table converted and installed at %d receiver location%s", n, n > 1 and "s" or ""))
  return n
end

--- After recalculating the table at `lnum`, send it when it is a radio
--- table.
function M.maybe_send(bufnr, lnum)
  bufnr = (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
  local info = tbl().find(bufnr, lnum)
  if info and #send_defs(bufnr, info.start) > 0 then
    return M.send_table(bufnr, info.start, true)
  end
end

--- Insert a radio table template for the buffer's filetype
--- (orgtbl-insert-radio-table, `orgtbl_radio_table_templates`).
function M.insert_radio_table()
  local ft = vim.bo.filetype
  local templates = require("org.config").opts.orgtbl_radio_table_templates or {}
  local txt = templates[ft]
  if not txt then
    utils.warn("No radio table setup defined for " .. ft)
    return
  end
  local name = utils.input({ prompt = "Table name: " })
  if not name or name == "" then
    return
  end
  txt = txt:gsub("%%n", function()
    return name
  end)
  local lines = vim.split(txt:gsub("\n$", ""), "\n", { plain = true })
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local cur = vim.api.nvim_get_current_line()
  local at = cur:match("^%s*$") and lnum - 1 or lnum
  vim.api.nvim_buf_set_lines(0, at, cur:match("^%s*$") and lnum or at, false, lines)
  vim.api.nvim_win_set_cursor(0, { at + 1, 0 })
end

--- Comment or uncomment the table at the cursor with 'commentstring'
--- (orgtbl-toggle-comment).
function M.toggle_comment()
  local cs = vim.bo.commentstring
  local prefix = vim.trim((cs:match("^(.-)%%s") or "#"))
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  local cpat = "^%s*" .. vim.pesc(prefix) .. "%s?%s*|"
  local commented = lines[lnum]:match(cpat) ~= nil
  local pat = commented and cpat or "^%s*|"
  if not lines[lnum]:match(pat) then
    utils.warn("Not at an org table")
    return
  end
  local s, e = lnum, lnum
  while s > 1 and lines[s - 1]:match(pat) do
    s = s - 1
  end
  while e < #lines and lines[e + 1]:match(pat) do
    e = e + 1
  end
  local out = {}
  for i = s, e do
    local l = lines[i]
    if commented then
      out[#out + 1] = (l:gsub("^(%s*)" .. vim.pesc(prefix) .. " ?", "%1", 1))
    else
      out[#out + 1] = prefix .. " " .. l
    end
  end
  vim.api.nvim_buf_set_lines(0, s - 1, e, false, out)
end

---------------------------------------------------------------------------
-- orgtbl-mode
---------------------------------------------------------------------------

local function in_table()
  return vim.api.nvim_get_current_line():match("^%s*|") ~= nil
end

--- C-c C-c in orgtbl-mode: on `#+ORGTBL` or a table line realign (count:
--- recalculate) and send; on `#+TBLFM` recalculate (orgtbl-ctrl-c-ctrl-c).
function M.ctrl_c_ctrl_c()
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local line = vim.api.nvim_get_current_line()
  local lines = vim.api.nvim_buf_get_lines(0, lnum - 1, lnum + 1, false)
  if line:match("^%s*#%+[Oo][Rr][Gg][Tt][Bb][Ll]:") and lines[2] and lines[2]:match("^%s*|") then
    lnum = lnum + 1
  elseif tbl().is_tblfm(line) then
    tbl().recalc(0, lnum)
    return true
  elseif not line:match("^%s*|") then
    return false
  end
  if vim.v.count > 0 then
    tbl().recalc(0, lnum)
  else
    tbl().align_at(0, lnum)
  end
  M.send_table(0, lnum, true)
  return true
end

--- Keys of orgtbl-mode (orgtbl-mode-map): { mode, lhs, function }.
local function mode_keys()
  local t = tbl()
  return {
    { "i", "<Tab>", t.next_field },
    { "i", "<S-Tab>", t.prev_field },
    { "i", "<CR>", t.next_row },
    { { "n", "i" }, "<S-CR>", t.copy_down },
    { "n", "<C-c><C-c>", M.ctrl_c_ctrl_c },
    { { "n", "x" }, "<C-c>|", t.create_or_convert },
    {
      "n",
      "<C-c>-",
      function()
        t.insert_hline(vim.v.count > 0)
      end,
    },
    { "n", "<C-c><CR>", t.hline_and_move },
    { "n", "<C-c>=", t.eval_formula },
    { "n", "<C-c>'", t.edit_formulas },
    { "n", "<C-c>`", t.edit_field },
    { "n", "<C-c>*", t.recalculate },
    { "n", "<C-c>^", t.sort_column },
    { "n", "<C-c>?", t.field_info },
    { { "n", "x" }, "<C-c><Space>", t.blank_field },
    { { "n", "x" }, "<C-c>+", t.sum },
    { "n", "<C-c>}", t.toggle_coordinate_overlays },
    { "n", "<C-c>{", t.toggle_formula_debugger },
    { "n", "<C-c><Tab>", t.toggle_column_width },
    { "n", "<C-#>", t.rotate_recalc_marks },
    { { "n", "x" }, "<C-c><C-x><M-w>", t.copy_region },
    { { "n", "x" }, "<C-c><C-x><C-w>", t.cut_region },
    { "n", "<C-c><C-x><C-y>", t.paste_rectangle },
    {
      "n",
      "<M-Left>",
      function()
        t.move_column(-1)
      end,
    },
    {
      "n",
      "<M-Right>",
      function()
        t.move_column(1)
      end,
    },
    {
      "n",
      "<M-Up>",
      function()
        t.move_row(-1)
      end,
    },
    {
      "n",
      "<M-Down>",
      function()
        t.move_row(1)
      end,
    },
    { "n", "<M-S-Left>", t.delete_column },
    { "n", "<M-S-Right>", t.insert_column },
    { "n", "<M-S-Up>", t.delete_row },
    {
      "n",
      "<M-S-Down>",
      function()
        t.insert_row(true)
      end,
    },
    {
      "n",
      "<M-h>",
      function()
        t.move_column(-1)
      end,
    },
    {
      "n",
      "<M-l>",
      function()
        t.move_column(1)
      end,
    },
    {
      "n",
      "<M-k>",
      function()
        t.move_row(-1)
      end,
    },
    {
      "n",
      "<M-j>",
      function()
        t.move_row(1)
      end,
    },
    { "n", "<M-H>", t.delete_column },
    { "n", "<M-L>", t.insert_column },
    { "n", "<M-K>", t.delete_row },
    {
      "n",
      "<M-J>",
      function()
        t.insert_row(true)
      end,
    },
    {
      "n",
      '<C-c>"a',
      function()
        require("org.table.plot").ascii_plot()
      end,
    },
    {
      "n",
      '<C-c>"g',
      function()
        require("org.table.plot").gnuplot()
      end,
    },
  }
end

M._fns = {}

--- Run key function `i` of `bufnr` (from an orgtbl-mode mapping).
function M._call(bufnr, i)
  local fn = (M._fns[bufnr] or {})[i]
  if fn then
    utils.run(fn)
  end
end

--- Enable orgtbl-mode in `bufnr`: the table keys work on table lines (and
--- keep their normal meaning elsewhere), tables are realigned when
--- leaving Insert mode.
function M.enable(bufnr)
  bufnr = (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
  if vim.b[bufnr].orgtbl_mode then
    return
  end
  vim.b[bufnr].orgtbl_mode = true
  local keys, fns = {}, {}
  for _, k in ipairs(mode_keys()) do
    local modes = type(k[1]) == "table" and k[1] or { k[1] }
    fns[#fns + 1] = k[3]
    local i, lhs = #fns, k[2]
    local anywhere = lhs == "<C-c>|" or lhs == "<C-c><C-c>"
    for _, mode in ipairs(modes) do
      vim.keymap.set(mode, lhs, function()
        if anywhere or in_table() then
          return "<Cmd>lua require('org.table.orgtbl')._call(" .. bufnr .. ", " .. i .. ")<CR>"
        end
        -- the key's own meaning outside tables
        return lhs
      end, { buffer = bufnr, expr = true, desc = "orgtbl: " .. lhs })
      keys[#keys + 1] = { mode, lhs }
    end
  end
  M._fns[bufnr] = fns
  M._keys = M._keys or {}
  M._keys[bufnr] = keys
  if require("org.config").opts.orgtbl_optimized ~= false then
    require("org.table.typing").attach(bufnr)
  end
  vim.api.nvim_create_autocmd("InsertLeave", {
    buffer = bufnr,
    group = vim.api.nvim_create_augroup("orgtbl." .. bufnr, { clear = true }),
    callback = function()
      if require("org.config").opts.table_automatic_realign == false then
        return
      end
      if in_table() then
        tbl().align_at(bufnr, vim.api.nvim_win_get_cursor(0)[1])
      end
    end,
  })
  utils.notify("Orgtbl mode enabled")
  -- orgtbl-mode-hook
  pcall(vim.api.nvim_exec_autocmds, "User", {
    pattern = "OrgtblMode",
    data = { enabled = true, bufnr = bufnr },
    modeline = false,
  })
end

--- Disable orgtbl-mode in `bufnr`.
function M.disable(bufnr)
  bufnr = (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
  vim.b[bufnr].orgtbl_mode = nil
  for _, k in ipairs((M._keys or {})[bufnr] or {}) do
    pcall(vim.keymap.del, k[1], k[2], { buffer = bufnr })
  end
  pcall(vim.api.nvim_del_augroup_by_name, "orgtbl." .. bufnr)
  require("org.table.typing").detach(bufnr)
  -- orgtbl-mode-hook
  pcall(vim.api.nvim_exec_autocmds, "User", {
    pattern = "OrgtblMode",
    data = { enabled = false, bufnr = bufnr },
    modeline = false,
  })
end

--- Toggle orgtbl-mode, the table editor for buffers that are not org
--- (Emacs orgtbl-mode).
function M.toggle(bufnr)
  bufnr = (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
  if vim.b[bufnr].orgtbl_mode then
    M.disable(bufnr)
    utils.notify("Orgtbl mode disabled")
  else
    M.enable(bufnr)
  end
end

return M
