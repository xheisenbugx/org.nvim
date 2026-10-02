-- Clock tables compared with Emacs Org 9.8.10 (tests/fixtures/emacs/
-- clocktable, scripts/emacs-parity/clocktable.el): every dynamic block of
-- tables.org updated, one test per block.

local P = require("tests.emacs_parity")
local dblock = require("org.dblock")

local dir = P.dir .. "/clocktable"

-- Blocks (by their #+BEGIN: line) that still differ from Emacs, with the
-- reason. A block listed here must keep failing (remove it once fixed).
local KNOWN = {}

--- The dynamic blocks of `lines`: a list of { head = "#+BEGIN: ...", lines = {...} }.
local function blocks(lines)
  local out, cur = {}, nil
  for _, l in ipairs(lines) do
    if l:match("^#%+BEGIN:") then
      cur = { head = l, lines = { l } }
    elseif cur then
      cur.lines[#cur.lines + 1] = l
      if l:match("^#%+END:") then
        out[#out + 1] = cur
        cur = nil
      end
    end
  end
  return out
end

local updated

--- Our tables.org with every block updated (computed once), the fixture
--- directory in links written as @DIR@/ like the generator does.
local function ours()
  if not updated then
    vim.cmd("silent! %bwipeout!")
    vim.cmd("edit " .. vim.fn.fnameescape(dir .. "/tables.org"))
    local buf = vim.api.nvim_get_current_buf()
    dblock.update_all(buf)
    local prefix = vim.fs.normalize(vim.fn.fnamemodify(dir, ":p")):gsub("/?$", "/")
    updated = {}
    for i, l in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
      updated[i] = (l:gsub(vim.pesc(prefix), "@DIR@/"))
    end
    vim.cmd("silent! bwipeout!")
  end
  return updated
end

describe("clock tables match Emacs", function()
  P.freeze_time()
  local expected = blocks(P.lines(P.read(dir .. "/tables.expected.org")))
  for i, b in ipairs(expected) do
    it(i .. ": " .. b.head, function()
      local mine = blocks(ours())
      ok(mine[i] and mine[i].head == b.head, "block " .. i .. " not found")
      P.compare(b.lines, mine[i].lines, KNOWN[b.head])
    end)
  end
end)
