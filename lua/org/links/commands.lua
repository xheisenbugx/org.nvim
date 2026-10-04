---@mod org.links.commands Other link commands
---
--- Link display toggle, next/previous link, the links of the entry
--- at the cursor, C-c C-o on headlines, link export through custom
--- types, keyword files and the mark ring. Part of org.links, which
--- loads it.

local config = require("org.config")
local files = require("org.files")
local utils = require("org.utils")
local shared = require("org.links.shared")

local M = require("org.links")

---------------------------------------------------------------------------
-- Misc
---------------------------------------------------------------------------

--- Toggle descriptive / literal display of links in the buffer
--- (org-toggle-link-display). Only link concealing changes.
function M.toggle_link_display()
  local bufnr = vim.api.nvim_get_current_buf()
  local cur = vim.b[bufnr].org_link_descriptive
  if cur == nil then
    cur = config.opts.ui.conceal_links ~= false
  end
  vim.b[bufnr].org_link_descriptive = not cur
  if vim.wo.conceallevel == 0 then
    vim.wo.conceallevel = 2
  end
  if utils.is_org(bufnr) then
    vim.cmd("syntax clear")
    require("org.syntax").apply(bufnr)
  end
  utils.notify(cur and "Literal link display" or "Descriptive link display")
end

--- Lines whose links are not links for Emacs (src, example, export and
--- comment blocks, comments, fixed-width lines, node properties and
--- keywords other than TITLE, AUTHOR, DATE and CAPTION).
local function ignored_lines(lines)
  local skip = {}
  local block
  local in_props = false
  for i, l in ipairs(lines) do
    local low = l:lower()
    if block then
      skip[i] = true
      if low:match("^%s*#%+end_" .. block) then
        block = nil
      end
    else
      local kind = low:match("^%s*#%+begin_(%a+)")
      if kind == "src" or kind == "example" or kind == "export" or kind == "comment" then
        block = kind
        skip[i] = true
      elseif low:match("^%s*:properties:%s*$") then
        in_props = true
        skip[i] = true
      elseif in_props then
        skip[i] = true
        if low:match("^%s*:end:%s*$") then
          in_props = false
        end
      elseif l:match("^%s*#%s") or l:match("^%s*#$") or l:match("^%s*:%s") or l:match("^%s*:$") then
        skip[i] = true
      else
        local key = l:match("^%s*#%+([%w_]+):")
        if key and not ({ TITLE = true, AUTHOR = true, DATE = true, CAPTION = true })[key:upper()] then
          skip[i] = true
        end
      end
    end
  end
  return skip
end

--- Spans of inline code and verbatim (`~...~`, `=...=`) in `line`.
local function verbatim_spans(line)
  local spans = {}
  local init = 1
  while true do
    local s = line:find("[=~]", init)
    if not s then
      break
    end
    local m = line:sub(s, s)
    local pre = line:sub(s - 1, s - 1)
    local nxt = line:sub(s + 1, s + 1)
    if (pre == "" or pre:match("[%s%(%{'\"%-]")) and nxt ~= "" and not nxt:match("%s") then
      local e = s + 1
      local found
      while true do
        e = line:find(m, e + 1, true)
        if not e then
          break
        end
        local after = line:sub(e + 1, e + 1)
        if not line:sub(e - 1, e - 1):match("%s") and (after == "" or after:match("[%s%-%.,;:!%?'\"%)%}%[%]]")) then
          found = e
          break
        end
      end
      if found then
        spans[#spans + 1] = { s, found }
        init = found + 1
      else
        init = s + 1
      end
    else
      init = s + 1
    end
  end
  return spans
end

--- Links of `line` that Emacs treats as links.
local function real_links(line)
  local spans = verbatim_spans(line)
  return vim.tbl_filter(function(lk)
    for _, sp in ipairs(spans) do
      if lk.start_col >= sp[1] and lk.start_col <= sp[2] then
        return false
      end
    end
    return true
  end, M.parse_links(line))
end

M.verbatim_spans = verbatim_spans
M.real_links = real_links
M.ignored_lines = ignored_lines

M._search_failed = nil

--- Move to the next (dir = 1) or previous (dir = -1) link of any kind.
--- Repeating a failed search wraps around the buffer (org-next-link).
local function goto_link(dir)
  local bufnr = vim.api.nvim_get_current_buf()
  local lnum, col = utils.cursor()
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  local last = #lines
  local skip = utils.is_org() and ignored_lines(lines) or {}
  local f = M._search_failed
  local wrapped = false
  if f and f.bufnr == bufnr and f.dir == dir and f.lnum == lnum and f.col == col then
    wrapped = true
    if dir > 0 then
      lnum, col = 1, 0
    else
      lnum, col = last, math.huge
    end
  end
  M._search_failed = nil
  local l = lnum
  while l >= 1 and l <= last do
    local found
    if not skip[l] then
      local list = real_links(lines[l])
      if dir > 0 then
        for _, lk in ipairs(list) do
          if l > lnum or lk.start_col > col or (wrapped and lk.start_col >= col) then
            found = lk
            break
          end
        end
      else
        for i = #list, 1, -1 do
          local lk = list[i]
          if l < lnum or lk.start_col < col then
            found = lk
            break
          end
        end
      end
    end
    if found then
      vim.cmd("normal! m'")
      vim.api.nvim_win_set_cursor(0, { l, found.start_col - 1 })
      pcall(vim.cmd, "normal! zv")
      if wrapped then
        utils.notify(
          dir > 0 and "Link search wrapped back to beginning of buffer" or "Link search wrapped back to end of buffer"
        )
      end
      return true
    end
    l = l + dir
  end
  local c = vim.api.nvim_win_get_cursor(0)
  M._search_failed = { bufnr = bufnr, dir = dir, lnum = c[1], col = c[2] + 1 }
  return false
end

function M.next_link()
  for _ = 1, math.max(vim.v.count, 1) do
    if not goto_link(1) then
      utils.notify("No further link found")
      return
    end
  end
end

function M.prev_link()
  for _ = 1, math.max(vim.v.count, 1) do
    if not goto_link(-1) then
      utils.notify("No further link found")
      return
    end
  end
end

--- Links in the entry at the cursor, from its headline to the next
--- headline, without duplicates (org-offer-links-in-entry). Links in
--- comments, keywords and properties count (org-open-at-point opens
--- them); links in src, example and export blocks and verbatim do not.
function M.entry_links()
  if not utils.is_org() then
    return {}
  end
  local lnum = utils.cursor()
  local hl = files.get_buffer(0):headline_at(lnum)
  if not hl then
    return {}
  end
  local out, seen = {}, {}
  local last = hl.body_end or hl.line
  local lines = vim.api.nvim_buf_get_lines(0, hl.line - 1, last, false)
  local block
  for l, line in ipairs(lines) do
    local low = line:lower()
    if block then
      if low:match("^%s*#%+end_" .. block) then
        block = nil
      end
    else
      local kind = low:match("^%s*#%+begin_(%a+)")
      if kind == "src" or kind == "example" or kind == "export" then
        block = kind
      else
        for _, lk in ipairs(real_links(line)) do
          if not seen[lk.raw] then
            seen[lk.raw] = true
            lk.lnum = hl.line + l - 1
            out[#out + 1] = lk
          end
        end
      end
    end
  end
  return out
end

--- On a headline without a link at the cursor, open one of the entry's
--- links, or all of them (org-offer-links-in-entry). Without links, open
--- the entry's attachment directory when it exists. Returns false when
--- there is nothing to open.
function M.open_entry_links(arg)
  arg = arg or vim.v.count
  local list = M.entry_links()
  local bufnr = vim.api.nvim_get_current_buf()
  if #list == 0 then
    local ok, dir = pcall(function()
      return require("org.attach").dir_for({ bufnr = bufnr, lnum = utils.cursor() })
    end)
    if ok and dir and utils.is_dir(dir) then
      utils.notify("Opening attachment")
      vim.cmd("edit " .. vim.fn.fnameescape(dir))
      return true
    end
    utils.notify("No links")
    return false
  end
  local chosen = { list[1] }
  if #list > 1 then
    local labels = {}
    for i, lk in ipairs(list) do
      labels[i] = lk.desc and (lk.desc .. " (" .. lk.target .. ")") or lk.target
    end
    labels[#labels + 1] = "Open all links"
    local pick, idx = utils.select(labels, { prompt = "Select link to open" })
    if not pick then
      return
    end
    chosen = idx > #list and list or { list[idx] }
  end
  local win = vim.api.nvim_get_current_win()
  local pos = vim.api.nvim_win_get_cursor(win)
  for i, lk in ipairs(chosen) do
    if i > 1 and vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_set_current_win(win)
      vim.api.nvim_win_set_buf(win, bufnr)
      vim.api.nvim_win_set_cursor(win, pos)
    end
    M.open(lk.target, { bufnr = bufnr, link = lk, arg = arg, avoid = { lk.lnum, lk.start_col + 2 } })
  end
  return true
end

--- Tag of the headline under the cursor, when the cursor is on the tags.
local function tag_at_cursor(line, col)
  local s, e = line:find("%s:[^%s]+:%s*$")
  if not s then
    return nil
  end
  s = s + 1
  e = line:find(":%s*$", s + 1)
  if col < s or col > e then
    return nil
  end
  local pos = s
  for tag in line:sub(s + 1, e - 1):gmatch("[^:]+") do
    -- the colon before a tag belongs to it
    if col >= pos and col <= pos + #tag then
      return tag
    end
    pos = pos + #tag + 1
  end
end

--- C-c C-o: open the link / footnote / date at point; on the tags of a
--- headline, show a tags agenda for the tag; elsewhere on a headline,
--- offer the entry's links (org-open-at-point).
function M.open_at_point_or_entry()
  local arg = vim.v.count
  local r = require("org.context").open_at_point()
  if r ~= false then
    return r
  end
  local line = vim.api.nvim_get_current_line()
  if not require("org.parser").headline_level(line) then
    return false
  end
  local bufnr = vim.api.nvim_get_current_buf()
  local _, col = utils.cursor()
  local tag = tag_at_cursor(line, col)
  if tag then
    r = require("org.agenda").open_tags(tag, arg > 0)
  else
    r = M.open_entry_links(arg)
  end
  if r ~= false then
    M.run_follow_hook(bufnr)
  end
  return r
end

--- Export a link with its type's `export` function (org-link-parameters
--- `:export`). `backend` is "html", "md", "latex" or "ascii". Returns nil
--- when the type has none (or it returns nil).
function M.export_link(path, desc, backend)
  local scheme, rest = path:match("^([%a][%w+%-]*):(.*)$")
  local t = M.link_type(scheme)
  if t and type(t.export) == "function" then
    local r = t.export(rest, desc, backend)
    if type(r) == "string" then
      return r
    end
  end
end

--- C-c ' on `#+INCLUDE:`, `#+SETUPFILE:` or `#+BIBLIOGRAPHY:` visits the
--- file (org-edit-special). Returns false on other lines.
function M.open_keyword_file(line, bufnr)
  local key, value = line:match("^%s*#%+([%w_]+):%s*(.-)%s*$")
  if not key or not ({ INCLUDE = true, SETUPFILE = true, BIBLIOGRAPHY = true })[key:upper()] then
    return false
  end
  if value == "" then
    utils.warn("No file to edit")
    return true
  end
  local f = value:match('^"(.-)"') or value:match("^%S+")
  if f:match("^%a[%w+.%-]*://") then
    utils.warn("Files located with a URL cannot be edited")
    return true
  end
  M.open("file:" .. M.resolve_path(f, bufnr or 0), { bufnr = bufnr })
  return true
end

--- Jump back to the position before the last link was followed
--- (org-mark-ring-goto).
function M.mark_ring_goto()
  vim.cmd("normal! \15")
end
