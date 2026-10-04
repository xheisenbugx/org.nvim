---@mod org.columns.dblock Column view dynamic block
---
--- The columnview dynamic block (org-dblock-write:columnview).
--- Part of org.columns, which loads it.

local config = require("org.config")
local files = require("org.files")
local utils = require("org.utils")
local shared = require("org.columns.shared")

local M = require("org.columns")

local scope_for = shared.scope_for

---------------------------------------------------------------------------
-- Dynamic block writer
---------------------------------------------------------------------------

--- Tag/property matcher for `:match`, or nil.
local function matcher(match)
  if type(match) ~= "string" or match == "" then
    return nil
  end
  local ok, pred = pcall(require("org.agenda.search").compile, match)
  if not ok then
    error("invalid :match " .. match)
  end
  return pred
end

--- Tags listed in `:exclude-tags` ("(a b)" or "a b").
local function tag_list(v)
  if type(v) ~= "string" then
    return {}
  end
  local out = {}
  for t in v:gsub('[()"]', " "):gmatch("%S+") do
    out[#out + 1] = t
  end
  return out
end

--- A headline title without the objects that cannot be copied into a
--- table: statistics cookies, footnote references, targets, radio
--- targets, inline src blocks and babel calls; `|` becomes `\vert{}`.
--- Emacs org-columns--clean-item.
function M.clean_item(item)
  local s = item
  s = s:gsub("%s*%[%d*%%%]", ""):gsub("%s*%[%d*/%d*%]", "")
  s = s:gsub("%s*%[fn:[^%]]*%]", "")
  s = s:gsub("%s*<<<[^>]*>>>", ""):gsub("%s*<<[^>]*>>", "")
  s = s:gsub("%s*src_[%w%-]+%b[]%b{}", ""):gsub("%s*src_[%w%-]+%b{}", "")
  s = s:gsub("%s*call_[%w%-_]+%b[]%b()%b[]", ""):gsub("%s*call_[%w%-_]+%b()%b[]", "")
  s = s:gsub("%s*call_[%w%-_]+%b[]%b()", ""):gsub("%s*call_[%w%-_]+%b()", "")
  return (vim.trim(s):gsub("|", "\\vert{}"))
end

--- Search string of a heading link (org-link-heading-search-string).
local function heading_search(title)
  local t = title:gsub("%[%d*%%%]", " "):gsub("%[%d*/%d*%]", " "):gsub("[ \t]+", " ")
  return "*" .. vim.trim(t)
end

--- The rows captured for a columnview block, like Emacs
--- org-columns--capture-view: the titles, "hline", then for every entry
--- `{ level = n, hl = headline, cells... }` (display values; ITEM raw).
local function capture(rows, cols, params)
  local pred = matcher(params.match)
  local exclude = tag_list(params["exclude-tags"])
  local has_item = false
  for _, c in ipairs(cols) do
    has_item = has_item or c.prop:upper() == "ITEM"
  end
  local titles = {}
  for i, c in ipairs(cols) do
    titles[i] = c.title
  end
  local out = { titles, "hline" }
  for _, r in ipairs(rows) do
    local row = { level = r.hl.level, hl = r.hl, rel_level = r.rel_level }
    local distinct = {}
    for i, c in ipairs(cols) do
      row[i] = c.prop:upper() == "ITEM" and r.cells[i] or r.display[i]
      if row[i] ~= "" then
        distinct[row[i]] = true
      end
    end
    local n = vim.tbl_count(distinct)
    local empty = n == 0 or (has_item and n == 1)
    local excluded = false
    if #exclude > 0 then
      local tags = r.hl:get_tags()
      for _, t in ipairs(exclude) do
        excluded = excluded or vim.tbl_contains(tags, t)
      end
    end
    if
      not r.hl:is_hidden_by_ancestor()
      and not (params["skip-empty-rows"] and empty)
      and not excluded
      and (not pred or pred(r.hl))
    then
      out[#out + 1] = row
    end
  end
  return out
end

--- The default columnview writer (org-columns-dblock-write-default): the
--- rows as table lines, with hlines, indented and linked items, column
--- groups and a width cookie row when the format has widths.
local function write_default(captured, cols, params, file)
  local item_index
  for i, c in ipairs(cols) do
    if c.prop:upper() == "ITEM" and not item_index then
      item_index = i
    end
  end
  local hlines, indent = params.hlines, params.indent and params.indent ~= false
  local out = { captured[1], "hline" }
  for k = 3, #captured do
    local row = captured[k]
    -- the entry's own level, also in a local or :id view (Emacs
    -- org-columns--capture-view keeps org-current-level)
    local level = row.level
    if out[#out] ~= "hline" and (hlines == true or (type(hlines) == "number" and row.level <= hlines)) then
      out[#out + 1] = "hline"
    end
    local cells = {}
    for i = 1, #cols do
      cells[i] = row[i] or ""
    end
    if item_index then
      local raw = cells[item_index]
      local item = M.clean_item(raw)
      if params.link then
        local search = heading_search(raw)
        local target = file.filename and ("file:" .. file.filename .. "::" .. search) or search
        -- org-link-make-string escapes brackets in the link
        item = "[[" .. target:gsub("[%[%]]", "\\%0") .. "][" .. item .. "]]"
      end
      if indent and level > 1 then
        item = "\\_" .. string.rep(" ", 2 * (level - 1)) .. item
      end
      cells[item_index] = item
    end
    for i, v in ipairs(cells) do
      if i ~= item_index then
        cells[i] = v:gsub("|", "\\vert{}")
      end
    end
    out[#out + 1] = cells
  end
  if params.vlines then
    for i, row in ipairs(out) do
      if row ~= "hline" then
        out[i] = vim.list_extend({ "" }, row)
      end
    end
    local groups = { "/" }
    for _ = 1, #cols do
      groups[#groups + 1] = "<>"
    end
    out[#out + 1] = groups
  end
  local widths, any = {}, false
  for i, c in ipairs(cols) do
    widths[i] = c.width and ("<" .. c.width .. ">") or ""
    any = any or c.width ~= nil
  end
  if any then
    table.insert(out, 1, widths)
  end
  return out, any
end

function M.dblock(params, ctx)
  local file = files.get_buffer(ctx.bufnr)
  local id = params.id
  local roots, fmt
  if id == "local" or id == nil then
    local hl = file:headline_at(ctx.start_line)
    fmt, roots = scope_for(file, ctx.start_line)
    if hl then
      roots = { hl }
    end
  elseif type(id) == "string" and id:match("^file:") then
    local path = utils.expand(id:sub(6), file.filename and vim.fn.fnamemodify(file.filename, ":h") or nil)
    local f = files.get(path)
    if not f then
      return { "# file not found: " .. path }
    end
    file = f
    fmt, roots = scope_for(f, nil)
  elseif type(id) == "string" and id ~= "global" then
    local found
    for _, f in ipairs(files.agenda_files_with_current()) do
      found = f:find_by_id(id) or f:find_by_custom_id(id)
      if found then
        break
      end
    end
    if not found then
      return { "# no entry with ID " .. id }
    end
    file = found.file
    fmt, roots = scope_for(found.file, found.line)
    roots = { found }
  else
    fmt, roots = scope_for(file, nil)
  end
  if params.format then
    fmt = params.format
  end
  local cols = M.parse_format(fmt)
  local rows = M.compute(roots, cols, { maxlevel = tonumber(params.maxlevel), update = true })
  local captured = capture(rows, cols, params)
  -- :formatter (a global Lua function name) or columns_dblock_formatter
  local formatter = params.formatter
  if type(formatter) == "string" then
    formatter = _G[formatter] or error("unknown :formatter " .. formatter)
  end
  formatter = formatter or config.opts.columns_dblock_formatter
  if type(formatter) == "function" then
    return formatter(captured, params)
  end
  local out, has_widths = write_default(captured, cols, params, file)
  -- Like Emacs, keep the keywords (#+NAME: ...) above the table and the
  -- #+TBLFM lines below it, and recalculate.
  local tbl = require("org.table")
  local keywords, tblfm = {}, {}
  for _, l in ipairs(vim.api.nvim_buf_get_lines(ctx.bufnr, ctx.start_line, ctx.end_line - 1, false)) do
    if tbl.is_tblfm(l) then
      tblfm[#tblfm + 1] = vim.trim(l)
    elseif l:match("^%s*#%+") and #tblfm == 0 and not tbl.is_table_line(l) then
      keywords[#keywords + 1] = vim.trim(l)
    end
  end
  local lines = require("org.clock").format_table(out)
  if #tblfm > 0 then
    lines = tbl.recalc_lines(ctx.bufnr, lines, tblfm, ctx.start_line)
  end
  if has_widths then
    -- shrink the columns once the block is written (org-table-shrink)
    local bufnr, start = ctx.bufnr, ctx.start_line + #keywords + 1
    vim.schedule(function()
      if vim.api.nvim_buf_is_valid(bufnr) then
        pcall(tbl.shrink, bufnr, start)
      end
    end)
  end
  return vim.list_extend(vim.list_extend(keywords, lines), tblfm)
end
