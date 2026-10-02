-- Exports of examples/*.org compared with Emacs Org 9.8.10 (tests/fixtures/
-- emacs/export, scripts/emacs-parity/export.el): body only, Babel not
-- evaluated, one test per file and backend.

local P = require("tests.emacs_parity")
local ox = require("org.export.ox")
local config = require("org.config")

local dir = P.dir .. "/export"
local EXT = { ascii = "txt", html = "html", latex = "tex", md = "md" }

-- "<file> <backend>" cases that still differ from Emacs, with the reason.
-- A case listed here must keep failing (remove it once it matches).
local ATTACH = "attachment: links are not expanded to file: links on export "
  .. "(Emacs: org-attach-expand-links in org-export-before-parsing-functions)"
local KNOWN = {
  ["21-images-latex ascii"] = ATTACH,
  ["21-images-latex md"] = ATTACH,
}

describe("export matches Emacs", function()
  P.freeze_time()
  local saved
  before_each(function()
    local o = config.opts
    saved = { o.babel.evaluate_on_export }
    o.babel.evaluate_on_export = false
    -- "Reference ... cannot be resolved without publishing" and the like
    require("org.utils").notify = function() end
  end)
  after_each(function()
    local o = config.opts
    o.babel.evaluate_on_export = saved[1]
  end)
  for _, case in ipairs(P.cases(dir .. "/cases.txt")) do
    local file = P.root .. "/" .. case[1]
    local name = vim.fn.fnamemodify(file, ":t:r")
    for i = 2, #case do
      local backend = case[i]
      local key = name .. " " .. backend
      it(key, function()
        local expected = P.lines(P.read(dir .. "/" .. name .. "." .. EXT[backend]))
        local out = ox.export_as(backend, vim.fn.readfile(file), { filename = file, body_only = true })
        -- the repository root in paths as @ROOT@/, like the generator
        out = out:gsub(vim.pesc(P.root .. "/"), "@ROOT@/")
        local e, o = P.normalise("export", expected, P.lines(out))
        P.compare(e, o, KNOWN[key])
      end)
    end
  end
end)
