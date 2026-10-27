-- The faces of tables (org-table, org-formula) drawn by the parser
-- highlighter (org.ui.highlight.table), against Emacs Org 9.8.12 on every
-- byte of the fixtures (tests/helpers/faces.lua).
local KNOWN = {
  ["examples-17-babel.org"] = {
    -- the body of a #+begin_src org block: Emacs fontifies it natively
    -- (org-src-fontify-natively, with Org itself); org.nvim draws a src
    -- block's body with the syntax of its language
    [531] = "native fontification of an org src block",
    [532] = "native fontification of an org src block",
  },
}

describe("Emacs faces: tables", function()
  with_config({ ui = { highlighter = "parser", hide_emphasis_markers = true } })
  require("tests.helpers.faces").spec("table", KNOWN)
end)
