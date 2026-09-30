---@mod org.extensions.lsp.diagnostics org-lint reports as diagnostics

local util = require("org.extensions.lsp.util")

local M = {}

local SEVERITY = { error = 1, warning = 2, information = 3, info = 3, hint = 4 }

local function severity(name)
  if type(name) == "number" then
    return name
  end
  return SEVERITY[tostring(name):lower()] or 2
end

--- The checkers to run: `diagnostics.checkers` (default: org-lint's
--- default set) minus `diagnostics.exclude`.
---@return string[]
function M.checkers()
  local lint = require("org.lint")
  local o = util.opts().diagnostics or {}
  local names = o.checkers or lint.checker_names()
  local skip = {}
  for _, n in ipairs(o.exclude or {}) do
    skip[n] = true
  end
  return vim.tbl_filter(function(n)
    return not skip[n]
  end, names)
end

--- Diagnostics of a buffer.
---@param bufnr integer
---@return table[] Diagnostic[]
function M.compute(bufnr)
  local o = util.opts().diagnostics or {}
  local sev = o.severity or {}
  local reports = require("org.lint").lint(bufnr, M.checkers())
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local out = {}
  for _, r in ipairs(reports) do
    local lnum = math.max(1, math.min(r.lnum, #lines))
    local line = lines[lnum] or ""
    local col = math.max(1, math.min(r.col, #line + 1))
    -- up to the end of the word at the column (or the line)
    local e = line:find("%s", col) or (#line + 1)
    if e <= col then
      e = #line + 1
    end
    local s_ = (sev.checkers or {})[r.checker] or (r.trust == "low" and sev.low or sev.high)
    out[#out + 1] = {
      range = { start = util.pos(lnum, col), ["end"] = util.pos(lnum, e) },
      severity = severity(s_ or (r.trust == "low" and "Warning" or "Error")),
      source = "org-lint",
      code = r.checker,
      message = r.message:gsub("%s*\n%s*", " "),
      data = { checker = r.checker, lnum = r.lnum, col = r.col },
    }
  end
  return out
end

--- Debounced publisher: `schedule(bufnr, delay?)` lints the buffer after
--- `diagnostics.debounce` ms without changes and calls `publish(uri,
--- diagnostics)`.
---@param publish fun(uri: string, diagnostics: table[])
function M.scheduler(publish)
  local uv = vim.uv or vim.loop
  local timers = {}
  local self = {}
  function self.cancel(bufnr)
    local t = timers[bufnr]
    if t then
      timers[bufnr] = nil
      if not t:is_closing() then
        t:stop()
        t:close()
      end
    end
  end
  function self.run(bufnr)
    if not vim.api.nvim_buf_is_valid(bufnr) or not vim.api.nvim_buf_is_loaded(bufnr) then
      return
    end
    local uri = vim.uri_from_bufnr(bufnr)
    local ok, diags = pcall(M.compute, bufnr)
    if not ok then
      diags = {
        {
          range = { start = { line = 0, character = 0 }, ["end"] = { line = 0, character = 0 } },
          severity = 1,
          source = "org-lint",
          message = "org-lint failed: " .. tostring(diags),
        },
      }
    end
    publish(uri, diags)
  end
  function self.schedule(bufnr, delay)
    local o = util.opts().diagnostics or {}
    self.cancel(bufnr)
    local t = uv.new_timer()
    timers[bufnr] = t
    t:start(
      delay or o.debounce or 500,
      0,
      vim.schedule_wrap(function()
        if timers[bufnr] ~= t then
          return
        end
        self.cancel(bufnr)
        self.run(bufnr)
      end)
    )
  end
  function self.clear(bufnr)
    self.cancel(bufnr)
    if vim.api.nvim_buf_is_valid(bufnr) then
      publish(vim.uri_from_bufnr(bufnr), {})
    end
  end
  function self.stop()
    for b in pairs(timers) do
      self.cancel(b)
    end
  end
  return self
end

return M
