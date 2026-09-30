---@mod org.extensions.transclusion Live transclusion (org-transclusion)
---
--- Shows the text a `#+transclude: [[link]]` keyword points to, with
--- org-transclusion's keyword syntax. By default the text is drawn as
--- virtual lines under the keyword, so the file is never touched;
--- `transclusion_add` inserts it into the buffer instead, like Emacs, and
--- it is taken out again while the file is written. `transclusion_edit`
--- opens the source in a float whose `:write` updates the source and every
--- transclusion of it. See `:h org-extensions-transclusion`.
---
--- ```lua
--- require("org").setup({ extensions = { transclusion = {} } })
--- ```

local edit = require("org.extensions.transclusion.edit")
local highlight = require("org.extensions.transclusion.highlight")
local keyword = require("org.extensions.transclusion.keyword")
local source = require("org.extensions.transclusion.source")
local utils = require("org.utils")

local M = {}

local MOD = "org.extensions.transclusion"

M.keyword = keyword
M.source = source

M.defaults = {
  --- How transclusions show when an org buffer is opened: "virtual"
  --- (virtual lines under the keyword; the buffer text is untouched),
  --- "materialized" (inserted into the buffer like Emacs
  --- org-transclusion-add-all, and removed while writing) or false
  --- (nothing until `transclusion_toggle` or `transclusion_add`).
  mode = "virtual",
  --- Element types always left out of org text
  --- (org-transclusion-exclude-elements); `:exclude-elements` adds more.
  exclude_elements = { "property-drawer" },
  --- Include the text before the first headline when a whole org file is
  --- transcluded (org-transclusion-include-first-section).
  include_first_section = true,
  --- Expand `#+transclude:` keywords inside transcluded text.
  nested = true,
  --- How deep nested transclusions go; deeper ones (and cycles) are left
  --- as keywords and reported.
  max_depth = 5,
  --- Longest transclusion drawn as virtual lines; the rest is summarized.
  max_virtual_lines = 400,
  --- Left border of virtual lines.
  border = "│ ",
  --- Sign on materialized lines (false for none), like org-transclusion's
  --- fringe indicator.
  sign = "▎",
  --- Show where the text comes from at the end of the keyword line.
  show_source = true,
  --- Redraw when a source buffer changes, not only when it is written.
  live = true,
  --- Watch source files that aren't loaded for changes made outside
  --- Neovim (only while a buffer showing them is loaded).
  watch = true,
  --- Milliseconds to wait before redrawing after a change.
  debounce = 150,
  --- Expand `#+transclude:` keywords when exporting.
  export = true,
  --- Key that edits the transclusion under the cursor (on its keyword or
  --- its materialized text); elsewhere the key keeps its meaning. false
  --- for none.
  edit_key = "<CR>",
  --- The window of `transclusion_edit`: `window` is "float" or an Ex
  --- command such as "split", "vsplit" or "tabnew"; `width` and `height`
  --- are columns/lines or fractions of the screen.
  edit = { window = "float", width = 0.8, height = 0.7, border = "rounded" },
  --- How `transclusion_open_source` shows the source: "edit", "split",
  --- "vsplit" or "tab".
  open_source = "split",
}

local function a(fn, desc)
  return { MOD, fn, desc = desc }
end

M.actions = {
  transclusion_add = a("add", "Transclusion: insert the text at point into the buffer (org-transclusion-add)"),
  transclusion_add_all = a("add_all", "Transclusion: insert every transclusion (org-transclusion-add-all)"),
  transclusion_remove = a("remove", "Transclusion: remove the transclusion at point (org-transclusion-remove)"),
  transclusion_remove_all = a(
    "remove_all",
    "Transclusion: remove inserted transclusions (org-transclusion-remove-all)"
  ),
  transclusion_refresh = a("refresh", "Transclusion: refresh from the sources (org-transclusion-refresh)"),
  transclusion_edit = a("edit", "Transclusion: edit the source in a float (org-transclusion-live-sync-start)"),
  transclusion_open_source = a("open_source", "Transclusion: open the source (org-transclusion-open-source)"),
  transclusion_toggle = a("toggle", "Transclusion: toggle virtual transclusions in the buffer"),
  transclusion_detach = a("detach", "Transclusion: turn the transclusion into a copy (org-transclusion-detach)"),
  transclusion_make_from_link = a(
    "make_from_link",
    "Transclusion: add a #+transclude: for the link at point (org-transclusion-make-from-link)"
  ),
  transclusion_promote = a("promote", "Transclusion: promote the transcluded subtree (:level - 1)"),
  transclusion_demote = a("demote", "Transclusion: demote the transcluded subtree (:level + 1)"),
}

M.commands = {
  transclusion_insert = {
    MOD,
    "insert_command",
    desc = "Insert a #+transclude: line: :Org transclusion_insert [[link]] [:level N ...]",
  },
}

M.mappings = {
  org = {
    transclusion_add = "<prefix>ua",
    transclusion_add_all = "<prefix>uA",
    transclusion_remove = "<prefix>ud",
    transclusion_remove_all = "<prefix>uD",
    transclusion_refresh = "<prefix>ug",
    transclusion_edit = "<prefix>ue",
    transclusion_open_source = "<prefix>uo",
    transclusion_toggle = "<prefix>ut",
    transclusion_detach = "<prefix>uc",
    transclusion_make_from_link = "<prefix>ul",
    transclusion_promote = "<prefix>u<",
    transclusion_demote = "<prefix>u>",
  },
}

M.groups = { { "u", "transclusion" } }

local api = vim.api
local ns = api.nvim_create_namespace("org_transclusion")
local ns_region = api.nvim_create_namespace("org_transclusion_region")
local ns_hide = api.nvim_create_namespace("org_transclusion_hidden")
local ns_end = api.nvim_create_namespace("org_transclusion_end")
local augroup = api.nvim_create_augroup("OrgTransclusion", { clear = true })

M.ns, M.ns_region = ns, ns_region

--- buf -> { virtual, regions = { [extmark id] = { lines, label, sources } },
--- sources, sig, tick, keys }
---@type table<integer, table>
M.buffers = {}

local function opts()
  return require("org.extensions").opts("transclusion") or M.defaults
end

local function enabled()
  return require("org.extensions").enabled("transclusion")
end

local function valid(buf)
  return buf and api.nvim_buf_is_valid(buf) and api.nvim_buf_is_loaded(buf)
end

local function state(buf, create)
  local st = M.buffers[buf]
  if not st and create then
    st = { virtual = opts().mode == "virtual", regions = {}, sources = {}, sig = "", tick = -1 }
    M.buffers[buf] = st
  end
  return st
end

local function define_highlights()
  local function hl(name, val)
    val.default = true
    api.nvim_set_hl(0, name, val)
  end
  hl("OrgTransclusionBorder", { link = "FloatBorder" })
  hl("OrgTransclusionSource", { link = "Comment" })
  hl("OrgTransclusionSign", { link = "Special" })
  hl("OrgTransclusionError", { link = "DiagnosticError" })
end

---------------------------------------------------------------------------
-- Materialized regions
---------------------------------------------------------------------------

--- Materialized regions of `buf` in buffer order: { id, s, e (0-based
--- rows of the text, inclusive; s is also the keyword's 1-based row),
--- intact, data }. A region is anchored on its keyword line; its text is
--- the lines below that equal what was inserted (`intact`), else, after
--- an edit, the extent an end mark kept.
---@param buf integer
---@return table[]
function M.regions(buf)
  local st = M.buffers[buf]
  if not st or not next(st.regions) or not valid(buf) then
    return {}
  end
  local out = {}
  for _, m in ipairs(api.nvim_buf_get_extmarks(buf, ns_region, 0, -1, {})) do
    local data = st.regions[m[1]]
    if data then
      local s0 = m[2] + 1
      local n = #data.lines
      local r = { id = m[1], s = s0, data = data }
      if vim.deep_equal(api.nvim_buf_get_lines(buf, s0, s0 + n, false), data.lines) then
        r.e, r.intact = s0 + n - 1, true
      else
        local em = data.end_id and api.nvim_buf_get_extmark_by_id(buf, ns_end, data.end_id, {}) or {}
        local e = em[1] or (s0 + n - 1)
        -- an end at column 0 has moved to the next line: the region's
        -- last lines were deleted (or all of them)
        if em[2] == 0 and data.lines[n] ~= "" then
          e = e - 1
        end
        r.e = math.max(s0 - 1, e)
      end
      out[#out + 1] = r
    end
  end
  table.sort(out, function(x, y)
    return x.s < y.s
  end)
  return out
end

--- Lines of `buf` without its materialized text, and a map from those
--- lines to buffer lines (nil when there is nothing materialized).
---@param buf integer
---@return string[], integer[]|nil
function M.clean_lines(buf)
  local lines = api.nvim_buf_get_lines(buf, 0, -1, false)
  local regs = M.regions(buf)
  if #regs == 0 then
    return lines, nil
  end
  local inside = {}
  for _, r in ipairs(regs) do
    for row = r.s, r.e do
      inside[row + 1] = true
    end
  end
  local out, map = {}, {}
  for i, l in ipairs(lines) do
    if not inside[i] then
      out[#out + 1] = l
      map[#out] = i
    end
  end
  return out, map
end

-- run `fn` with the buffer's modified flag kept as it was
local function keep_modified(buf, fn)
  local mod = vim.bo[buf].modified
  local ok, err = pcall(fn)
  if valid(buf) then
    vim.bo[buf].modified = mod
  end
  if not ok then
    error(err, 0)
  end
end

local function undojoin(buf)
  api.nvim_buf_call(buf, function()
    pcall(vim.cmd, "undojoin")
  end)
end

-- `row0`: 0-based row of the first line of text (the keyword's 1-based row)
local function set_region(buf, row0, lines, data)
  data.end_id = api.nvim_buf_set_extmark(buf, ns_end, row0 + #lines - 1, #lines[#lines], {
    right_gravity = false,
  })
  local id = api.nvim_buf_set_extmark(buf, ns_region, row0 - 1, 0, {})
  M.buffers[buf].regions[id] = data
  return id
end

local function forget_region(buf, r)
  pcall(api.nvim_buf_del_extmark, buf, ns_region, r.id)
  if r.data.end_id then
    pcall(api.nvim_buf_del_extmark, buf, ns_end, r.data.end_id)
  end
  M.buffers[buf].regions[r.id] = nil
end

local function delete_region(buf, r)
  if r.e >= r.s then
    api.nvim_buf_set_lines(buf, r.s, r.e + 1, false, {})
  end
  forget_region(buf, r)
end

-- the region whose text starts right below keyword row `row` (1-based)
local function region_below(buf, row)
  for _, r in ipairs(M.regions(buf)) do
    if r.s == row then
      return r
    end
  end
end

--- Level of the headline above `row` (1-based), materialized text left out.
local function level_at(buf, row)
  local lines = api.nvim_buf_get_lines(buf, 0, row - 1, false)
  local inside = {}
  for _, r in ipairs(M.regions(buf)) do
    for i = r.s, r.e do
      inside[i + 1] = true
    end
  end
  for i = #lines, 1, -1 do
    if not inside[i] then
      local stars = lines[i]:match("^(%*+) ")
      if stars and require("org.parser").outline_level(lines[i]) then
        return #stars
      end
    end
  end
  return 0
end

local function context(buf, row, indent)
  local name = api.nvim_buf_get_name(buf)
  local filename = name ~= "" and not name:match("^%a[%w+%-]*://") and vim.fs.normalize(name) or nil
  return {
    dir = require("org.links").base_dir(buf),
    filename = filename,
    bufnr = buf,
    level = level_at(buf, row),
    indent = indent,
    depth = 0,
  }
end

local function resolve_at(buf, row)
  local line = api.nvim_buf_get_lines(buf, row - 1, row, false)[1] or ""
  local indent, value = keyword.match(line)
  if not indent then
    return nil, "not a #+transclude: line"
  end
  local spec, err = keyword.parse(value)
  if not spec then
    return nil, err
  end
  local ctx = context(buf, row, indent)
  local res, rerr = source.resolve(spec, ctx)
  return res, rerr, spec, ctx
end

--- Insert the text of the keyword on `row` (1-based) below it.
---@return boolean ok, string|nil err
local function materialize(buf, row)
  local res, err = resolve_at(buf, row)
  if not res then
    return false, err
  end
  if #res.lines == 0 then
    return false, "No content found with " .. res.label
  end
  keep_modified(buf, function()
    api.nvim_buf_set_lines(buf, row, row, false, res.lines)
    set_region(buf, row, res.lines, { lines = res.lines, label = res.label, sources = res.sources })
  end)
  -- the new text shows open, whatever the folds around it
  for _, w in ipairs(vim.fn.win_findbuf(buf)) do
    api.nvim_win_call(w, function()
      pcall(vim.cmd, string.format("silent! %d,%dfoldopen!", row + 1, row + #res.lines))
    end)
  end
  return true
end

--- Check the materialized text. It is read-only, like in Emacs: text
--- edited in place is put back. Text whose keyword was deleted is
--- removed with it, and text deleted as a whole (or undone) is forgotten.
local function protect(buf)
  local st = M.buffers[buf]
  if not st or st.saving or not next(st.regions) then
    return
  end
  local restored = false
  for _, r in ipairs(vim.fn.reverse(M.regions(buf))) do
    local kw = api.nvim_buf_get_lines(buf, r.s - 1, r.s, false)[1]
    if not kw or not keyword.match(kw) then
      -- the keyword went: its text goes too when it is still there
      local n = #r.data.lines
      local here = vim.deep_equal(api.nvim_buf_get_lines(buf, r.s - 1, r.s - 1 + n, false), r.data.lines)
      keep_modified(buf, function()
        if here then
          undojoin(buf)
          api.nvim_buf_set_lines(buf, r.s - 1, r.s - 1 + n, false, {})
        end
        forget_region(buf, r)
      end)
    elseif r.intact then
      local em = api.nvim_buf_get_extmark_by_id(buf, ns_end, r.data.end_id, {})
      if em[1] ~= r.e then
        forget_region(buf, r)
        set_region(buf, r.s, r.data.lines, r.data)
      end
    elseif r.e < r.s then
      forget_region(buf, r)
    else
      keep_modified(buf, function()
        undojoin(buf)
        api.nvim_buf_set_lines(buf, r.s, r.e + 1, false, r.data.lines)
        forget_region(buf, r)
        set_region(buf, r.s, r.data.lines, r.data)
      end)
      restored = true
    end
  end
  if restored then
    utils.warn(
      "Transcluded text is read-only: edit its source with transclusion_edit (" .. (opts().edit_key or "") .. ")"
    )
  end
end

---------------------------------------------------------------------------
-- Drawing
---------------------------------------------------------------------------

local function source_label(text)
  return { { "  ⇣ " .. text, "OrgTransclusionSource" } }
end

local function draw_virtual(buf, row, indent, res, err)
  local o = opts()
  local border = { o.border or "", "OrgTransclusionBorder" }
  local virt = {}
  local function add(chunks)
    local line = {}
    if indent ~= "" then
      line[1] = { indent }
    end
    line[#line + 1] = border
    vim.list_extend(line, chunks)
    virt[#virt + 1] = line
  end
  local label
  if res then
    local chunks = res.kind == "org" and highlight.org(res.lines) or highlight.code(res.lines, res.lang)
    local max = o.max_virtual_lines or 400
    for i, c in ipairs(chunks) do
      if i > max then
        add({ { string.format("… %d more lines", #chunks - max), "OrgTransclusionSource" } })
        break
      end
      add(c)
    end
    for _, e in ipairs(res.errors) do
      add({ { e, "OrgTransclusionError" } })
    end
    label = string.format("%s (%d line%s)", res.label, #res.lines, #res.lines == 1 and "" or "s")
  else
    add({ { "transclusion: " .. tostring(err), "OrgTransclusionError" } })
  end
  local mark = { virt_lines = virt, hl_mode = "combine" }
  if label and o.show_source then
    mark.virt_text = source_label(label)
    mark.virt_text_pos = "eol"
  end
  api.nvim_buf_set_extmark(buf, ns, row - 1, 0, mark)
end

local function draw_region(buf, row, r)
  local o = opts()
  if o.show_source then
    api.nvim_buf_set_extmark(buf, ns, row - 1, 0, {
      virt_text = source_label(r.data.label .. " (inserted)"),
      virt_text_pos = "eol",
      hl_mode = "combine",
    })
  end
  if o.sign and o.sign ~= "" then
    for i = r.s, r.e do
      api.nvim_buf_set_extmark(buf, ns, i, 0, { sign_text = o.sign, sign_hl_group = "OrgTransclusionSign" })
    end
  end
end

local function hidden(buf, row)
  return #api.nvim_buf_get_extmarks(buf, ns_hide, { row - 1, 0 }, { row - 1, -1 }, {}) > 0
end

local function signature(sources)
  local keys = vim.tbl_keys(sources)
  table.sort(keys)
  local parts = {}
  for _, p in ipairs(keys) do
    parts[#parts + 1] = source.signature(p)
  end
  return table.concat(parts, "|")
end

local update_watchers
local wrap_key

--- Draw the transclusions of `buf`. With `refresh`, materialized text is
--- replaced by the current text of its source.
---@param buf? integer
---@param refresh? boolean
function M.render(buf, refresh)
  buf = (buf == nil or buf == 0) and api.nvim_get_current_buf() or buf
  if not valid(buf) or not enabled() then
    return
  end
  local st = state(buf, true)
  if st.saving then
    return
  end
  protect(buf)
  api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  local regs = M.regions(buf)
  if refresh then
    for i = #regs, 1, -1 do
      local r = regs[i]
      local res = resolve_at(buf, r.s)
      if res and #res.lines > 0 and not vim.deep_equal(res.lines, r.data.lines) then
        keep_modified(buf, function()
          api.nvim_buf_set_lines(buf, r.s, r.e + 1, false, res.lines)
          forget_region(buf, r)
          set_region(buf, r.s, res.lines, { lines = res.lines, label = res.label, sources = res.sources })
        end)
      end
    end
    regs = M.regions(buf)
  end
  local lines = api.nvim_buf_get_lines(buf, 0, -1, false)
  local inside, below = {}, {}
  for _, r in ipairs(regs) do
    below[r.s] = r
    for i = r.s, r.e do
      inside[i + 1] = true
    end
  end
  st.sources = {}
  local kws = keyword.scan(lines, function(row)
    return inside[row]
  end)
  for _, kw in ipairs(kws) do
    local r = below[kw.row]
    if r then
      draw_region(buf, kw.row, r)
      for p in pairs(r.data.sources or {}) do
        st.sources[p] = true
      end
    elseif st.virtual and not hidden(buf, kw.row) then
      local spec, err = keyword.parse(kw.value)
      if not (spec and spec.disable_auto) then
        local res
        if spec then
          res, err = source.resolve(spec, context(buf, kw.row, kw.indent))
        end
        local n = res and #res.lines or 0
        if n > 0 and vim.deep_equal(vim.list_slice(lines, kw.row + 1, kw.row + n), res.lines) then
          -- its text is already below it (an undone removal): take it back
          local data = { lines = res.lines, label = res.label, sources = res.sources }
          set_region(buf, kw.row, res.lines, data)
          draw_region(buf, kw.row, { s = kw.row, e = kw.row + n - 1, data = data })
        else
          draw_virtual(buf, kw.row, kw.indent, res, err)
        end
        for p in pairs(res and res.sources or {}) do
          st.sources[p] = true
        end
      end
    end
  end
  st.count = #kws
  st.tick = api.nvim_buf_get_changedtick(buf)
  st.sig = signature(st.sources)
  if #kws > 0 then
    wrap_key(buf)
  end
  update_watchers()
end

--- Redraw every buffer showing `path` (after it changed).
---@param path string
---@param except? integer
function M.refresh_dependents(path, except)
  path = vim.fs.normalize(path)
  source.clear_cache(path)
  for buf, st in pairs(M.buffers) do
    if buf ~= except and st.sources[path] then
      M.render(buf, true)
    end
  end
end

---------------------------------------------------------------------------
-- Debouncing and watching
---------------------------------------------------------------------------

local timers = {}

local function later(key, fn)
  local t = timers[key]
  if not t then
    t = vim.uv.new_timer()
    timers[key] = t
  end
  t:stop()
  t:start(
    opts().debounce or 150,
    0,
    vim.schedule_wrap(function()
      if enabled() then
        fn()
      end
    end)
  )
end

-- directory -> { handle, files = { [basename] = path } }. Directories are
-- watched rather than files: that also sees files saved by renaming.
local watchers = {}

local function close_handle(h)
  pcall(function()
    h:stop()
    h:close()
  end)
end

update_watchers = function()
  local want = {}
  if opts().watch then
    for buf, st in pairs(M.buffers) do
      if valid(buf) then
        for p in pairs(st.sources) do
          local d = vim.fn.fnamemodify(p, ":h")
          want[d] = want[d] or {}
          want[d][vim.fn.fnamemodify(p, ":t")] = p
        end
      end
    end
  end
  for d, w in pairs(watchers) do
    if not want[d] then
      close_handle(w.handle)
      watchers[d] = nil
    end
  end
  for d, names in pairs(want) do
    if watchers[d] then
      watchers[d].files = names
    elseif utils.is_dir(d) then
      local h = vim.uv.new_fs_event()
      local entry = { handle = h, files = names }
      local ok = h
        and h:start(d, {}, function(err, fname)
          if err then
            return
          end
          -- a fast callback: no vim.fn here
          local tail = fname and fname:match("[^/]+$")
          for name, p in pairs(entry.files) do
            if not tail or tail == name then
              later("watch:" .. p, function()
                require("org.files").invalidate(p)
                M.refresh_dependents(p)
              end)
            end
          end
        end)
      if ok == 0 then
        watchers[d] = entry
      elseif h then
        close_handle(h)
      end
    end
  end
end

local function stop_all()
  for _, t in pairs(timers) do
    close_handle(t)
  end
  timers = {}
  for _, w in pairs(watchers) do
    close_handle(w.handle)
  end
  watchers = {}
end

---------------------------------------------------------------------------
-- The edit key
---------------------------------------------------------------------------

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
  local line = api.nvim_buf_get_lines(buf, row - 1, row, false)[1] or ""
  if keyword.match(line) then
    return { row = row, region = region_below(buf, row) }
  end
end

wrap_key = function(buf)
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
  buf = (buf == nil or buf == 0) and api.nvim_get_current_buf() or buf
  state(buf, true)
  api.nvim_buf_clear_namespace(buf, ns_hide, 0, -1)
  local lines = api.nvim_buf_get_lines(buf, 0, -1, false)
  local inside = {}
  for _, r in ipairs(M.regions(buf)) do
    for i = r.s, r.e do
      inside[i + 1] = true
    end
  end
  local kws = keyword.scan(lines, function(row)
    return inside[row]
  end)
  local errors = {}
  for i = #kws, 1, -1 do
    local kw = kws[i]
    local spec = keyword.parse(kw.value)
    if spec and not spec.disable_auto and not region_below(buf, kw.row) then
      local ok, err = materialize(buf, kw.row)
      if not ok then
        errors[#errors + 1] = err
      end
    end
  end
  for _, e in ipairs(errors) do
    utils.warn(tostring(e))
  end
  M.render(buf)
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
    keep_modified(buf, function()
      delete_region(buf, t.region)
    end)
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
  local rows = {}
  local regs = M.regions(buf)
  if #regs > 0 then
    keep_modified(buf, function()
      for i = #regs, 1, -1 do
        delete_region(buf, regs[i])
      end
    end)
    local removed = 0
    for _, r in ipairs(regs) do
      rows[#rows + 1] = r.s - removed
      removed = removed + (r.e - r.s + 1)
    end
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
    forget_region(buf, t.region)
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
  local res = resolve_at(buf, t.row)
  local line = api.nvim_buf_get_lines(buf, t.row - 1, t.row, false)[1]
  local cur = tonumber(line:match(":level *(%d)"))
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
  api.nvim_buf_set_lines(buf, t.row - 1, t.row, false, { new })
  if t.region then
    M.render(buf, true)
  else
    M.render(buf)
  end
end

--- Promote the transcluded subtree (org-transclusion-promote-subtree).
function M.promote()
  shift(-1)
end

--- Demote the transcluded subtree (org-transclusion-demote-subtree).
function M.demote()
  shift(1)
end

---------------------------------------------------------------------------
-- Saving: inserted text never reaches the file
---------------------------------------------------------------------------

local function before_write(buf)
  local st = M.buffers[buf]
  if not st or not next(st.regions) then
    return
  end
  protect(buf)
  local views = {}
  for _, w in ipairs(vim.fn.win_findbuf(buf)) do
    views[w] = api.nvim_win_call(w, vim.fn.winsaveview)
  end
  local rows = M.remove_all(buf)
  st.saving = { rows = rows, views = views }
end

local function after_write(buf)
  local st = M.buffers[buf]
  if not st or not st.saving then
    return
  end
  local saving = st.saving
  st.saving = nil
  -- joined to the removal, so undo doesn't see the save
  for i = #saving.rows, 1, -1 do
    undojoin(buf)
    materialize(buf, saving.rows[i])
  end
  vim.bo[buf].modified = false
  for w, view in pairs(saving.views) do
    if api.nvim_win_is_valid(w) and api.nvim_win_get_buf(w) == buf then
      api.nvim_win_call(w, function()
        vim.fn.winrestview(view)
      end)
    end
  end
  M.render(buf)
end

---------------------------------------------------------------------------
-- Export
---------------------------------------------------------------------------

--- Expand `#+transclude:` keywords of exported lines (an
--- `org.export.hooks` preprocessor). Text inserted in the exported buffer
--- is replaced, not doubled.
---@param lines string[]
---@param ctx table { dir, filename, bufnr }
---@return string[]
function M.export_preprocess(lines, ctx)
  if not opts().export then
    return lines
  end
  local regs = ctx.bufnr and valid(ctx.bufnr) and M.regions(ctx.bufnr) or {}
  local inserted = {}
  for _, r in ipairs(regs) do
    inserted[#inserted + 1] = r.data.lines
  end
  local skip = function(kw, all)
    for _, ins in ipairs(inserted) do
      if vim.deep_equal(vim.list_slice(all, kw.row + 1, kw.row + #ins), ins) then
        return #ins
      end
    end
    return 0
  end
  local out, errors = source.expand(lines, {
    dir = ctx.dir,
    filename = ctx.filename,
    bufnr = ctx.bufnr,
  }, skip)
  for _, e in ipairs(errors) do
    utils.warn("transclusion: " .. tostring(e))
  end
  return out
end

---------------------------------------------------------------------------
-- Setup
---------------------------------------------------------------------------

local function attach(buf)
  if not valid(buf) or vim.bo[buf].filetype ~= "org" then
    return
  end
  local st = M.buffers[buf]
  if not st then
    if not opts().mode then
      return
    end
    st = state(buf, true)
    M.render(buf)
    if opts().mode == "materialized" then
      M.add_all(buf)
    end
  elseif st.tick ~= api.nvim_buf_get_changedtick(buf) or st.sig ~= signature(st.sources) then
    M.render(buf, true)
  end
end

M.attach = attach

local function on_change(buf)
  local st = M.buffers[buf]
  if st and not st.saving then
    protect(buf)
    later("render:" .. buf, function()
      if valid(buf) and M.buffers[buf] then
        M.render(buf)
      end
    end)
  end
  if opts().live then
    local name = api.nvim_buf_get_name(buf)
    if name ~= "" then
      local path = vim.fs.normalize(name)
      for b, s in pairs(M.buffers) do
        if b ~= buf and s.sources[path] then
          later("deps:" .. path, function()
            M.refresh_dependents(path, buf)
          end)
          break
        end
      end
    end
  end
end

function M.setup()
  define_highlights()
  source.opts = opts()
  source.buffer_lines = M.clean_lines
  source.clear_cache()
  edit.on_written = function(path, sb)
    if path then
      M.refresh_dependents(path)
    elseif sb then
      M.render(sb, true)
    end
  end
  require("org.export.hooks").preprocessors.transclusion = M.export_preprocess
  api.nvim_clear_autocmds({ group = augroup })
  api.nvim_create_autocmd("ColorScheme", { group = augroup, callback = define_highlights })
  api.nvim_create_autocmd({ "FileType" }, {
    group = augroup,
    pattern = "org",
    callback = function(ev)
      attach(ev.buf)
    end,
  })
  api.nvim_create_autocmd({ "BufWinEnter", "BufEnter", "FocusGained" }, {
    group = augroup,
    callback = function(ev)
      attach(ev.buf ~= 0 and ev.buf or api.nvim_get_current_buf())
    end,
  })
  api.nvim_create_autocmd({ "TextChanged", "InsertLeave" }, {
    group = augroup,
    callback = function(ev)
      on_change(ev.buf)
    end,
  })
  api.nvim_create_autocmd("BufWritePre", {
    group = augroup,
    callback = function(ev)
      before_write(ev.buf)
    end,
  })
  api.nvim_create_autocmd("BufWritePost", {
    group = augroup,
    callback = function(ev)
      after_write(ev.buf)
      local name = api.nvim_buf_get_name(ev.buf)
      if name ~= "" then
        M.refresh_dependents(vim.fs.normalize(name), ev.buf)
      end
    end,
  })
  api.nvim_create_autocmd({ "BufUnload", "BufWipeout" }, {
    group = augroup,
    callback = function(ev)
      if M.buffers[ev.buf] then
        M.buffers[ev.buf] = nil
        vim.schedule(update_watchers)
      end
    end,
  })
  for _, buf in ipairs(api.nvim_list_bufs()) do
    if valid(buf) and vim.bo[buf].filetype == "org" then
      attach(buf)
    end
  end
end

--- Undo `setup`: inserted text is removed, virtual lines cleared and the
--- edit key given back.
function M.teardown()
  api.nvim_clear_autocmds({ group = augroup })
  for buf in pairs(M.buffers) do
    if valid(buf) then
      pcall(M.remove_all, buf)
      unwrap_key(buf)
      api.nvim_buf_clear_namespace(buf, ns, 0, -1)
      api.nvim_buf_clear_namespace(buf, ns_region, 0, -1)
      api.nvim_buf_clear_namespace(buf, ns_end, 0, -1)
      api.nvim_buf_clear_namespace(buf, ns_hide, 0, -1)
    end
  end
  M.buffers = {}
  stop_all()
  require("org.export.hooks").preprocessors.transclusion = nil
  source.buffer_lines = function(buf)
    return api.nvim_buf_get_lines(buf, 0, -1, false), nil
  end
  source.clear_cache()
end

function M.health(h, o)
  h.ok("transclusion: mode " .. tostring(o.mode) .. (o.watch and ", watching source files" or ""))
  local ok = pcall(vim.treesitter.language.inspect, "python")
  if ok then
    h.ok("transclusion: tree-sitter parsers colour transcluded code")
  else
    h.info("transclusion: code in virtual lines is coloured only for languages with a tree-sitter parser")
  end
end

return M
