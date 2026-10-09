-- The org.nvim side of the differential test: for an Org file, what each
-- oracle prints. scripts/emacs-parity/difftest.el prints the same things
-- with Emacs Org 9.8.10; keep the two in step.
--
--   export-<backend>  ox.export_as(backend), body only, Babel off
--   agenda            "=== <view>" + the text of a few views over the file
--   table             the buffer after recalculating every table with a
--                     #+TBLFM line, top down
--   visibility        "=== <step>" + "v"/"h" per line at startup and after
--                     each of three S-TABs
--
-- Run them inside M.frozen(): Emacs' "now" and time zone.

local P = require("tests.emacs_parity")

local M = {}

M.EXPORT = { "export-html", "export-ascii", "export-md", "export-latex", "export-org" }
M.ALL = vim.list_extend(vim.deepcopy(M.EXPORT), { "agenda", "table", "visibility" })

--- The NORMALISE area (tests/emacs_parity.lua) whose rules apply to an
--- oracle's output.
function M.area(oracle)
  if oracle:match("^export%-") then
    return "export"
  end
  return oracle
end

--- Run `fn` with "now" frozen at Emacs' (P.NOW, zone P.TZ).
function M.frozen(fn)
  local date = require("org.date")
  local saved = { tz = vim.env.TZ, time = os.time, date = os.date }
  date.set_tz(P.TZ)
  local real_time, real_date = os.time, os.date
  local now = real_time(P.NOW)
  os.time = function(t)
    if t == nil then
      return now
    end
    return real_time(t)
  end
  os.date = function(fmt, t)
    return real_date(fmt or "%c", t or now)
  end
  local res = { pcall(fn) }
  os.time, os.date = saved.time, saved.date
  date.set_tz(saved.tz)
  if not res[1] then
    error(res[2], 0)
  end
  return unpack(res, 2)
end

--- Babel off, and broken links marked instead of aborting the export
--- (as difftest.el sets Emacs)
local function export(backend, file)
  local ox = require("org.export.ox")
  local o = require("org.config").opts
  local saved = { o.babel.evaluate_on_export, o.export.with_broken_links }
  o.babel.evaluate_on_export, o.export.with_broken_links = false, "mark"
  local okc, res = pcall(ox.export_as, backend, vim.fn.readfile(file), { filename = file, body_only = true })
  o.babel.evaluate_on_export, o.export.with_broken_links = saved[1], saved[2]
  if not okc then
    error(res, 0)
  end
  return res
end

-- Emacs renders the views in a batch frame 80 columns wide
local WIDTH = 80

local VIEWS = {
  {
    "week",
    function(a, date)
      a.open_agenda({ span = "week", anchor = date.read_date("2026-09-28"):days() })
    end,
  },
  {
    "day",
    function(a, date)
      a.open_agenda({ span = "day", anchor = date.read_date("2026-10-01"):days() })
    end,
  },
  {
    "todo",
    function(a)
      a.open_todo(nil)
    end,
  },
  {
    "tags",
    function(a)
      a.open_tags("work|@ctx", false)
    end,
  },
  {
    "tags-todo",
    function(a)
      a.open_tags("home", true)
    end,
  },
}

local function agenda(file)
  local config = require("org.config")
  local a = require("org.agenda")
  local view = require("org.agenda.view")
  local date = require("org.date")
  local saved = { config.opts.agenda_files, config.opts.agenda.show_current_time_in_grid }
  config.opts.agenda_files = { file }
  -- the current-time line depends on the clock: off on both sides
  config.opts.agenda.show_current_time_in_grid = false
  local out = {}
  local okc, err = pcall(function()
    for _, v in ipairs(VIEWS) do
      out[#out + 1] = "=== " .. v[1]
      local okv, e = pcall(v[2], a, date)
      if okv then
        vim.list_extend(out, view.build(WIDTH).lines)
      else
        out[#out + 1] = "!error " .. tostring(e)
      end
      vim.cmd("silent! %bwipeout!")
    end
  end)
  config.opts.agenda_files, config.opts.agenda.show_current_time_in_grid = saved[1], saved[2]
  assert(okc, err)
  return table.concat(out, "\n") .. "\n"
end

--- A scratch buffer holding `file`'s lines, with filetype org.
local function scratch(file)
  vim.cmd("silent! %bwipeout!")
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_set_current_buf(buf)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.fn.readfile(file))
  vim.bo[buf].filetype = "org"
  return buf
end

local function tables(file)
  local tbl = require("org.table")
  local buf = scratch(file)
  -- the warnings of a formula that fails are not output
  local l = 1
  while l <= vim.api.nvim_buf_line_count(buf) do
    local line = vim.api.nvim_buf_get_lines(buf, l - 1, l, false)[1]
    local info = line:match("^%s*|") and tbl.find(buf, l)
    if info then
      if #info.tblfm > 0 then
        tbl.recalc(buf, l)
        info = tbl.find(buf, l)
      end
      l = (info.tblfm[#info.tblfm] or info.finish) + 1
    else
      l = l + 1
    end
  end
  local out = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n") .. "\n"
  vim.cmd("silent! %bwipeout!")
  return out
end

local function visibility(file)
  local fold = require("org.fold")
  vim.cmd("silent! only!")
  vim.cmd("silent! %bwipeout!")
  vim.cmd("edit " .. vim.fn.fnameescape(file))
  local out = {}
  local function dump(name)
    out[#out + 1] = "=== " .. name
    for l = 1, vim.fn.line("$") do
      out[#out + 1] = (fold.line_visible(l) and "v " or "h ") .. vim.fn.getline(l)
    end
  end
  dump("startup")
  vim.w.org_last_global = nil
  for i = 1, 3 do
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    fold.global_cycle()
    dump("S" .. i)
  end
  vim.cmd("silent! %bwipeout!")
  return table.concat(out, "\n") .. "\n"
end

--- What `oracle` prints for `file` ("!error <message>" if it raised).
---@param oracle string
---@param file string
---@return string
function M.run(oracle, file)
  local okr, res = pcall(function()
    -- messages and warnings (unknown macros, failed formulas) are not
    -- output, and an :echo would wait for Enter
    local utils = require("org.utils")
    local saved = { utils.notify, utils.warn, vim.api.nvim_echo }
    utils.notify = function() end
    utils.warn = function() end
    vim.api.nvim_echo = function() end
    local okc, r = pcall(function()
      if oracle:match("^export%-") then
        return export(oracle:sub(8), file)
      elseif oracle == "agenda" then
        return agenda(file)
      elseif oracle == "table" then
        return tables(file)
      elseif oracle == "visibility" then
        return visibility(file)
      end
      error("unknown oracle " .. oracle)
    end)
    utils.notify, utils.warn, vim.api.nvim_echo = saved[1], saved[2], saved[3]
    if not okc then
      error(r, 0)
    end
    return r
  end)
  if not okr then
    return "!error " .. tostring(res):gsub("\n", " ") .. "\n"
  end
  return res
end

return M
