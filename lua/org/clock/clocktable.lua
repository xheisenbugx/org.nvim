---@mod org.clock.clocktable The clocktable dynamic block (org-dblock-write:clocktable)
---
--- Table data, :scope files, :sort, :step tables, the languages of the
--- table terms and the formatting of the table.
---
--- Part of org.clock, which loads it.

local config = require("org.config")
local date = require("org.date")
local files = require("org.files")
local utils = require("org.utils")
local shared = require("org.clock.shared")

local M = require("org.clock")

local clock_cfg = shared.clock_cfg
local clock_sum = shared.clock_sum
local mkdate = shared.mkdate

---------------------------------------------------------------------------
-- Clock table
---------------------------------------------------------------------------
--- Clocktable terms per `:lang` (org-clock-clocktable-language-setup):
--- File, L, Timestamp, Headline, Time, ALL, Total time, File time, Clock
--- summary at. Add a language by adding an entry.
M.languages = {
  en = { "File", "L", "Timestamp", "Headline", "Time", "ALL", "Total time", "File time", "Clock summary at" },
  de = { "Datei", "E", "Zeitstempel", "Kopfzeile", "Dauer", "GESAMT", "Gesamtdauer", "Dateizeit", "Erstellt am" },
  es = {
    "Archivo",
    "N",
    "Fecha y hora",
    "Tarea",
    "Duración",
    "TODO",
    "Duración total",
    "Tiempo archivo",
    "Generado el",
  },
  fr = {
    "Fichier",
    "N",
    "Horodatage",
    "En-tête",
    "Durée",
    "TOUT",
    "Durée totale",
    "Durée fichier",
    "Horodatage sommaire à",
  },
  nl = { "Bestand", "N", "Tijdstip", "Rubriek", "Duur", "ALLES", "Totale duur", "Bestandstijd", "Klok overzicht op" },
  nn = { "Fil", "N", "Tidspunkt", "Overskrift", "Tid", "ALLE", "Total tid", "Filtid", "Tidsoversyn" },
  pl = {
    "Plik",
    "P",
    "Data i godzina",
    "Nagłówek",
    "Czas",
    "WSZYSTKO",
    "Czas całkowity",
    "Czas pliku",
    "Poddumowanie zegara na",
  },
  ["pt-BR"] = {
    "Arquivo",
    "N",
    "Data e hora",
    "Título",
    "Hora",
    "TODOS",
    "Hora total",
    "Hora do arquivo",
    "Resumo das horas em",
  },
  sk = {
    "Súbor",
    "L",
    "Časová značka",
    "Záhlavie",
    "Čas",
    "VŠETKO",
    "Celkový čas",
    "Čas súboru",
    "Časový súhrn pre",
  },
}
local TERMS = {
  File = 1,
  L = 2,
  Timestamp = 3,
  Headline = 4,
  Time = 5,
  ALL = 6,
  ["Total time"] = 7,
  ["File time"] = 8,
  ["Clock summary at"] = 9,
}

local function translate(term, lang)
  local l = M.languages[tostring(lang or "en")] or M.languages.en
  return l[TERMS[term]] or term
end

--- Align a list of rows ("hline" or list of cells) into org table lines,
--- the way `org-table-align` does (numeric columns right-aligned).
function M.format_table(rows)
  return require("org.table").rows_to_lines(rows)
end

local function matcher(match)
  if not match or match == "" then
    return nil
  end
  local pred = require("org.agenda.search").compile(tostring(match))
  return pred
end

local function param_on(v)
  return v ~= nil and v ~= false and v ~= "nil"
end

--- Emacs `org-shorten-string`: cut at a word boundary and add "...".
local function shorten(s, max)
  if vim.fn.strchars(s) <= max then
    return s
  end
  local n = math.max(max - 4, 1)
  for i = n + 1, 2, -1 do
    local head = vim.fn.strcharpart(s, 0, i)
    local nxt = vim.fn.strcharpart(s, i, 1)
    if head:sub(-1) ~= " " and (nxt == " " or nxt == "") then
      return head .. "..."
    end
  end
  return vim.fn.strcharpart(s, 0, math.max(max - 3, 0)) .. "..."
end

--- The files a clocktable reads for :scope, and whether they form one list
--- (Emacs `consp files`). `roots` restricts to one subtree.
local function scope_files(scope, cur, lnum)
  local function with_archives(list)
    local archive = require("org.archive")
    local out, seen = {}, {}
    local function add(f)
      local key = f and (f.filename or f)
      if f and not seen[key] then
        seen[key] = true
        out[#out + 1] = f
      end
    end
    for _, f in ipairs(list) do
      add(f)
      if f.filename then
        local locs = { archive.location_for({ properties = {}, file = f }) }
        for _, hl in ipairs(f.headlines) do
          if hl.properties.ARCHIVE and hl.properties.ARCHIVE ~= "" then
            locs[#locs + 1] = hl.properties.ARCHIVE
          end
        end
        for _, loc in ipairs(locs) do
          local target = archive.parse_location(loc, f.filename).filename
          if target and target ~= f.filename and utils.exists(target) then
            add(files.get(target))
          end
        end
      end
    end
    return out
  end
  scope = scope == nil and "file" or scope
  if type(scope) == "table" then
    -- a list of org.File (the agenda's files)
    return scope, nil, true
  elseif scope == false or scope == "file" or scope == "nil" then
    return { cur }, nil, false
  elseif scope == "agenda" then
    return files.agenda_files(), nil, true
  elseif scope == "agenda-with-archives" then
    return with_archives(files.agenda_files()), nil, true
  elseif scope == "file-with-archives" then
    return with_archives({ cur }), nil, false
  elseif scope == "subtree" or scope == "tree" or tostring(scope):match("^tree%d+$") then
    local hl = cur:headline_at(lnum or 1)
    if not hl then
      error("Before first headline", 0)
    end
    local level = scope == "tree" and 0 or tonumber(tostring(scope):match("^tree(%d+)$"))
    if level then
      while hl.parent do
        hl = hl.parent
        if hl.level <= level then
          break
        end
      end
    end
    return { cur }, { hl }, false
  elseif type(scope) == "string" and scope:match("^%(") then
    local list = {}
    local dir = cur.filename and vim.fn.fnamemodify(cur.filename, ":h") or nil
    for p in scope:gmatch('"([^"]+)"') do
      local path = utils.expand(p, dir)
      local f = files.get(path)
      if f then
        f.display_name = p
        list[#list + 1] = f
      end
    end
    return list, nil, true
  end
  error("Unknown scope: " .. tostring(scope), 0)
end

--- First active (or inactive) timestamp of an entry outside its planning
--- line and CLOCK lines (the TIMESTAMP / TIMESTAMP_IA special properties).
local function entry_timestamp(hl, active)
  local lines = hl.file.lines
  for i = hl.line, hl.body_end or hl.line do
    local l = lines[i]
    if l and i ~= hl.planning_line and not l:match("^%s*CLOCK:") then
      local text = i == hl.line and hl.title or l
      for _, item in ipairs(date.parse_all(text)) do
        if item.date.active == active then
          return item.date:to_string()
        end
      end
    end
  end
end

--- Emacs `org-link-escape`: backslash-escape brackets in a link path.
local function link_escape(s)
  s = s:gsub("(\\*)([%[%]])", function(bs, br)
    return bs .. bs .. "\\" .. br
  end)
  return (s:gsub("(\\+)$", "%1%1"))
end

local COOKIE = "%[%d*%%%]"
local COOKIE2 = "%[%d*/%d*%]"

local function link_display(s)
  s = s:gsub("%[%[([^%]]-)%]%[([^%]]-)%]%]", "%2")
  return (s:gsub("%[%[([^%]]-)%]%]", "%1"))
end

--- Clock data of one file (org-clock-get-table-data).
---@return { file: org.File, total: integer, entries: table[] }
local function table_data(file, roots, params, ts, te)
  local maxlevel = tonumber(params.maxlevel) or 2
  local link = param_on(params.link)
  local props = params._props
  local times, total = clock_sum(roots or file.children, ts, te, matcher(params.match))
  local entries = {}
  local function walk(hl)
    local time = times[hl]
    if time and time > 0 and hl.level <= maxlevel then
      local title = vim.trim(hl.title)
      local headline = title
      if link then
        local search = "*" .. vim.trim((title:gsub(COOKIE, " "):gsub(COOKIE2, " "):gsub("[ \t]+", " ")))
        local desc = vim.trim(link_display((title:gsub(COOKIE, ""):gsub(COOKIE2, ""))))
        local target = file.filename and ("file:" .. file.filename .. "::" .. search) or search
        headline = "[[" .. link_escape(target) .. "][" .. desc .. "]]"
      end
      local tsp
      if param_on(params.timestamp) then
        tsp = hl:get_property("SCHEDULED")
          or hl:get_property("DEADLINE")
          or entry_timestamp(hl, true)
          or entry_timestamp(hl, false)
      end
      local values = {}
      for i, p in ipairs(props) do
        values[i] = hl:get_property(p, param_on(params["inherit-props"])) or ""
      end
      entries[#entries + 1] = {
        level = hl.level,
        headline = headline,
        tags = param_on(params.tags) and hl:get_tags() or {},
        ts = tsp,
        time = time,
        props = values,
      }
    end
    for _, child in ipairs(hl.children) do
      walk(child)
    end
  end
  for _, hl in ipairs(roots or file.children) do
    walk(hl)
  end
  return { file = file, total = total, entries = entries }
end

--- Sort the data rows of the first section after the total row
--- (`:sort (COLUMN . ?TYPE)`, like org-table-sort-lines).
local function sort_rows(rows, spec)
  local col, kind = tostring(spec):match("^%(%s*(%d+)%s*%.%s*%?(%a)%s*%)$")
  col = tonumber(col)
  if not col then
    error("Invalid :sort parameter " .. tostring(spec), 0)
  end
  local data = 0
  local first
  for i, r in ipairs(rows) do
    if r ~= "hline" then
      data = data + 1
      if data == 3 then
        first = i
        break
      end
    end
  end
  if not first then
    return rows
  end
  local s, e = first, first
  while s > 1 and rows[s - 1] ~= "hline" do
    s = s - 1
  end
  while e < #rows and rows[e + 1] ~= "hline" do
    e = e + 1
  end
  local lower = kind:lower()
  local function key(r)
    local f = vim.trim(r[col] or "")
    if lower == "n" then
      return tonumber(f:match("^[-+]?%d*%.?%d+")) or 0
    elseif lower == "t" then
      local d = date.parse(f:match("[<%[]%d%d%d%d%-%d%d%-%d%d[^>%]]*[>%]]") or "")
      if d then
        return d:minutes()
      end
      return date.parse_duration(f:gsub("^[*/]", ""):gsub("[*/]$", "")) or 0
    elseif lower == "a" then
      -- org-string< ignoring case compares upcased strings ("P" < "\\")
      return (link_display(f):gsub("[*/_=~+]", ""):upper())
    end
    error("Invalid sorting type " .. kind, 0)
  end
  local slice = {}
  for i = s, e do
    slice[#slice + 1] = { row = rows[i], key = key(rows[i]), i = i }
  end
  -- sort-subr sorts a reversed list stably and reverses it again: equal
  -- keys keep their order either way
  local reverse = kind ~= lower
  table.sort(slice, function(a, b)
    if a.key ~= b.key then
      if reverse then
        return a.key > b.key
      end
      return a.key < b.key
    end
    return a.i < b.i
  end)
  for i, x in ipairs(slice) do
    rows[s + i - 1] = x.row
  end
  return rows
end

--- Split an org table row into cells ("hline" for rules).
local function row_cells(line)
  if line:match("^%s*|%-") then
    return "hline"
  end
  return require("org.table").split_cells(line)
end

--- One clock table (org-clocktable-write-default) for [ts, te).
---@param ctx { bufnr: integer, lnum?: integer, content?: string[] }
---@return string[] lines, integer total minutes
local function clocktable_single(params, ctx, ts, te)
  local lang = params.lang or "en"
  local cur = type(params.scope) ~= "table" and files.get_buffer(ctx.bufnr) or nil
  local file_list, roots, listp = scope_files(params.scope, cur, ctx.lnum)
  local multifile = listp and not param_on(params.hidefiles) and params.scope ~= "file-with-archives"
  local maxlevel = tonumber(params.maxlevel) or 2
  local compact = param_on(params.compact)
  local level_col = param_on(params.level) and not compact
  local show_ts = param_on(params.timestamp)
  local show_tags = param_on(params.tags)
  local props = {}
  if type(params.properties) == "string" then
    for p in params.properties:gmatch('"([^"]+)"') do
      props[#props + 1] = p
    end
  end
  params._props = props
  local emph = param_on(params.emphasize)
  local indent = compact or param_on(params.indent)
  local percent = params.formula == "%"
  local link = param_on(params.link)
  local narrow = params.narrow
  if narrow == nil or narrow == false then
    narrow = compact and "40!" or nil
  end
  if type(narrow) == "number" and link then
    narrow = narrow .. "!"
  end
  local narrow_cut
  if type(narrow) == "string" then
    narrow_cut = tonumber(narrow:match("^(%d+)!$"))
    if not narrow_cut then
      error("Invalid value " .. narrow .. " of :narrow property in clock table", 0)
    end
  end

  local tables = {}
  for _, f in ipairs(file_list) do
    tables[#tables + 1] = table_data(f, roots, params, ts, te)
  end
  local formatter = clock_cfg().clocktable_formatter
  if type(formatter) == "function" then
    -- org-clock-clocktable-formatter: the data, as Emacs passes it
    local data, sum = {}, 0
    for _, t in ipairs(tables) do
      local entries = {}
      for _, e in ipairs(t.entries) do
        entries[#entries + 1] = {
          level = e.level,
          headline = e.headline,
          tags = e.tags,
          timestamp = e.ts,
          time = e.time,
          properties = e.props,
        }
      end
      data[#data + 1] = { file = t.file.filename, time = t.total, entries = entries }
      sum = sum + t.total
    end
    local out = formatter(data, vim.tbl_extend("force", params, { multifile = multifile }))
    if type(out) == "string" then
      out = vim.split(out, "\n", { plain = true })
    end
    return out or {}, sum
  end
  local total = 0
  local deepest
  for _, t in ipairs(tables) do
    total = total + t.total
    if t.total ~= 0 then
      for _, e in ipairs(t.entries) do
        deepest = math.max(deepest or 0, e.level)
      end
    end
  end
  local tcols = (compact or maxlevel < 2) and 1 or math.min(maxlevel, tonumber(params.tcolumns) or 100, deepest or 1)
  local fmt = date.duration_to_string
  local function tr(term)
    return translate(term, lang)
  end
  local nprops = string.rep("|", #props)
  local function cell_format(fmt_str)
    return function(s)
      return (fmt_str:gsub("%%s", function()
        return s
      end))
    end
  end
  local total_cell = cell_format(clock_cfg().total_time_cell_format or "*%s*")
  local file_cell = cell_format(clock_cfg().file_time_cell_format or "*%s*")

  -- The table text, built like Emacs does and aligned afterwards.
  local text = {}
  if type(narrow) == "number" then
    text[#text + 1] = "|"
      .. (multifile and "|" or "")
      .. (level_col and "|" or "")
      .. (show_ts and "|" or "")
      .. (show_tags and "|" or "")
      .. nprops
      .. string.format("<%d>| |", narrow)
  end
  text[#text + 1] = "|"
    .. (multifile and (tr("File") .. "|") or "")
    .. (level_col and (tr("L") .. "|") or "")
    .. (show_ts and (tr("Timestamp") .. "|") or "")
    .. (show_tags and "Tags |" or "")
    .. (#props > 0 and (table.concat(props, "|") .. "|") or "")
    .. tr("Headline")
    .. "|"
    .. tr("Time")
    .. "|"
    .. string.rep("|", math.max(0, tcols - 1))
    .. (percent and "%|" or "")
  text[#text + 1] = "|-"
  text[#text + 1] = "|"
    .. (multifile and string.format("| %s ", tr("ALL")) or "")
    .. (level_col and "|" or "")
    .. (show_ts and "|" or "")
    .. (show_tags and "|" or "")
    .. nprops
    .. total_cell(tr("Total time"))
    .. "| "
    .. total_cell(fmt(total))
    .. "|"
    .. string.rep("|", math.max(0, tcols - 1))
    .. (percent and (total == 0 and "0.0|" or "100.0|") or "")
  if total > 0 then
    for _, t in ipairs(tables) do
      if t.total > 0 or not param_on(params.fileskip0) then
        text[#text + 1] = "|-"
        if multifile then
          local name = t.file.display_name or vim.fn.fnamemodify(t.file.filename or "", ":t")
          if param_on(params.filetitle) and t.file.settings.title then
            name = t.file.settings.title
          end
          text[#text + 1] = string.format(
            "| %s %s | %s%s%s%s | *%s*|%s%s",
            name,
            level_col and "| " or "",
            show_ts and "| " or "",
            show_tags and "| " or "",
            nprops,
            file_cell(tr("File time")),
            fmt(t.total),
            string.rep("|", math.max(0, tcols - 1)),
            percent and string.format(" %.1f |", 100 * t.total / total) or ""
          )
        end
        if maxlevel > 0 then
          for _, e in ipairs(t.entries) do
            local headline = e.headline
            if narrow_cut then
              local l, d = headline:match("^%[%[(.-)%]%[(.*)%]%]$")
              headline = l and ("[[" .. l .. "][" .. shorten(d, narrow_cut) .. "]]") or shorten(headline, narrow_cut)
            end
            local function field(s)
              if emph and e.level == 1 then
                return "*" .. s .. "* |"
              elseif emph and e.level == 2 then
                return "/" .. s .. "/ |"
              end
              return s .. " |"
            end
            local values = {}
            for i, v in ipairs(e.props) do
              values[i] = v
            end
            text[#text + 1] = "|"
              .. (multifile and "|" or "")
              .. (level_col and (e.level .. "|") or "")
              .. (show_ts and ((e.ts or "") .. "|") or "")
              .. (show_tags and (table.concat(e.tags, ", ") .. "|") or "")
              .. (#props > 0 and (table.concat(values, "|") .. "|") or "")
              .. (indent and e.level > 1 and ("\\_" .. string.rep(" ", 2 * (e.level - 1))) or "")
              .. field((headline:gsub("|", "\\vert{}")))
              .. string.rep("|", math.max(0, math.min(tcols, e.level) - 1))
              .. field(fmt(e.time))
              .. string.rep("|", math.max(0, tcols - e.level))
              .. (percent and string.format("%.1f |", 100 * e.time / total) or "")
          end
        end
      end
    end
  end

  local rows = vim.tbl_map(row_cells, text)
  local tblfm
  if params.formula == nil or params.formula == false or percent then
    for _, l in ipairs(ctx.content or {}) do
      local f = l:match("^%s*(#%+[Tt][Bb][Ll][Ff][Mm]:.*)$")
      if f then
        tblfm = f
        break
      end
    end
  elseif type(params.formula) == "string" then
    tblfm = "#+TBLFM: " .. params.formula
  else
    error("Invalid :formula parameter in clocktable", 0)
  end
  if params.sort then
    sort_rows(rows, params.sort)
  end
  local out = M.format_table(rows)
  if tblfm then
    out = require("org.table").recalc_lines(ctx.bufnr, out, { tblfm }, ctx.lnum)
    out[#out + 1] = tblfm
  end

  local header = params.header
  local caption
  if header == nil or header == false then
    caption = "#+CAPTION: " .. tr("Clock summary at") .. " " .. date.now():clone({ active = false }):to_string()
    if params.block then
      local _, _, range_text = M.special_range(params.block, params.wstart, params.mstart)
      caption = caption .. ", for " .. range_text .. "."
    end
    caption = caption .. "\n"
  else
    caption = tostring(header):gsub("\\n", "\n")
  end
  -- the header is inserted as is: text after its last newline starts the
  -- first table line
  local head = vim.split(caption, "\n", { plain = true })
  out[1] = head[#head] .. out[1]
  head[#head] = nil
  return vim.list_extend(head, out), total
end

local STEP_HEADERS = {
  day = "Daily report: ",
  week = "Weekly report starting on: ",
  semimonth = "Semimonthly report starting on: ",
  month = "Monthly report starting on: ",
  quarter = "Quarterly report starting on: ",
  year = "Annual report starting on: ",
}

--- Start of the step period after the one starting at `m` minutes.
local function next_step(m, step, wstart, mstart)
  local d = date.from_days(math.floor(m / 1440))
  local dow = d:weekday() % 7 -- 0 = Sunday
  local nd
  if step == "day" then
    nd = d:add(1, "d")
  elseif step == "week" then
    nd = d:add(dow == wstart and 7 or (wstart - dow) % 7, "d")
  elseif step == "semimonth" then
    nd = d.day < 16 and mkdate(d.year, d.month, 16) or mkdate(d.year, d.month + 1, 1)
  elseif step == "month" then
    nd = mkdate(d.year, d.month + 1, mstart)
  elseif step == "quarter" then
    nd = mkdate(d.year, d.month + 3, mstart)
  else
    nd = mkdate(d.year + 1, 1, 1)
  end
  -- days, weeks and years start at `extend_today_until` o'clock (Emacs
  -- starts the other periods at midnight)
  local ext = (step == "day" or step == "week" or step == "year") and tonumber(config.opts.extend_today_until) or 0
  return nd:minutes() + ext * 60
end

local function ts_string(m, with_time)
  local d = date.from_days(math.floor(m / 1440))
  if with_time then
    d = d:clone({ hour = math.floor((m % 1440) / 60), min = m % 60 })
  end
  return d:clone({ active = false }):to_string()
end

--- One table per :step period (org-clocktable-steps).
local function clocktable_steps(params, ctx)
  local step = tostring(params.step)
  if not STEP_HEADERS[step] then
    error("Unknown `:step' specification: " .. step, 0)
  end
  local wstart = tonumber(params.wstart) or 1
  local mstart = tonumber(params.mstart) or 1
  local start, stop
  if params.block then
    start, stop = M.special_range(params.block, wstart, mstart)
    start = start or M.matcher_time("<2003-01-01 Thu 00:00>")
  else
    start = M.matcher_time(params.tstart or "<2003-01-01 Thu 00:00>")
    stop = M.matcher_time(params.tend)
  end
  local out = {}
  local guard = 0
  local skipped = false
  while start < stop and guard < 5000 do
    guard = guard + 1
    local nxt = next_step(start, step, wstart % 7, mstart)
    local sub = vim.tbl_extend("force", params, { header = "", step = false, block = false })
    local lines, total = clocktable_single(sub, ctx, start, math.min(stop, nxt))
    skipped = param_on(params.stepskip0) and total == 0
    if not skipped then
      out[#out + 1] = ""
      out[#out + 1] = STEP_HEADERS[step] .. ts_string(start)
      vim.list_extend(out, lines)
    end
    start = nxt
  end
  if skipped then
    -- Emacs deletes a skipped table but keeps the empty line before it
    out[#out + 1] = ""
  end
  return out
end

--- Build clock table lines for a dynamic block. Parameters follow Emacs
--- (`org-dblock-write:clocktable`): :scope :maxlevel :block :tstart :tend
--- :wstart :mstart :step :stepskip0 :fileskip0 :match :emphasize :lang
--- :link :narrow :indent :filetitle :hidefiles :tcolumns :level :sort
--- :compact :timestamp :tags :properties :inherit-props :formula :header.
--- Defaults come from `clock.clocktable_default`.
---@param params table parsed block parameters
---@param bufnr integer buffer containing the block
---@param lnum? integer line of the block (for :scope subtree)
---@param content? string[] the block's previous content (to keep a #+TBLFM)
---@return string[]
function M.clocktable(params, bufnr, lnum, content)
  local defaults = {
    maxlevel = 2,
    lang = "en",
    scope = "file",
    wstart = 1,
    mstart = 1,
    narrow = "40!",
    indent = true,
  }
  params = vim.tbl_extend("force", defaults, clock_cfg().clocktable_default or {}, params or {})
  local ctx = {
    bufnr = (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr,
    lnum = lnum,
    content = content,
  }
  local ok, res = pcall(function()
    if param_on(params.step) then
      if not (param_on(params.block) or (param_on(params.tstart) and param_on(params.tend))) then
        error("Clocktable `:step' can only be used with `:block' or `:tstart', `:tend'", 0)
      end
      return clocktable_steps(params, ctx)
    end
    local ts, te
    if param_on(params.block) then
      ts, te = M.special_range(params.block, params.wstart, params.mstart)
    else
      params.block = nil
      ts = param_on(params.tstart) and M.matcher_time(params.tstart) or nil
      te = param_on(params.tend) and M.matcher_time(params.tend) or nil
    end
    return (clocktable_single(params, ctx, ts, te))
  end)
  if not ok then
    error(res, 0)
  end
  return res
end
