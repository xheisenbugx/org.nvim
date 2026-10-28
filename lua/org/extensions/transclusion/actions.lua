---@mod org.extensions.transclusion.actions The edit key and the transclusion actions
---
--- The transclusion under the cursor (`at_cursor`), the edit key wrapped
--- around the buffer's own mapping, and the actions: add, remove, refresh,
--- toggle, edit, open the source, detach, make from a link, insert and
--- promote or demote. Part of org.extensions.transclusion, which loads it.

local edit = require("org.extensions.transclusion.edit")
local keyword = require("org.extensions.transclusion.keyword")
local shared = require("org.extensions.transclusion.shared")
local source = require("org.extensions.transclusion.source")
local utils = require("org.utils")

local M = require("org.extensions.transclusion")

local api = vim.api
local ns_hide = shared.ns_hide
local opts = shared.opts
local valid = shared.valid
local state = shared.state
local touch = shared.touch
local keep_modified = shared.keep_modified
local forget = shared.forget
local owned_rows = shared.owned_rows
local delete_rows = shared.delete_rows
local region_below = shared.region_below
local inside_rows = shared.inside_rows
local environment = shared.environment
local resolve_at = shared.resolve_at
local materialize = shared.materialize

-- whether 1-based `row` is a #+transclude: keyword (not in a block)
local function keyword_row(buf, row)
  local line = api.nvim_buf_get_lines(buf, row - 1, row, false)[1] or ""
  if not keyword.match(line) then
    return false
  end
  local kws = keyword.scan(api.nvim_buf_get_lines(buf, 0, row, false))
  return kws[#kws] ~= nil and kws[#kws].row == row
end

--- The transclusion under the cursor: { row = keyword row (1-based),
--- region = materialized region or nil }.
---@param buf? integer
---@return table|nil
function M.at_cursor(buf)
  buf = (buf == nil or buf == 0) and api.nvim_get_current_buf() or buf
  local row = api.nvim_win_get_cursor(0)[1]
  for _, r in ipairs(M.regions(buf)) do
    if row - 1 >= r.s and row - 1 <= r.e then
      return { row = r.s, region = r }
    end
  end
  if keyword_row(buf, row) then
    return { row = row, region = region_below(buf, row) }
  end
end

local function wrap_key(buf)
  local key = opts().edit_key
  local st = M.buffers[buf]
  if not key or key == "" or st.keys then
    return
  end
  local prev = api.nvim_buf_call(buf, function()
    return vim.fn.maparg(key, "n", false, true)
  end)
  st.keys = { key, prev }
  vim.keymap.set("n", key, function()
    if M.at_cursor(0) then
      return M.edit()
    end
    if type(prev) == "table" and prev.callback then
      return prev.callback()
    elseif type(prev) == "table" and prev.rhs and prev.rhs ~= "" then
      local keys = api.nvim_replace_termcodes(prev.rhs, true, true, true)
      api.nvim_feedkeys(keys, prev.noremap == 1 and "n" or "m", false)
    else
      api.nvim_feedkeys(api.nvim_replace_termcodes(key, true, true, true), "n", false)
    end
  end, { buffer = buf, desc = "org: edit the transclusion at point, else " .. ((prev or {}).desc or key) })
end

local function unwrap_key(buf)
  local st = M.buffers[buf]
  if not st or not st.keys or not valid(buf) then
    return
  end
  local key, prev = st.keys[1], st.keys[2]
  api.nvim_buf_call(buf, function()
    pcall(vim.keymap.del, "n", key, { buffer = buf })
    if type(prev) == "table" and prev.lhs and prev.buffer == 1 then
      pcall(vim.fn.mapset, "n", false, prev)
    end
  end)
  st.keys = nil
end

---------------------------------------------------------------------------
-- Actions
---------------------------------------------------------------------------

local function need()
  local t = M.at_cursor(0)
  if not t then
    utils.warn("Not on a #+transclude: keyword or transcluded text")
  end
  return t
end

--- Insert the text of the transclusion at point (org-transclusion-add).
function M.add()
  local t = need()
  if not t then
    return
  end
  local buf = api.nvim_get_current_buf()
  state(buf, true)
  if t.region then
    utils.notify("Already inserted")
    return
  end
  pcall(api.nvim_buf_clear_namespace, buf, ns_hide, t.row - 1, t.row)
  local ok, err = materialize(buf, t.row)
  if not ok then
    utils.warn(tostring(err))
  end
  M.render(buf)
end

--- Insert every transclusion of the buffer except `:disable-auto` ones
--- (org-transclusion-add-all).
---@param buf? integer
function M.add_all(buf)
  if buf == nil or buf == 0 then
    buf = api.nvim_get_current_buf()
  end
  if not valid(buf) then
    return
  end
  state(buf, true)
  api.nvim_buf_clear_namespace(buf, ns_hide, 0, -1)
  local lines = api.nvim_buf_get_lines(buf, 0, -1, false)
  local inside = inside_rows(buf)
  local env = environment(buf, lines, inside)
  local kws = keyword.scan(lines, function(row)
    return inside[row]
  end)
  local has = {}
  for _, r in ipairs(M.regions(buf)) do
    has[r.s] = true
  end
  local errors = {}
  source.frame(function()
    -- bottom-up: the lines above each keyword stay as they were read
    for i = #kws, 1, -1 do
      local kw = kws[i]
      local spec = keyword.parse(kw.value)
      if spec and not spec.disable_auto and not has[kw.row] then
        local ok, err = materialize(buf, kw.row, env)
        if not ok then
          errors[#errors + 1] = err
        end
      end
    end
  end)
  for _, e in ipairs(errors) do
    utils.warn(tostring(e))
  end
  M.render(buf)
end

-- Take out inserted text of `regs` (bottom-up); returns the keyword rows,
-- as they are afterwards.
local function take_out(buf, regs)
  local rows = {}
  keep_modified(buf, function()
    for i = #regs, 1, -1 do
      delete_rows(buf, owned_rows(regs[i]))
    end
  end)
  local removed = 0
  for _, r in ipairs(regs) do
    rows[#rows + 1] = r.s - removed
    removed = removed + #owned_rows(r)
  end
  touch(M.buffers[buf])
  return rows
end

--- Remove the transclusion at point (org-transclusion-remove): inserted
--- text is taken out; a virtual one is hidden until refreshed.
function M.remove()
  local t = need()
  if not t then
    return
  end
  local buf = api.nvim_get_current_buf()
  if t.region then
    t.region.data.removed = true
    take_out(buf, { t.region })
    api.nvim_win_set_cursor(0, { t.row, 0 })
  else
    api.nvim_buf_set_extmark(buf, ns_hide, t.row - 1, 0, {})
  end
  M.render(buf)
end

--- Take out every inserted transclusion (org-transclusion-remove-all);
--- the buffer shows them as virtual lines again when those are on.
---@param buf? integer
---@return integer[] rows of the keywords whose text was removed
function M.remove_all(buf)
  buf = (buf == nil or buf == 0) and api.nvim_get_current_buf() or buf
  local regs = M.regions(buf)
  local rows = {}
  if #regs > 0 then
    for _, r in ipairs(regs) do
      r.data.removed = true
    end
    rows = take_out(buf, regs)
  end
  if M.buffers[buf] then
    M.render(buf)
  end
  return rows
end

--- Refresh the transclusion at point, or the whole buffer
--- (org-transclusion-refresh). Hidden ones are shown again.
function M.refresh()
  local buf = api.nvim_get_current_buf()
  local t = M.at_cursor(buf)
  if t then
    pcall(api.nvim_buf_clear_namespace, buf, ns_hide, t.row - 1, t.row)
  else
    api.nvim_buf_clear_namespace(buf, ns_hide, 0, -1)
  end
  source.clear_cache()
  M.render(buf, true)
end

--- Toggle the virtual transclusions of the buffer.
function M.toggle()
  local buf = api.nvim_get_current_buf()
  local st = state(buf, true)
  st.virtual = not st.virtual
  api.nvim_buf_clear_namespace(buf, ns_hide, 0, -1)
  M.render(buf)
  utils.notify("Transclusions " .. (st.virtual and "shown" or "hidden"))
  return true
end

--- Open the source of the transclusion at point in a float to edit it;
--- `:w` writes it back (org-transclusion-live-sync-start).
function M.edit()
  local t = need()
  if not t then
    return
  end
  local buf = api.nvim_get_current_buf()
  local res, err, spec, ctx = resolve_at(buf, t.row)
  if not res then
    utils.warn(tostring(err))
    return
  end
  return edit.open(res, spec, ctx, opts().edit)
end

--- Visit the source of the transclusion at point
--- (org-transclusion-open-source).
function M.open_source()
  local t = need()
  if not t then
    return
  end
  local res, err = resolve_at(api.nvim_get_current_buf(), t.row)
  if not res then
    utils.warn(tostring(err))
    return
  end
  local lnum = res.map and res.map[res.first] or res.first
  if res.path then
    local how = opts().open_source
    utils.open_file(res.path, lnum, { split = how ~= "edit" and how or nil })
  else
    api.nvim_win_set_cursor(0, { lnum, 0 })
  end
end

--- Replace the transclusion at point by a copy of its text
--- (org-transclusion-detach).
function M.detach()
  local t = need()
  if not t then
    return
  end
  local buf = api.nvim_get_current_buf()
  if t.region then
    forget(buf, t.region.id)
    -- undo brings the keyword back over the text: render takes it back
    local st = M.buffers[buf]
    if st then
      st.detached = true
    end
    api.nvim_buf_set_lines(buf, t.row - 1, t.row, false, {})
  else
    local res, err = resolve_at(buf, t.row)
    if not res then
      utils.warn(tostring(err))
      return
    end
    api.nvim_buf_set_lines(buf, t.row - 1, t.row, false, res.lines)
  end
  M.render(buf)
end

--- Add a `#+transclude:` line for the link at point below it
--- (org-transclusion-make-from-link).
function M.make_from_link()
  local l = require("org.links").link_at_cursor()
  if not l or not l.target then
    utils.warn("No link at point")
    return
  end
  local link = l.raw and l.raw:sub(1, 2) == "[[" and l.raw or ("[[" .. l.target .. "]]")
  local row = l.end_lnum or api.nvim_win_get_cursor(0)[1]
  local indent = api.nvim_get_current_line():match("^(%s*)")
  api.nvim_buf_set_lines(0, row, row, false, { indent .. "#+transclude: " .. link })
  api.nvim_win_set_cursor(0, { row + 1, 0 })
  M.render(0)
end

--- `:Org transclusion_insert [[link]] [props]`: a `#+transclude:` line
--- below the cursor.
---@param args? string
function M.insert_command(args)
  args = vim.trim(args or "")
  if args == "" then
    args = vim.trim(vim.fn.input("Transclude link: ", "[[file:"))
    if args == "" then
      return
    end
  end
  if not args:match("^%[%[") then
    local first, rest = args:match("^(%S+)(.*)$")
    args = "[[" .. first .. "]]" .. rest
  end
  local row = api.nvim_win_get_cursor(0)[1]
  -- below the inserted text when the cursor is in it
  for _, r in ipairs(M.regions(0)) do
    if row - 1 >= r.s - 1 and row - 1 <= r.e then
      row = r.e + 1
    end
  end
  local indent = api.nvim_get_current_line():match("^(%s*)")
  api.nvim_buf_set_lines(0, row, row, false, { indent .. "#+transclude: " .. args })
  api.nvim_win_set_cursor(0, { row + 1, 0 })
  M.render(0)
end

local function shift(delta)
  local t = need()
  if not t then
    return
  end
  local buf = api.nvim_get_current_buf()
  local res, _, spec = resolve_at(buf, t.row)
  local line = api.nvim_buf_get_lines(buf, t.row - 1, t.row, false)[1]
  local cur = spec and type(spec.level) == "number" and spec.level or nil
  if not cur and res then
    for _, l in ipairs(res.lines) do
      local stars = l:match("^(%*+) ")
      if stars then
        cur = #stars
        break
      end
    end
  end
  if not cur then
    utils.warn("The transclusion has no headline to promote or demote")
    return
  end
  local new = keyword.set_level(line, cur + delta)
  -- in place: the keyword keeps its mark and its inserted text
  api.nvim_buf_set_text(buf, t.row - 1, 0, t.row - 1, #line, { new })
  M.render(buf)
end

--- Promote the transcluded subtree (org-transclusion-promote-subtree).
function M.promote()
  shift(-1)
end

--- Demote the transcluded subtree (org-transclusion-demote-subtree).
function M.demote()
  shift(1)
end

shared.wrap_key = wrap_key
shared.unwrap_key = unwrap_key
