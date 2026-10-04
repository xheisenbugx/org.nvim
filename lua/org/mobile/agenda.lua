---@mod org.mobile.agenda agendas.org
---
--- The agenda views written to agendas.org (org-mobile-sumo-agenda-command
--- and org-mobile-create-sumo-agenda).
--- Part of org.mobile, which loads it.

local config = require("org.config")
local utils = require("org.utils")
local shared = require("org.mobile.shared")

local M = require("org.mobile")

local cfg = shared.cfg
local stage_write = shared.stage_write
local staging_dir = shared.staging_dir
local text_of = shared.text_of

---------------------------------------------------------------------------
-- agendas.org
---------------------------------------------------------------------------

local SKIP_TYPES = {
  search = true,
  stuck = true,
  ["stuck-projects"] = true,
  stuck_projects = true,
  todo_tree = true,
  ["todo-tree"] = true,
  tags_tree = true,
  ["tags-tree"] = true,
  occur_tree = true,
  ["occur-tree"] = true,
}
local MATCH_TYPES = { todo = true, tags = true, tags_todo = true, ["tags-todo"] = true }
local BLOCK_TYPES = {
  agenda = true,
  alltodo = true,
  todo = true,
  tags = true,
  tags_todo = true,
  ["tags-todo"] = true,
  search = true,
  stuck = true,
}

local function match_of(b)
  if b.match and b.match ~= "" then
    return b.match
  end
  local kws = b.keywords
  if type(kws) == "table" then
    return table.concat(kws, "|")
  end
  return kws
end

--- The blocks of the agenda written to agendas.org
--- (org-mobile-sumo-agenda-command), each with its `<after>KEYS=... TITLE:
--- ...</after>` title in `mobile_title`.
---@return table[]
function M.sumo_blocks()
  local agenda = require("org.agenda")
  local custom = (config.opts.agenda or {}).custom_commands or {}
  local keys = vim.tbl_keys(custom)
  table.sort(keys)
  local custom_list = {}
  for _, k in ipairs(keys) do
    local cmd = custom[k]
    if type(cmd) == "table" and (cmd.blocks or cmd.types) then
      custom_list[#custom_list + 1] = {
        key = k,
        desc = cmd.description or "",
        blocks = cmd.blocks or cmd.types,
        settings = cmd.settings or cmd.options,
      }
    elseif type(cmd) == "table" and cmd.type then
      local block = vim.tbl_extend("force", {}, cmd)
      block.description, block.settings, block.options = nil, nil, nil
      custom_list[#custom_list + 1] = {
        key = k,
        desc = cmd.description or "",
        type = cmd.type,
        block = block,
        settings = cmd.settings or cmd.options,
      }
    end
  end
  local default_list = {
    { key = "a", desc = "Agenda", type = "agenda", block = { type = "agenda" } },
    { key = "t", desc = "All TODO", type = "alltodo", block = { type = "todo" } },
  }
  local function find(list, key)
    for _, e in ipairs(list) do
      if e.key == key then
        return e
      end
    end
  end
  local mode = cfg().agendas or "all"
  local list
  if mode == "custom" then
    list = custom_list
  elseif mode == "default" then
    list = default_list
  elseif mode == "all" then
    list = vim.list_slice(custom_list)
    if not find(list, "t") then
      table.insert(list, 1, { key = "t", desc = "ALL TODO", type = "alltodo", block = { type = "todo" } })
    end
    if not find(list, "a") then
      table.insert(list, 1, default_list[1])
    end
  elseif type(mode) == "table" then
    local both = vim.list_extend(vim.list_slice(custom_list), default_list)
    list = {}
    for _, k in ipairs(mode) do
      list[#list + 1] = find(both, k)
    end
  else
    list = {}
  end
  local mobile_files = vim.tbl_map(function(e)
    return e.file
  end, M.files_alist())
  local out = {}
  local function add(block, settings, title)
    local nb = agenda.normalize_block(block, settings)
    nb.files = nb.files or nb.org_agenda_files or mobile_files
    nb.mobile_title = "<after>" .. title .. "</after>"
    out[#out + 1] = nb
  end
  for _, e in ipairs(list) do
    local t = e.type
    if e.blocks then
      local n = 0
      for _, b in ipairs(e.blocks) do
        if type(b) == "table" and BLOCK_TYPES[b.type or "agenda"] then
          n = n + 1
          local atitle = e.desc ~= "" and e.desc or (match_of(b) or "")
          add(b, e.settings, string.format("KEYS=%s#%d TITLE: %s", e.key, n, atitle))
        end
      end
    elseif type(t) == "string" and not SKIP_TYPES[t] and BLOCK_TYPES[t] then
      if not (MATCH_TYPES[t] and not (match_of(e.block) or ""):match("%S")) then
        add(e.block, e.settings, string.format("KEYS=%s TITLE: %s", e.key, e.desc ~= "" and e.desc or t))
      end
    end
  end
  return out
end

local function escape_olp(s)
  return (
    s:gsub("[%%:/]", function(c)
      if c == "%" then
        return c
      end
      return string.format("%%%02X", c:byte())
    end)
  )
end

--- The olp: link of a headline (org-mobile-get-outline-path-link).
function M.outline_path_link(hl)
  local path = {}
  local p = hl.parent
  while p do
    table.insert(path, 1, escape_olp(p.title or ""))
    p = p.parent
  end
  return "olp:"
    .. escape_olp(vim.fn.fnamemodify(hl.file.filename or "", ":t"))
    .. ":"
    .. table.concat(path, "/")
    .. "/"
    .. escape_olp(hl.title or "")
end

--- The body of an entry for agendas.org (org-agenda-get-some-entry-text
--- with `planning` kept): drawers removed, common indentation stripped,
--- every line prefixed with `indent`, at most `max` lines.
function M.entry_text(hl, max, indent)
  local src = vim.list_slice(hl.file.lines, hl.line + 1, hl.body_end)
  local lines = {}
  local in_drawer = false
  for _, l in ipairs(src) do
    if in_drawer then
      if l:match("^%s*:END:") then
        in_drawer = false
      end
    elseif l:match("^%s*:[%w_%-]+:%s*$") then
      in_drawer = true
    else
      lines[#lines + 1] = (l:gsub("\t", "        "))
    end
  end
  -- trailing whitespace of the whole text
  while #lines > 0 and not lines[#lines]:match("%S") do
    table.remove(lines)
  end
  if #lines > 0 then
    lines[#lines] = lines[#lines]:gsub("%s+$", "")
  end
  local ind
  for _, l in ipairs(lines) do
    if l:match("%S") then
      local n = #l:match("^ *")
      ind = ind and math.min(ind, n) or n
    end
  end
  for i, l in ipairs(lines) do
    if l:match("%S") then
      lines[i] = l:sub((ind or 0) + 1)
    end
    lines[i] = indent .. lines[i]
  end
  while #lines > 0 and not lines[1]:match("%S") do
    table.remove(lines, 1)
  end
  while #lines > max do
    table.remove(lines)
  end
  return lines
end

local function block_kind(t)
  if t == "agenda" then
    return "agenda"
  elseif t == "todo" then
    return "todo"
  elseif t == "search" then
    return "search"
  end
  return "tags"
end

local function short_heading(block)
  if block.header ~= nil then
    return nil
  end
  if block.type == "todo" then
    local kws = block.keywords
    if type(kws) == "string" then
      kws = vim.split(kws, "[|%s]+", { trimempty = true })
    end
    return "ToDo: " .. ((kws and #kws > 0) and table.concat(kws, "|") or "ALL")
  elseif block.type == "tags" or block.type == "tags_todo" then
    return "Match: " .. (block.match or "")
  elseif block.type == "search" then
    return "Search words: " .. (block.match or "")
  end
end

--- Split a rendered item line into the heading part and its prefix.
local function split_item_line(line, it, kind)
  local ok, prefix = pcall(function()
    return require("org.agenda.render").prefix(it, kind)
  end)
  local pl
  if ok and type(prefix) == "string" and line:sub(1, #prefix) == prefix then
    pl = #prefix
  else
    local head = it.todo or it.title
    local s = head and line:find(head, 1, true)
    pl = s and s - 1 or 0
  end
  return vim.trim(line:sub(pl + 1)), vim.trim(line:sub(1, pl))
end

--- Convert the rendered SUMO agenda into agendas.org lines
--- (org-mobile-write-agenda-for-mobile).
local function agenda_file_lines(S, lines, blocks)
  local starts = S.block_starts or { 1 }
  local header_line, sep_line, block_at = {}, {}, {}
  for i, s in ipairs(starts) do
    if i > 1 then
      sep_line[s - 1] = true
    end
    if not S.day_lines[s] and not S.line_items[s] and lines[s] and lines[s]:match("%S") then
      header_line[s] = i
    end
  end
  local cur = 0
  for l = 1, #lines do
    if starts[cur + 1] and l >= starts[cur + 1] then
      cur = cur + 1
    end
    block_at[l] = cur
  end
  local out = { "#+READONLY" }
  local in_date = false
  for l, line in ipairs(lines) do
    local block = blocks[block_at[l]] or {}
    local it = S.line_items[l]
    if not line:match("%S") then
      out[#out + 1] = ""
    elseif sep_line[l] then
      out[#out + 1] = ""
    elseif header_line[l] then
      in_date = false
      out[#out + 1] = "* " .. (short_heading(block) or line) .. (block.mobile_title or "")
    elseif S.day_lines[l] then
      in_date = true
      out[#out + 1] = "** " .. line
    elseif it and it.headline then
      local text, prefix = split_item_line(line, it, block_kind(block.type))
      out[#out + 1] = (in_date and "***  " or "**  ") .. text .. "<before>" .. prefix .. "</before>"
      if it.type ~= "sexp" then
        local body = M.entry_text(it.headline, 10, "   ")
        if #body == 0 then
          body = { "" }
        end
        vim.list_extend(out, body)
        local hl = it.headline
        local id = hl.properties.ID
        if not (id and id:match("%S")) then
          id = M.outline_path_link(hl)
        end
        vim.list_extend(out, { "   :PROPERTIES:", "   :ORIGINAL_ID: " .. id, "   :END:" })
      end
      out[#out + 1] = ""
    else
      out[#out + 1] = line
    end
  end
  return out
end

--- Temporarily merge `overrides` into `config.opts.agenda` while `fn` runs.
local function with_agenda_options(overrides, fn)
  local acfg = config.opts.agenda
  local saved = {}
  for k, v in pairs(overrides) do
    saved[k] = { acfg[k] }
    acfg[k] = v
  end
  local ok, err = pcall(fn)
  for k, v in pairs(saved) do
    acfg[k] = v[1]
  end
  if not ok then
    error(err, 0)
  end
end

--- Give every entry of the open SUMO agenda an ID
--- (org-mobile-force-id-on-agenda-items). Returns the changed buffers.
local function force_ids(view)
  local S = view.state
  local by_buf = {}
  for _, it in pairs(S.line_items) do
    local hl = it.headline
    if hl and it.type ~= "sexp" and not (hl.properties.ID and hl.properties.ID:match("%S")) then
      local target = view.resolve_target(it)
      if target then
        by_buf[target.bufnr] = by_buf[target.bufnr] or {}
        by_buf[target.bufnr][target.lnum] = true
      end
    end
  end
  local id = require("org.id")
  local bufs = {}
  for bufnr, set in pairs(by_buf) do
    local lnums = vim.tbl_keys(set)
    table.sort(lnums, function(a, b)
      return a > b
    end)
    for _, lnum in ipairs(lnums) do
      id.get_create({ bufnr = bufnr, lnum = lnum })
    end
    bufs[#bufs + 1] = bufnr
  end
  return bufs
end

--- Create agendas.org in the staging directory (org-mobile-create-sumo-agenda).
--- Returns its checksum, or nil when there is no agenda to write.
function M.create_sumo_agenda()
  local blocks = M.sumo_blocks()
  if #blocks == 0 then
    return nil
  end
  require("org.agenda.highlights").setup()
  local view = require("org.agenda.view")
  local content
  with_agenda_options({ compact_blocks = false, sticky = true, window = "float" }, function()
    view.open({ blocks = blocks, multi = true, key = "mobile-sumo", title = "SUMO" }, {})
    local ok, err = pcall(function()
      if cfg().force_id_on_agenda_items ~= false then
        for _, b in ipairs(force_ids(view)) do
          utils.save_buffer_or_warn(b)
        end
        view.refresh()
      end
      local S = view.state
      local lines = vim.api.nvim_buf_get_lines(S.buf, 0, -1, false)
      content = text_of(agenda_file_lines(S, lines, blocks))
    end)
    pcall(view.quit, true)
    if not ok then
      error(err, 0)
    end
  end)
  stage_write(staging_dir() .. "/agendas.org", content)
  return M.md5(content)
end
