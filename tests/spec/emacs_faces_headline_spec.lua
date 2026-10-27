-- The headline faces org.nvim draws with the parser highlighter (levels,
-- TODO keywords, priorities, tags, COMMENT, ARCHIVE, inline tasks), byte
-- by byte against Emacs Org 9.8.12 (tests/helpers/faces.lua).
local F = require("tests.helpers.faces")

--- Lines left out, per fixture: line -> reason.
local KNOWN = {}

-- Export snippets ("@@html:...@@") draw their back-end in org-tag, a face
-- this family shares with the object family, which draws snippets: their
-- lines (other than headlines) are left out here until the parts are
-- merged.
local P = require("tests.emacs_parity")
for _, dir in ipairs({ "examples", "tests/fixtures/emacs/fontify", "tests/fixtures/emacs/faces" }) do
  for _, path in ipairs(vim.fn.globpath(P.root .. "/" .. dir, "*.org", false, true)) do
    local name = dir:gsub("/", "-") .. "-" .. vim.fn.fnamemodify(path, ":t")
    for l, line in ipairs(vim.fn.readfile(path)) do
      if line:find("@@", 1, true) and not line:find("^%*+ ") then
        KNOWN[name] = KNOWN[name] or {}
        KNOWN[name][l] = "export snippet back-end (object family)"
      end
    end
  end
end

describe("Emacs faces: headline", function()
  -- (inlinetask_min_level: the fixtures are made with org-inlinetask
  -- loaded, whose minimum level is 15)
  with_config({ inlinetask_min_level = 15, ui = { highlighter = "parser", hide_emphasis_markers = true } })
  F.spec("headline", KNOWN)
end)
