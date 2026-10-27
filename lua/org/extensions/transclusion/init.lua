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
---
--- Inserted text is tracked by an extmark on its keyword line and one on
--- each inserted line, all with `invalidate`: a line whose mark is valid
--- is transcluded text and never reaches the file, whatever edits, undo or
--- redo did to the buffer (undo brings the marks back with their text).
---
--- This file holds the options, actions, shared helpers and setup; the
--- rest loads from org/extensions/transclusion/: regions (inserted text
--- and its marks), protect (keeping it read-only), render (resolving and
--- drawing), watch (debouncing and watching sources), actions (the edit
--- key and the actions) and save (writes and export without the inserted
--- text). keyword, source, highlight and edit are modules of their own.

local edit = require("org.extensions.transclusion.edit")
local keyword = require("org.extensions.transclusion.keyword")
local source = require("org.extensions.transclusion.source")
local shared = require("org.extensions.transclusion.shared")
local utils = require("org.utils")

local M = {}
-- The parts add their functions to this table and require it back, so it
-- must be in package.loaded before they load.
package.loaded["org.extensions.transclusion"] = M

local MOD = "org.extensions.transclusion"

M.keyword = keyword
M.source = source

--- See :h org-extensions-stability (scripts/extension_report.lua measures it).
M.stability = "stable"

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
  --- are columns/lines or fractions of the screen. With `live`, the source
  --- (and every transclusion of it) follows as you type, like
  --- org-transclusion-live-sync; `:w` still writes it.
  edit = { window = "float", width = 0.8, height = 0.7, border = "rounded", live = false },
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

local PROPS = {
  ":level",
  ":only-contents",
  ":no-first-heading",
  ":exclude-elements",
  ":expand-links",
  ":disable-auto",
  ":lines",
  ":src",
  ":rest",
  ":end",
  ":thing-at-point",
  ":noweb-chunk",
}

--- Completion of `:Org transclusion_insert`: a `file:` link first, then
--- keyword properties.
---@param arglead string
---@param cmdline string
---@return string[]
function M.complete_insert(arglead, cmdline)
  local args = cmdline:match("transclusion_insert%s+(.*)$") or ""
  local before = args:sub(1, #args - #arglead)
  if vim.trim(before) == "" then
    if arglead:match("^%[?%[?id:") then
      return {}
    end
    local prefix, path = arglead:match("^(%[?%[?file:)(.*)$")
    if not prefix then
      prefix, path = "file:", arglead
    end
    local base = require("org.links").base_dir(0)
    local absolute = path:match("^[/~]") ~= nil
    local full = absolute and utils.expand(path) or (base .. "/" .. path)
    if path:sub(-1) == "/" then
      full = full .. "/"
    end
    local out = {}
    for _, f in ipairs(vim.fn.glob(vim.fn.escape(full, "*?[]{}") .. "*", false, true)) do
      local shown = absolute and (path:match("^(.*/)") or "") .. vim.fn.fnamemodify(f, ":t") or f:sub(#base + 2)
      out[#out + 1] = prefix .. shown .. (vim.fn.isdirectory(f) == 1 and "/" or "")
    end
    return out
  end
  local out = {}
  for _, p in ipairs(PROPS) do
    if not before:find(vim.pesc(p) .. "%f[^%w%-]") then
      out[#out + 1] = p
    end
  end
  return out
end

M.commands = {
  transclusion_insert = {
    MOD,
    "insert_command",
    desc = "Insert a #+transclude: line: :Org transclusion_insert [[link]] [:level N ...]",
    complete = function(arglead, cmdline)
      return M.complete_insert(arglead, cmdline)
    end,
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
local ns_line = api.nvim_create_namespace("org_transclusion_line")
local ns_hide = api.nvim_create_namespace("org_transclusion_hidden")
local augroup = api.nvim_create_augroup("OrgTransclusion", { clear = true })

M.ns, M.ns_region, M.ns_line = ns, ns_region, ns_line

--- buf -> { virtual, regions = { [anchor mark] = data }, owner = { [line
--- mark] = anchor mark }, gen, sources, sig, tick, keys }. A region's
--- data is { lines, label, sources, kw (its keyword line), marks (its line
--- marks, old ones included: undo can bring them back), removed }.
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
    st = { virtual = opts().mode == "virtual", regions = {}, owner = {}, gen = 0, sources = {}, sig = "", tick = -1 }
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

-- Report a message once (errors in timers and watchers must not spam).
local reported = {}
local function report_once(msg)
  msg = tostring(msg)
  if not reported[msg] then
    reported[msg] = true
    utils.warn("transclusion: " .. msg)
  end
end

shared.ns_hide = ns_hide
shared.opts = opts
shared.enabled = enabled
shared.valid = valid
shared.state = state
shared.report_once = report_once

require("org.extensions.transclusion.regions")
require("org.extensions.transclusion.protect")
require("org.extensions.transclusion.render")
require("org.extensions.transclusion.watch")
require("org.extensions.transclusion.actions")
require("org.extensions.transclusion.save")

local protect = shared.protect
local signature = shared.signature
local later = shared.later
local update_watchers = shared.update_watchers
local stop_all = shared.stop_all
local cancel_timer = shared.cancel_timer
local unwrap_key = shared.unwrap_key
local before_write = shared.before_write
local after_write = shared.after_write
local heal = shared.heal

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
    local name = api.nvim_buf_get_name(buf)
    st.mtime = name ~= "" and source.stamp(name) or nil
    M.render(buf)
    if opts().mode == "materialized" then
      M.add_all(buf)
    end
  elseif st.tick ~= api.nvim_buf_get_changedtick(buf) or st.sig ~= source.frame(signature, st.sources) then
    M.render(buf, true)
  end
end

M.attach = attach

local function on_change(buf)
  local st = M.buffers[buf]
  if st and not st.saving then
    local ok, err = pcall(protect, buf)
    if not ok then
      report_once(err)
    end
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
        if b ~= buf and source.source_key(s.sources, path) then
          later("deps:" .. path, function()
            M.refresh_dependents(path, buf)
          end)
          break
        end
      end
    end
  end
end

local function range_marks(buf)
  local s = api.nvim_buf_get_mark(buf, "[")[1]
  local e = api.nvim_buf_get_mark(buf, "]")[1]
  if s > 0 and e >= s then
    return s, e
  end
end

--- After an edit buffer was written: refresh what transcludes `path`, or
--- render source buffer `sb` again.
---@param path? string
---@param sb? integer
local function on_written(path, sb)
  if path then
    M.refresh_dependents(path)
  elseif sb then
    M.render(sb, true)
  end
end

function M.setup()
  define_highlights()
  source.opts = opts()
  source.buffer_lines = M.clean_lines
  source.clear_cache()
  reported = {}
  edit.on_written = on_written
  edit.later = later
  require("org.lazy").on_load("org.export.hooks", "transclusion", function(hooks)
    hooks.preprocessors.transclusion = M.export_preprocess
  end)
  api.nvim_clear_autocmds({ group = augroup })
  local function guard(fn)
    return function(ev)
      local ok, err = pcall(fn, ev)
      if not ok then
        report_once(err)
      end
    end
  end
  api.nvim_create_autocmd("ColorScheme", { group = augroup, callback = define_highlights })
  api.nvim_create_autocmd({ "FileType" }, {
    group = augroup,
    pattern = "org",
    callback = guard(function(ev)
      attach(ev.buf)
    end),
  })
  api.nvim_create_autocmd({ "BufWinEnter", "BufEnter", "FocusGained" }, {
    group = augroup,
    callback = guard(function(ev)
      local buf = ev.buf ~= 0 and ev.buf or api.nvim_get_current_buf()
      heal(buf)
      attach(buf)
    end),
  })
  api.nvim_create_autocmd({ "BufLeave", "CursorHold", "FocusLost" }, {
    group = augroup,
    callback = guard(function(ev)
      heal(ev.buf ~= 0 and ev.buf or api.nvim_get_current_buf())
    end),
  })
  api.nvim_create_autocmd({ "TextChanged", "InsertLeave" }, {
    group = augroup,
    callback = guard(function(ev)
      on_change(ev.buf)
    end),
  })
  -- the buffer after :e! holds the file again
  api.nvim_create_autocmd("BufReadPost", {
    group = augroup,
    callback = guard(function(ev)
      local st = M.buffers[ev.buf]
      if st and opts().mode == "materialized" then
        vim.schedule(function()
          if M.buffers[ev.buf] == st and valid(ev.buf) then
            M.add_all(ev.buf)
          end
        end)
      end
    end),
  })
  -- A whole write is a write hook, so `:w` and org's own saves
  -- (`utils.save_buffer`) both leave the inserted text out of the file.
  -- It runs before the other hooks (crypt encrypts the file's text, not
  -- the inserted one).
  require("org.write_hooks").register("transclusion", {
    order = 10,
    pre = function(buf)
      before_write(buf)
    end,
    post = function(buf, ctx)
      after_write(buf)
      local name = api.nvim_buf_get_name(buf)
      if ctx.ok and name ~= "" then
        local ok, err = pcall(M.refresh_dependents, vim.fs.normalize(name), buf)
        if not ok then
          report_once(err)
        end
      end
    end,
  })
  -- A partial write or an append (:w >>), which Vim reports with the '[
  -- and '] marks
  api.nvim_create_autocmd({ "FileWritePre", "FileAppendPre" }, {
    group = augroup,
    callback = function(ev)
      local s, e = range_marks(ev.buf)
      if s then
        before_write(ev.buf, s, e)
      end
    end,
  })
  api.nvim_create_autocmd({ "FileWritePost", "FileAppendPost" }, {
    group = augroup,
    callback = guard(function(ev)
      after_write(ev.buf)
    end),
  })
  api.nvim_create_autocmd({ "BufUnload", "BufWipeout" }, {
    group = augroup,
    callback = function(ev)
      if M.buffers[ev.buf] then
        M.buffers[ev.buf] = nil
        cancel_timer("render:" .. ev.buf)
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

--- The lines of buffer `buf` as they are, inserted text included.
---@param buf integer
---@return string[] lines, nil
local function raw_lines(buf)
  return api.nvim_buf_get_lines(buf, 0, -1, false), nil
end

--- Undo `setup`: inserted text is removed, virtual lines cleared and the
--- edit key given back.
function M.teardown()
  api.nvim_clear_autocmds({ group = augroup })
  require("org.write_hooks").unregister("transclusion")
  for buf in pairs(M.buffers) do
    if valid(buf) then
      pcall(M.remove_all, buf)
      unwrap_key(buf)
      api.nvim_buf_clear_namespace(buf, ns, 0, -1)
      api.nvim_buf_clear_namespace(buf, ns_region, 0, -1)
      api.nvim_buf_clear_namespace(buf, ns_line, 0, -1)
      api.nvim_buf_clear_namespace(buf, ns_hide, 0, -1)
    end
  end
  M.buffers = {}
  stop_all()
  edit.close_all()
  require("org.lazy").if_loaded("org.export.hooks", "transclusion", function(hooks)
    hooks.preprocessors.transclusion = nil
  end)
  source.buffer_lines = raw_lines
  source.clear_cache()
end

function M.health(h, o)
  if o.mode ~= "virtual" and o.mode ~= "materialized" and o.mode ~= false then
    h.error(
      "transclusion: mode must be "
        .. '"virtual", "materialized" or false, not '
        .. vim.inspect(o.mode)
        .. " (nothing is shown until transclusion_add)"
    )
  else
    h.ok("transclusion: mode " .. tostring(o.mode) .. (o.watch and ", watching source files" or ""))
  end
  for _, k in ipairs({ "max_depth", "debounce" }) do
    local n = tonumber(o[k])
    if not n or n < 0 then
      h.error(string.format("transclusion: %s must be a number, 0 or more, not %s", k, vim.inspect(o[k])))
    end
  end
  local ok = pcall(vim.treesitter.language.inspect, "python")
  if ok then
    h.ok("transclusion: tree-sitter parsers colour transcluded code")
  else
    h.info("transclusion: code in virtual lines is coloured only for languages with a tree-sitter parser")
  end
end

return M
