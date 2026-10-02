-- Visibility after startup and TAB/S-TAB, compared with Emacs Org 9.8.10
-- (tests/fixtures/emacs/visibility, scripts/emacs-parity/visibility.el).

local P = require("tests.emacs_parity")
local fold = require("org.fold")

local dir = P.dir .. "/visibility"

-- Cases that still differ from Emacs, with the reason. A case listed here
-- must keep failing (remove it once it matches).
local KNOWN = {}

local function run(file, cmds)
  vim.cmd("silent! only!")
  vim.cmd("silent! %bwipeout!")
  vim.cmd("edit " .. vim.fn.fnameescape(dir .. "/" .. file))
  local last
  -- the cycling messages (FOLDED, CHILDREN, ...) would clutter the output
  local echo = vim.api.nvim_echo
  vim.api.nvim_echo = function() end
  local okc, err = pcall(function()
    for _, c in ipairs(cmds) do
      if c:sub(1, 1) == "L" then
        vim.api.nvim_win_set_cursor(0, { tonumber(c:sub(2)), 0 })
      elseif c == "T" then
        -- like Emacs' last-command: any other command ends a TAB cycle
        if last ~= "T" then
          vim.w.org_last_cycle = nil
        end
        fold.cycle()
      elseif c == "S" then
        if last ~= "S" then
          vim.w.org_last_global = nil
        end
        fold.global_cycle()
      else
        error("unknown command " .. c)
      end
      last = c
    end
  end)
  vim.api.nvim_echo = echo
  assert(okc, err)
  local out = {}
  for l = 1, vim.fn.line("$") do
    out[#out + 1] = (fold.line_visible(l) and "v " or "h ") .. vim.fn.getline(l)
  end
  vim.cmd("silent! %bwipeout!")
  return out
end

describe("visibility matches Emacs", function()
  P.freeze_time()
  local expected = P.sections(dir .. "/expected.txt")
  for _, case in ipairs(P.cases(dir .. "/cases.txt")) do
    local name, file = case[1], case[2]
    local cmds = vim.list_slice(case, 3)
    if cmds[1] == "-" then
      cmds = {}
    end
    it(name, function()
      ok(expected[name], "no Emacs output for " .. name .. " (run make parity-fixtures)")
      P.compare(expected[name].lines, run(file, cmds), KNOWN[name])
    end)
  end
end)
