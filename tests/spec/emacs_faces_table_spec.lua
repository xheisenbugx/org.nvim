-- The faces of tables (org-table, org-formula) drawn by the parser
-- highlighter (org.ui.highlight.table), against Emacs Org 9.8.12 on every
-- byte of the fixtures (tests/helpers/faces.lua).
local KNOWN = {}

describe("Emacs faces: tables", function()
  with_config({ ui = { hide_emphasis_markers = true } })
  require("tests.helpers.faces").spec("table", KNOWN)
end)
