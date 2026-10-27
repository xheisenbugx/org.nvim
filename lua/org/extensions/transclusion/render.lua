---@mod org.extensions.transclusion.render Resolving and drawing transclusions
---
--- What a keyword resolves against (its file, directory and headline
--- level), inserting its text (`materialize`), and drawing every
--- transclusion of a buffer: virtual lines, the source label of inserted
--- text, and inserted text that follows its source. Part of
--- org.extensions.transclusion, which loads it.

local highlight = require("org.extensions.transclusion.highlight")
local keyword = require("org.extensions.transclusion.keyword")
local shared = require("org.extensions.transclusion.shared")
local source = require("org.extensions.transclusion.source")

local M = require("org.extensions.transclusion")

local api = vim.api
local ns = M.ns
local ns_hide = shared.ns_hide
local opts = shared.opts
local enabled = shared.enabled
local valid = shared.valid
local state = shared.state
local touch = shared.touch
local keep_modified = shared.keep_modified
local undojoin = shared.undojoin
local at_tip = shared.at_tip
local mark_lines = shared.mark_lines
local new_region = shared.new_region
local owned_rows = shared.owned_rows
local delete_rows = shared.delete_rows
local protect = shared.protect

-- 1-based lines of `buf` holding inserted text
local function inside_rows(buf)
  local inside = {}
  for _, r in ipairs(M.regions(buf)) do
    for _, row in ipairs(owned_rows(r)) do
      inside[row + 1] = true
    end
  end
  return inside
end

--- What the keywords of `buf` resolve against: its file and directory, and
--- the level of the headline above each line (inserted text left out).
local function environment(buf, lines, inside)
  lines = lines or api.nvim_buf_get_lines(buf, 0, -1, false)
  inside = inside or inside_rows(buf)
  local name = api.nvim_buf_get_name(buf)
  local env = {
    dir = require("org.links").base_dir(buf),
    filename = name ~= "" and not name:match("^%a[%w+%-]*://") and vim.fs.normalize(name) or nil,
    bufnr = buf,
    levels = {},
  }
  local outline = require("org.parser").outline_level
  local level = 0
  for i, l in ipairs(lines) do
    env.levels[i] = level
    if not inside[i] and l:byte(1) == 42 then
      local stars = l:match("^(%*+) ")
      if stars and outline(l) then
        level = #stars
      end
    end
  end
  return env
end

local function context(env, row, indent)
  return {
    dir = env.dir,
    filename = env.filename,
    bufnr = env.bufnr,
    level = env.levels[row] or 0,
    indent = indent,
    depth = 0,
  }
end

local function resolve_at(buf, row, env)
  local line = api.nvim_buf_get_lines(buf, row - 1, row, false)[1] or ""
  local indent, value = keyword.match(line)
  if not indent or not value then
    return nil, "not a #+transclude: line"
  end
  local spec, err = keyword.parse(value)
  if not spec then
    return nil, err
  end
  local ctx = context(env or environment(buf), row, indent)
  local res, rerr = source.frame(source.resolve_cached, spec, ctx)
  return res, rerr, spec, ctx
end

local function open_folds(buf, first, last)
  for _, w in ipairs(vim.fn.win_findbuf(buf)) do
    api.nvim_win_call(w, function()
      pcall(vim.api.nvim_command, string.format("silent! %d,%dfoldopen!", first, last))
    end)
  end
end

--- Insert the text of the keyword on `row` (1-based) below it.
---@return boolean ok, string|nil err
local function materialize(buf, row, env)
  local res, err = resolve_at(buf, row, env)
  if not res then
    return false, err
  end
  if #res.lines == 0 then
    return false, "No content found with " .. res.label
  end
  keep_modified(buf, function()
    api.nvim_buf_set_lines(buf, row, row, false, res.lines)
    new_region(buf, row, { lines = res.lines, label = res.label, sources = res.sources })
  end)
  -- the new text shows open, whatever the folds around it
  open_folds(buf, row + 1, row + #res.lines)
  return true
end

-- Replace the text of region `r` by `lines`, changing only the lines that
-- differ (marks, folds and the cursor stay on the others).
local function replace_text(buf, r, lines)
  local old = r.data.lines
  -- vim.text.diff is Neovim 0.12+; 0.11, still supported, has only vim.diff
  ---@diagnostic disable-next-line: deprecated
  local diff = (vim.text and vim.text.diff) or vim.diff
  local ok, hunks = pcall(diff, table.concat(old, "\n") .. "\n", table.concat(lines, "\n") .. "\n", {
    result_type = "indices",
  })
  if not ok or type(hunks) ~= "table" then
    hunks = { { 1, #old, 1, #lines } }
  end
  for i = #hunks, 1, -1 do
    local h = hunks[i]
    local start = h[2] == 0 and h[1] or h[1] - 1
    api.nvim_buf_set_lines(buf, r.s + start, r.s + start + h[2], false, vim.list_slice(lines, h[3], h[3] + h[4] - 1))
    if h[4] > 0 then
      mark_lines(buf, r.id, r.s + start, h[4])
    end
  end
end

---------------------------------------------------------------------------
-- Drawing
---------------------------------------------------------------------------

local function source_label(text)
  return { { "  ⇣ " .. text, "OrgTransclusionSource" } }
end

local function virt_chunks(res, max)
  res.chunks = res.chunks or {}
  local c = res.chunks[max]
  if not c then
    local lines = #res.lines > max and vim.list_slice(res.lines, 1, max) or res.lines
    c = res.kind == "org" and highlight.org(lines, res.todo) or highlight.code(lines, res.lang)
    res.chunks[max] = c
  end
  return c
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
    local max = o.max_virtual_lines or 400
    for _, c in ipairs(virt_chunks(res, max)) do
      add(c)
    end
    if #res.lines > max then
      add({ { string.format("… %d more lines", #res.lines - max), "OrgTransclusionSource" } })
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
  return api.nvim_buf_set_extmark(buf, ns, row - 1, 0, mark)
end

local function draw_region(buf, row, r)
  if opts().show_source then
    return api.nvim_buf_set_extmark(buf, ns, row - 1, 0, {
      virt_text = source_label(r.data.label .. " (inserted)"),
      virt_text_pos = "eol",
      hl_mode = "combine",
    })
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

local function render(buf, st, refresh)
  protect(buf)
  local regs = M.regions(buf)
  local lines = api.nvim_buf_get_lines(buf, 0, -1, false)
  local inside = inside_rows(buf)
  local env = environment(buf, lines, inside)
  -- inserted text follows its source (refresh) and its keyword
  local tip
  local changed = false
  for i = #regs, 1, -1 do
    local r = regs[i]
    local kw = lines[r.s]
    if refresh or kw ~= r.data.kw then
      if tip == nil then
        tip = at_tip(buf)
      end
      if kw ~= r.data.kw and not tip then
        r.data.kw = kw
      else
        local res = resolve_at(buf, r.s, env)
        if res and #res.lines > 0 and (kw ~= r.data.kw or not vim.deep_equal(res.lines, r.data.lines)) then
          keep_modified(buf, function()
            if kw ~= r.data.kw then
              undojoin(buf)
            end
            if r.intact then
              replace_text(buf, r, res.lines)
            else
              delete_rows(buf, owned_rows(r))
              api.nvim_buf_set_lines(buf, r.s, r.s, false, res.lines)
              mark_lines(buf, r.id, r.s, #res.lines)
            end
          end)
          r.data.lines, r.data.label, r.data.sources, r.data.kw = res.lines, res.label, res.sources, kw
          changed = true
        else
          r.data.kw = kw
        end
      end
    end
  end
  if changed then
    touch(st)
    regs = M.regions(buf)
    lines = api.nvim_buf_get_lines(buf, 0, -1, false)
    inside = inside_rows(buf)
    env = environment(buf, lines, inside)
  end
  -- Only what changed is drawn again: each mark remembers what it shows
  -- (a result, shared while its sources don't change, or an error).
  local old, drawn, now = {}, st.drawn or {}, {}
  for _, m in ipairs(api.nvim_buf_get_extmarks(buf, ns, 0, -1, {})) do
    local key = drawn[m[1]]
    if key ~= nil and not old[m[2] + 1] then
      old[m[2] + 1] = { id = m[1], key = key }
    else
      pcall(api.nvim_buf_del_extmark, buf, ns, m[1])
    end
  end
  local function place(row, key, draw)
    local o = old[row]
    old[row] = nil
    if o and o.key == key then
      now[o.id] = key
      return
    elseif o then
      pcall(api.nvim_buf_del_extmark, buf, ns, o.id)
    end
    local id = draw()
    if id then
      now[id] = key
    end
  end
  local below = {}
  for _, r in ipairs(regs) do
    below[r.s] = r
  end
  local ui
  local function text_pad(level)
    if ui == nil then
      local ok, decorations = pcall(require, "org.ui.decorations")
      local uok, u = false, nil
      if ok then
        uok, u = pcall(decorations.ui_options, buf)
      end
      ui = uok and u and u.indent_mode and { u = u, widths = decorations.indent_widths } or false
    end
    if not ui or not level or level <= 0 then
      return 0
    end
    local _, text = ui.widths(ui.u, level)
    return text
  end
  local sources = {}
  local kws = keyword.scan(lines, function(row)
    return inside[row]
  end)
  for _, kw in ipairs(kws) do
    local r = below[kw.row]
    if r then
      place(kw.row, "r\0" .. r.data.label, function()
        return draw_region(buf, kw.row, r)
      end)
      for p in pairs(r.data.sources or {}) do
        sources[p] = true
      end
    else
      local spec, err = keyword.parse(kw.value)
      local show = st.virtual and not hidden(buf, kw.row) and not (spec and spec.disable_auto)
      -- text under a keyword may be its own, brought back by undo: look
      -- when it is drawn anyway or the buffer had inserted text (a detach
      -- forgets its region, and undo brings the keyword back over it)
      local check = show or next(st.regions) ~= nil or st.detached or vim.bo[buf].undofile
      local res, adopted
      if spec and check then
        res, err = source.resolve_cached(spec, context(env, kw.row, kw.indent))
      end
      local n = res and #res.lines or 0
      if
        res
        and n > 0
        and lines[kw.row + n] ~= nil
        and vim.deep_equal(vim.list_slice(lines, kw.row + 1, kw.row + n), res.lines)
      then
        -- its text is right below it; when undo brought it back (from
        -- before a write, even of an earlier session with 'undofile'),
        -- it is taken back
        if tip == nil then
          tip = at_tip(buf)
        end
        if not tip then
          new_region(buf, kw.row, { lines = res.lines, label = res.label, sources = res.sources })
          place(kw.row, "r\0" .. res.label, function()
            return draw_region(buf, kw.row, { data = { label = res.label } })
          end)
          show, adopted = false, true
        end
      end
      if show then
        -- org-indent-mode: the keyword is drawn after its entry's virtual
        -- indentation, and so is the text under it
        local pad = text_pad(env.levels[kw.row])
        local indent = pad > 0 and string.rep(" ", pad) .. kw.indent or kw.indent
        local key = res or ("e\0" .. tostring(err))
        if pad > 0 or kw.indent ~= "" then
          key = tostring(key) .. "\0" .. indent
        end
        place(kw.row, key, function()
          return draw_virtual(buf, kw.row, indent, res, err)
        end)
      end
      if show or adopted then
        for p in pairs(res and res.sources or {}) do
          sources[p] = true
        end
      end
    end
  end
  for _, o in pairs(old) do
    pcall(api.nvim_buf_del_extmark, buf, ns, o.id)
  end
  st.drawn = now
  st.sources = sources
  st.count = #kws
  st.tick = api.nvim_buf_get_changedtick(buf)
  st.sig = signature(sources)
  local keys = vim.tbl_keys(sources)
  table.sort(keys)
  local key = table.concat(keys, "\n")
  if #kws > 0 then
    shared.wrap_key(buf)
  end
  if key ~= st.srckey then
    st.srckey = key
    shared.update_watchers()
  end
end

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
  source.frame(render, buf, st, refresh)
end

--- Redraw every buffer showing `path` (after it changed).
---@param path string
---@param except? integer
function M.refresh_dependents(path, except)
  path = vim.fs.normalize(path)
  source.clear_cache(path)
  for buf, st in pairs(M.buffers) do
    if buf ~= except and source.source_key(st.sources, path) then
      M.render(buf, true)
    end
  end
end

shared.inside_rows = inside_rows
shared.environment = environment
shared.resolve_at = resolve_at
shared.materialize = materialize
shared.signature = signature
