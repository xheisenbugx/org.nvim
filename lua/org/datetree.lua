---@mod org.datetree Date tree maintenance
---
--- Date trees themselves are built by `org.capture` (`ensure_datetree`),
--- also for archiving. This module holds the commands working on a whole
--- tree.

local files = require("org.files")
local utils = require("org.utils")

local M = {}

local ns = vim.api.nvim_create_namespace("org_datetree_cleanup")
local TS = "<(%d%d%d%d)%-(%d%d)%-(%d%d)[^<>\n]*>"

--- The next active time stamp at or after (lnum, col): lnum, start col,
--- end col, year, month, day.
local function next_stamp(bufnr, lnum, col)
  local n = vim.api.nvim_buf_line_count(bufnr)
  while lnum <= n do
    local line = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1]
    local s, e, y, m, d = line:find(TS, col)
    if s then
      return lnum, s, e, tonumber(y), tonumber(m), tonumber(d), line
    end
    lnum, col = lnum + 1, 1
  end
end

--- Move every entry of a date tree under the day node of its time stamp
--- (org-datetree-cleanup). An entry is the headline an active time stamp
--- belongs to, when its parent is a day node (`YYYY-MM-DD`); the end of a
--- range and SCHEDULED / DEADLINE stamps are skipped. Moved entries become
--- the last child of their day, which is created when missing.
---@param bufnr? integer
function M.cleanup(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local capture = require("org.capture")
  local refile = require("org.refile")
  local lnum, col = 1, 1
  local moved = 0
  while moved < 10000 do
    local l, s, e, y, m, d, line = next_stamp(bufnr, lnum, col)
    if not l then
      break
    end
    lnum, col = l, e + 1
    local before = line:sub(1, s - 1)
    local hl = not before:match("%-$")
      and not before:match("SCHEDULED:%s*$")
      and not before:match("DEADLINE:%s*$")
      and files.get_buffer(bufnr):headline_at(l)
    local parent = hl and hl.parent
    local ptitle = parent and vim.api.nvim_buf_get_lines(bufnr, parent.line - 1, parent.line, false)[1]
    if ptitle and ptitle:match("^%*+[ \t]+%d%d%d%d%-[01]%d%-[0-3]%d") then
      local want = string.format("%d-%02d-%02d", y, m, d)
      if not ptitle:match("^%*+[ \t]+" .. vim.pesc(want)) then
        local lines = vim.api.nvim_buf_get_lines(bufnr, hl.line - 1, hl.end_line, false)
        vim.api.nvim_buf_set_lines(bufnr, hl.line - 1, hl.end_line, false, {})
        -- scanning goes on where the entry was, as that position moves
        -- (a marker: text inserted there comes after it)
        local row, c = hl.line - 1, 0
        local count = vim.api.nvim_buf_line_count(bufnr)
        if row >= count then
          row = count - 1
          c = #vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1]
        end
        local mark = vim.api.nvim_buf_set_extmark(bufnr, ns, row, c, { right_gravity = false })
        local day = capture.ensure_datetree(bufnr, nil, require("org.date").Date.new({ year = y, month = m, day = d }))
        refile.insert_subtree(lines, { bufnr = bufnr, lnum = day })
        local pos = vim.api.nvim_buf_get_extmark_by_id(bufnr, ns, mark, {})
        vim.api.nvim_buf_del_extmark(bufnr, ns, mark)
        lnum, col = pos[1] + 1, 1
        moved = moved + 1
      end
    end
  end
  utils.notify(moved == 0 and "Date tree entries are under their dates" or ("Moved " .. moved .. " date tree entries"))
  return moved
end

return M
