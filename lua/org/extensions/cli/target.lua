---@mod org.extensions.cli.target Headings a command names
---
--- Finding the headings of a TARGET or query (`find_headlines`,
--- `resolve_target`, `open_target`) and the helpers that print them and
--- read numeric flags. Part of org.extensions.cli.run, which loads it.

local data = require("org.extensions.cli.data")
local schema = require("org.extensions.cli.schema")

local M = require("org.extensions.cli.run")

local fail = M.fail
local arg_path = M.arg_path

local function short_path(p)
  return p and require("org.utils").abbreviate(p) or nil
end
M.short_path = short_path

--- Load a file into a buffer (filetype org) and return its number.
local function load_buffer(path)
  local bufnr = require("org.utils").load_buffer(path)
  if vim.bo[bufnr].filetype ~= "org" then
    vim.bo[bufnr].filetype = "org"
  end
  return bufnr
end
M.load_buffer = load_buffer

local function headline_line(hl)
  local parts = { string.rep("*", hl.level) }
  if hl.todo then
    parts[#parts + 1] = hl.todo
  end
  if hl.priority then
    parts[#parts + 1] = "[#" .. hl.priority .. "]"
  end
  parts[#parts + 1] = hl:plain_title()
  local tags = hl.tags or {}
  if #tags > 0 then
    parts[#parts + 1] = ":" .. table.concat(tags, ":") .. ":"
  end
  return string.format("%s:%d: %s", short_path(hl.file.filename), hl.line, table.concat(parts, " "))
end
M.headline_line = headline_line

local function int_flag(flags, key)
  local v = flags[key]
  if v == nil then
    return nil
  end
  local n = tonumber(v)
  if not n or n < 1 or n ~= math.floor(n) then
    fail(string.format("%s needs a positive whole number, not %s", schema.BY_KEY[key].names[1], v), "bad_value")
  end
  return n
end
M.int_flag = int_flag

--- The org files a `FILE` of a query names: agenda files by path, name or
--- name without extension, else the file itself when it exists.
local function files_named(name, files)
  local want = arg_path(name)
  local sel = {}
  for _, f in ipairs(files) do
    local fname = f.filename or ""
    local tail = vim.fn.fnamemodify(fname, ":t")
    if
      fname == want
      or vim.fn.resolve(fname) == vim.fn.resolve(want)
      or tail == name
      or vim.fn.fnamemodify(tail, ":r") == name
    then
      sel[#sel + 1] = f
    end
  end
  if #sel == 0 and vim.fn.filereadable(want) == 1 then
    local f = require("org.files").get(want)
    if f then
      sel[1] = f
    end
  end
  return sel
end
M.files_named = files_named

--- Headlines matching `query`: an `id:` or ID, `FILE:LINE` (the entry
--- containing that line of any org file), `FILE::#CUSTOM_ID`,
--- `FILE::HEADING` (a file of the agenda, by path or name, or any org
--- file, and a title in it, `*` stars allowed, as in an org link), a ql
--- query when ql is enabled, else a case-insensitive title substring (an
--- exact title wins).
function M.find_headlines(query)
  local files = require("org.files").agenda_files()
  local items = require("org.agenda.items")
  query = vim.trim(query)
  local id = query:match("^id:(.+)$")
  local file_part, head_part = query:match("^(.-)::(.+)$")
  if not file_part then
    local f, l = query:match("^(.-[^:]):(%d+)$")
    -- FILE: a path, else (as in FILE::TITLE) an agenda file's name
    local named = {}
    if f and vim.fn.filereadable(arg_path(f)) == 1 then
      named = { require("org.files").get(arg_path(f)) }
    elseif f then
      named = files_named(f, files)
    end
    if #named > 0 then
      local found = {}
      for _, file in ipairs(named) do
        found[#found + 1] = file:headline_at(tonumber(l))
      end
      return found
    end
  end
  if file_part and file_part ~= "" then
    files = files_named(file_part, files)
    local cid = head_part:match("^#(.+)$")
    if cid then
      local found = {}
      items.each_headline(files, { all = true }, function(hl)
        if hl.properties.CUSTOM_ID == cid then
          found[#found + 1] = hl
        end
      end)
      return found
    end
    query = vim.trim((head_part:gsub("^%*+%s*", "")))
  else
    file_part = nil
  end
  local found, exact, by_id = {}, {}, {}
  if not id and not file_part and require("org.extensions").enabled("ql") then
    local ok, res = pcall(require("org.extensions.ql").select, files, query)
    if ok and #res > 0 then
      return res
    end
  end
  local q = query:lower()
  items.each_headline(files, { all = true }, function(hl)
    if id then
      if hl.properties.ID == id then
        found[#found + 1] = hl
      end
    else
      local t = hl:plain_title():lower()
      if hl.properties.ID == query then
        by_id[#by_id + 1] = hl
      elseif t == q then
        exact[#exact + 1] = hl
      elseif t:find(q, 1, true) then
        found[#found + 1] = hl
      end
    end
  end)
  return #by_id > 0 and by_id or #exact > 0 and exact or found
end

--- The one headline `query` names (`--pick N` among several), or a
--- `not_found` / `ambiguous` failure.
---@return org.Headline
function M.resolve_target(query, flags)
  query = vim.trim(query or "")
  if query == "" then
    fail("a heading is needed (id:ID, FILE:LINE, FILE::TITLE or title words)", "usage")
  end
  local hls = M.find_headlines(query)
  local pick = int_flag(flags, "pick")
  if #hls == 0 then
    fail("no heading matches " .. query, "not_found", { query = query })
  end
  if pick and not hls[pick] then
    fail(string.format("--pick %s: pick 1 to %d", flags.pick, #hls), "usage", { count = #hls })
  end
  if #hls > 1 and not pick then
    local lines = { "several headings match " .. query .. " (--pick N):" }
    local candidates = {}
    for i, hl in ipairs(hls) do
      lines[#lines + 1] = string.format("%3d  %s", i, headline_line(hl))
      candidates[i] = data.headline(hl)
    end
    fail(table.concat(lines, "\n"), "ambiguous", { query = query, candidates = candidates })
  end
  return hls[pick or 1]
end

--- The buffer target of a headline found on disk: (bufnr, lnum).
function M.open_target(hl, flags)
  M.guard(hl.file.filename, flags)
  local bufnr = load_buffer(hl.file.filename)
  local file = require("org.files").get_buffer(bufnr)
  local target = file:headline_at(hl.line)
  if not target then
    fail("the heading moved: " .. headline_line(hl), "failed")
  end
  ---@cast target -nil
  return bufnr, target.line
end

--- The headline at (bufnr, lnum) of the current buffer text.
function M.headline_at(bufnr, lnum)
  return require("org.files").get_buffer(bufnr):headline_at(lnum)
end
