---@mod org.extensions.lsp.inlay_hints textDocument/inlayHint
---
--- Hints drawn at the end of lines: the time clocked in each subtree
--- (org-clock-display's sums, `clock.display_default_range`), how far a
--- DEADLINE or SCHEDULED date is ("in 3 d.", "2 d. ago", the agenda's
--- wording, within the deadline warning period) and, where an Effort
--- property exists, the time clocked against it (rolled up from the
--- children like column view's `{:}` summary).

local date = require("org.date")
local util = require("org.extensions.lsp.util")

local M = {}

--- Options of the hints (`inlay_hints`), defaults filled in.
---@return { clock: boolean, countdowns: boolean, effort: boolean, clock_range: string|nil }
local function hint_opts()
  local o = util.opts().inlay_hints or {}
  return {
    clock = o.clock ~= false,
    countdowns = o.countdowns ~= false,
    effort = o.effort ~= false,
    clock_range = o.clock_range,
  }
end

local function in_range(range, lnum)
  if not range then
    return true
  end
  local l = lnum - 1
  return l >= range.start.line and l <= range["end"].line
end

local function hint(lnum, col, label, tooltip)
  return {
    position = util.pos(lnum, col),
    label = label,
    paddingLeft = true,
    tooltip = tooltip,
  }
end

--- The countdown label of a planning date `days` days from today, or nil
--- when the agenda shows no reminder for it: overdue and today always,
--- upcoming within `warn` days (org-deadline-warning-days).
---@param diff integer days from today (negative: past)
---@param warn integer
---@return string|nil
function M.countdown(diff, warn)
  if diff == 0 then
    return "today"
  elseif diff < 0 then
    return string.format("%d d. ago", -diff)
  elseif diff <= warn then
    return string.format("in %d d.", diff)
  end
end

--- Countdown hints on a headline's planning line.
local function countdowns(out, hl, lines, range, today)
  local p = hl.planning_line
  if not p or not in_range(range, p) or hl:is_done() then
    return
  end
  local line = lines[p] or ""
  local cfg_warn = require("org.config").opts.deadline_warning_days or 14
  for _, kind in ipairs({ "deadline", "scheduled" }) do
    local ts = hl.planning[kind]
    if ts and ts.active ~= false then
      local key = kind == "deadline" and "DEADLINE:" or "SCHEDULED:"
      local _, ke = line:find(key, 1, true)
      local e = ke and select(2, line:find("^%s*<[^>]*>", ke + 1))
      if e then
        local warn = kind == "deadline" and date.deadline_warning_days(ts, cfg_warn) or math.abs(cfg_warn)
        local diff = ts:days() - today
        local label = M.countdown(diff, warn)
        if label then
          local tip = (kind == "deadline" and "Deadline " or "Scheduled ")
            .. (diff == 0 and "today" or (diff > 0 and ("in " .. diff .. " days") or (-diff .. " days ago")))
          out[#out + 1] = hint(p, e + 1, label, tip)
        end
      end
    end
  end
end

--- Effort of each headline that has one, rolled up: a headline whose
--- children (or their descendants) have an Effort gets their sum, like
--- column view's `{:}` summary; else its own Effort property.
---@return table<org.Headline, integer>
local function efforts(file)
  local out = {}
  local function visit(hl)
    local sum, any = 0, false
    for _, c in ipairs(hl.children) do
      local m = visit(c)
      if m then
        sum, any = sum + m, true
      end
    end
    local m
    if any then
      m = sum
    else
      local raw = hl.properties and hl.properties.EFFORT
      m = raw and date.parse_duration(raw) or nil
    end
    if m then
      out[hl] = m
    end
    return m
  end
  for _, hl in ipairs(file.children) do
    visit(hl)
  end
  return out
end

--- textDocument/inlayHint: the hints of the lines in `params.range`.
---@param doc org.lsp.Doc
---@param params table
---@return table[] InlayHint[]
function M.hints(doc, params)
  local o = hint_opts()
  local range = params and params.range
  local file, lines = doc.file, doc.lines
  local out = {}
  local clock, shared
  if o.clock or o.effort then
    clock = require("org.clock")
    shared = require("org.clock.shared")
  end
  local sums, all_time, effort
  if o.clock and clock and shared then
    local key = o.clock_range or (require("org.config").opts.clock or {}).display_default_range or "thisyear"
    local from, to = clock.special_range(key)
    sums = shared.clock_sum(file.children, from, to)
  end
  if o.effort and shared then
    effort = efforts(file)
    if next(effort) then
      all_time = shared.clock_sum(file.children)
    end
  end
  local today = date.today():days()
  for _, hl in ipairs(file.headlines) do
    if not (doc.foreign and doc.foreign[hl.line]) then
      if in_range(range, hl.line) then
        local col = #(lines[hl.line] or "") + 1
        local m = sums and sums[hl]
        if m and m > 0 then
          out[#out + 1] = hint(hl.line, col, "clocked " .. date.duration_to_string(m), "Time clocked in the subtree")
        end
        local e = effort and effort[hl]
        if e then
          local spent = all_time and all_time[hl] or 0
          local label = string.format("effort %s/%s", date.duration_to_string(spent), date.duration_to_string(e))
          if spent > e then
            label = label .. " over"
          end
          out[#out + 1] = hint(hl.line, col, label, "Time clocked against the Effort estimate")
        end
      end
      if o.countdowns then
        countdowns(out, hl, lines, range, today)
      end
    end
  end
  -- headline hints come in line order; the countdowns of a planning
  -- line go after their headline's, so a stable insertion keeps it so
  local sorted = {}
  for i, h in ipairs(out) do
    h._i = i
    sorted[i] = h
  end
  table.sort(sorted, function(a, b)
    if a.position.line ~= b.position.line then
      return a.position.line < b.position.line
    end
    return a._i < b._i
  end)
  for _, h in ipairs(sorted) do
    h._i = nil
  end
  return sorted
end

---------------------------------------------------------------------------
-- Refreshing
---------------------------------------------------------------------------

local function supports(srv, kind)
  local w = srv.client_capabilities and srv.client_capabilities.workspace
  return type(w) == "table" and type(w[kind]) == "table" and w[kind].refreshSupport == true
end

--- Ask the client to request the inlay hints and code lenses again
--- (`workspace/inlayHint/refresh`, `workspace/codeLens/refresh`) when
--- something they show changed outside the document's text: a clock
--- started, stopped or was cancelled.
---@param srv table the server state
---@param dispatchers table vim.lsp.rpc.Dispatchers
function M.watch(srv, dispatchers)
  local group = vim.api.nvim_create_augroup("org.lsp.refresh." .. tostring(srv), { clear = true })
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = { "OrgClockIn", "OrgClockOut", "OrgClockCancel" },
    callback = function()
      if srv.closing then
        pcall(vim.api.nvim_del_augroup_by_id, group)
        return
      end
      -- after the clock's own edits are done
      vim.schedule(function()
        M.refresh(srv, dispatchers)
      end)
    end,
  })
end

--- Send the refresh requests the client supports.
function M.refresh(srv, dispatchers)
  if srv.closing or not srv.initialized then
    return
  end
  local f = util.opts().features or {}
  if f.inlay_hints ~= false and supports(srv, "inlayHint") then
    -- lint: allow pcall: a request to Neovim's LSP client, which may be stopping
    pcall(dispatchers.server_request, "workspace/inlayHint/refresh", vim.NIL)
  end
  if f.code_lens ~= false then
    if supports(srv, "codeLens") then
      -- lint: allow pcall: a request to Neovim's LSP client, which may be stopping
      pcall(dispatchers.server_request, "workspace/codeLens/refresh", vim.NIL)
    else
      M.refresh_lenses()
    end
  end
end

--- Neovim 0.11 has no `workspace/codeLens/refresh`: ask again for the
--- lenses of the org buffers that show some (those the user turned on
--- with `vim.lsp.codelens.refresh()`), so a "Clock in" lens says "Clock out".
function M.refresh_lenses()
  -- the 0.11 API (get(bufnr), refresh()), deprecated in later versions
  local cl = vim.lsp.codelens --[[@as table]]
  if type(cl.refresh) ~= "function" or type(cl.get) ~= "function" then
    return
  end
  for _, c in ipairs(vim.lsp.get_clients({ name = "org" })) do
    for b in pairs(c.attached_buffers or {}) do
      if vim.api.nvim_buf_is_loaded(b) and #cl.get(b) > 0 then
        pcall(cl.refresh, { bufnr = b })
      end
    end
  end
end

--- Add the request handler to the server's table.
---@param requests table<string, function>
---@param doc_or_err fun(params: table): org.lsp.Doc
function M.register(requests, doc_or_err)
  requests["textDocument/inlayHint"] = function(_, params)
    return M.hints(doc_or_err(params), params)
  end
end

return M
