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

--- Is `name` a regexp member of a tag group (`{P@.+}`)?
local function is_regexp_tag(name)
  return name:match("^{.*}$") ~= nil
end

--- Tags used in a file: headline tags and #+FILETAGS (org-get-buffer-tags).
local function buffer_tags(f, add)
  for _, t in ipairs(f.settings.filetags) do
    add(t)
  end
  for _, hl in ipairs(f.headlines) do
    for _, t in ipairs(hl.tags) do
      add(t)
    end
  end
end

--- Tags offered for completion, like Emacs org-set-tags-command: the tag
--- definitions of the buffer (`#+TAGS` or the `tags` option), or the tags
--- used in the buffer when there are none; with
--- `complete_tags_always_offer_all_agenda_tags`, also every tag of the
--- agenda files.
---@return string[]
function M.all_tags(bufnr)
  local seen, out = {}, {}
  local function add(t)
    if t and t ~= "" and not seen[t] and not is_regexp_tag(t) then
      seen[t] = true
      out[#out + 1] = t
    end
  end
  local b = bufnr or vim.api.nvim_get_current_buf()
  local file = vim.api.nvim_buf_is_valid(b) and vim.bo[b].filetype == "org" and files.get_buffer(b) or nil
  local defined = false
  local defs = file and file:tag_definitions() or {}
  if not file then
    for _, spec in ipairs(config.opts.tags or {}) do
      for tok in spec:gmatch("%S+") do
        if not tok:match("^[{}%[%]:]$") and tok ~= "\\n" then
          defs[#defs + 1] = { name = (tok:gsub("%(.%)$", "")) }
        end
      end
    end
  end
  for _, d in ipairs(defs) do
    if d.name then
      defined = true
      add(d.name)
    end
  end
  if file and not defined then
    buffer_tags(file, add)
  end
  if config.opts.complete_tags_always_offer_all_agenda_tags then
    for _, f in ipairs(files.agenda_files()) do
      for _, d in ipairs(f:tag_definitions()) do
        add(d.name)
      end
      buffer_tags(f, add)
    end
  end
  table.sort(out, function(a, c)
    return a:lower() < c:lower()
  end)
  return out
end

---------------------------------------------------------------------------
-- Tag groups (org-group-tags)
---------------------------------------------------------------------------

--- Group tags defined by tag definitions (`[ GTD : Control Persp ]`,
--- `{ Context : @Home @Work }`): { [group tag] = { members } }. Members may
--- be `{regexp}` strings.
---@param defs { name?: string, group?: string }[]
---@param into? table<string, string[]>
function M.groups_from_definitions(defs, into)
  local groups = into or {}
  local open, head = false, nil
  for i, d in ipairs(defs) do
    if d.group == "{" or d.group == "[" then
      open, head = true, nil
    elseif d.group == "}" or d.group == "]" then
      open, head = false, nil
    elseif d.group == ":" then
      local prev = defs[i - 1]
      if open and prev and prev.name then
        head = prev.name
        groups[head] = groups[head] or {}
      end
    elseif d.name and head then
      if not vim.tbl_contains(groups[head], d.name) then
        table.insert(groups[head], d.name)
      end
    end
  end
  return groups
end

--- Tag groups used by tag matches: the current buffer's, the `tags`
--- option's and every agenda file's (org-tag-groups-alist-for-agenda). nil
--- when `group_tags` is off.
---@return table<string, string[]>|nil
function M.match_groups()
  if not config.opts.group_tags then
    return nil
  end
  local groups = {}
  local b = vim.api.nvim_get_current_buf()
  if vim.bo[b].filetype == "org" then
    M.groups_from_definitions(files.get_buffer(b):tag_definitions(), groups)
  end
  local defs = {}
  for _, spec in ipairs(config.opts.tags or {}) do
    for tok in spec:gmatch("%S+") do
      if tok:match("^[{}%[%]:]$") then
        defs[#defs + 1] = { group = tok }
      else
        defs[#defs + 1] = { name = (tok:gsub("%(.%)$", "")) }
      end
    end
  end
  M.groups_from_definitions(defs, groups)
  local ok, list = pcall(files.agenda_files)
  for _, f in ipairs(ok and list or {}) do
    if #f.settings.tags > 0 then
      M.groups_from_definitions(f:tag_definitions(), groups)
    end
  end
  return groups
end

--- Expand a group tag (case-insensitively, like Emacs) into its tags and
--- regexps, recursively (org--tags-expand-group). nil when `tag` is not a
--- group tag.
---@param tag string
---@param groups table<string, string[]>
---@return { names: table<string, boolean>, regexps: string[] }|nil
function M.expand_group(tag, groups)
  local by_lower = {}
  for k in pairs(groups) do
    by_lower[k:lower()] = k
  end
  local key = by_lower[tag:lower()]
  if not key then
    return nil
  end
  local out = { names = {}, regexps = {} }
  local seen = {}
  local function walk(name)
    if seen[name] then
      return
    end
    seen[name] = true
    local re = name:match("^{(.*)}$")
    if re then
      out.regexps[#out.regexps + 1] = re
      return
    end
    out.names[name] = true
    local g = by_lower[name:lower()]
    for _, m in ipairs(g and groups[g] or {}) do
      walk(m)
    end
  end
  walk(key)
  return out
end

--- Toggle tag group expansion in matches (org-toggle-tags-groups, C-c C-x q).
function M.toggle_groups()
  config.opts.group_tags = not config.opts.group_tags
  utils.notify("Groups tags support has been turned " .. (config.opts.group_tags and "on" or "off"))
  return true
end

---------------------------------------------------------------------------
-- Fast tag selection
---------------------------------------------------------------------------

M.FAST_KEYS = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ{|}~"

--- The fast selection table: entries in display order with their keys.
--- Tags without a key get one automatically, like Emacs: the first letter
--- (after a leading `@`) when it is free, else the first free character of
--- `FAST_KEYS`.
---@return table[] entries, table<string, table> by_key, string[][] groups
local function fast_table(defs, todo_keys)
  local explicit = {}
  for _, d in ipairs(defs) do
    if d.key then
      explicit[d.key] = true
    end
  end
  for _, t in ipairs(todo_keys or {}) do
    explicit[t.key] = true
  end
  local used = {}
  local pool = vim.split(M.FAST_KEYS, "")
  local entries, by_key, groups = {}, {}, {}
  local in_group, in_taggroup = nil, false
  for i, d in ipairs(defs) do
    if d.group == "{" then
      in_group = {}
      groups[#groups + 1] = in_group
      entries[#entries + 1] = { open = "{" }
    elseif d.group == "}" then
      in_group = nil
      entries[#entries + 1] = { close = "}" }
    elseif d.group == "[" then
      in_taggroup = true
      entries[#entries + 1] = { open = "[" }
    elseif d.group == "]" then
      in_taggroup = false
      entries[#entries + 1] = { close = "]" }
    elseif d.group == ":" then
      if entries[#entries] and entries[#entries].name then
        entries[#entries].group_tag = true
      end
    elseif d.group then
      entries[#entries + 1] = { newline = true }
    elseif d.name and not is_regexp_tag(d.name) then
      local key = d.key
      if not key then
        local auto = d.name:gsub("^@", ""):sub(1, 1):lower()
        if auto ~= "" and not used[auto] and not explicit[auto] then
          key = auto
        else
          while pool[1] and (used[pool[1]] or explicit[pool[1]]) do
            table.remove(pool, 1)
          end
          key = pool[1] or " "
        end
      end
      local e = { name = d.name, key = key, group = in_group, in_taggroup = in_taggroup, index = i }
      if in_group then
        in_group[#in_group + 1] = d.name
      end
      used[key] = true
      if key ~= " " and not by_key[key] then
        by_key[key] = e
      end
      entries[#entries + 1] = e
    end
  end
  return entries, by_key, groups
end

--- Add or remove a tag; adding a tag of an exclusive group removes the
--- other tags of that group (org--add-or-remove-tag).
local function add_or_remove(tag, current, groups)
  for i, t in ipairs(current) do
    if t == tag then
      table.remove(current, i)
      return current
    end
  end
  for _, g in ipairs(groups or {}) do
    if vim.tbl_contains(g, tag) then
      current = vim.tbl_filter(function(t)
        return t == tag or not vim.tbl_contains(g, t)
      end, current)
    end
  end
  current[#current + 1] = tag
  return current
end

--- Tags in table order, then the others in their order.
local function sort_tags(current, entries)
  local index = {}
  for i, e in ipairs(entries) do
    if e.name and not index[e.name] then
      index[e.name] = i
    end
  end
  local known, unknown = {}, {}
  for _, t in ipairs(current) do
    if index[t] then
      known[#known + 1] = t
    else
      unknown[#unknown + 1] = t
    end
  end
  table.sort(known, function(a, b)
    return index[a] < index[b]
  end)
  return vim.list_extend(known, unknown)
end

local function tagstr(list)
  return #list > 0 and (":" .. table.concat(list, ":") .. ":") or ""
end

--- Render the selection grid.
local function render(entries, current, inherited, exit_next, todo_keys, groups_on)
  local lines = {
    "Inherited: " .. tagstr(inherited),
    "Current:   " .. tagstr(current),
    exit_next and "Next change exits" or "",
  }
  local width = 0
  for _, e in ipairs(entries) do
    if e.name then
      width = math.max(width, vim.fn.strdisplaywidth(e.name))
    end
  end
  local field = 3 + 1 + 3 + width
  local per_row = math.max(1, math.floor((math.min(vim.o.columns - 8, 100) - 4) / field))
  local marks = {}
  local row, n = "", 0
  local function flush()
    if row ~= "" then
      lines[#lines + 1] = row
    end
    row, n = "", 0
  end
  for _, t in ipairs(todo_keys or {}) do
    row = row .. string.format("[%s] %s  ", t.key, t.name)
  end
  if row ~= "" then
    flush()
  end
  local in_block = false
  for _, e in ipairs(entries) do
    if e.open then
      flush()
      row = (groups_on or e.open == "[") and (e.open .. " ") or "  "
      in_block = true
    elseif e.close then
      row = row .. ((groups_on or e.close == "]") and e.close or "")
      flush()
      in_block = false
    elseif e.newline then
      flush()
    else
      if row == "" and not in_block then
        row = "  "
      end
      local label = string.format("[%s] %s", e.key, e.name)
      local pad = field - 4 - vim.fn.strdisplaywidth(e.name)
      local text = label .. string.rep(" ", math.max(pad, 1))
      if e.group_tag then
        text = label .. " : " .. string.rep(" ", math.max(pad - 3, 0))
      end
      local s = #row + 4
      row = row .. text
      local hl_group = vim.tbl_contains(current, e.name) and "OrgTodo"
        or (vim.tbl_contains(inherited, e.name) and "OrgDone")
        or (e.group_tag and "Title")
        or nil
      if hl_group then
        marks[#marks + 1] = { #lines, s, s + #e.name, hl_group }
      end
      n = n + 1
      if n >= per_row then
        flush()
        if in_block then
          row = "  "
        end
      end
    end
  end
  flush()
  return lines, marks
end

--- Fast tag selection (Emacs org-fast-tag-selection). Keys toggle tags,
--- <Tab> adds or removes one tag by completion, <Space> clears, <CR>
--- accepts, `!` toggles the exclusivity of `{ }` groups, <C-c> toggles
--- "exit after the next change" (`fast_tag_selection_single_key`), `q`
--- (when not a tag key), <Esc> or <C-g> cancel. TODO keyword keys (with
--- `fast_tag_selection_include_todo`) change the TODO state right away.
--- Returns the new tag list (in table order) or nil when cancelled.
---@param current string[]
---@param defs { name?: string, key?: string, group?: string }[]
---@param inherited string[]
---@param opts? { todo_keys?: { key: string, name: string }[], on_todo?: fun(kw: string), completion?: string[] }
function M.fast_select(current, defs, inherited, opts)
  opts = opts or {}
  current = vim.deepcopy(current)
  local entries, by_key, groups = fast_table(defs, opts.todo_keys)
  local todo_by_key = {}
  for _, t in ipairs(opts.todo_keys or {}) do
    todo_by_key[t.key] = t.name
  end
  local single = config.opts.fast_tag_selection_single_key
  local expert = single == "expert"
  local exit_next = single and true or false
  local groups_on = #groups > 0
  while true do
    local win
    if not expert then
      local lines, marks = render(entries, current, inherited, exit_next, opts.todo_keys, groups_on)
      lines[#lines + 1] = ""
      lines[#lines + 1] = string.format(
        "[a-z..]:toggle [SPC]:clear [RET]:accept [TAB]:edit [!] %sgroups [C-c]:%s",
        groups_on and "" or "no ",
        exit_next and "single" or "multi"
      )
      local buf
      buf, win = require("org.ui").float(lines, { title = "Tags" })
      for _, m in ipairs(marks) do
        pcall(vim.api.nvim_buf_set_extmark, buf, ns, m[1], m[2], { end_col = m[3], hl_group = m[4] })
      end
      vim.api.nvim_buf_set_extmark(buf, ns, 1, 0, { end_col = #lines[2], hl_group = "Title" })
      vim.cmd("redraw")
    end
    local ch = utils.getchar()
    if win and vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
    local changed = false
    if ch == nil or ch == "\27" or ch == "\7" or (ch == "q" and not by_key.q) then
      return nil
    elseif ch == "\r" or ch == "\n" then
      return sort_tags(current, entries)
    elseif ch == "!" then
      groups_on = not groups_on
      if not groups_on then
        for _, e in ipairs(entries) do
          e.group = nil
        end
        groups = {}
      else
        entries, by_key, groups = fast_table(defs, opts.todo_keys)
      end
    elseif ch == "\3" then
      if expert then
        expert = false
      else
        exit_next = not exit_next
      end
    elseif ch == " " then
      current = {}
      changed = true
    elseif ch == "\t" then
      local tag = utils.input_complete("Tag: ", opts.completion or M.all_tags())
      tag = tag and vim.trim(tag)
      if tag and tag ~= "" then
        current = add_or_remove(tag, current, groups)
      end
      changed = true
    elseif todo_by_key[ch] and opts.on_todo then
      opts.on_todo(todo_by_key[ch])
      changed = true
    elseif by_key[ch] then
      current = add_or_remove(by_key[ch].name, current, groups)
      changed = true
    end
    current = sort_tags(current, entries)
    if changed and exit_next then
      return current
    end
  end
end

--- Set tags for a headline (org-set-tags-command). Fast selection is used
--- when some tag has a key (org-use-fast-tag-selection `auto`); with
--- `no_fast`, the tags are typed with completion.
---@param target? org.Target
---@param tags? string[] set directly without prompting
---@param no_fast? boolean
function M.set_tags(target, tags, no_fast)
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
    if has_keys and not no_fast then
      local lnum = hl.line
      local todo_keys
      if config.opts.fast_tag_selection_include_todo then
        todo_keys = {}
        for _, kw in ipairs(file.settings.todo.keywords) do
          if kw.key then
            todo_keys[#todo_keys + 1] = { key = kw.key, name = kw.name }
          end
        end
      end
      tags = M.fast_select(hl.tags, defs, hl:get_inherited_tags(), {
        todo_keys = todo_keys,
        on_todo = function(kw)
          require("org.todo").change_state({ bufnr = bufnr, lnum = lnum }, kw)
        end,
        completion = M.all_tags(bufnr),
      })
    else
      local default = #hl.tags > 0 and (":" .. table.concat(hl.tags, ":") .. ":") or ""
      local typed = utils.input_complete("Tags: ", M.all_tags(bufnr), default)
      tags = typed and M.parse_input(typed) or nil
    end
    if not tags then
      return nil
    end
    hl = files.get_buffer(bufnr):headline_at(hl.line)
  end
  edit.update_headline(bufnr, hl.line, { tags = tags })
  return tags
end
--- Add (`op = "add"`) or remove (`op = "remove"`) `tag` on every headline
--- whose line is in [s, e] (org-change-tag-in-region). Returns the
--- number of headlines changed.
function M.change_tag_in_region(bufnr, s, e, op, tag)
  bufnr = (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
  local file = files.get_buffer(bufnr)
  local changed = 0
  for _, hl in ipairs(file.headlines) do
    if hl.line >= s and hl.line <= e then
      local tags = vim.deepcopy(hl.tags)
      local has = vim.tbl_contains(tags, tag)
      if op == "add" and not has then
        tags[#tags + 1] = tag
      elseif op == "remove" and has then
        tags = vim.tbl_filter(function(t)
          return t ~= tag
        end, tags)
      end
      if #tags ~= #hl.tags then
        edit.update_headline(bufnr, hl.line, { tags = tags })
        changed = changed + 1
      end
    end
  end
  return changed
end

--- Set tags (C-c C-q). With a count, realign the tags of every headline
--- (C-u C-c C-q); a count of 16 (C-u C-u) types the tags with completion
--- instead of the fast selection menu. In Visual mode, add or remove one tag on every headline
--- of the selection (org-change-tag-in-region).
function M.set_tags_command()
  local mode = vim.fn.mode()
  if mode == "v" or mode == "V" or mode == "\22" then
    local s, _, e = utils.visual_range()
    vim.api.nvim_feedkeys(vim.keycode("<Esc>"), "nx", false)
    local op = require("org.ui").menu({
      title = "Change tag in region",
      items = {
        { key = "a", label = "Add a tag", value = "add" },
        { key = "r", label = "Remove a tag", value = "remove" },
      },
    })
    if not op then
      return
    end
    local candidates = M.all_tags()
    if op == "remove" then
      local seen = {}
      candidates = {}
      for _, hl in ipairs(files.get_buffer(0).headlines) do
        if hl.line >= s and hl.line <= e then
          for _, t in ipairs(hl.tags) do
            if not seen[t] then
              seen[t] = true
              candidates[#candidates + 1] = t
            end
          end
        end
      end
    end
    local tag = utils.input_complete((op == "add" and "Add" or "Remove") .. " tag: ", candidates)
    tag = tag and M.parse_input(tag)[1]
    if not tag then
      return
    end
    local n = M.change_tag_in_region(0, s, e, op, tag)
    local msg = op == "add" and "Added tag :%s: to %d headline(s)" or "Removed tag :%s: from %d headline(s)"
    utils.notify(string.format(msg, tag, n))
    return
  end
  if vim.v.count == 16 then
    -- C-u C-u: type the tags even when they have fast keys
    return M.set_tags(nil, nil, true)
  elseif vim.v.count > 0 then
    M.align_all()
    utils.notify("All tags realigned")
    return
  end
  return M.set_tags()
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
