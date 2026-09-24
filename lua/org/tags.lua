---@mod org.tags Setting and aligning tags

local config = require("org.config")
local edit = require("org.edit")
local files = require("org.files")
local parser = require("org.parser")
local utils = require("org.utils")

local M = {}

local ns = vim.api.nvim_create_namespace("org.tags.select")

--- Parse a tag input string (":a:b:" / "a b" / "a:b") into a list.
function M.parse_input(str)
  local out, seen = {}, {}
  for tag in (str or ""):gmatch("[^:%s,]+") do
    if not seen[tag] then
      seen[tag] = true
      out[#out + 1] = tag
    end
  end
  return out
end

--- All known tags: config, current buffer settings, agenda files.
---@return string[]
function M.all_tags(bufnr)
  local seen, out = {}, {}
  local function add(t)
    if t and t ~= "" and not seen[t] then
      seen[t] = true
      out[#out + 1] = t
    end
  end
  local function add_file(f)
    for _, d in ipairs(f:tag_definitions()) do
      add(d.name)
    end
    for _, t in ipairs(f.settings.filetags) do
      add(t)
    end
    for _, hl in ipairs(f.headlines) do
      for _, t in ipairs(hl.tags) do
        add(t)
      end
    end
  end
  for _, spec in ipairs(config.opts.tags or {}) do
    for tok in spec:gmatch("%S+") do
      if tok ~= "{" and tok ~= "}" then
        add((tok:gsub("%(.%)$", "")))
      end
    end
  end
  local b = bufnr or vim.api.nvim_get_current_buf()
  if vim.api.nvim_buf_is_valid(b) and vim.bo[b].filetype == "org" then
    add_file(files.get_buffer(b))
  end
  for _, f in ipairs(files.agenda_files()) do
    add_file(f)
  end
  table.sort(out, function(a, c)
    return a:lower() < c:lower()
  end)
  return out
end

--- Fast tag selection (Emacs org-fast-tag-selection). Returns the new tag
--- list or nil when cancelled.
---@param current string[]
---@param defs { name?: string, key?: string, group?: string }[]
---@param inherited string[]
function M.fast_select(current, defs, inherited)
  local selected = {}
  for _, t in ipairs(current) do
    selected[t] = true
  end
  local order = vim.deepcopy(current)
  -- groups of mutually exclusive tags
  local groups, in_group = {}, nil
  local by_key = {}
  local entries = {}
  for _, d in ipairs(defs) do
    if d.group == "{" then
      in_group = {}
      groups[#groups + 1] = in_group
    elseif d.group == "}" then
      in_group = nil
    elseif d.group then
      entries[#entries + 1] = { newline = true }
    elseif d.name then
      local e = { name = d.name, key = d.key, group = in_group }
      if in_group then
        in_group[#in_group + 1] = d.name
      end
      if d.key then
        by_key[d.key] = e
      end
      entries[#entries + 1] = e
    end
  end

  local function toggle(name, group)
    if selected[name] then
      selected[name] = nil
    else
      if group then
        for _, other in ipairs(group) do
          selected[other] = nil
        end
      end
      selected[name] = true
      if not vim.tbl_contains(order, name) then
        order[#order + 1] = name
      end
    end
  end

  while true do
    local cur = {}
    for _, t in ipairs(order) do
      if selected[t] then
        cur[#cur + 1] = t
      end
    end
    local lines = {
      "Inherited: " .. (#inherited > 0 and (":" .. table.concat(inherited, ":") .. ":") or ""),
      "Current:   " .. (#cur > 0 and (":" .. table.concat(cur, ":") .. ":") or ""),
      "",
    }
    local row, hl_marks = {}, {}
    local function flush()
      if #row > 0 then
        lines[#lines + 1] = table.concat(row, "  ")
        row = {}
      end
    end
    for _, e in ipairs(entries) do
      if e.newline then
        flush()
      else
        local label = string.format("[%s] %s", e.key or " ", e.name)
        if e.group then
          label = label .. "*"
        end
        row[#row + 1] = utils.pad_right(label, 18)
        if selected[e.name] then
          hl_marks[#hl_marks + 1] = e.name
        end
        if #row >= 4 then
          flush()
        end
      end
    end
    flush()
    lines[#lines + 1] = ""
    lines[#lines + 1] = "key: toggle  TAB: type tags  SPC: clear  RET: accept  Esc: cancel   (* exclusive)"
    local buf, win = require("org.ui").float(lines, { title = "Tags" })
    for i, l in ipairs(lines) do
      for _, name in ipairs(hl_marks) do
        local s = l:find("%] " .. utils.escape_pattern(name) .. "%f[%s%*]")
        if not s then
          s = l:find("%] " .. utils.escape_pattern(name) .. "$")
        end
        if s and i > 3 then
          vim.api.nvim_buf_set_extmark(buf, ns, i - 1, s + 1, { end_col = s + 1 + #name, hl_group = "Search" })
        end
      end
    end
    vim.api.nvim_buf_set_extmark(buf, ns, 1, 0, { end_col = #lines[2], hl_group = "Title" })
    vim.cmd("redraw")
    local ch = utils.getchar()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
    if ch == nil then
      return nil
    elseif ch == "\r" or ch == "\n" then
      return cur
    elseif ch == " " then
      selected = {}
    elseif ch == "\t" then
      local typed = utils.input_complete("Tags: ", M.all_tags(), #cur > 0 and (":" .. table.concat(cur, ":") .. ":") or "")
      if typed then
        return M.parse_input(typed)
      end
    elseif by_key[ch] then
      toggle(by_key[ch].name, by_key[ch].group)
    end
  end
end

--- Set tags for a headline (org-set-tags-command).
---@param target? org.Target
---@param tags? string[] set directly without prompting
function M.set_tags(target, tags)
  local bufnr, file, hl = edit.resolve_headline(target)
  if not bufnr then
    return nil
  end
  if not tags then
    local defs = file:tag_definitions()
    local has_keys = false
    for _, d in ipairs(defs) do
      if d.key then
        has_keys = true
      end
    end
    if has_keys then
      tags = M.fast_select(hl.tags, defs, hl:get_inherited_tags())
    else
      local default = #hl.tags > 0 and (":" .. table.concat(hl.tags, ":") .. ":") or ""
      local typed = utils.input_complete("Tags: ", M.all_tags(bufnr), default)
      tags = typed and M.parse_input(typed) or nil
    end
    if not tags then
      return nil
    end
  end
  edit.update_headline(bufnr, hl.line, { tags = tags })
  return tags
end

--- Toggle one tag on a headline.
function M.toggle_tag(target, tag)
  local bufnr, _, hl = edit.resolve_headline(target)
  if not bufnr then
    return nil
  end
  local tags = vim.deepcopy(hl.tags)
  local idx
  for i, t in ipairs(tags) do
    if t == tag then
      idx = i
    end
  end
  if idx then
    table.remove(tags, idx)
  else
    tags[#tags + 1] = tag
  end
  edit.update_headline(bufnr, hl.line, { tags = tags })
  return not idx
end

--- Realign tags on one line.
function M.align(bufnr, lnum)
  bufnr = (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
  local line = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1]
  if not line then
    return
  end
  local new = edit.align_tags_line(line, files.get_buffer(bufnr).settings.todo)
  if new ~= line then
    vim.api.nvim_buf_set_lines(bufnr, lnum - 1, lnum, false, { new })
  end
end

--- Realign every headline's tags in the buffer.
function M.align_all(bufnr)
  if type(bufnr) ~= "number" then
    bufnr = nil
  end
  bufnr = (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local todo_cfg = files.get_buffer(bufnr).settings.todo
  for i, line in ipairs(lines) do
    if line:byte(1) == 42 and parser.headline_level(line) then
      local new = edit.align_tags_line(line, todo_cfg)
      if new ~= line then
        vim.api.nvim_buf_set_lines(bufnr, i - 1, i, false, { new })
      end
    end
  end
end

return M
