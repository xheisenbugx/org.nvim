-- org-lint reports compared with Emacs Org 9.8.10 (tests/fixtures/emacs/
-- lint, scripts/emacs-parity/lint.el): every default checker over
-- examples/*.org and tests/fixtures/emacs/lint/*.org, one test per file.

local P = require("tests.emacs_parity")
local lint = require("org.lint")

-- Files whose reports still differ from Emacs, with the reason. A file
-- listed here must keep failing (remove it once it matches).
local KNOWN = {}

local function reports(rel)
  vim.cmd("silent! %bwipeout!")
  vim.cmd("edit " .. vim.fn.fnameescape(P.root .. "/" .. rel))
  local out = {}
  for _, r in ipairs(lint.lint(0)) do
    out[#out + 1] = string.format("%d:%d [%s] %s", r.lnum, r.col, r.checker, (r.message:gsub("\n", " ")))
  end
  vim.cmd("silent! bwipeout!")
  return out
end

describe("org-lint matches Emacs", function()
  P.freeze_time()
  before_each(function()
    -- like the generator's empty ID database
    require("org.id").locations = {}
  end)
  for _, s in ipairs(P.sections(P.dir .. "/lint/expected.txt")) do
    it(s.name, function()
      local e, o = P.normalise("lint", s.lines, reports(s.name))
      P.compare(e, o, KNOWN[s.name])
    end)
  end
end)
